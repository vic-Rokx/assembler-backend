const std = @import("std");
const app = @import("app.zig");
const Settings = @import("Settings.zig");

pub fn main(init: std.process.Init) !void {
    const settings = Settings.fromEnv(init.environ_map) catch |err| {
        std.log.err("bad environment: {any}", .{err});
        return err;
    };

    var server: app.Server = undefined;
    try server.new(.{ .host = settings.host, .port = settings.port }, init.arena.allocator());
    defer server.deinit();

    try server.installSignalHandlers();
    try app.register(&server, settings);

    std.log.info("listening on {s}:{d}, CORS origin {s}", .{ settings.host, settings.port, settings.allowed_origin });
    try server.listen();
}

test {
    _ = Settings;
    _ = @import("tests.zig");
}
