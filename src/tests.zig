//! The real routes on a real server, on an ephemeral port, driven over a
//! socket. Handler logic that does not need a server is tested next to it.
const std = @import("std");
const testing = std.testing;
const app = @import("app.zig");
const Settings = @import("Settings.zig");

const origin = "http://frontend.test";

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    server: app.Server,
    thread: std.Thread,
    port: u16,

    /// Binds before the loop starts, so the port is connectable as soon as
    /// this returns. `h` must not move while the server runs.
    fn start(h: *Harness) !void {
        h.arena = .init(testing.allocator);
        errdefer h.arena.deinit();
        try h.server.new(.{ .port = 0 }, h.arena.allocator());
        errdefer h.server.deinit();
        try app.register(&h.server, .{ .allowed_origin = origin });
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
        h.arena.deinit();
    }

    /// Sends one request that asks the server to close, and reads the
    /// whole response. Caller owns the result.
    fn roundTrip(h: *Harness, request: []const u8) ![]u8 {
        const io = testing.io;
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(h.port) };
        const stream = try address.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        var write_buf: [1024]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        try writer.interface.writeAll(request);
        try writer.interface.flush();

        var read_buf: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        return reader.interface.allocRemaining(testing.allocator, .limited(1024 * 1024));
    }
};

test "GET / answers SUCCESS with credentialed CORS for the configured origin" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    const response = try h.roundTrip("GET / HTTP/1.1\r\nHost: x\r\nOrigin: " ++ origin ++ "\r\nConnection: close\r\n\r\n");
    defer testing.allocator.free(response);

    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
    try testing.expect(std.mem.endsWith(u8, response, "\r\n\r\nSUCCESS"));
    try testing.expect(std.mem.indexOf(u8, response, "Access-Control-Allow-Origin: " ++ origin ++ "\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, response, "Access-Control-Allow-Credentials: true\r\n") != null);
}

test "a JSON preflight is allowed, with the requested headers echoed" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    const response = try h.roundTrip("OPTIONS /chat HTTP/1.1\r\nHost: x\r\nOrigin: " ++ origin ++
        "\r\nAccess-Control-Request-Method: POST\r\nAccess-Control-Request-Headers: content-type\r\nConnection: close\r\n\r\n");
    defer testing.allocator.free(response);

    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, response, "Access-Control-Allow-Origin: " ++ origin ++ "\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, response, "Access-Control-Allow-Headers: content-type\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, response, "Access-Control-Allow-Methods: ") != null);
}
