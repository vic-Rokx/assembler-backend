//! The `users` table: one row per person who has signed in, keyed by their
//! Google account. Written at each sign-in by `upsert`, which reverb-auth's
//! `on_sign_in` hook calls; the id it returns is what the session names.
const std = @import("std");
const pg_orm = @import("pg_orm");
const pg = pg_orm.pg;
const SignedIn = @import("reverb_auth").KeyStone.SignedIn;

/// The table's shape, for its DDL.
pub const User = struct {
    id: i64,
    /// Google's id for the account. Stable, where an email address can
    /// change hands.
    google_sub: []const u8,
    email: []const u8,
    name: ?[]const u8,
    picture: ?[]const u8,
    created_at: i64,
    last_sign_in_at: i64,

    pub const orm = .{
        .table = "users",
        .primary_key = .id,
        .schema = .{
            .id = .{ .type = .bigserial, .primary_key = true },
            .google_sub = .{ .type = .text, .unique = true, .not_null = true },
            .email = .{ .type = .text, .not_null = true },
            .name = .{ .type = .text },
            .picture = .{ .type = .text },
            .created_at = .{ .type = .timestamptz, .not_null = true, .default = "now()" },
            .last_sign_in_at = .{ .type = .timestamptz, .not_null = true, .default = "now()" },
        },
    };
};

/// Creates the table if it does not exist yet.
pub fn migrate(pool: *pg.Pool) !void {
    _ = try pool.exec(comptime pg_orm.schema.createTableSql(User), .{});
}

/// Records a sign-in: adds the user, or brings their email, name and
/// picture up to date, and returns their id as text, allocated from
/// `allocator`.
///
/// Raw SQL rather than pg-orm's insert builder: its `RETURNING` maps no
/// columns back, so the id would come back undefined.
pub fn upsert(pool: *pg.Pool, allocator: std.mem.Allocator, user: SignedIn) ![]const u8 {
    if (user.provider != .google) return error.UnsupportedProvider;
    var row = try pool.row(
        \\INSERT INTO users (google_sub, email, name, picture) VALUES ($1, $2, $3, $4)
        \\ON CONFLICT (google_sub) DO UPDATE SET email = EXCLUDED.email, name = EXCLUDED.name,
        \\    picture = EXCLUDED.picture, last_sign_in_at = now()
        \\RETURNING id
    , .{ user.subject, user.email, user.name, user.picture }) orelse return error.NoRowReturned;
    defer row.deinit() catch {};
    return std.fmt.allocPrint(allocator, "{d}", .{try row.get(i64, 0)});
}
