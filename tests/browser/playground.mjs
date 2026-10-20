// End to end: the playground's Submit builds the editor's sample on this
// backend, and the frame runs the build; the header names the versions
// builds use; and a compile error is underlined where the compiler says.
// Usage: SITE=<assembler-chat dir> node playground.mjs
//   after `zig build` here and `zig build` in assembler-chat (whose default
//   backend URL, http://localhost:8080, is where this starts the backend).
// Serves the app, starts zig-out/bin/assembler-backend on :8080 with this
// origin allowed, clicks Submit, waits for the sample to render in the
// frame, and fails on any exception or console error in page or frame.
// Node >= 22, Chrome.
import { spawn } from "node:child_process";
import { createServer, request } from "node:http";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const siteDir = resolve(process.env.SITE);
const backendExe = resolve(dirname(fileURLToPath(import.meta.url)), "../../zig-out/bin/assembler-backend");
const backendPort = 8080;
// A cold zig cache makes the first build take a while.
const buildTimeoutMs = 120_000;

// ── server ──────────────────────────────────────────────────────────────────

const mime = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript",
  ".wasm": "application/wasm",
  ".css": "text/css",
  ".svg": "image/svg+xml",
  ".webp": "image/webp",
  ".jpg": "image/jpeg",
  ".png": "image/png",
  ".woff2": "font/woff2",
  ".json": "application/json",
};

function serve(req, res) {
  let path = decodeURIComponent(new URL(req.url, "http://x").pathname);
  if (path === "/bundle.min.js" || path === "/browser.min.js") path = "/zig-out/bin" + path;
  const file = normalize(join(siteDir, path));
  if (!file.startsWith(siteDir)) return res.writeHead(400).end();
  if (extname(path)) {
    if (!existsSync(file) || !statSync(file).isFile()) return res.writeHead(404).end("not found");
    res.writeHead(200, { "content-type": mime[extname(path)] ?? "application/octet-stream" });
    return res.end(readFileSync(file));
  }
  // Routes are client-side: every extensionless path gets the app shell.
  res.writeHead(200, { "content-type": mime[".html"] });
  res.end(readFileSync(join(siteDir, "template.html")));
}

// ── backend ─────────────────────────────────────────────────────────────────

const ping = () => new Promise((resolve) => {
  const req = request({ host: "127.0.0.1", port: backendPort, path: "/" }, (res) => {
    res.resume();
    resolve(res.statusCode === 200);
  });
  req.on("error", () => resolve(false));
  req.end();
});

async function startBackend(origin) {
  if (!existsSync(backendExe)) throw new Error(`missing ${backendExe}; run \`zig build\` in assembler-backend`);
  if (await ping()) throw new Error(`something already answers on :${backendPort}; stop it first`);
  const builds = mkdtempSync(join(tmpdir(), "assembler-builds-"));
  const proc = spawn(backendExe, [], {
    cwd: resolve(dirname(backendExe), "../.."),
    env: { ...process.env, PORT: String(backendPort), ALLOWED_ORIGIN: origin, BUILDS_DIR: builds },
    stdio: ["ignore", "inherit", "inherit"],
  });
  for (let i = 0; i < 100; i++) {
    if (await ping()) {
      return () => {
        proc.kill("SIGTERM");
        rmSync(builds, { recursive: true, force: true });
      };
    }
    await sleep(100);
  }
  proc.kill();
  throw new Error("the backend did not start");
}

// ── chrome + CDP ────────────────────────────────────────────────────────────

