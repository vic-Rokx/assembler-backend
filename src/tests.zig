//! The real routes on a real server, on an ephemeral port, driven over a
//! socket. Handler logic that does not need a server is tested next to it.
const std = @import("std");
const testing = std.testing;
const app = @import("app.zig");
const WasmBuilder = @import("WasmBuilder.zig");
const Settings = @import("Settings.zig");
const chat = @import("chat.zig");
const users = @import("users.zig");
const pg = @import("pg_orm").pg;
const JWT = @import("reverb_auth").JWT;
const playground_template = @import("test_options").playground_template;

const origin = "http://frontend.test";

/// What the harness reports at `/api/wasm/versions`; reading the real ones
/// runs `zig_exe`, which some tests replace.
const test_versions: WasmBuilder.Versions = .{ .zig = "0.16.0", .vapor = "3.1.2" };

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    builds: testing.TmpDir,
    server: app.Server,
    thread: std.Thread,
    port: u16,

    /// Binds before the loop starts, so the port is connectable as soon as
    /// this returns. `h` must not move while the server runs.
    fn start(h: *Harness) !void {
        return h.startWith(.{ .allowed_origin = origin });
    }

    fn startWith(h: *Harness, settings: Settings) !void {
        return h.startWithDb(settings, null);
    }

    fn startWithDb(h: *Harness, settings: Settings, db: ?*pg.Pool) !void {
        h.arena = .init(testing.allocator);
        errdefer h.arena.deinit();
        h.builds = testing.tmpDir(.{});
        errdefer h.builds.cleanup();

        const builder: WasmBuilder = .{
            .io = testing.io,
            .template_path = playground_template,
            .builds_path = try h.builds.dir.realPathFileAlloc(testing.io, ".", h.arena.allocator()),
            .zig_exe = settings.zig_exe,
        };

        try h.server.new(.{ .port = 0 }, h.arena.allocator());
        errdefer h.server.deinit();
        // Leak-checks every reply.
        h.server.reply_allocator = testing.allocator;
        try app.register(&h.server, settings, testing.io, testing.allocator, builder, test_versions, db);
        errdefer app.deinit();
        try h.server.bindListener();
        h.port = try h.server.boundPort();
        h.thread = try std.Thread.spawn(.{}, serve, .{&h.server});
    }

    fn serve(server: *app.Server) void {
        server.listen() catch |err| std.debug.print("test server stopped: {any}\n", .{err});
    }

    fn stop(h: *Harness) void {
        h.server.stop();
        h.thread.join();
        app.deinit();
        h.server.deinit();
        h.builds.cleanup();
        h.arena.deinit();
    }

    /// Sends one request and reads one response, framed by its
    /// Content-Length. Caller frees with `Response.deinit`.
    fn roundTrip(h: *Harness, request: []const u8) !Response {
        const stream = try h.send(request);
        defer stream.close(testing.io);
        return receive(stream);
    }

    /// Sends one request on a new connection and leaves the response
    /// unread, for tests that hold several requests open at once. Caller
    /// closes the stream.
    fn send(h: *Harness, request: []const u8) !std.Io.net.Stream {
        const io = testing.io;
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(h.port) };
        const stream = try address.connect(io, .{ .mode = .stream });
        errdefer stream.close(io);

        var write_buf: [1024]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        try writer.interface.writeAll(request);
        try writer.interface.flush();
        return stream;
    }

    fn post(h: *Harness, path: []const u8, body: []const u8) !Response {
        const stream = try h.sendPost(path, body);
        defer stream.close(testing.io);
        return receive(stream);
    }

    /// `headers` are extra header lines, each ending in CRLF.
    fn postWith(h: *Harness, path: []const u8, headers: []const u8, body: []const u8) !Response {
        const stream = try h.sendPostWith(path, headers, body);
        defer stream.close(testing.io);
        return receive(stream);
    }

    fn sendPost(h: *Harness, path: []const u8, body: []const u8) !std.Io.net.Stream {
        return h.sendPostWith(path, "", body);
    }

    fn sendPostWith(h: *Harness, path: []const u8, headers: []const u8, body: []const u8) !std.Io.net.Stream {
        const request = try std.fmt.allocPrint(
            testing.allocator,
            "POST {s} HTTP/1.1\r\nHost: x\r\nOrigin: " ++ origin ++ "\r\n{s}Content-Length: {d}\r\n\r\n{s}",
            .{ path, headers, body.len, body },
        );
        defer testing.allocator.free(request);
        return h.send(request);
    }

    fn get(h: *Harness, path: []const u8) !Response {
        const request = try std.fmt.allocPrint(testing.allocator, "GET {s} HTTP/1.1\r\nHost: x\r\nOrigin: " ++ origin ++ "\r\n\r\n", .{path});
        defer testing.allocator.free(request);
        return h.roundTrip(request);
    }
};

