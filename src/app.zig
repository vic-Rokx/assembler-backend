//! Routes and middleware for the assembler-chat backend.
const std = @import("std");
const reverb = @import("reverb");
const Context = reverb.Context;
const Settings = @import("Settings.zig");

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    max: usize = 256,
    /// Reverb puts a receive buffer of this size on the stack, so it stays
    /// well under the 8 MB main-thread stack. Playground sources and chat
    /// prompts are a few KB.
    max_body_size: usize = 1024 * 1024,
};

pub const Server = reverb.Server(Config);

pub fn register(server: *Server, settings: Settings) !void {
    try server.useCors(.{ .cors_headers = .{
        .origin = .{ .override = settings.allowed_origin },
        .credentials = .{ .override = "true" },
    } });

    try server.get("/", ping, &.{});
}

fn ping(ctx: *Context) !void {
    try ctx.STRING("SUCCESS");
}
