use tiny_skia::Color;

// Mirrors Theme.swift — Claude warm palette.
pub const CLAUDE_TAN: (u8, u8, u8) = (0xE8, 0x9B, 0x68);
pub const CLAUDE_ORANGE: (u8, u8, u8) = (0xE0, 0x6B, 0x3E);
pub const CLAUDE_DEEP: (u8, u8, u8) = (0xCC, 0x48, 0x22);
pub const CLAUDE_RED: (u8, u8, u8) = (0xC0, 0x28, 0x1C);
pub const TRACK: (u8, u8, u8, u8) = (0x99, 0x99, 0x99, 0x55);

pub fn color_for(pct: f64) -> Color {
    let (r, g, b) = match pct {
        p if p < 33.0 => CLAUDE_TAN,
        p if p < 66.0 => CLAUDE_ORANGE,
        p if p < 90.0 => CLAUDE_DEEP,
        _ => CLAUDE_RED,
    };
    Color::from_rgba8(r, g, b, 255)
}

pub fn color_special_orange() -> Color {
    Color::from_rgba8(0xFF, 0x95, 0x00, 255)
}

pub fn color_special_red() -> Color {
    Color::from_rgba8(0xFF, 0x3B, 0x30, 255)
}

pub fn color_idle() -> Color {
    Color::from_rgba8(0xAA, 0xAA, 0xAA, 180)
}