/// Reads one response, framed by its Content-Length. Caller frees with
/// `Response.deinit`.
fn receive(stream: std.Io.net.Stream) !Response {
    var read_buf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(testing.io, &read_buf);
    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(testing.allocator);
    while (!std.mem.endsWith(u8, head.items, "\r\n\r\n")) {
        try head.append(testing.allocator, try reader.interface.takeByte());
    }

    const length_header = "Content-Length: ";
    const at = std.mem.indexOf(u8, head.items, length_header) orelse return error.NoContentLength;
    const length_end = std.mem.indexOfPos(u8, head.items, at, "\r\n").?;
    const length = try std.fmt.parseInt(usize, head.items[at + length_header.len .. length_end], 10);
    return .{
        .head = try head.toOwnedSlice(testing.allocator),
        .body = try reader.interface.readAlloc(testing.allocator, length),
    };
}

const Response = struct {
    head: []u8,
    body: []u8,

    fn deinit(r: Response) void {
        testing.allocator.free(r.head);
        testing.allocator.free(r.body);
    }

    fn expectStatus(r: Response, comptime status: []const u8) !void {
        if (!std.mem.startsWith(u8, r.head, "HTTP/1.1 " ++ status)) {
            std.debug.print("expected {s}, got:\n{s}{s}\n", .{ status, r.head, r.body });
            return error.UnexpectedStatus;
        }
    }

    fn hasHeader(r: Response, comptime line: []const u8) bool {
        return std.mem.indexOf(u8, r.head, line ++ "\r\n") != null;
    }
};

test "GET / answers SUCCESS with credentialed CORS for the configured origin" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    const response = try h.get("/");
    defer response.deinit();

    try response.expectStatus("200");
    try testing.expectEqualStrings("SUCCESS", response.body);
    try testing.expect(response.hasHeader("Access-Control-Allow-Origin: " ++ origin));
    try testing.expect(response.hasHeader("Access-Control-Allow-Credentials: true"));
}

test "a JSON preflight is allowed, with the requested headers echoed" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    const response = try h.roundTrip("OPTIONS /chat HTTP/1.1\r\nHost: x\r\nOrigin: " ++ origin ++
        "\r\nAccess-Control-Request-Method: POST\r\nAccess-Control-Request-Headers: content-type\r\n\r\n");
    defer response.deinit();

    try response.expectStatus("200");
    try testing.expect(response.hasHeader("Access-Control-Allow-Origin: " ++ origin));
    try testing.expect(response.hasHeader("Access-Control-Allow-Headers: content-type"));
}

test "a playground build returns an id whose wasm can be fetched" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    const built = try h.post("/api/wasm/build",
        \\const Vapor = @import("vapor");
        \\
        \\export fn init() void {
        \\    Vapor.init(.{});
        \\    Vapor.Page(.{ .route = "/" }, render, null);
        \\}
        \\
        \\fn render() void {
        \\    Vapor.Text("Hello from the playground").end();
        \\}
        \\
    );
    defer built.deinit();
    try built.expectStatus("200");
    try testing.expectEqual(@as(usize, 16), built.body.len);

    const path = try std.fmt.allocPrint(testing.allocator, "/api/wasm/build/{s}.wasm", .{built.body});
    defer testing.allocator.free(path);
    const wasm = try h.get(path);
    defer wasm.deinit();
    try wasm.expectStatus("200");
    try testing.expect(wasm.hasHeader("Content-Type: application/wasm"));
    try testing.expect(std.mem.startsWith(u8, wasm.body, "\x00asm"));

    // Only the finished wasm is left behind.
    var it = h.builds.dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".cache")) continue;
        try testing.expect(std.mem.endsWith(u8, entry.name, ".wasm"));
    }
}

