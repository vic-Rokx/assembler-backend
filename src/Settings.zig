//! Runtime settings, read once from the environment in `main`.
//!
//! Zig 0.16 has no `getenv`; the environment arrives through
//! `std.process.Init`, so this takes the map rather than reading globals.
const std = @import("std");
const Environ = std.process.Environ;
const Cookie = @import("reverb").Cookie;

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
/// Builds that run at once. Each is a `zig build` that can keep several
/// cores busy, so this is the cap on concurrent builds.
build_threads: u16 = 2,
/// Builds that may wait for a free thread. Past this a build answers 503.
build_queue: u16 = 8,
/// Model calls in flight at once. They wait on the network, not the CPU.
chat_threads: u16 = 8,
/// Model calls that may wait for a free thread. Past this a chat answers 503.
chat_queue: u16 = 32,
/// `POST /chat` answers 503 without it.
anthropic_api_key: ?[]const u8 = null,
claude_model: []const u8 = "claude-opus-5-5",
/// `POST /api/vertex` answers 503 without both. The token is an OAuth
/// access token (`gcloud auth print-access-token`), which expires hourly.
vertex_project_id: ?[]const u8 = null,
vertex_access_token: ?[]const u8 = null,
/// A specific region: claude-zig builds `<region>-aiplatform.googleapis.com`,
/// which has no form for `global`.
vertex_region: []const u8 = "us-east5",
vertex_model: []const u8 = "claude-opus-5-5",
/// Google sign-in is on when the client id, its secret and
/// `session_secret` are all set (`signInConfigured`). The client is the
/// one the frontend's KeyStone names.
google_client_id: ?[]const u8 = null,
google_client_secret: ?[]const u8 = null,
/// Where Google sends the browser back: the frontend's `/auth/callback`.
/// Must be listed for the client in Google Cloud, and match exactly.
oauth_redirect_uri: []const u8 = "http://localhost:5173/auth/callback",
/// Google's token endpoint. Tests point it at a fake.
google_token_url: []const u8 = "https://oauth2.googleapis.com/token",
/// Signs session tokens (HMAC-SHA256). At least 32 bytes, random;
/// changing it signs everyone out.
session_secret: ?[]const u8 = null,
/// Mark session cookies `Secure`. On wherever the backend is served over
/// HTTPS.
secure_cookies: bool = false,
/// The session cookies' `SameSite`. `lax` works while the frontend is on
/// the same site as this backend (`app.example.com` and
/// `api.example.com`); a frontend on another site needs `none`, which
/// requires `SECURE_COOKIES`.
cookie_same_site: Cookie.SameSite = .lax,
/// The Postgres holding the `users` table, which records who signed in.
/// Optional: without it sign-in still works, the session names the Google
/// account, and nothing is stored.
database_url: ?[]const u8 = null,

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
    settings.build_threads = try count(env, "BUILD_THREADS", settings.build_threads);
    settings.build_queue = try count(env, "BUILD_QUEUE", settings.build_queue);
    settings.chat_threads = try count(env, "CHAT_THREADS", settings.chat_threads);
    settings.chat_queue = try count(env, "CHAT_QUEUE", settings.chat_queue);
    if (env.get("ANTHROPIC_API_KEY")) |key| settings.anthropic_api_key = key;
    if (env.get("CLAUDE_MODEL")) |model| settings.claude_model = model;
    if (env.get("VERTEX_PROJECT_ID")) |id| settings.vertex_project_id = id;
    if (env.get("VERTEX_ACCESS_TOKEN")) |token| settings.vertex_access_token = token;
    if (env.get("VERTEX_REGION")) |region| settings.vertex_region = region;
    if (env.get("VERTEX_MODEL")) |model| settings.vertex_model = model;
    if (env.get("GOOGLE_CLIENT_ID")) |id| settings.google_client_id = id;
    if (env.get("GOOGLE_CLIENT_SECRET")) |secret| settings.google_client_secret = secret;
    if (env.get("OAUTH_REDIRECT_URI")) |uri| settings.oauth_redirect_uri = uri;
    if (env.get("GOOGLE_TOKEN_URL")) |url| settings.google_token_url = url;
    if (env.get("SESSION_SECRET")) |secret| {
        if (secret.len < min_session_secret_len) return error.SessionSecretTooShort;
        settings.session_secret = secret;
    }
    if (env.get("SECURE_COOKIES")) |flag| settings.secure_cookies = std.mem.eql(u8, flag, "1") or std.mem.eql(u8, flag, "true");
    if (env.get("COOKIE_SAMESITE")) |value| {
        settings.cookie_same_site = std.meta.stringToEnum(Cookie.SameSite, value) orelse return error.InvalidCookieSameSite;
    }
    // Browsers drop a SameSite=None cookie that is not also Secure.
    if (settings.cookie_same_site == .none and !settings.secure_cookies) return error.SameSiteNoneNeedsSecureCookies;
    if (env.get("DATABASE_URL")) |url| settings.database_url = url;
    return settings;
}

