const std = @import("std");
const app = @import("app.zig");
const Settings = @import("Settings.zig");
const WasmBuilder = @import("WasmBuilder.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const settings = Settings.fromEnv(init.environ_map) catch |err| {
        std.log.err("bad environment: {any}", .{err});
        return err;
    };

    // `zig build` runs inside each build folder, so the paths it is given
    // must not depend on this process's working directory.
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, settings.builds_dir);
    const builder: WasmBuilder = .{
        .io = io,
        .template_path = cwd.realPathFileAlloc(io, settings.playground_template, arena) catch |err| {
            std.log.err("playground template {s}: {any}", .{ settings.playground_template, err });
            return err;
        },
        .builds_path = try cwd.realPathFileAlloc(io, settings.builds_dir, arena),
        .zig_exe = settings.zig_exe,
        .timeout = .fromSeconds(settings.build_timeout_seconds),
    };

    var server: app.Server = undefined;
    try server.new(.{ .host = settings.host, .port = settings.port }, arena);
    defer server.deinit();
    // Leak-checked in Debug, and threadsafe as replies need.
    server.reply_allocator = init.gpa;

    try server.installSignalHandlers();
    try app.register(&server, settings, io, init.gpa, builder);
    // Before `server.deinit`: jobs still queued send their replies.
    defer app.deinit();

    std.log.info("listening on {s}:{d}, CORS origin {s}", .{ settings.host, settings.port, settings.allowed_origin });
    try server.listen();
}

test {
    _ = Settings;
    _ = WasmBuilder;
    _ = @import("chat.zig");
    _ = @import("tests.zig");
}