test "a failing playground build answers 500 with file:line:col errors" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    const response = try h.post("/api/wasm/build",
        \\const Vapor = @import("vapor");
        \\
        \\export fn init() void {
        \\    Vapor.init(.{});
        \\    notDeclared();
        \\}
        \\
    );
    defer response.deinit();

    try response.expectStatus("500");
    try testing.expectEqualStrings(
        \\src/main.zig:5:5: error: use of undeclared identifier 'notDeclared'
        \\    notDeclared();
        \\    ^~~~~~~~~~~
    , response.body);
}

test "an empty build request is rejected" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    const response = try h.post("/api/wasm/build", " \n");
    defer response.deinit();
    try response.expectStatus("400");
}

test "the versions playground code is built with" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    const response = try h.get("/api/wasm/versions");
    defer response.deinit();
    try response.expectStatus("200");
    try testing.expect(response.hasHeader("Content-Type: application/json"));
    try testing.expectEqualStrings("{\"zig\":\"0.16.0\",\"vapor\":\"3.1.2\"}", response.body);
}

test "the template's versions are read from zig and its pin" {
    var builds = testing.tmpDir(.{});
    defer builds.cleanup();
    const builder: WasmBuilder = .{ .io = testing.io, .template_path = playground_template, .builds_path = "unused" };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const versions = try builder.versions(arena.allocator());
    try testing.expectEqualStrings(@import("builtin").zig_version_string, versions.zig);
    try testing.expectEqualStrings("3.1.2", versions.vapor);
}

test "a wasm that was never built is a 404" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    for ([_][]const u8{ "/api/wasm/build/0123456789abcdef.wasm", "/api/wasm/build/..%2F..%2Fbuild.zig", "/api/wasm/build/x.wasm" }) |path| {
        const response = try h.get(path);
        defer response.deinit();
        try response.expectStatus("404");
    }
}

test "a build past its deadline is stopped and cleaned up" {
    var builds = testing.tmpDir(.{});
    defer builds.cleanup();
    const builds_path = try builds.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(builds_path);

    const builder: WasmBuilder = .{
        .io = testing.io,
        .template_path = playground_template,
        .builds_path = builds_path,
        .timeout = .fromMilliseconds(50),
    };
    const outcome = try builder.build(testing.allocator, "export fn init() void {}\n");
    defer testing.allocator.free(outcome.failed);
    try testing.expectEqualStrings("error: the build took too long and was stopped", outcome.failed);

    var it = builds.dir.iterate();
    while (try it.next(testing.io)) |entry| {
        try testing.expectEqualStrings(".cache", entry.name);
    }
}

