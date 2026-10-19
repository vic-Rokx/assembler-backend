// Headless-Chrome check of a vapor app, from the assembler-chat migration.
// Usage: SITE=<app dir> node crawl.mjs /route ...  (after `zig build` in the app)
// Serves the app (SPA fallback, /bundle.min.js -> zig-out/bin), reports
// exceptions and vapor [ERROR]/[WARN] logs. Node >= 22, Chrome.
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const siteDir = resolve(process.env.SITE);
const args = process.argv.slice(2);
const flags = new Set(args.filter((a) => a.startsWith("--")));
const positional = args.filter((a) => !a.startsWith("--"));

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
  const problems = []; // uncaught exceptions and console errors/warnings, per test
  const dialogs = []; // window.alert/confirm messages, accepted as they open
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    } else if (msg.method === "Page.javascriptDialogOpening") {
      dialogs.push(msg.params.message);
      ws.send(JSON.stringify({ id: ++nextId, method: "Page.handleJavaScriptDialog", params: { accept: true } }));
    } else if (msg.method === "Runtime.exceptionThrown") {
      const d = msg.params.exceptionDetails;
      problems.push(`exception: ${(d.exception?.description ?? d.text).split("\n").slice(0, 6).join("\n        ")}`);
    } else if (msg.method === "Runtime.consoleAPICalled") {
      // vapor reports its problems through console.log with an [ERROR] or
      // [WARN] label; a showcase page should print nothing of either.
      const text = msg.params.args.map((a) => a.value ?? a.description).join(" ");
      if (msg.params.type === "error" || msg.params.type === "warning" || /\[%c(ERROR|WARN)%c\]/.test(text)) {
        problems.push(`console.${msg.params.type}: [${(msg.params.stackTrace?.callFrames ?? []).slice(0, 12).map((f) => f.functionName).join(" < ")}] ${text.replace(/%c/g, "").slice(0, process.env.LONG ? 4000 : 300)}`);
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
  // Headless pages never have focus, so focus/blur events would not fire.
  await send("Emulation.setFocusEmulationEnabled", { enabled: true });
  await send("Emulation.setDeviceMetricsOverride", { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });

  const close = () => {
    ws.close();
    proc.kill();
    try { rmSync(profile, { recursive: true, force: true }); } catch {}
  };
  return { send, problems, dialogs, close };
}

// ── page helpers ────────────────────────────────────────────────────────────

// In-page code shared by the helpers: find elements by their visible text.
const finders = `
  window.__ui = {
    visible(e) {
      if (!e || !e.isConnected) return false;
      const r = e.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) return false;
      // What is left of the box after every clipping ancestor (a collapsed
      // panel is usually height 0 with overflow hidden, not display none).
      let left = r.left, top = r.top, right = r.right, bottom = r.bottom;
      for (let n = e; n; n = n.parentElement) {
        const s = getComputedStyle(n);
        if (s.display === "none" || s.visibility === "hidden" || Number(s.opacity) === 0) return false;
        // Only hidden/clip hide content (a scroll area just needs scrolling),
        // and each axis on its own.
        if (n !== e) {
          const c = n.getBoundingClientRect();
          if (/hidden|clip/.test(s.overflowX)) { left = Math.max(left, c.left); right = Math.min(right, c.right); }
          if (/hidden|clip/.test(s.overflowY)) { top = Math.max(top, c.top); bottom = Math.min(bottom, c.bottom); }
          if (right - left < 1 || bottom - top < 1) return false;
        }
      }
      return true;
    },
    // The innermost visible elements whose whole text is \`text\`.
    byText(text, root = document) {
      const all = [...root.querySelectorAll("body *")].filter((e) => e.textContent.trim() === text && this.visible(e));
      return all.filter((e) => !all.some((o) => o !== e && e.contains(o)));
    },
    byLabel(label) {
      return [...document.querySelectorAll("[aria-label]")].filter((e) => e.getAttribute("aria-label") === label && this.visible(e));
    },
  };
`;

const server = createServer(serve);
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const origin = `http://127.0.0.1:${server.address().port}`;
const cdp = await launch();
const evaluate = async (expression) => (await cdp.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true })).result.value;
// Backend-down noise: the app's own fetch error logs.
const noise = /fetch failed|Failed to fetch|parse (requests|json|error response|result)|could not parse json|auth exchange|Failjd/i;
const go = async (path) => { await cdp.send("Page.navigate", { url: origin + path }); await sleep(1200); };

let bad = 0;
for (const path of positional) {
  await go(path);
  const count = await evaluate(`(() => { ${finders} return [...document.querySelectorAll("button, [role=button], a, [role=tab], [role=option]")].filter((e) => __ui.visible(e)).length })()`);
  let clicked = 0;
  for (let i = 0; i < count; i++) {
    cdp.problems.length = 0;
    const here = await evaluate("location.pathname");
    if (here !== path) await go(path);
    const target = await evaluate(`(() => { ${finders}
      const all = [...document.querySelectorAll("button, [role=button], a, [role=tab], [role=option]")].filter((e) => __ui.visible(e));
      const e = all[${i}]; if (!e) return null;
      e.scrollIntoView({ block: "center" });
      const r = e.getBoundingClientRect();
      return { x: r.left + r.width / 2, y: r.top + r.height / 2, what: (e.getAttribute("aria-label") || e.textContent.trim()).replace(/\\s+/g, " ").slice(0, 40) || e.innerHTML.replace(/ id="[^"]*"/g, "").slice(0, 120) };
    })()`);
    if (!target) continue;
    for (const type of ["mouseMoved", "mousePressed", "mouseReleased"]) await cdp.send("Input.dispatchMouseEvent", { type, x: target.x, y: target.y, button: "left", clickCount: 1 });
    await sleep(250);
    // Escape closes whatever opened.
    await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27 });
    await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27 });
    clicked++;
    const real = [...new Set(cdp.problems)].filter((p) => !noise.test(p));
    if (real.length) { bad++; console.log(`!! ${path} click "${target.what}"\n   ${real.join("\n   ")}`); }
  }
  console.log(`── ${path}: clicked ${clicked}`);
}
cdp.close();
server.close();
console.log(bad ? `${bad} clicks with problems` : "no problems");
