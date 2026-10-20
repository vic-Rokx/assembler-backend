# assembler-backend

The HTTP backend for **assembler-chat** (`~/Desktop/Zig/assembler-chat`), a
vapor app with three tools: an LLM chat that writes vapor code, a playground
that compiles Zig/vapor code to wasm and runs it in an iframe, and a planner.
Built on **reverb** (the user's HTTP server, `~/Desktop/Zig/reverb`).

Created on 2026-10-19. Plan steps 1-4 are built (see "Status" below).

## Status (2026-10-19)

Done: steps 1, 2 and 3, and assembler-chat `5998ffc` (wasm URL carries the
build id; the dead 5 s `call()` is gone). `zig build test` (21 tests, ~50 s)
drives the real routes over a socket and runs real playground builds.

Step 4 (2026-10-20): vapor `58b5944` adds `<html data-vapor-boot="playground">`,
the frame side of `Vapor.Wasm.runPlaygroundWasm`, and assembler-chat's
`playground.html` uses it instead of the forked 2.x runtime. Builds render
at `/` in the frame. `tests/browser/playground.mjs` checks it end to end.
The frame loads assembler-chat's runtime (vapor by path, HEAD) and runs
builds made against the template's pin (v3.1.1), so the two must stay
compatible: move the template pin when the runtime's ABI changes. vapor
`58b5944` is local, not pushed or released.

The frame is same-origin with assembler-chat and unsandboxed, so playground
code can read the app's cookies and storage. It runs the user's own (or
the model's) code in the user's browser, so this is self-XSS, not a hole
for others, but a sandboxed frame on another origin would be safer.

Layout: `src/main.zig` (env, paths), `src/app.zig` (routes), `src/chat.zig`,
`src/WasmBuilder.zig`, `src/Settings.zig` (every env var and its default),
`src/vapor_prompt.md` (the system prompt; its examples and
`src/testdata/prompt_api.zig` are compiled by the tests),
`playground_template/`.

Decisions and known gaps:

- `POST /api/wasm/build` answers 200 with a 16-hex-char id; the wasm is
  `GET /api/wasm/build/<id>.wasm` (the extension makes reverb send
  `application/wasm`). Old builds are swept after an hour.
- Builds and model calls run on worker pools (`reverb.Workers`) behind
  `ctx.deferReply()`, so the loop keeps answering while they run (2026-10-20).
  Builds: `BUILD_THREADS` (2, the concurrency cap) and `BUILD_QUEUE` (8);
  chats: `CHAT_THREADS` (8) and `CHAT_QUEUE` (32). A full queue answers
  503. Requests may wait 10 min for a reply (`Config.reply_timeout_ms`).
  Shutdown waits for queued jobs to finish, which can take a while with
  builds queued.
- reverb is pinned at `7791913` (deferred replies), which pins Loom
  `8d791ac`. Both are pushed.
- The deferred chat path was never run against a model: claude-zig's base
  URL is fixed, so tests cannot fake the API, and there is no key here.
- No memory cap on builds: macOS cannot set one per process. Cap it where
  the backend is deployed (cgroup/container). Builds have a wall-clock
  deadline that kills the `zig build` process group.
- claude-zig, reverb-auth, stripe-zig and pg-orm are private on GitHub, so
  `zig fetch` cannot reach them; claude-zig is a path dependency.
- `/chat` and `/api/vertex` were never called against the real API (no key
  in the session). Default model `claude-opus-5-5`.
- The frontend runs `api.unescapeJson` on the chat reply, which turns a
  `\n` inside a Zig string literal into a newline. The backend sends plain
  text, so that call should go (step 6).
- vapor 3.1.1 bug: `TextField(.float).bind(&f32)` does not compile
  (`text_field/value.zig:518` assigns `evt.number()`'s `i32` to `f32`).
- reverb's `Date` header is a month ahead (`Nov` on 2026-10-19).

## Why it exists

The old backend was reverb's `src/example.zig`, one file serving both
assembler-chat and ryven. It was removed from reverb on 2026-10-05
(`98713bb`, "remove dead code"). Its helper libraries were split into their
own repos on 2026-10-07 (`832f902`). assembler-chat was migrated to vapor 3.x
on 2026-10-19, so this backend must build playground code against vapor 3.x
too. The user's direction: "move the backend to keep up with the version of
vapor".

## Where the old code is

| What | Where |
|---|---|
| Old server: routes, handlers, wasm build | `git -C ../reverb show dbb7235:src/example.zig` (~880 lines; routes at lines ~715-750, `buildWasm` ~833, `spawn` ~756, `cleanErrorMessage` ~778, `getWasmBuild` ~857, `vertexapi` ~869) |
| Assembler user handlers | `../reverb/src/assembler/api.zig`, `crud.zig` (still in reverb HEAD) |
| Old vapor system prompt (2.x API) | `../reverb/src/context.txt` (102 KB), `context_v2.txt` (21 KB) |
| Old playground build project | `../reverb/wasm/` (untracked in reverb; `src/` is empty; zon points at `../../vapor` 1.2.7) |

Treat the old code as a reference, not something to copy wholesale.
Re-derive each handler against current reverb, because reverb's API moved
after the snapshot.

## Packages (all Zig 0.16.0, sibling folders in ~/Desktop/Zig)

| Package | Commit | Use |
|---|---|---|
| reverb | `7791913363101e368b6fb73046b3cdfb957ce855` | HTTP server. Public. Pinned here by URL and hash (see `build.zig.zon`); metal still pins the older `57375b7`. README has the `Server(Config)` quickstart and "Replying later". |
| claude-zig | `5396745` | Claude + Vertex clients (modules `claude`, `vertex`). Reads no env itself: `init.environ_map.get("ANTHROPIC_API_KEY")` in `main` (see `examples/claude_demo.zig`). It no longer injects any system prompt; this backend must send its own. |
| reverb-auth | `a47c0e5` | OAuth (Google, GitHub), sessions, JWT. Its README says reverb is private; that's stale (reverb is public now). It uses a path dep on `../reverb`. |
| stripe-zig | `2f20771` | Stripe client, for `/checkout` (later). |
| pg-orm | `b617520` | Postgres ORM over pg.zig, if users are stored. |

Zig 0.16: `std.posix.getenv` is gone (env comes through `main(init)`), and
I/O goes through `std.Io` (the old `buildWasm` already uses
`std.Io.Threaded` / `std.Io.Dir`). Check `~/.zvm/0.16.0/lib/std` rather than
guessing APIs.

## The API assembler-chat calls

Base URL comes from assembler-chat's `-Dbackend_base_url` (default
`http://localhost:8080`, see `src/routes/backend.zig`). Requests use
`credentials: "include"`, so CORS must allow the frontend origin with
credentials.

| Route | Caller (assembler-chat/src) | Request | Expected response |
|---|---|---|---|
| `POST /chat` | `routes/api.zig` `submitToBackend` | JSON `{"query": "<prompt>"}` | Claude's reply text |
| `POST /api/vertex` | `routes/api.zig` `submitToBackendVertex` | same | reply text |
| `POST /api/wasm/build` | `routes/Playground_state_switch.zig` `getWasm` | raw body = the editor's `main.zig` source | 200 `success`, or 500 whose body starts `file:line:col: error: …` (the frontend splits on `:`) |
| `GET /api/wasm/build` | same file, `handleWasmResponse` → `Vapor.Wasm.runPlaygroundWasm(url)` | none | the built `.wasm` bytes |
| `POST /user` | `routes/auth/login/Page.zig` `createAccount` | JSON `Details{name,email,password}` | text |
| `POST /api/users` | same file, `createUser` | JSON user | text |
| `POST /checkout` | same file, `payment` (not wired to UI yet) | form-encoded | redirect URL in body |

The browser calls Anthropic and OpenAI directly in some paths (keys from
Settings). Those don't involve this backend.

## Plan (agreed with the user)

1. **Skeleton:** `zig init`-style exe with reverb pinned. Add `GET /` ping,
   CORS for the frontend origin, config from env (port, API keys, allowed
   origin), and `zig build test`.
2. **`/chat` and `/api/vertex`** on claude-zig. Parse JSON properly (the
   frontend now JSON-escapes the prompt). Send a **vapor 3.x system
   prompt**, kept in this repo as a file and `@embedFile`d. The old
   `context.txt` describes the 2.x API. Rebuild the prompt from vapor's
   current public API (`../vapor/src/root.zig` is the export list, every
   pub fn is documented, `../vapor/CHANGELOG.md` lists 3.x renames). Keep
   it lean; the 102 KB version was too big.
3. **`/api/wasm/build`, rebuilt, not copied.** The old one wrote every
   request to one shared `wasm/src/main.zig` and ran `zig build` with no
   limits. Instead:
   - A template vapor 3.x project in this repo (`playground_template/`:
     build.zig, build.zig.zon pinned to vapor **v3.1.1** tarball
     `https://github.com/senet-toolbox/vapor/archive/refs/tags/v3.1.1.tar.gz`,
     hash `vapor-3.1.1-VGoNdYnwEwAoDDctBmqdky3a-6O9NZ4_FBhGUqYWTzEV`, plus
     vaporize if the samples need it; it's on 3.1.1 too). Move the pin with
     each vapor release, the same way metal does. Mirror assembler-chat's
     `build.zig` (wasm32-wasi, `entry = .disabled`, `rdynamic`, theme and
     config modules).
   - Each build goes in its own folder under `builds/<id>/`: copy the
     template, write `src/main.zig`, run `zig build -Doptimize=ReleaseSmall`
     with a timeout, a concurrency cap, and the shared global zig cache so
     builds after the first are fast.
   - Return an id. Serve `GET /api/wasm/build/:id`, and clean old builds.
     That needs a small frontend change: the POST response carries the id
     and the GET URL uses it. Coordinate it in assembler-chat.
   - Keep the `file:line:col: error: msg` error format (strip ANSI, drop
     the build-runner noise; see the old `cleanErrorMessage`).
   - Security: user code only gets a fixed build.zig, comptime can't do
     I/O, and `@embedFile` is limited to the package. The real risks are
     CPU/memory/time, so cap them. Never let the request choose paths or
     build options.
4. **Make the playground iframe run 3.x wasm.** `assembler-chat/playground.html`
   loads a forked **2.x** runtime (`assembler-chat/playground/playground_obj.js`).
   It waits for a `{type:"load-wasm", bytes}` postMessage after posting
   `playground-ready`. A 3.x build needs vapor's runtime, but
   `vapor/js/src/runtime.js` `loadWasiModule()` hard-codes
   `/zig-out/bin/vapor.wasm`. Likely fix: a vapor runtime option to boot
   from given bytes or URL, used by a small playground loader. That's a
   vapor change, so add a vapor browser test (see vapor rules below).
5. **Auth and users** (`/user`, `/api/users`) with reverb-auth (+ pg-orm
   if persisted). **Stripe** later; it needs the user's keys.
6. **assembler-chat follow-ups** found during migration, to fix alongside:
   - `getWasm` waits a hard-coded 5 s timeout (`call()` →
     `Vapor.timeout("wait", 5000, …)`) before building.
   - Error highlighting is a placeholder: always line 13, text "This is a
     test err". It parses line/col as `u8`, which overflows past 255.
   - The playground header says "Vapor Version: 1.2.7" and "Zig Version:
     0.15.2". Make it show the template's real versions.
   - The `*_sample.zig` playground files were migrated to 3.x on
     2026-10-19. The user wants them on 3.x; they must compile against
     the template.

## How to test

- `zig build test` here for handler logic and the build runner. Use a temp
  dir and a tiny `main.zig` that compiles, plus one that doesn't, and
  assert the `file:line:col` error body.
- Run the server and drive it with curl.
- End to end: `zig build` in `../assembler-chat`, run this backend on
  :8080, then `SITE=../assembler-chat node tests/browser/smoke.mjs /playground`.
  Also use `crawl.mjs` (clicks every control) and `typing.mjs` (types into
  every field). They serve the app themselves on a random port.
- The playground: `SITE=../assembler-chat node tests/browser/playground.mjs`
  starts this backend on :8080 itself (stop any other first), clicks
  Submit, and waits for the sample to render in the frame with no errors
  in page or frame. Needs `zig build` here and in assembler-chat.
- Without the backend, assembler-chat logs only network errors (verified
  2026-10-19, Debug and ReleaseSmall).

## Rules (from the user)

- Commit locally as you go (end messages with the Co-Authored-By line the
  session gives you). **Never push, tag, create remotes, or rename repos
  without asking.**
- Other repos: ask before writing into one that has uncommitted user work.
  State on 2026-10-19:
  - vapor **3.1.1** is released (timeouts, transitions, morph, migrate fixes).
  - ryven's 3.x migration is pushed (`03b71e1`).
  - assembler-chat's migration is committed (`d9855b4`). It has no remote;
    its frontend changes (build id in the wasm URL, the playground fixes
    above) go there as new commits.
- Vapor changes need a browser test in `../vapor/tests/browser` (page in
  `app/src/main.zig`, test in `run.mjs`). Show it fails without the fix,
  then run `zig build browser-test` in all four modes
  (`-Dbrowser-optimize=Debug|ReleaseSmall` × `-Dbrowser-static=false|true`).
  After editing `vapor/js/src`, run `zig build runtime` and check its exit
  code.
- The shell is zsh. Never take an exit code through `| tail`, and use
  `${=VAR}` for word splitting.
- Write like the surrounding code. Don't leave dead or commented-out code.
- When reporting, say what was verified and how, and what wasn't.