/// Stands in for `zig build` (as `Settings.zig_exe`) and holds every build
/// until the test opens the gate, so a test can act while builds are
/// running. A build that sees the gate open fails with "error: the gate
/// opened"; one that waits five seconds without it gives up with "error:
/// the gate never opened", so a server that waits on its builds fails the
/// test instead of hanging it.
const Gate = struct {
    dir: testing.TmpDir,
    path: [:0]u8,
    zig_exe: []u8,

    fn init(g: *Gate) !void {
        g.dir = testing.tmpDir(.{});
        errdefer g.dir.cleanup();
        g.path = try g.dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(g.path);
        g.zig_exe = try std.fs.path.join(testing.allocator, &.{ g.path, "zig" });
        errdefer testing.allocator.free(g.zig_exe);

        const script = try std.fmt.allocPrint(testing.allocator,
            \\#!/bin/sh
            \\touch '{0s}/started'
            \\i=0
            \\while [ ! -e '{0s}/gate' ]; do
            \\  i=$((i + 1))
            \\  if [ $i -gt 100 ]; then echo 'error: the gate never opened' >&2; exit 1; fi
            \\  sleep 0.05
            \\done
            \\echo 'error: the gate opened' >&2
            \\exit 1
            \\
        , .{g.path});
        defer testing.allocator.free(script);
        try g.dir.dir.writeFile(testing.io, .{
            .sub_path = "zig",
            .data = script,
            .flags = .{ .permissions = .executable_file },
        });
    }

    fn deinit(g: *Gate) void {
        testing.allocator.free(g.zig_exe);
        testing.allocator.free(g.path);
        g.dir.cleanup();
    }

    /// Waits until some build has started.
    fn waitStarted(g: *Gate) !void {
        for (0..500) |_| {
            if (g.dir.dir.access(testing.io, "started", .{})) |_| return else |_| {}
            try testing.io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.BuildNeverStarted;
    }

    fn open(g: *Gate) !void {
        try g.dir.dir.writeFile(testing.io, .{ .sub_path = "gate", .data = "" });
    }
};

test "a running build does not hold up other requests" {
    var gate: Gate = undefined;
    try gate.init();
    defer gate.deinit();
    var h: Harness = undefined;
    try h.startWith(.{ .allowed_origin = origin, .zig_exe = gate.zig_exe });
    defer h.stop();

    const build = try h.sendPost("/api/wasm/build", "export fn init() void {}\n");
    defer build.close(testing.io);
    try gate.waitStarted();

    // Answered while the build is still held at the gate.
    const ping = try h.get("/");
    defer ping.deinit();
    try ping.expectStatus("200");

    try gate.open();
    const built = try receive(build);
    defer built.deinit();
    try built.expectStatus("500");
    try testing.expectEqualStrings("error: the gate opened", built.body);
}

test "builds past the pool wait their turn, and past the queue answer 503" {
    var gate: Gate = undefined;
    try gate.init();
    defer gate.deinit();
    var h: Harness = undefined;
    try h.startWith(.{
        .allowed_origin = origin,
        .zig_exe = gate.zig_exe,
        .build_threads = 1,
        .build_queue = 1,
    });
    defer h.stop();

    const source = "export fn init() void {}\n";
    const running = try h.sendPost("/api/wasm/build", source);
    defer running.close(testing.io);
    try gate.waitStarted();
    const queued = try h.sendPost("/api/wasm/build", source);
    defer queued.close(testing.io);
    // The queued build reached the server before this request, and the
    // loop serves every connection that is ready before it waits again,
    // so once this is answered the queued build has been submitted.
    const ping = try h.get("/");
    ping.deinit();

    const refused = try h.post("/api/wasm/build", source);
    defer refused.deinit();
    try refused.expectStatus("503");

    try gate.open();
    for ([_]std.Io.net.Stream{ running, queued }) |stream| {
        const built = try receive(stream);
        defer built.deinit();
        try testing.expectEqualStrings("error: the gate opened", built.body);
    }
}

test "chat answers 503 when its credentials are not configured" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    for ([_][]const u8{ "/chat", "/api/vertex" }) |path| {
        const response = try h.post(path, "{\"query\": \"a counter\"}");
        defer response.deinit();
        try response.expectStatus("503");
    }
}

test "chat rejects a body without a query before calling the model" {
    var h: Harness = undefined;
    try h.startWith(.{
        .allowed_origin = origin,
        .anthropic_api_key = "not-a-key",
        .vertex_project_id = "project",
        .vertex_access_token = "not-a-token",
    });
    defer h.stop();

    for ([_][]const u8{ "/chat", "/api/vertex" }) |path| {
        for ([_][]const u8{ "a counter", "{}", "{\"query\": \"  \"}" }) |body| {
            const response = try h.post(path, body);
            defer response.deinit();
            try response.expectStatus("400");
        }
    }
}

