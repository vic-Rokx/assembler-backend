//! `POST /chat` and `POST /api/vertex`: the frontend's prompt, answered by
//! Claude under the vapor 3.x system prompt. The reply body is the model's
//! text, which the frontend puts in the playground editor as `main.zig`.
const std = @import("std");
const claude = @import("claude");
const vertex = @import("vertex");
const Context = @import("reverb").Context;
const Settings = @import("Settings.zig");

/// Its examples are compiled against the playground template by the tests.
pub const system_prompt = @embedFile("vapor_prompt.md");

/// The request is not streamed, so this stays at a size that answers in
/// reasonable time while fitting a whole `main.zig` and the model's thinking.
const max_tokens = 16000;

const Query = struct { query: []const u8 };

pub fn anthropic(ctx: *Context, settings: *const Settings) !void {
    const api_key = settings.anthropic_api_key orelse
        return ctx.ERROR(503, "ANTHROPIC_API_KEY is not set on the backend");
    const query = readQuery(ctx) orelse return ctx.ERROR(400, "expected JSON {\"query\": \"...\"}");

    var provider: claude.Provider = undefined;
    claude.Provider.init(&provider, .{
        .api_key = api_key,
        .model = settings.claude_model,
        .max_tokens = max_tokens,
    }, ctx.requestAllocator());
    // Not `chat()`: it sends a temperature, which current models reject.
    const response = provider.createMessage(.{
        .messages = &.{.{ .role = .user, .content = query }},
        .system = system_prompt,
    }) catch |err| {
        std.log.err("claude: {any}", .{err});
        return ctx.ERROR(502, "the Claude request failed");
    };
    try reply(ctx, response);
}

pub fn googleVertex(ctx: *Context, settings: *const Settings) !void {
    const project_id = settings.vertex_project_id orelse
        return ctx.ERROR(503, "VERTEX_PROJECT_ID is not set on the backend");
    const access_token = settings.vertex_access_token orelse
        return ctx.ERROR(503, "VERTEX_ACCESS_TOKEN is not set on the backend");
    const query = readQuery(ctx) orelse return ctx.ERROR(400, "expected JSON {\"query\": \"...\"}");

    var provider: vertex.Provider = undefined;
    vertex.Provider.init(&provider, .{
        .backend = .{ .vertex = .{
            .project_id = project_id,
            .access_token = access_token,
            .region = settings.vertex_region,
        } },
        .model = settings.vertex_model,
        .max_tokens = max_tokens,
    }, ctx.requestAllocator());
    const response = provider.createMessage(.{
        .messages = &.{.{ .role = .user, .content = query }},
        .system = system_prompt,
    }) catch |err| {
        std.log.err("vertex: {any}", .{err});
        return ctx.ERROR(502, "the Vertex request failed");
    };
    try reply(ctx, response);
}

/// The prompt from `{"query": "..."}`, or null if there is none.
fn readQuery(ctx: *Context) ?[]const u8 {
    var body: Query = undefined;
    ctx.bind(Query, &body) catch return null;
    if (std.mem.trim(u8, body.query, " \t\r\n").len == 0) return null;
    return body.query;
}

/// Sends the response's text. `response` is a claude or a vertex
/// `MessageResponse`; the two have the same shape.
fn reply(ctx: *Context, response: anytype) !void {
    const stop_reason = response.stop_reason orelse "";
    if (std.mem.eql(u8, stop_reason, "refusal")) return ctx.ERROR(502, "Claude declined this request");
    if (std.mem.eql(u8, stop_reason, "max_tokens")) std.log.warn("reply cut off at max_tokens ({d})", .{max_tokens});

    const text = try joinText(ctx.requestAllocator(), response.content);
    if (text.len == 0) return ctx.ERROR(502, "Claude returned no text");
    try ctx.STRING(text);
}

/// The text blocks of a reply, in order. Thinking blocks carry no `text`
/// and are skipped.
fn joinText(gpa: std.mem.Allocator, blocks: anytype) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (blocks) |block| {
        if (!std.mem.eql(u8, block.type, "text")) continue;
        try out.appendSlice(gpa, block.text orelse continue);
    }
    return out.toOwnedSlice(gpa);
}

test "joinText keeps text blocks in order and skips the rest" {
    var blocks = [_]claude.ContentBlock{
        .{ .type = "thinking" },
        .{ .type = "text", .text = "const std = " },
        .{ .type = "text", .text = "@import(\"std\");\n" },
    };
    const text = try joinText(std.testing.allocator, &blocks);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("const std = @import(\"std\");\n", text);
}
