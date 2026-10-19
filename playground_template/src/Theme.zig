//! The theme every playground build gets. `.palette(.text)` and friends read
//! these tokens, so the system prompt lists them.
const Vapor = @import("vapor");
const Color = Vapor.Types.Color;

pub const ThemeTokens = enum(u8) { none, text, text_muted, background, surface, border, primary, danger };

pub const Colors = struct {
    text: Color = .hex("#111111"),
    text_muted: Color = .hex("#6B7280"),
    background: Color = .white,
    surface: Color = .hex("#F5F5F5"),
    border: Color = .hex("#E0E0E0"),
    primary: Color = .vapor_blue,
    danger: Color = .hex("#DC2626"),
};

pub const Light = Colors{};
pub const Dark = Colors{
    .text = .hex("#F5F5F5"),
    .text_muted = .hex("#9CA3AF"),
    .background = .hex("#111111"),
    .surface = .hex("#1F1F1F"),
    .border = .hex("#333333"),
};
