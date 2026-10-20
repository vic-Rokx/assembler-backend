//! Routes and middleware for the assembler-chat backend.
//!
//! Builds and model calls take seconds to minutes, so their handlers defer
//! the reply and hand the work to a worker pool; the event loop keeps
//! answering everyone else. One pool per kind of work, so a burst of chats
//! cannot keep builds waiting, or the other way round.
const std = @import("std");
const Allocator = std.mem.Allocator;
const reverb = @import("reverb");
const Context = reverb.Context;
const Settings = @import("Settings.zig");
const WasmBuilder = @import("WasmBuilder.zig");
const chat = @import("chat.zig");
const users = @import("users.zig");
const KeyStone = @import("reverb_auth").KeyStone;
const pg = @import("pg_orm").pg;

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    max: usize = 256,
    /// Reverb puts a receive buffer of this size on the stack, so it stays
    /// well under the 8 MB main-thread stack. Playground sources and chat
    /// prompts are a few KB.
    max_body_size: usize = 1024 * 1024,
    /// How long a deferred request may wait for its reply. A non-streamed
    /// answer of `max_tokens` can take longer than reverb's five-minute
    /// default.
    reply_timeout_ms: i64 = 10 * 60 * 1000,
};

pub const Server = reverb.Server(Config);

const content_type = "text/plain; charset=utf-8";

const BuildJob = struct {
    reply: *reverb.Reply,
    /// Owned by the job; `runBuild` frees it.
    source: []u8,
};

/// What the handlers need. Reverb handlers take only a `Context`, so this
/// is set once by `register`.
const State = struct {
    settings: Settings,
    io: std.Io,
    /// Threadsafe: jobs are allocated on the loop thread and freed on a
    /// worker.
    gpa: Allocator,
    builder: WasmBuilder,
    versions: WasmBuilder.Versions,
    /// The users table's database; null when sign-in is off.
    db: ?*pg.Pool,
    builds: reverb.Workers(BuildJob, runBuild),
    chats: reverb.Workers(chat.Job, runChat),
};
var state: State = undefined;

/// Starts the worker pools and adds the routes. Call `deinit` once
/// `listen` has returned and before `server.deinit`. `db`, if given, must
/// already be migrated; sign-in then records each user there.
pub fn register(
    server: *Server,
    settings: Settings,
    io: std.Io,
    gpa: Allocator,
    builder: WasmBuilder,
    versions: WasmBuilder.Versions,
    db: ?*pg.Pool,
) !void {
    state = .{
        .settings = settings,
        .io = io,
        .gpa = gpa,
        .builder = builder,
        .versions = versions,
        .db = db,
        .builds = undefined,
        .chats = undefined,
    };
    try state.builds.init(gpa, io, .{ .threads = settings.build_threads, .queue = settings.build_queue });
    errdefer state.builds.deinit();
    try state.chats.init(gpa, io, .{ .threads = settings.chat_threads, .queue = settings.chat_queue });
    errdefer state.chats.deinit();

    try server.useCors(.{ .cors_headers = .{
        .origin = .{ .override = settings.allowed_origin },
        .credentials = .{ .override = "true" },
    } });

    try server.get("/", ping, &.{});
    try server.post("/chat", postChat, &.{});
    try server.post("/api/vertex", postVertex, &.{});
    try server.post("/api/wasm/build", buildWasm, &.{});
    try server.get("/api/wasm/build/:file", getWasm, &.{});
    try server.get("/api/wasm/versions", getVersions, &.{});

    if (settings.signInConfigured()) try registerSignIn(server);
}

/// reverb-auth's routes for vapor's KeyStone: `/exchange/google/token`,
/// `/auth/session/{bootstrap,refresh,signout}` and
/// `/auth/validate/google/session`. Sign-in and refresh wait on Google,
/// so reverb-auth runs them on its own workers; the users upsert
/// (`onSignIn`) runs there too. Without a database there is no upsert, and
/// the session names the Google account itself.
fn registerSignIn(server: *Server) !void {
    const settings = &state.settings;
    try KeyStone.install(server, .{
        .clients = .{ .google = .{
            .client_id = settings.google_client_id.?,
            .client_secret = settings.google_client_secret.?,
            .redirect_uri = settings.oauth_redirect_uri,
            .token_url = settings.google_token_url,
        } },
        .session_secret = settings.session_secret.?,
        .secure_cookies = settings.secure_cookies,
        .same_site = settings.cookie_same_site,
        .on_sign_in = if (state.db != null) onSignIn else null,
    }, state.gpa, state.io);
}

