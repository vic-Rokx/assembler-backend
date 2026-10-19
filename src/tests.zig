//! The real routes on a real server, on an ephemeral port, driven over a
//! socket. Handler logic that does not need a server is tested next to it.
const std = @import("std");
const testing = std.testing;
const app = @import("app.zig");
const WasmBuilder = @import("WasmBuilder.zig");
const Settings = @import("Settings.zig");
const chat = @import("chat.zig");
const playground_template = @import("test_options").playground_template;

const origin = "http://frontend.test";

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
        h.arena = .init(testing.allocator);
        errdefer h.arena.deinit();
        h.builds = testing.tmpDir(.{});
        errdefer h.builds.cleanup();

        const builder: WasmBuilder = .{
            .io = testing.io,
            .template_path = playground_template,
            .builds_path = try h.builds.dir.realPathFileAlloc(testing.io, ".", h.arena.allocator()),
        };

        try h.server.new(.{ .port = 0 }, h.arena.allocator());
        errdefer h.server.deinit();
        try app.register(&h.server, settings, testing.io, builder);
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
        h.server.deinit();
        h.builds.cleanup();
        h.arena.deinit();
    }

    /// Sends one request and reads one response, framed by its
    /// Content-Length. Caller frees with `Response.deinit`.
    fn roundTrip(h: *Harness, request: []const u8) !Response {
        const io = testing.io;
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(h.port) };
        const stream = try address.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        var write_buf: [1024]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        try writer.interface.writeAll(request);
        try writer.interface.flush();

        var read_buf: [64 * 1024]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
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

    fn post(h: *Harness, path: []const u8, body: []const u8) !Response {
        const request = try std.fmt.allocPrint(
            testing.allocator,
            "POST {s} HTTP/1.1\r\nHost: x\r\nOrigin: " ++ origin ++ "\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ path, body.len, body },
        );
        defer testing.allocator.free(request);
        return h.roundTrip(request);
    }

    fn get(h: *Harness, path: []const u8) !Response {
        const request = try std.fmt.allocPrint(testing.allocator, "GET {s} HTTP/1.1\r\nHost: x\r\nOrigin: " ++ origin ++ "\r\n\r\n", .{path});
        defer testing.allocator.free(request);
        return h.roundTrip(request);
    }
};

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
