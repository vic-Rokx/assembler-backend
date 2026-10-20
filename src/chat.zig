//! `POST /chat` and `POST /api/vertex`: the frontend's prompt, answered by
//! Claude under the vapor 3.x system prompt. The reply body is the model's
//! text, which the frontend puts in the playground editor as `main.zig`.
//!
//! A model call can take minutes, so it runs on a chat worker: the handler
//! (in `app.zig`) checks what it can on the loop thread with `unconfigured`
//! and `readQuery`, then queues a `Job` that `answer` completes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const claude = @import("claude");
const vertex = @import("vertex");
const reverb = @import("reverb");
const Context = reverb.Context;
const Settings = @import("Settings.zig");

/// Its examples are compiled against the playground template by the tests.
pub const system_prompt = @embedFile("vapor_prompt.md");

/// The request is not streamed, so this stays at a size that answers in
/// reasonable time while fitting a whole `main.zig` and the model's thinking.
const max_tokens = 16000;

const content_type = "text/plain; charset=utf-8";

pub const Provider = enum { anthropic, vertex };

/// One model call, for a chat worker.
pub const Job = struct {
    reply: *reverb.Reply,
    provider: Provider,
    /// Owned by the job; `answer` frees it.
    query: []u8,
};

/// Why `provider` cannot be called, for a 503, or null if it can.
pub fn unconfigured(settings: *const Settings, provider: Provider) ?[]const u8 {
    switch (provider) {
        .anthropic => if (settings.anthropic_api_key == null) return "ANTHROPIC_API_KEY is not set on the backend",
        .vertex => {
            if (settings.vertex_project_id == null) return "VERTEX_PROJECT_ID is not set on the backend";
            if (settings.vertex_access_token == null) return "VERTEX_ACCESS_TOKEN is not set on the backend";
        },
    }
    return null;
}

const Query = struct { query: []const u8 };

/// The prompt from `{"query": "..."}`, or null if there is none. Points
/// into the request.
pub fn readQuery(ctx: *Context) ?[]const u8 {
    var body: Query = undefined;
    ctx.bind(Query, &body) catch return null;
    if (std.mem.trim(u8, body.query, " \t\r\n").len == 0) return null;
    return body.query;
}

/// Calls the model and sends its reply. Runs on a chat worker. `gpa` must
/// be threadsafe.
pub fn answer(gpa: Allocator, settings: *const Settings, job: Job) void {
    defer gpa.free(job.query);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const result = ask(arena.allocator(), settings, job.provider, job.query);
    job.reply.send(result.status, content_type, result.body);
}

const Answer = struct { status: u16, body: []const u8 };

/// The provider's credentials were checked by `unconfigured` before the
/// job was queued, and settings do not change after startup.
fn ask(arena: Allocator, settings: *const Settings, provider: Provider, query: []const u8) Answer {
    switch (provider) {
        .anthropic => {
            var client: claude.Provider = undefined;
            claude.Provider.init(&client, .{
                .api_key = settings.anthropic_api_key.?,
                .model = settings.claude_model,
                .max_tokens = max_tokens,
            }, arena);
            // Not `chat()`: it sends a temperature, which current models reject.
            const response = client.createMessage(.{
                .messages = &.{.{ .role = .user, .content = query }},
                .system = system_prompt,
            }) catch |err| {
                std.log.err("claude: {any}", .{err});
                return .{ .status = 502, .body = "the Claude request failed" };
            };
            return fromResponse(arena, response);
        },
        .vertex => {
            var client: vertex.Provider = undefined;
            vertex.Provider.init(&client, .{
                .backend = .{ .vertex = .{
                    .project_id = settings.vertex_project_id.?,
                    .access_token = settings.vertex_access_token.?,
                    .region = settings.vertex_region,
                } },
                .model = settings.vertex_model,
                .max_tokens = max_tokens,
            }, arena);
            const response = client.createMessage(.{
                .messages = &.{.{ .role = .user, .content = query }},
                .system = system_prompt,
            }) catch |err| {
                std.log.err("vertex: {any}", .{err});
                return .{ .status = 502, .body = "the Vertex request failed" };
            };
            return fromResponse(arena, response);
        },
    }
}

/// The response's text. `response` is a claude or a vertex
/// `MessageResponse`; the two have the same shape.
fn fromResponse(arena: Allocator, response: anytype) Answer {
    const stop_reason = response.stop_reason orelse "";
    if (std.mem.eql(u8, stop_reason, "refusal")) return .{ .status = 502, .body = "Claude declined this request" };
    if (std.mem.eql(u8, stop_reason, "max_tokens")) std.log.warn("reply cut off at max_tokens ({d})", .{max_tokens});

    const text = joinText(arena, response.content) catch return .{ .status = 500, .body = "out of memory" };
    if (text.len == 0) return .{ .status = 502, .body = "Claude returned no text" };
    return .{ .status = 200, .body = text };
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