/// On a sign-in worker; the pool is threadsafe.
fn onSignIn(allocator: Allocator, user: KeyStone.SignedIn) anyerror![]const u8 {
    return users.upsert(state.db.?, allocator, user);
}

/// Stops the pools. Jobs already queued still run and send their replies,
/// so this waits for them.
pub fn deinit() void {
    state.builds.deinit();
    state.chats.deinit();
    KeyStone.deinit();
}

fn ping(ctx: *Context) !void {
    try ctx.STRING("SUCCESS");
}

fn postChat(ctx: *Context) !void {
    try deferChat(ctx, .anthropic);
}

fn postVertex(ctx: *Context) !void {
    try deferChat(ctx, .vertex);
}

/// Answers what it can at once (no credentials, no query), and hands the
/// model call to a chat worker.
fn deferChat(ctx: *Context, provider: chat.Provider) !void {
    if (chat.unconfigured(&state.settings, provider)) |reason| return ctx.ERROR(503, reason);
    const query = chat.readQuery(ctx) orelse return ctx.ERROR(400, "expected JSON {\"query\": \"...\"}");

    const owned = try state.gpa.dupe(u8, query);
    errdefer state.gpa.free(owned);
    const reply = try ctx.deferReply();
    state.chats.submit(.{ .reply = reply, .provider = provider, .query = owned }) catch {
        state.gpa.free(owned);
        reply.send(503, content_type, "too many chats are in progress; try again shortly");
    };
}

fn runChat(job: chat.Job) void {
    chat.answer(state.gpa, &state.settings, job);
}

/// The body is the playground's `main.zig`, built on a build worker.
fn buildWasm(ctx: *Context) !void {
    const source = ctx.body();
    if (std.mem.trim(u8, source, " \t\r\n").len == 0) return ctx.ERROR(400, "error: empty source");

    const owned = try state.gpa.dupe(u8, source);
    errdefer state.gpa.free(owned);
    const reply = try ctx.deferReply();
    state.builds.submit(.{ .reply = reply, .source = owned }) catch {
        state.gpa.free(owned);
        reply.send(503, content_type, "error: too many builds are running; try again shortly");
    };
}

/// Answers 200 with the build id, or 500 with the compiler's
/// `file:line:col: error: ...` lines.
fn runBuild(job: BuildJob) void {
    defer state.gpa.free(job.source);
    const outcome = state.builder.build(state.gpa, job.source) catch |err| {
        std.log.err("wasm build: {any}", .{err});
        return job.reply.send(500, content_type, "error: the build server failed");
    };
    switch (outcome) {
        .built => |id| job.reply.send(200, content_type, &id),
        .failed => |errors| {
            defer state.gpa.free(errors);
            job.reply.send(500, content_type, errors);
        },
    }
}

/// `GET /api/wasm/versions`: `{"zig": "0.16.0", "vapor": "3.1.2"}`, what
/// playground code is built with.
fn getVersions(ctx: *Context) !void {
    // Not `ctx.JSON`: it allocates from memory that lives as long as the
    // process, so every response would leak.
    const body = try std.json.Stringify.valueAlloc(ctx.requestAllocator(), state.versions, .{});
    try ctx.SEND(200, "application/json", body);
}

/// `GET /api/wasm/build/<id>.wasm`. The extension is in the URL so reverb
/// sends `application/wasm`, which `WebAssembly.instantiateStreaming` needs.
fn getWasm(ctx: *Context) !void {
    const file = (ctx.param("file") orelse return ctx.ERROR(404, "")).value;
    if (!std.mem.endsWith(u8, file, ".wasm")) return ctx.ERROR(404, "");
    const path = try state.builder.wasmPath(ctx.requestAllocator(), file[0 .. file.len - ".wasm".len]) orelse
        return ctx.ERROR(404, "");
    const wasm = std.Io.Dir.cwd().openFile(state.io, path, .{}) catch return ctx.ERROR(404, "");
    // The connection owns the file from here and closes it once sent.
    try ctx.FILE(wasm);
}
