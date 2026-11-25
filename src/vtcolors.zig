//! 把 `Config` 里的配色转成 VT 层要的 `vt.Wrapper.Colors`。
//!
//! 两平台共用一份：启动时建 VT、以及配置热加载（`general.live_config_reload`）时换色，
//! 都走这里。早期 Linux 与 Windows 各写一份，改配色键时就容易漏掉一边。

const std = @import("std");
const config = @import("config.zig");
const vt = @import("vt.zig");

pub fn of(cfg: *const config.Config) vt.Wrapper.Colors {
    var colors: vt.Wrapper.Colors = .{};
    if (cfg.colors_bg) |c| colors.background = .{ .r = c.r, .g = c.g, .b = c.b };
    if (cfg.colors_fg) |c| colors.foreground = .{ .r = c.r, .g = c.g, .b = c.b };
    if (cfg.colors_cursor) |c| colors.cursor = .{ .r = c.r, .g = c.g, .b = c.b };
    if (cfg.cursor_style) |st| colors.cursor_style = switch (st) {
        .block => .block,
        .bar => .bar,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
    for (cfg.colors_palette, 0..) |maybe, i| {
        if (maybe) |c| colors.palette[i] = .{ .r = c.r, .g = c.g, .b = c.b };
    }
    return colors;
}

/// 同样的映射，但来源是 app.Config（Linux 侧把配置投影成了这个更小的结构）。
/// 字段是 config.Config 的子集且同型，所以逻辑与 `of` 完全一致——这里显式写一份，
/// 避免用 anytype 把类型错误推到调用点才发现。
pub fn ofConfig(cfg: anytype) vt.Wrapper.Colors {
    var colors: vt.Wrapper.Colors = .{};
    if (cfg.colors_bg) |c| colors.background = .{ .r = c.r, .g = c.g, .b = c.b };
    if (cfg.colors_fg) |c| colors.foreground = .{ .r = c.r, .g = c.g, .b = c.b };
    if (cfg.colors_cursor) |c| colors.cursor = .{ .r = c.r, .g = c.g, .b = c.b };
    if (cfg.cursor_style) |st| colors.cursor_style = switch (st) {
        .block => .block,
        .bar => .bar,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
    for (cfg.colors_palette, 0..) |maybe, i| {
        if (maybe) |c| colors.palette[i] = .{ .r = c.r, .g = c.g, .b = c.b };
    }
    return colors;
}

test "of：背景/前景/光标/16 色" {
    const testing = std.testing;
    var cfg: config.Config = .{};
    cfg.colors_bg = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
    cfg.colors_fg = .{ .r = 0xaa, .g = 0xbb, .b = 0xcc };
    cfg.cursor_style = .bar;
    cfg.colors_palette[1] = .{ .r = 1, .g = 2, .b = 3 };
    const got = of(&cfg);
    try testing.expectEqual(@as(u8, 0x11), got.background.?.r);
    try testing.expectEqual(@as(u8, 0xcc), got.foreground.?.b);
    try testing.expectEqual(vt.Wrapper.CursorStyle.bar, got.cursor_style.?);
    try testing.expectEqual(@as(u8, 3), got.palette[1].?.b);
    try testing.expectEqual(null, got.palette[2]);
}
