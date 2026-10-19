//! Compiles playground source to wasm against the fixed template project.
//!
//! Each build gets its own folder, `<builds>/<id>/`: a copy of the template
//! with the source written to `src/main.zig`. Nothing in a request chooses a
//! path, a build option or a flag. A successful build leaves only
//! `<builds>/<id>.wasm`; the folder is deleted either way.
//!
//! Untrusted code only reaches the compiler: `comptime` cannot do I/O and
//! `@embedFile` cannot leave the package. What it can do is burn CPU and
//! memory, so every build runs under a wall-clock deadline that kills the
//! whole `zig build` process group. Builds are serialized by the server's
//! single event loop. Memory is not capped here; cap it where the backend is
//! deployed (cgroup, container), since macOS cannot limit it per process.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const WasmBuilder = @This();

io: Io,
/// The template project, absolute.
template_path: []const u8,
/// Where build folders and finished `.wasm` files live, absolute.
builds_path: []const u8,
zig_exe: []const u8 = "zig",
timeout: Io.Duration = .fromSeconds(60),
/// Finished builds older than this are deleted on the next build.
retention: Io.Duration = .fromSeconds(60 * 60),

pub const max_source_len = 256 * 1024;
const max_output_len = 256 * 1024;
const cache_dir_name = ".cache";
/// The files copied from the template; `src/main.zig` comes from the request.
const template_files = [_][]const u8{ "build.zig", "build.zig.zon", "src/config.zig", "src/Theme.zig" };

pub const Id = [16]u8;

pub const Outcome = union(enum) {
    built: Id,
    /// Compiler diagnostics, `file:line:col: error: ...`, or a one-line
    /// reason when there are none. Owned by the caller.
    failed: []u8,
};

pub fn build(b: *const WasmBuilder, gpa: Allocator, source: []const u8) !Outcome {
    const io = b.io;
    if (source.len > max_source_len) return .{ .failed = try gpa.dupe(u8, "error: source is larger than 256 KB") };

    var builds = try Io.Dir.cwd().createDirPathOpen(io, b.builds_path, .{});
    defer builds.close(io);
    b.sweep(builds);

    var raw_id: [@sizeOf(Id) / 2]u8 = undefined;
    io.random(&raw_id);
    const id: Id = std.fmt.bytesToHex(raw_id, .lower);

    var template = try Io.Dir.cwd().openDir(io, b.template_path, .{});
    defer template.close(io);
    var dir = try builds.createDirPathOpen(io, &id, .{});
    defer {
        dir.close(io);
        builds.deleteTree(io, &id) catch |err| std.log.warn("leaving build folder {s}: {any}", .{ &id, err });
    }
    for (template_files) |path| {
        try template.copyFile(path, dir, path, io, .{ .make_path = true });
    }
    try dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = source });

    const build_path = try std.fs.path.join(gpa, &.{ b.builds_path, &id });
    defer gpa.free(build_path);
    const cache_path = try std.fs.path.join(gpa, &.{ b.builds_path, cache_dir_name });
    defer gpa.free(cache_path);

    const stderr = b.runZigBuild(gpa, build_path, cache_path) catch |err| switch (err) {
        error.Timeout => return .{ .failed = try gpa.dupe(u8, "error: the build took too long and was stopped") },
        error.StreamTooLong => return .{ .failed = try gpa.dupe(u8, "error: the build printed too much output") },
        else => return err,
    } orelse {
        try dir.rename("zig-out/bin/playground.wasm", builds, &(id ++ ".wasm".*), io);
        return .{ .built = id };
    };
    defer gpa.free(stderr);
    return .{ .failed = try cleanErrors(gpa, stderr) };
}

/// The path of a finished build, or null if `id` is not one this builder
/// could have produced. Caller owns the result.
pub fn wasmPath(b: *const WasmBuilder, gpa: Allocator, id: []const u8) !?[]u8 {
    if (!isId(id)) return null;
    const name = try std.fmt.allocPrint(gpa, "{s}.wasm", .{id});
    defer gpa.free(name);
    return try std.fs.path.join(gpa, &.{ b.builds_path, name });
}