test "every complete example in the system prompt compiles against the template" {
    var builds = testing.tmpDir(.{});
    defer builds.cleanup();
    const builds_path = try builds.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(builds_path);
    const builder: WasmBuilder = .{ .io = testing.io, .template_path = playground_template, .builds_path = builds_path };

    var sources: std.ArrayList([]const u8) = .empty;
    defer sources.deinit(testing.allocator);
    var blocks = std.mem.splitSequence(u8, chat.system_prompt, "```zig\n");
    _ = blocks.next();
    while (blocks.next()) |block| {
        const code = block[0 .. std.mem.indexOf(u8, block, "```") orelse return error.UnclosedFence];
        if (std.mem.indexOf(u8, code, "export fn init") != null) try sources.append(testing.allocator, code);
    }
    try testing.expect(sources.items.len >= 3);
    // The prompt's prose names more API than its examples use.
    try sources.append(testing.allocator, @embedFile("testdata/prompt_api.zig"));

    for (sources.items) |source| {
        switch (try builder.build(testing.allocator, source)) {
            .built => {},
            .failed => |errors| {
                defer testing.allocator.free(errors);
                std.debug.print("{s}\n---\n{s}\n", .{ errors, source });
                return error.ExampleDoesNotCompile;
            },
        }
    }
}

// ── Google sign-in ──────────────────────────────────────────────────────────

/// The `assembler-pg` container in CLAUDE.md. `TEST_DATABASE_URL` overrides.
const default_test_database_url = "postgres://postgres:postgres@127.0.0.1:54329/assembler_test";

/// A fresh `users` table in the test database. Tests that need it are
/// skipped, saying so, when no database answers.
const TestDb = struct {
    pool: *pg.Pool,

    fn open() !TestDb {
        var env = try testing.environ.createMap(testing.allocator);
        defer env.deinit();
        const uri = try std.Uri.parse(env.get("TEST_DATABASE_URL") orelse default_test_database_url);
        // Probed first: pg logs a refused connection as an error, which
        // fails the test it was meant to skip.
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = try uri.getHost(&host_buf);
        const address = try std.Io.net.IpAddress.parse(host.bytes, uri.port orelse 5432);
        const probe = address.connect(testing.io, .{ .mode = .stream }) catch |err| {
            std.debug.print("skipped: no test database at {s}:{d} ({any}); see CLAUDE.md\n", .{ host.bytes, uri.port orelse 5432, err });
            return error.SkipZigTest;
        };
        probe.close(testing.io);
        const pool = try pg.Pool.initUri(testing.io, testing.allocator, uri, .{ .size = 2 });
        errdefer pool.deinit();
        _ = try pool.exec("DROP TABLE IF EXISTS users", .{});
        try users.migrate(pool);
        return .{ .pool = pool };
    }

    fn close(db: TestDb) void {
        db.pool.deinit();
    }

    fn count(db: TestDb) !i64 {
        var row = (try db.pool.row("SELECT count(*) FROM users", .{})).?;
        defer row.deinit() catch {};
        return row.get(i64, 0);
    }

    fn nameOf(db: TestDb, google_sub: []const u8) ![]u8 {
        var row = (try db.pool.row("SELECT name FROM users WHERE google_sub = $1", .{google_sub})) orelse return error.NoSuchUser;
        defer row.deinit() catch {};
        return testing.allocator.dupe(u8, try row.get([]const u8, 0));
    }
};