/// Adds the `KEY=value` lines of a `.env` file to `env`, for development,
/// where secrets live in a git-ignored file rather than the shell. A
/// variable already in `env` wins, so a deployment's environment is never
/// overridden by a stray file. Blank lines and `#` comments are skipped,
/// `export ` is allowed, and a value may be wrapped in single or double
/// quotes; nothing is expanded or unescaped.
pub fn loadDotEnv(env: *Environ.Map, contents: []const u8) !void {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line["export ".len..], " \t");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidDotEnv;
        const key = std.mem.trimEnd(u8, line[0..eq], " \t");
        var value = std.mem.trimStart(u8, line[eq + 1 ..], " \t");
        if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) {
            value = value[1 .. value.len - 1];
        }
        if (key.len == 0) return error.InvalidDotEnv;
        if (env.get(key) == null) try env.put(key, value);
    }
}

/// Whether Google sign-in, and with it the users table, is enabled.
pub fn signInConfigured(settings: *const Settings) bool {
    return settings.google_client_id != null and
        settings.google_client_secret != null and
        settings.session_secret != null;
}

/// HS256 keys shorter than the hash are weak; 32 bytes is SHA-256's size.
pub const min_session_secret_len = 32;

/// A pool size from `name`, or `default` if it is unset. Zero is refused:
/// a pool without threads or queue would answer every request with 503.
fn count(env: *const Environ.Map, name: []const u8, default: u16) !u16 {
    const text = env.get(name) orelse return default;
    const n = std.fmt.parseInt(u16, text, 10) catch return error.InvalidPoolSize;
    if (n == 0) return error.InvalidPoolSize;
    return n;
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

test "sign-in needs the client, its secret and a long enough session secret" {
    var env = Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("GOOGLE_CLIENT_ID", "id");
    try env.put("GOOGLE_CLIENT_SECRET", "secret");
    try std.testing.expect(!(try fromEnv(&env)).signInConfigured());

    try env.put("SESSION_SECRET", "too short");
    try std.testing.expectError(error.SessionSecretTooShort, fromEnv(&env));

    try env.put("SESSION_SECRET", "0123456789abcdef0123456789abcdef");
    try std.testing.expect((try fromEnv(&env)).signInConfigured());
}

test ".env adds what the environment lacks, and never overrides it" {
    var env = Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PORT", "9000");
    try loadDotEnv(&env,
        \\# local secrets
        \\
        \\PORT=8080
        \\export GOOGLE_CLIENT_ID = 123-abc.apps.googleusercontent.com
        \\GOOGLE_CLIENT_SECRET="se=cret # not a comment"
        \\SESSION_SECRET='0123456789abcdef0123456789abcdef'
        \\
    );
    try std.testing.expectEqualStrings("9000", env.get("PORT").?);
    try std.testing.expectEqualStrings("123-abc.apps.googleusercontent.com", env.get("GOOGLE_CLIENT_ID").?);
    try std.testing.expectEqualStrings("se=cret # not a comment", env.get("GOOGLE_CLIENT_SECRET").?);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", env.get("SESSION_SECRET").?);

    try std.testing.expectError(error.InvalidDotEnv, loadDotEnv(&env, "NOT A SETTING"));
}

test "SameSite is lax unless set, and none needs secure cookies" {
    var env = Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(Cookie.SameSite.lax, (try fromEnv(&env)).cookie_same_site);

    try env.put("COOKIE_SAMESITE", "none");
    try std.testing.expectError(error.SameSiteNoneNeedsSecureCookies, fromEnv(&env));
    try env.put("SECURE_COOKIES", "1");
    try std.testing.expectEqual(Cookie.SameSite.none, (try fromEnv(&env)).cookie_same_site);

    try env.put("COOKIE_SAMESITE", "Lax");
    try std.testing.expectError(error.InvalidCookieSameSite, fromEnv(&env));
}

test "pool sizes are read and must be positive" {
    var env = Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("BUILD_THREADS", "4");
    try std.testing.expectEqual(@as(u16, 4), (try fromEnv(&env)).build_threads);

    try env.put("CHAT_QUEUE", "0");
    try std.testing.expectError(error.InvalidPoolSize, fromEnv(&env));
}
