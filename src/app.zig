//! Routes and middleware for the assembler-chat backend.
const std = @import("std");
const reverb = @import("reverb");
const Context = reverb.Context;
const Settings = @import("Settings.zig");
const WasmBuilder = @import("WasmBuilder.zig");
const chat = @import("chat.zig");

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

/// What the handlers need. Reverb handlers take only a `Context`, so this
/// is set once by `register`.
const State = struct {
    settings: Settings,
    io: std.Io,
    builder: WasmBuilder,
};
var state: State = undefined;

pub fn register(server: *Server, settings: Settings, io: std.Io, builder: WasmBuilder) !void {
    state = .{ .settings = settings, .io = io, .builder = builder };

    try server.useCors(.{ .cors_headers = .{
        .origin = .{ .override = settings.allowed_origin },
        .credentials = .{ .override = "true" },
    } });

    try server.get("/", ping, &.{});
    try server.post("/chat", postChat, &.{});
    try server.post("/api/vertex", postVertex, &.{});
    try server.post("/api/wasm/build", buildWasm, &.{});
    try server.get("/api/wasm/build/:file", getWasm, &.{});
}

fn ping(ctx: *Context) !void {
    try ctx.STRING("SUCCESS");
}

fn postChat(ctx: *Context) !void {
    try chat.anthropic(ctx, &state.settings);
}

fn postVertex(ctx: *Context) !void {
    try chat.googleVertex(ctx, &state.settings);
}

/// The body is the playground's `main.zig`. Answers 200 with the build id,
/// or 500 with the compiler's `file:line:col: error: ...` lines.
fn buildWasm(ctx: *Context) !void {
    const source = ctx.body();
    if (std.mem.trim(u8, source, " \t\r\n").len == 0) return ctx.ERROR(400, "error: empty source");

    const outcome = state.builder.build(ctx.requestAllocator(), source) catch |err| {
        std.log.err("wasm build: {any}", .{err});
        return ctx.ERROR(500, "error: the build server failed");
    };
    switch (outcome) {
        .built => |id| try ctx.STRING(&id),
        .failed => |errors| try ctx.ERROR(500, errors),
    }
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
