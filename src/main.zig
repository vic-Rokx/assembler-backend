const std = @import("std");
const app = @import("app.zig");
const Settings = @import("Settings.zig");
const WasmBuilder = @import("WasmBuilder.zig");
const users = @import("users.zig");
const pg = @import("pg_orm").pg;

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

    // Builds would fail anyway if zig cannot run, so find out now.
    const versions = builder.versions(arena) catch |err| {
        std.log.err("reading the playground's zig and vapor versions: {any}", .{err});
        return err;
    };

    // Sign-in stores users, so its database must be there from the start
    // rather than fail the first person to sign in.
    const db: ?*pg.Pool = if (settings.signInConfigured()) blk: {
        const uri = std.Uri.parse(settings.database_url) catch return error.InvalidDatabaseUrl;
        const pool = pg.Pool.initUri(io, init.gpa, uri, .{ .size = 4 }) catch |err| {
            // Not the URL: it carries the password.
            std.log.err("could not open the database: {any}", .{err});
            return err;
        };
        errdefer pool.deinit();
        try users.migrate(pool);
        break :blk pool;
    } else null;
    defer if (db) |pool| pool.deinit();

    var server: app.Server = undefined;
    try server.new(.{ .host = settings.host, .port = settings.port }, arena);
    defer server.deinit();
    // Leak-checked in Debug, and threadsafe as replies need.
    server.reply_allocator = init.gpa;

    try server.installSignalHandlers();
    try app.register(&server, settings, io, init.gpa, builder, versions, db);
    // Before `server.deinit`: jobs still queued send their replies.
    defer app.deinit();

    std.log.info("listening on {s}:{d}, CORS origin {s}, sign-in {s}", .{
        settings.host,
        settings.port,
        settings.allowed_origin,
        if (settings.signInConfigured()) "on" else "off",
    });
    try server.listen();
}

test {
    _ = Settings;
    _ = WasmBuilder;
    _ = @import("chat.zig");
    _ = users;
    _ = @import("tests.zig");
}