function findChrome() {
  const found = [
    process.env.CHROME,
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  ].filter(Boolean).find((c) => existsSync(c));
  if (!found) throw new Error("Chrome not found; set $CHROME");
  return found;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function launch() {
  const profile = mkdtempSync(join(tmpdir(), "vapor-ui-test-"));
  const port = 9200 + Math.floor(Math.random() * 700);
  const proc = spawn(findChrome(), [
    "--headless=new",
    "--disable-gpu",
    "--no-first-run",
    "--no-default-browser-check",
    "--no-sandbox", // CI containers run as root
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${profile}`,
    "about:blank",
  ], { stdio: "ignore" });

  let targets;
  for (let i = 0; i < 100 && !targets; i++) {
    try {
      targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
    } catch {
      await sleep(100);
    }
  }
  if (!targets) throw new Error("Chrome did not start");
  const ws = new WebSocket(targets.find((t) => t.type === "page").webSocketDebuggerUrl);
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });

  let nextId = 0;
  const pending = new Map();
  // Exceptions and console errors/warnings from the page and its frame.
  const problems = [];
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    } else if (msg.method === "Runtime.exceptionThrown") {
      const d = msg.params.exceptionDetails;
      problems.push(`exception: ${(d.exception?.description ?? d.text).split("\n").slice(0, 6).join("\n        ")}`);
    } else if (msg.method === "Runtime.consoleAPICalled") {
      // vapor reports its problems through console.log with an [ERROR] or
      // [WARN] label.
      const text = msg.params.args.map((a) => a.value ?? a.description).join(" ");
      if (msg.params.type === "error" || msg.params.type === "warning" || /\[%c(ERROR|WARN)%c\]/.test(text)) {
        problems.push(`console.${msg.params.type}: ${text.replace(/%c/g, "").slice(0, 300)}`);
      }
    }
  };
  const send = (method, params = {}) => new Promise((res, rej) => {
    const id = ++nextId;
    pending.set(id, (m) => (m.error ? rej(new Error(`${method}: ${m.error.message}`)) : res(m.result)));
    ws.send(JSON.stringify({ id, method, params }));
  });
  await send("Runtime.enable");
  await send("Page.enable");
  await send("Emulation.setDeviceMetricsOverride", { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });

  const close = () => {
    ws.close();
    proc.kill();
    try { rmSync(profile, { recursive: true, force: true }); } catch {}
  };
  return { send, problems, close };
}

// ── the test ────────────────────────────────────────────────────────────────

const server = createServer(serve);
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const origin = `http://127.0.0.1:${server.address().port}`;
const stopBackend = await startBackend(origin);
const cdp = await launch();

const evaluate = async (expression) => {
  const r = await cdp.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
  return r.result.value;
};
const waitFor = async (expression, what, timeout) => {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (await evaluate(expression).catch(() => false)) return;
    await sleep(100);
  }
  throw new Error(`timed out after ${timeout} ms waiting for ${what}`);
};
const frameText = `(document.getElementById("playground-frame")?.contentDocument?.body?.innerText ?? "")`;

let failure;
try {
  await cdp.send("Page.navigate", { url: origin + "/playground" });
  await waitFor(`document.documentElement.hasAttribute("data-vapor-ready")`, "the app", 10_000);
  const before = await evaluate(frameText);

  const clicked = await evaluate(`(() => {
    const text = [...document.querySelectorAll("button *")].find((e) => e.textContent.trim().startsWith("Submit"));
    text?.closest("button").click();
    return !!text;
  })()`);
  if (!clicked) throw new Error("no Submit button");

  const started = Date.now();
  // main_sample.zig's heading.
  await waitFor(`${frameText}.includes("Vapor")`, "the sample to render in the frame", buildTimeoutMs);
  const frame = await evaluate(`({
    path: document.getElementById("playground-frame").contentWindow.location.pathname,
    nodes: document.getElementById("playground-frame").contentDocument.querySelectorAll("#contents *").length,
  })`);
  console.log(`frame before Submit: ${JSON.stringify(before.slice(0, 80))}`);
  console.log(`rendered in ${Date.now() - started} ms: path ${frame.path}, ${frame.nodes} elements`);
  if (frame.path !== "/") throw new Error(`the frame's app is at ${frame.path}, not /`);
  // Let late errors (hooks, a second render) arrive.
  await sleep(1000);
  if (cdp.problems.length) throw new Error(`page errors:\n  ${[...new Set(cdp.problems)].join("\n  ")}`);

  const versions = await (await fetch(`http://127.0.0.1:${backendPort}/api/wasm/versions`)).json();
  await waitFor(
    `document.body.innerText.includes("Zig Version: ${versions.zig}") && document.body.innerText.includes("Vapor Version: ${versions.vapor}")`,
    `the header to show zig ${versions.zig} and vapor ${versions.vapor}`,
    10_000,
  );

  // An error past line 255, which a u8 line number cannot reach.
  const broken = [
    'const Vapor = @import("vapor");',
    ...Array.from({ length: 296 }, (_, i) => `// filler ${i}`),
    "export fn init() void {",
    "    Vapor.init(.{});",
    "    notDeclared();",
    "}",
    "",
  ].join("\n");
  await evaluate(`(() => {
    const editor = document.querySelector("textarea");
    editor.value = ${JSON.stringify(broken)};
    editor.dispatchEvent(new Event("input", { bubbles: true }));
  })()`);
  await evaluate(`[...document.querySelectorAll("button *")].find((e) => e.textContent.trim().startsWith("Submit")).closest("button").click()`);
  const underlined = `[...document.querySelectorAll("span, p")]
    .filter((e) => e.children.length === 0 && getComputedStyle(e).textDecorationStyle === "wavy")
    .map((e) => e.textContent.trim())`;
  await waitFor(`${underlined}.length > 0`, "the compile error to be underlined", buildTimeoutMs);
  const marked = await evaluate(underlined);
  if (JSON.stringify(marked) !== JSON.stringify(["notDeclared"])) throw new Error(`underlined ${JSON.stringify(marked)}, expected ["notDeclared"]`);
  console.log(`compile error on line 300 underlined: ${JSON.stringify(marked)}`);
  // A failed build is an answer, not a page error; nothing else may log.
  const unexpected = cdp.problems.filter((p) => !p.includes("500"));
  if (unexpected.length) throw new Error(`page errors:\n  ${[...new Set(unexpected)].join("\n  ")}`);
} catch (err) {
  failure = err;
}

cdp.close();
server.close();
stopBackend();
if (failure) {
  console.log(`FAIL ${failure.message}`);
  process.exit(1);
}
console.log("ok   the playground builds the sample and runs it in the frame");
