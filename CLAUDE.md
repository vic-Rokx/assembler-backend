# assembler-backend

The HTTP backend for **assembler-chat** (`~/Desktop/Zig/assembler-chat`), a
vapor app with three tools: an LLM chat that writes vapor code, a playground
that compiles Zig/vapor code to wasm and runs it in an iframe, and a planner.
Built on **reverb** (the user's HTTP server, `~/Desktop/Zig/reverb`).

Created on 2026-10-19. Plan steps 1-6 are built (see "Status" below).

## Status (2026-10-19)

Done: steps 1, 2 and 3, and assembler-chat `5998ffc` (wasm URL carries the
build id; the dead 5 s `call()` is gone). `zig build test` (21 tests, ~50 s)
drives the real routes over a socket and runs real playground builds.

Step 4 (2026-10-20): vapor `58b5944` adds `<html data-vapor-boot="playground">`,
the frame side of `Vapor.Wasm.runPlaygroundWasm`, and assembler-chat's
`playground.html` uses it instead of the forked 2.x runtime. Builds render
at `/` in the frame. `tests/browser/playground.mjs` checks it end to end.
The frame loads assembler-chat's runtime (vapor by path, HEAD) and runs
builds made against the template's pin (v3.1.2), so the two must stay
compatible: move the template pin when the runtime's ABI changes. Released
as vapor 3.1.2 (pushed, tag `v3.1.2`); the template is pinned to it.

The frame has its own origin (assembler-chat `-Dplayground_url`, default
`http://localhost:5174/playground.html`; in production e.g.
`play.example.com` serving the same files): users keep API keys in the
app's localStorage, and code running in the frame cannot read them there.

Step 5 (2026-10-20): Google sign-in, with users in Postgres. reverb-auth
(`5f11737`, `348d719`, local) installs the routes vapor's KeyStone calls
(`/exchange/google/token`, `/auth/session/{bootstrap,refresh,signout}`,
`/auth/validate/google/session`) when `GOOGLE_CLIENT_ID`,
`GOOGLE_CLIENT_SECRET` and `SESSION_SECRET` are set. With `DATABASE_URL`,
each sign-in upserts `users` (`src/users.zig`, keyed by Google's `sub`)
and the session names the row's id; without it (the hosted exhibition)
nothing is stored and the session names the Google account. assembler-chat `a320530`: the login page is the Google
button, or the user and Sign out; the callback page reports the outcome.
`/user` and `/api/users` are gone (the old form never signed anyone in).

- Postgres for development and tests: `docker run -d --name assembler-pg
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=assembler -p
  127.0.0.1:54329:5432 postgres:17`, then `docker exec assembler-pg psql
  -U postgres -c "CREATE DATABASE assembler_test"`. 5432 and 5433 are
  taken by other projects' containers on this machine; leave them alone.
  Run the backend with `DATABASE_URL=postgres://postgres:postgres@127.0.0.1:54329/assembler`.
- Settings may also come from a git-ignored `.env` in the working
  directory (`KEY=value` lines); the real environment wins over it. The
  local one holds the Google client, `SESSION_SECRET` and a `DATABASE_URL`
  for the `assembler-pg` container. Never print its values.
- Verified with real Google on 2026-10-20: the user signed in through
  `http://localhost:5173/auth/login` (assembler-chat served on :5173, this
  backend on :8080 with `.env`), which created `users` row 1. The client
  is `403015953227-…`; `http://localhost:5173/auth/callback` is its
  registered redirect URI. Other origins need their own entry in Google
  Cloud and `OAUTH_REDIRECT_URI`.
- Sign-in and refresh run on reverb-auth's workers (deferred replies that
  set cookies, reverb `f5ec29a`); bootstrap, validate and sign-out stay on
  the loop. A test holds the fake Google's answer and requires `GET /` to
  answer meanwhile.
- Session cookies are `SameSite=Lax` (`COOKIE_SAMESITE`). That works while
  the frontend and backend are the same site (`app.example.com` and
  `api.example.com`); a frontend on another site needs
  `COOKIE_SAMESITE=none` with `SECURE_COOKIES=1`, which startup enforces.
- vapor's KeyStone makes the OAuth `state` from a timestamp, which is
  guessable; it should be random. A vapor change.
- pg-orm bugs found here, fixed in pg-orm `0d83ad8` (2026-10-20, pushed):
  `Connection.init` gave `pg.Pool` an `Io` in its own stack frame (it now
  takes one), and `RETURNING`, `SELECT` without `.select()` and renamed
  columns mapped nothing back. Its `src/live_test.zig` runs against
  Postgres when `PG_DB` is set (`PG_PORT=54329 PG_DB=pg_orm_test` with the
  container below). Pinned here since 2026-10-21; this backend still
  builds its `pg.Pool` itself and upserts with raw SQL.

Step 6 (2026-10-20): assembler-chat `b9eca94`, vaporize `a526e0c`.
Every `src/main.zig:L:C` error and note in a failed build is underlined
in the editor (`src/routes/diagnostics.zig`, unit-tested by assembler-chat's
new `zig build test`). The placeholder never underlined anything: the
editor's `recompile` clears its errors before drawing, so vaporize gained
`addExternalError`, which survives it. The header shows
`GET /api/wasm/versions` (`{"zig","vapor"}`, read at startup from
`zig version` and the template's pin). Chat replies are used as sent.

- The frontend never calls `/chat`: its one caller, `submitViaBackend`,
  is commented out. Claude and GPT models are called from the browser with
  the user's own keys; only the Vertex toggle reaches this backend
  (`/api/vertex`). The unescaping fix is on that path, checked by building
  and reading, not in a browser.
- reverb's `ctx.JSON` kept every response body (it formatted into the
  process-lifetime `ctx.arena`); reverb-auth's session routes use it.
  Fixed in reverb `07ccfa8`, pinned here and in reverb-auth.
- vaporize's `zig build test` runs none of `ZigParser.zig`'s tests: its
  root never references them, and they need an app's vapor (with its
  config and theme modules) to build.
