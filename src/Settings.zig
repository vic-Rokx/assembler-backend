//! Runtime settings, read once from the environment in `main`.
//!
//! Zig 0.16 has no `getenv`; the environment arrives through
//! `std.process.Init`, so this takes the map rather than reading globals.
const std = @import("std");
const Environ = std.process.Environ;

const Settings = @This();

/// Loopback by default: the build endpoint runs `zig build` on whatever it
/// is sent, so exposing it is a deliberate choice (`HOST=0.0.0.0`).
host: []const u8 = "127.0.0.1",
port: u16 = 8080,
/// The frontend's origin. Requests carry credentials, so CORS cannot use
/// `*` and must name the origin exactly. 5173 is metal's dev server.
allowed_origin: []const u8 = "http://localhost:5173",
/// The fixed project playground code is built in.
playground_template: []const u8 = "playground_template",
/// Per-build folders and finished `.wasm` files. Created if missing.
builds_dir: []const u8 = "builds",
zig_exe: []const u8 = "zig",
build_timeout_seconds: u32 = 60,

pub fn fromEnv(env: *const Environ.Map) !Settings {
    var settings: Settings = .{};
    if (env.get("HOST")) |host| settings.host = host;
    if (env.get("PORT")) |port| {
        settings.port = std.fmt.parseInt(u16, port, 10) catch return error.InvalidPort;
    }
    if (env.get("ALLOWED_ORIGIN")) |origin| settings.allowed_origin = origin;
    if (env.get("PLAYGROUND_TEMPLATE")) |path| settings.playground_template = path;
    if (env.get("BUILDS_DIR")) |path| settings.builds_dir = path;
    if (env.get("ZIG")) |path| settings.zig_exe = path;
    if (env.get("BUILD_TIMEOUT_SECONDS")) |seconds| {
        settings.build_timeout_seconds = std.fmt.parseInt(u32, seconds, 10) catch return error.InvalidBuildTimeout;
    }
    return settings;
}

test "defaults when the environment is empty" {
    var env = Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const settings = try fromEnv(&env);
    try std.testing.expectEqualStrings("127.0.0.1", settings.host);
    try std.testing.expectEqual(@as(u16, 8080), settings.port);
    try std.testing.expectEqualStrings("http://localhost:5173", settings.allowed_origin);
}

test "reads overrides from the environment" {
    var env = Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOST", "0.0.0.0");
    try env.put("PORT", "9090");
    try env.put("ALLOWED_ORIGIN", "https://assembler.example");
    try env.put("BUILD_TIMEOUT_SECONDS", "20");

    const settings = try fromEnv(&env);
    try std.testing.expectEqualStrings("0.0.0.0", settings.host);
    try std.testing.expectEqual(@as(u16, 9090), settings.port);
    try std.testing.expectEqualStrings("https://assembler.example", settings.allowed_origin);
    try std.testing.expectEqual(@as(u32, 20), settings.build_timeout_seconds);
}

test "rejects a port that is not a u16" {
    var env = Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PORT", "70000");

    try std.testing.expectError(error.InvalidPort, fromEnv(&env));
}
