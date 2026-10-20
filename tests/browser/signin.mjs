// End to end: Google sign-in through the real frontend, backend and
// Postgres, with Google played by the test.
// Usage: SITE=<assembler-chat dir> node signin.mjs
//   after `zig build` here and in assembler-chat, with the test database
//   up (the assembler-pg container in CLAUDE.md, or TEST_DATABASE_URL).
// Chrome's request to Google's sign-in page is answered with a redirect
// back to /auth/callback, as Google would after the user consents; the
// backend's code exchange goes to a fake token endpoint here. Then the
// login page must show the user, and Sign out must sign them out.
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
const databaseUrl = process.env.TEST_DATABASE_URL ?? "postgres://postgres:postgres@127.0.0.1:54329/assembler_test";
const clientId = "e2e-client";

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

async function startBackend(origin, extraEnv) {
  if (!existsSync(backendExe)) throw new Error(`missing ${backendExe}; run \`zig build\` in assembler-backend`);
  if (await ping()) throw new Error(`something already answers on :${backendPort}; stop it first`);
  const builds = mkdtempSync(join(tmpdir(), "assembler-builds-"));
  const proc = spawn(backendExe, [], {
    cwd: resolve(dirname(backendExe), "../.."),
    env: { ...process.env, PORT: String(backendPort), ALLOWED_ORIGIN: origin, BUILDS_DIR: builds, ...extraEnv },
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
  const handlers = {}; // CDP event name -> handler
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    } else if (handlers[msg.method]) {
      handlers[msg.method](msg.params);
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
  return { send, problems, handlers, close };
}

// ── Google ──────────────────────────────────────────────────────────────────

// The token endpoint. The id token is unsigned: the backend trusts what
// Google's endpoint returns over TLS and checks only its claims.
const googleForms = [];
const google = createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => (body += chunk));
  req.on("end", () => {
    googleForms.push(new URLSearchParams(body));
    const now = Math.floor(Date.now() / 1000);
    const part = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
    const idToken = `${part({ alg: "RS256", typ: "JWT" })}.${part({
      iss: "https://accounts.google.com", aud: clientId, azp: clientId, sub: "e2e-sub",
      email: "ada@example.com", email_verified: true, name: "Ada Lovelace", iat: now, exp: now + 3600,
    })}.c2ln`;
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ access_token: "ya29.e2e", token_type: "Bearer", expires_in: 3599, refresh_token: "refresh-e2e", id_token: idToken }));
  });
});

// ── the test ────────────────────────────────────────────────────────────────

const server = createServer(serve);
await new Promise((r) => server.listen(0, "127.0.0.1", r));
// localhost, like the backend's URL: 127.0.0.1 would be another site, and
// Chrome refuses cookies a cross-site response sets.
const origin = `http://localhost:${server.address().port}`;
await new Promise((r) => google.listen(0, "127.0.0.1", r));
const stopBackend = await startBackend(origin, {
  GOOGLE_CLIENT_ID: clientId,
  GOOGLE_CLIENT_SECRET: "e2e-secret",
  SESSION_SECRET: "e2e-session-secret-0123456789abcdef",
  GOOGLE_TOKEN_URL: `http://127.0.0.1:${google.address().port}/token`,
  OAUTH_REDIRECT_URI: `${origin}/auth/callback`,
  DATABASE_URL: databaseUrl,
});
const cdp = await launch();

// Google's sign-in page: the user consents, and Google sends the browser
// back to the redirect URI with a code and the state it was given.
const authorizeUrls = [];
cdp.handlers["Fetch.requestPaused"] = ({ requestId, request: req }) => {
  const url = new URL(req.url);
  authorizeUrls.push(url);
  const back = new URL(url.searchParams.get("redirect_uri"));
  back.searchParams.set("code", "e2e-code");
  back.searchParams.set("state", url.searchParams.get("state"));
  cdp.send("Fetch.fulfillRequest", { requestId, responseCode: 302, responseHeaders: [{ name: "Location", value: back.href }] });
};
await cdp.send("Fetch.enable", { patterns: [{ urlPattern: "https://accounts.google.com/*" }] });

const evaluate = async (expression) => {
  const r = await cdp.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
  return r.result.value;
};
const waitFor = async (expression, what, timeout = 10_000) => {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (await evaluate(expression).catch(() => false)) return;
    await sleep(100);
  }
  const text = await evaluate(`document.body.innerText.replace(/\\s+/g, " ").slice(0, 200)`).catch(() => "?");
  throw new Error(`timed out waiting for ${what}; page says ${JSON.stringify(text)}`);
};
const pageText = `document.body.innerText`;
const goto = async (path) => {
  await cdp.send("Page.navigate", { url: origin + path });
  await waitFor(`document.documentElement.hasAttribute("data-vapor-ready")`, `${path} to load`);
};
const clickButton = (text) => evaluate(`(() => {
  const b = [...document.querySelectorAll("button")].find((e) => e.textContent.trim() === ${JSON.stringify(text)});
  b?.click();
  return !!b;
})()`);

let failure;
try {
  await goto("/auth/login");
  await waitFor(`${pageText}.includes("Login into Assembler")`, "the signed-out login page");

  // The provider buttons are icons; the Google one carries its icon class.
  const clicked = await evaluate(`(() => {
    const b = [...document.querySelectorAll("button")].find((e) => e.querySelector("[class*=google]"));
    b?.click();
    return !!b;
  })()`);
  if (!clicked) throw new Error("no Google button");

  await waitFor(`location.pathname === "/auth/callback" && ${pageText}.includes("Signed in")`, "the callback to sign in");
  const authorize = authorizeUrls.at(-1);
  if (authorize.searchParams.get("redirect_uri") !== `${origin}/auth/callback`) throw new Error(`redirect_uri ${authorize.searchParams.get("redirect_uri")}`);
  const form = googleForms.at(-1);
  if (form?.get("code") !== "e2e-code" || form.get("client_secret") !== "e2e-secret" || form.get("client_id") !== clientId) {
    throw new Error(`the backend sent Google ${form}`);
  }

  await goto("/auth/login");
  await waitFor(`${pageText}.includes("Ada Lovelace") && ${pageText}.includes("ada@example.com")`, "the login page to show the user");

  // The session cookie reaches the backend: bootstrap sees the user.
  const boot = await evaluate(`fetch("http://localhost:${backendPort}/auth/session/bootstrap", { method: "POST", credentials: "include" }).then((r) => r.json())`);
  if (boot.state !== "signed_in" || boot.session?.user?.email !== "ada@example.com") throw new Error(`bootstrap: ${JSON.stringify(boot)}`);

  if (!(await clickButton("Sign out"))) throw new Error("no Sign out button");
  await waitFor(`${pageText}.includes("Login into Assembler")`, "sign-out to show the login page");
  await sleep(500); // the backend's signout reply clears the cookie
  const after = await evaluate(`fetch("http://localhost:${backendPort}/auth/session/bootstrap", { method: "POST", credentials: "include" }).then((r) => r.json())`);
  if (after.state !== "signed_out") throw new Error(`bootstrap after sign-out: ${JSON.stringify(after)}`);

  await goto("/auth/login");
  await waitFor(`${pageText}.includes("Login into Assembler")`, "a reload to stay signed out");
  if (cdp.problems.length) throw new Error(`page errors:\n  ${[...new Set(cdp.problems)].join("\n  ")}`);
} catch (err) {
  failure = err;
}

cdp.close();
server.close();
google.close();
stopBackend();
if (failure) {
  console.log(`FAIL ${failure.message}`);
  process.exit(1);
}
console.log("ok   Google sign-in, the signed-in page, and sign-out");
