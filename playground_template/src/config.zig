//! The icons playground code can name with `Vapor.Icon(.search)`.
pub const IconTokens = struct {
    web: ?[]const u8 = null,
    svg: ?[]const u8 = null,

    pub const search = IconTokens{ .web = "bi bi-search" };
    pub const plus = IconTokens{ .web = "bi bi-plus-lg" };
    pub const trash = IconTokens{ .web = "bi bi-trash3" };
    pub const check = IconTokens{ .web = "bi bi-check" };
    pub const x = IconTokens{ .web = "bi bi-x-lg" };
    pub const pencil = IconTokens{ .web = "bi bi-pencil" };
    pub const home = IconTokens{ .web = "bi bi-house" };
    pub const arrow_right = IconTokens{ .web = "bi bi-arrow-right" };
};