/// Stands in for Google's token endpoint: answers each request with
/// `status` and `answer`, and keeps the form it was sent.
///
/// While `held` is set it keeps a request waiting, as a slow Google would.
/// If the test has not released it within five seconds it refuses the
/// request, so a server that waits on Google fails the test instead of
/// hanging it.
const FakeGoogle = struct {
    server: std.Io.net.Server,
    thread: std.Thread,
    url: []u8,
    status: std.http.Status = .ok,
    answer: []u8 = &.{},
    form: []u8 = &.{},
    stopping: std.atomic.Value(bool) = .init(false),
    held: std.atomic.Value(bool) = .init(false),
    /// Requests received so far.
    received: std.atomic.Value(usize) = .init(0),

    fn start(g: *FakeGoogle) !void {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        g.* = .{ .server = try address.listen(testing.io, .{ .reuse_address = true }), .thread = undefined, .url = undefined };
        errdefer g.server.deinit(testing.io);
        g.url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/token", .{g.server.socket.address.getPort()});
        errdefer testing.allocator.free(g.url);
        g.thread = try std.Thread.spawn(.{}, serve, .{g});
    }

    fn stop(g: *FakeGoogle) void {
        g.stopping.store(true, .release);
        // Wakes the accept the thread is blocked in.
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(g.server.socket.address.getPort()) };
        if (address.connect(testing.io, .{ .mode = .stream })) |stream| stream.close(testing.io) else |_| {}
        g.thread.join();
        g.server.deinit(testing.io);
        testing.allocator.free(g.url);
        testing.allocator.free(g.answer);
        testing.allocator.free(g.form);
    }

    /// Answers the next exchange with a token response whose id token
    /// carries these claims.
    fn signIn(g: *FakeGoogle, sub: []const u8, name: []const u8, audience: []const u8) !void {
        const now = std.Io.Timestamp.now(testing.io, .real).toSeconds();
        const id_token = try JWT.encode(testing.allocator, .{ .alg = .HS256, .typ = "JWT" }, .{
            .iss = "https://accounts.google.com",
            .azp = audience,
            .aud = audience,
            .sub = sub,
            .email = "ada@example.com",
            .email_verified = true,
            .name = name,
            .iat = now,
            .exp = now + 3600,
        }, .{ .secret = "not-googles-key" });
        defer testing.allocator.free(id_token);
        try g.respond(.ok, try std.fmt.allocPrint(testing.allocator,
            \\{{"access_token":"ya29.fake","token_type":"Bearer","expires_in":3599,
            \\ "refresh_token":"refresh-1","id_token":"{s}"}}
        , .{id_token}));
    }

    /// Takes ownership of `answer`.
    fn respond(g: *FakeGoogle, status: std.http.Status, answer: []u8) !void {
        testing.allocator.free(g.answer);
        g.status = status;
        g.answer = answer;
    }

    fn serve(g: *FakeGoogle) void {
        while (true) {
            const stream = g.server.accept(testing.io) catch return;
            defer stream.close(testing.io);
            if (g.stopping.load(.acquire)) return;
            g.handle(stream) catch |err| std.debug.print("fake google: {any}\n", .{err});
        }
    }

    fn handle(g: *FakeGoogle, stream: std.Io.net.Stream) !void {
        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var reader = stream.reader(testing.io, &read_buf);
        var writer = stream.writer(testing.io, &write_buf);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        var body_buf: [1024]u8 = undefined;
        const form = try request.readerExpectNone(&body_buf).allocRemaining(testing.allocator, .unlimited);
        testing.allocator.free(g.form);
        g.form = form;
        _ = g.received.fetchAdd(1, .acq_rel);

        var waited: usize = 0;
        while (g.held.load(.acquire)) : (waited += 1) {
            if (waited == 500) {
                try request.respond("{\"error\":\"held too long\"}", .{ .status = .bad_request, .keep_alive = false });
                return writer.interface.flush();
            }
            try testing.io.sleep(.fromMilliseconds(10), .awake);
        }
        try request.respond(g.answer, .{
            .status = g.status,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
        try writer.interface.flush();
    }
};

fn signInSettings(google: *const FakeGoogle) Settings {
    return .{
        .allowed_origin = origin,
        .google_client_id = "test-client",
        .google_client_secret = "test-secret",
        .session_secret = "0123456789abcdef0123456789abcdef",
        .google_token_url = google.url,
    };
}

/// What vapor's KeyStone posts after Google sends the browser back.
fn exchange(h: *Harness, code: []const u8) !Response {
    const body = try std.fmt.allocPrint(testing.allocator, "auth-code={s}&state=&nonce=", .{code});
    defer testing.allocator.free(body);
    return h.postWith("/exchange/google/token", "Content-Type: application/x-www-form-urlencoded\r\n", body);
}

/// The value of the `Set-Cookie` named `name`, up to its first attribute.
fn cookie(r: Response, comptime name: []const u8) ?[]const u8 {
    const prefix = "Set-Cookie: " ++ name ++ "=";
    const at = std.mem.indexOf(u8, r.head, prefix) orelse return null;
    const value = r.head[at + prefix.len ..];
    return value[0..std.mem.indexOfAny(u8, value, ";\r").?];
}

const Exchanged = struct {
    success: bool,
    token: []const u8,
    user: struct { id: []const u8, email: []const u8, name: []const u8 },
};

const Bootstrapped = struct {
    state: []const u8,
    session: ?struct { user: struct { id: []const u8, email: []const u8 } } = null,
};

test "Google sign-in stores the user and starts a session the next request sees" {
    const db = try TestDb.open();
    defer db.close();
    var google: FakeGoogle = undefined;
    try google.start();
    defer google.stop();
    var h: Harness = undefined;
    try h.startWithDb(signInSettings(&google), db.pool);
    defer h.stop();

    try google.signIn("google-sub-1", "Ada", "test-client");
    const signed_in = try exchange(&h, "4/code-1");
    defer signed_in.deinit();
    try signed_in.expectStatus("200");
    const parsed = try std.json.parseFromSlice(Exchanged, testing.allocator, signed_in.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(parsed.value.success);
    try testing.expectEqualStrings("1", parsed.value.user.id);
    try testing.expectEqualStrings("ada@example.com", parsed.value.user.email);
    try testing.expectEqualStrings("Ada", parsed.value.user.name);

    // The backend sent Google the code and its own credentials.
    try testing.expect(std.mem.indexOf(u8, google.form, "code=4%2Fcode-1") != null);
    try testing.expect(std.mem.indexOf(u8, google.form, "client_secret=test-secret") != null);
    try testing.expect(std.mem.indexOf(u8, google.form, "redirect_uri=http%3A%2F%2Flocalhost%3A5173%2Fauth%2Fcallback") != null);

    // The session and Google's refresh token travel as HttpOnly cookies.
    const session = cookie(signed_in, "keystone_session_token") orelse return error.NoSessionCookie;
    try testing.expectEqualStrings(parsed.value.token, session);
    try testing.expectEqualStrings("refresh-1", cookie(signed_in, "keystone_refresh_token") orelse return error.NoRefreshCookie);
    try testing.expect(std.mem.indexOf(u8, signed_in.head, "HttpOnly; SameSite=Lax") != null);

    const cookie_header = try std.fmt.allocPrint(testing.allocator, "Cookie: keystone_session_token={s}\r\n", .{session});
    defer testing.allocator.free(cookie_header);
    const boot = try h.postWith("/auth/session/bootstrap", cookie_header, "");
    defer boot.deinit();
    try boot.expectStatus("200");
    const booted = try std.json.parseFromSlice(Bootstrapped, testing.allocator, boot.body, .{ .ignore_unknown_fields = true });
    defer booted.deinit();
    try testing.expectEqualStrings("signed_in", booted.value.state);
    try testing.expectEqualStrings("1", booted.value.session.?.user.id);

    // Signing in again is the same user, brought up to date.
    try google.signIn("google-sub-1", "Ada Lovelace", "test-client");
    const again = try exchange(&h, "4/code-2");
    defer again.deinit();
    try again.expectStatus("200");
    try testing.expectEqual(@as(i64, 1), try db.count());
    const name = try db.nameOf("google-sub-1");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("Ada Lovelace", name);
}

test "a sign-in waiting on Google does not hold up other requests" {
    const db = try TestDb.open();
    defer db.close();
    var google: FakeGoogle = undefined;
    try google.start();
    defer google.stop();
    var h: Harness = undefined;
    try h.startWithDb(signInSettings(&google), db.pool);
    defer h.stop();

    try google.signIn("google-sub-1", "Ada", "test-client");
    google.held.store(true, .release);
    const pending = try h.sendPostWith(
        "/exchange/google/token",
        "Content-Type: application/x-www-form-urlencoded\r\n",
        "auth-code=4/slow&state=&nonce=",
    );
    defer pending.close(testing.io);
    for (0..500) |_| {
        if (google.received.load(.acquire) > 0) break;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    } else return error.GoogleNeverAsked;

    // Answered while the sign-in is still waiting on Google.
    const ping = try h.get("/");
    defer ping.deinit();
    try ping.expectStatus("200");

    google.held.store(false, .release);
    const signed_in = try receive(pending);
    defer signed_in.deinit();
    try signed_in.expectStatus("200");
    try testing.expect(cookie(signed_in, "keystone_session_token") != null);
}

test "a code Google refuses is a 401 and stores nobody" {
    const db = try TestDb.open();
    defer db.close();
    var google: FakeGoogle = undefined;
    try google.start();
    defer google.stop();
    var h: Harness = undefined;
    try h.startWithDb(signInSettings(&google), db.pool);
    defer h.stop();

    try google.respond(.bad_request, try testing.allocator.dupe(u8, "{\"error\":\"invalid_grant\"}"));
    const refused = try exchange(&h, "4/used-already");
    defer refused.deinit();
    try refused.expectStatus("401");
    try testing.expect(cookie(refused, "keystone_session_token") == null);
    try testing.expectEqual(@as(i64, 0), try db.count());
}

test "an id token Google issued to another app is refused" {
    const db = try TestDb.open();
    defer db.close();
    var google: FakeGoogle = undefined;
    try google.start();
    defer google.stop();
    var h: Harness = undefined;
    try h.startWithDb(signInSettings(&google), db.pool);
    defer h.stop();

    try google.signIn("google-sub-1", "Ada", "someone-elses-client");
    const refused = try exchange(&h, "4/code-1");
    defer refused.deinit();
    try refused.expectStatus("401");
    try testing.expectEqual(@as(i64, 0), try db.count());
}

test "without a database, sign-in still works and the session names the Google account" {
    var google: FakeGoogle = undefined;
    try google.start();
    defer google.stop();
    var h: Harness = undefined;
    try h.startWithDb(signInSettings(&google), null);
    defer h.stop();

    try google.signIn("google-sub-1", "Ada", "test-client");
    const signed_in = try exchange(&h, "4/code-1");
    defer signed_in.deinit();
    try signed_in.expectStatus("200");
    const parsed = try std.json.parseFromSlice(Exchanged, testing.allocator, signed_in.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("google-sub-1", parsed.value.user.id);

    const session = cookie(signed_in, "keystone_session_token") orelse return error.NoSessionCookie;
    const cookie_header = try std.fmt.allocPrint(testing.allocator, "Cookie: keystone_session_token={s}\r\n", .{session});
    defer testing.allocator.free(cookie_header);
    const boot = try h.postWith("/auth/session/bootstrap", cookie_header, "");
    defer boot.deinit();
    const booted = try std.json.parseFromSlice(Bootstrapped, testing.allocator, boot.body, .{ .ignore_unknown_fields = true });
    defer booted.deinit();
    try testing.expectEqualStrings("signed_in", booted.value.state);
    try testing.expectEqualStrings("google-sub-1", booted.value.session.?.user.id);
}

test "a session signed with another key is signed out" {
    var google: FakeGoogle = undefined;
    try google.start();
    defer google.stop();
    var h: Harness = undefined;
    try h.startWithDb(signInSettings(&google), null);
    defer h.stop();

    const forged = try JWT.encode(testing.allocator, .{ .alg = .HS256, .typ = "JWT" }, .{
        .sub = "1",
        .email = "ada@example.com",
        .name = "Ada",
        .iat = std.Io.Timestamp.now(testing.io, .real).toSeconds(),
        .exp = std.Io.Timestamp.now(testing.io, .real).toSeconds() + 3600,
    }, .{ .secret = "not-the-session-secret-not-it-at-all" });
    defer testing.allocator.free(forged);
    const cookie_header = try std.fmt.allocPrint(testing.allocator, "Cookie: keystone_session_token={s}\r\n", .{forged});
    defer testing.allocator.free(cookie_header);

    for ([_][]const u8{ "", cookie_header }) |headers| {
        const boot = try h.postWith("/auth/session/bootstrap", headers, "");
        defer boot.deinit();
        try boot.expectStatus("200");
        const booted = try std.json.parseFromSlice(Bootstrapped, testing.allocator, boot.body, .{ .ignore_unknown_fields = true });
        defer booted.deinit();
        try testing.expectEqualStrings("signed_out", booted.value.state);
    }
}