fn isId(text: []const u8) bool {
    if (text.len != @sizeOf(Id)) return false;
    for (text) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// Runs `zig build` in `build_path`. Returns null on success, or its stderr
/// (caller owns) on failure.
fn runZigBuild(b: *const WasmBuilder, gpa: Allocator, build_path: []const u8, cache_path: []const u8) !?[]u8 {
    const io = b.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ b.zig_exe, "build", "-Doptimize=ReleaseSmall", "--cache-dir", cache_path, "--color", "off", "--summary", "none" },
        .cwd = .{ .path = build_path },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        // Its own process group, so a timeout can stop the compiler
        // processes `zig build` started, not only `zig build` itself.
        .pgid = 0,
    });
    defer child.kill(io);
    const pid = child.id.?;

    var streams_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var output: Io.File.MultiReader = undefined;
    output.init(gpa, io, streams_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer output.deinit();

    const deadline = (Io.Timeout{ .duration = .{ .raw = b.timeout, .clock = .awake } }).toDeadline(io);
    while (output.fill(64, deadline)) |_| {
        if (output.reader(0).buffered().len + output.reader(1).buffered().len > max_output_len) {
            std.posix.kill(-pid, .KILL) catch {};
            return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => {
            std.posix.kill(-pid, .KILL) catch {};
            return error.Timeout;
        },
        else => |e| return e,
    }
    try output.checkAnyError();

    const term = try child.wait(io);
    if (term == .exited and term.exited == 0) return null;
    return try output.toOwnedSlice(1);
}

/// Deletes finished builds and leftover folders older than `retention`.
fn sweep(b: *const WasmBuilder, builds: Io.Dir) void {
    const io = b.io;
    const cutoff = Io.Timestamp.now(io, .real).subDuration(b.retention);
    var it = builds.iterate();
    while (it.next(io) catch return) |entry| {
        if (std.mem.eql(u8, entry.name, cache_dir_name)) continue;
        const stat = builds.statFile(io, entry.name, .{}) catch continue;
        if (stat.mtime.nanoseconds >= cutoff.nanoseconds) continue;
        builds.deleteTree(io, entry.name) catch |err| std.log.warn("sweeping {s}: {any}", .{ entry.name, err });
    }
}

/// Keeps the compiler's diagnostics: each `file:line:col: error|note: ...`
/// line with the source line and caret under it. Drops the build-runner
/// tree, the summary and the failed command line, which carries the
/// server's absolute paths. Caller owns the result.
pub fn cleanErrors(gpa: Allocator, stderr: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var split = std.mem.splitScalar(u8, stderr, '\n');
    while (split.next()) |line| try lines.append(gpa, std.mem.trimEnd(u8, line, "\r"));

    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        if (!isDiagnostic(lines.items[i])) continue;
        const has_snippet = i + 2 < lines.items.len and isCaret(lines.items[i + 2]);
        const end = if (has_snippet) i + 3 else i + 1;
        for (lines.items[i..end]) |line| {
            if (out.items.len > 0) try out.append(gpa, '\n');
            try out.appendSlice(gpa, line);
        }
        i = end - 1;
    }

    if (out.items.len == 0) {
        // No located diagnostic, e.g. the build runner itself failed: fall
        // back to its first error line.
        for (lines.items) |line| {
            if (!std.mem.startsWith(u8, line, "error: ")) continue;
            if (std.mem.indexOf(u8, line, "build command failed") != null) continue;
            try out.appendSlice(gpa, line);
            break;
        } else try out.appendSlice(gpa, "error: the build failed");
    }
    return out.toOwnedSlice(gpa);
}

/// `path:line:col: error: ...` or `path:line:col: note: ...`.
fn isDiagnostic(line: []const u8) bool {
    var parts = std.mem.splitScalar(u8, line, ':');
    const path = parts.next() orelse return false;
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, ' ') != null) return false;
    for ([_]void{ {}, {} }) |_| {
        const number = parts.next() orelse return false;
        _ = std.fmt.parseInt(u32, number, 10) catch return false;
    }
    const rest = parts.rest();
    return std.mem.startsWith(u8, rest, " error: ") or std.mem.startsWith(u8, rest, " note: ");
}

fn isCaret(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " ");
    return trimmed.len > 0 and std.mem.trim(u8, trimmed, "^~").len == 0;
}

const testing = std.testing;

test "cleanErrors keeps located diagnostics with their snippets" {
    const stderr =
        \\install
        \\+- install playground
        \\   +- compile exe playground ReleaseSmall wasm32-wasi 1 errors
        \\src/main.zig:39:25: error: no field named 'top' in struct 'lib.Shadow'
        \\            .shadow(.{ .top = 12 })
        \\                        ^~~
        \\zig-pkg/vapor/src/lib/Shadow.zig:1:1: note: struct declared here
        \\//! Box and text shadows.
        \\^~~~~~~~~~~~~~~~~~~~~~~~
        \\referenced by:
        \\    Page__anon_341: zig-pkg/vapor/src/lib/vapor.zig:781:15
        \\error: 1 compilation errors
        \\failed command: /secret/zig build-exe -Mroot=/srv/builds/x/src/main.zig
        \\
        \\error: the following build command failed with exit code 1:
        \\/srv/builds/.cache/o/abc/build /secret/zig
        \\
    ;
    const cleaned = try cleanErrors(testing.allocator, stderr);
    defer testing.allocator.free(cleaned);
    try testing.expectEqualStrings(
        \\src/main.zig:39:25: error: no field named 'top' in struct 'lib.Shadow'
        \\            .shadow(.{ .top = 12 })
        \\                        ^~~
        \\zig-pkg/vapor/src/lib/Shadow.zig:1:1: note: struct declared here
        \\//! Box and text shadows.
        \\^~~~~~~~~~~~~~~~~~~~~~~~
    , cleaned);
}

test "cleanErrors falls back to the first error line" {
    const stderr =
        \\error: no build.zig file found
        \\error: the following build command failed with exit code 1:
    ;
    const cleaned = try cleanErrors(testing.allocator, stderr);
    defer testing.allocator.free(cleaned);
    try testing.expectEqualStrings("error: no build.zig file found", cleaned);
}

test "wasmPath accepts only build ids" {
    const b: WasmBuilder = .{ .io = testing.io, .template_path = "/t", .builds_path = "/b" };
    const path = (try b.wasmPath(testing.allocator, "0123456789abcdef")).?;
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/b/0123456789abcdef.wasm", path);

    try testing.expectEqual(null, try b.wasmPath(testing.allocator, "../../etc/passwd"));
    try testing.expectEqual(null, try b.wasmPath(testing.allocator, "0123456789ABCDEF"));
    try testing.expectEqual(null, try b.wasmPath(testing.allocator, "0123456789abcde"));
}