- The old copy of the playground is gone, and `Playground_state_switch.zig`
  is now `src/routes/Playground.zig` (assembler-chat `d15eca3`, `8e9dabe`,
  pushed).

Exhibition readiness (2026-10-20): every dependency pinned by URL (a lone
clone builds); MIT licenses; READMEs with screenshots (assembler-chat
`docs/`, taken headlessly from the running app); `.env.example`;
`Dockerfile` (Zig 0.16 + the template precompiled; checked to build and
serve a wasm); assembler-chat's `zig build site` and `scripts/serve.mjs`
(app :5173, frame :5174); CI in both repos, green: here the 33 tests
against a Postgres service, both browser tests in headless Chrome against
the built site, and the Docker image. CI's first Linux run found that
`builds/` was opened without `iterate`, which Linux needs to list it: Debug
builds panicked, release builds silently never swept.

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
- reverb is pinned at `7862f54` (deferred replies with cookies, `ctx.JSON` no longer
  leaking, the right month in `Date`), which pins Loom
  `8d791ac`. Both are pushed.
- The deferred chat path was never run against a model: claude-zig's base
  URL is fixed, so tests cannot fake the API, and there is no key here.
- No memory cap on builds: macOS cannot set one per process. Cap it where
  the backend is deployed (cgroup/container). Builds have a wall-clock
  deadline that kills the `zig build` process group.
- Every dependency is pinned by URL and hash, so a clone builds on its own
  (claude-zig, reverb-auth and pg-orm were made public on 2026-10-20).
  To develop against a sibling checkout, swap one for `.{ .path = "../x" }`
  temporarily; don't commit that form.
- `/chat` and `/api/vertex` were never called against the real API (no key
  in the session). Default model `claude-opus-5-5`.
- `TextField(.float).bind(&f32)` did not compile in vapor 3.1.x; fixed in
  vapor `e0b5ec0` (pushed, unreleased, with a browser test). The template
  gets it with the next vapor release.
- reverb's `Date` header named the next month (`std.time.epoch.Month`
  counts from 1); fixed in reverb `7862f54`, pinned here and in
  reverb-auth (`83a8e05`).

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
| reverb | `7862f54f46acbefaaaee1fdcf71575a232c6fc55` | HTTP server. Public. Pinned here by URL and hash (see `build.zig.zon`); metal still pins the older `57375b7`. README has the `Server(Config)` quickstart and "Replying later". |
| claude-zig | `5396745` | Claude + Vertex clients (modules `claude`, `vertex`). Reads no env itself: `init.environ_map.get("ANTHROPIC_API_KEY")` in `main` (see `examples/claude_demo.zig`). It no longer injects any system prompt; this backend must send its own. |
| reverb-auth | `83a8e05` | OAuth (Google, GitHub), sessions, JWT. Pins the same reverb as this backend, by URL. |
| stripe-zig | `2f20771` | Stripe client, for `/checkout` (later). |
| pg-orm | `0d83ad8` | Postgres ORM over pg.zig: the users table's DDL. |

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
| `POST /api/wasm/build` | `routes/Playground.zig` `getWasm` | raw body = the editor's `main.zig` source | 200 `success`, or 500 whose body starts `file:line:col: error: …` (the frontend splits on `:`) |
| `GET /api/wasm/build` | same file, `handleWasmResponse` → `Vapor.Wasm.runPlaygroundWasm(url)` | none | the built `.wasm` bytes |
| `POST /exchange/google/token`, `/auth/session/*`, `/auth/validate/google/session` | vapor's KeyStone (`keystone/KeyStone.zig`) | form `auth-code`, `state`, `nonce`; cookies | KeyStone's JSON session shapes |
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
     vaporize if the samples need it; it's on 3.1.1 too; the template is on
     **v3.1.2** since 2026-10-20). Move the pin with
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
  starts this backend on :8080 and serves the frame on :5174 itself (stop
  any other first), checks the frame cannot read the app's storage, clicks
  Submit, and waits for the sample to render in the frame with no errors
  in page or frame; checks the header's versions; then submits code with
  an error on line 300 and requires exactly that token underlined. Needs
  `zig build` here and in assembler-chat.
- Sign-in: `SITE=../assembler-chat node tests/browser/signin.mjs` with the
  test database up. It starts this backend on :8080, plays Google (Chrome's
  request to Google's sign-in page is answered with the redirect back; the
  code exchange goes to a fake token endpoint), and checks the login page
  shows the user and Sign out signs them out. `zig build test` runs the
  sign-in routes against a fake Google and `TEST_DATABASE_URL` (default
  the container above); without a database those four tests are skipped,
  saying so.
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
