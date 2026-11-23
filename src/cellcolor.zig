//! 单元格取色（纯函数）：Windows 与 Linux 共用的配色语义。
//!
//! 为什么单独抽出来：Windows 侧的 presentFrame 直接面向 `w32_cell`，没法在 Linux 上跑；
//! 而配色语义（bold→bright、faint、inverse、invisible、selection）必须与 Linux 侧
//! `render.zig` 以及 Rust 版 `decide.rs` 完全一致。抽成纯函数后：
//!   - Windows 走这里；
//!   - Linux 侧保持 `render.zig` 自己的实现（已与 Rust 做过 48 例逐像素对照）；
//!   - 单测在 Linux 上就能覆盖 Windows 的配色分支。
//!
//! 语义（与 alacritty / Rust 版对齐）：
//!   - bold + `draw_bold_text_with_bright_colors`：只把**调色板 0-7** 换成 8-15，默认前景不动。
//!   - faint（SGR 2）：前景向背景混合 **50%**（等价于 ghostty 默认 `faint-opacity = 0.5`，
//!     也是 Rust 版 `dim()` 的 `fg/2 + bg/2`；早前用 60% 导致两边灰阶差 ~12 级）。
//!   - inverse（SGR 7）：前景/背景互换。
//!   - invisible（SGR 8）：前景=背景（只留底色）。
//!   - selection：配置了 `[colors.selection]` 就用配置色，否则反色。

const std = @import("std");
const gh = @import("ghostty-vt");

pub const Resolved = struct {
    fg: u32,
    bg: u32,
};

pub const Params = struct {
    /// [colors] draw_bold_text_with_bright_colors
    bold_bright: bool = false,
    /// [colors] faint：SGR 2 是否压暗（false = 按原色绘制）
    faint: bool = true,
    /// [colors] faint_opacity：压暗强度百分比（0..100，默认 50，= ghostty faint-opacity 0.5）
    faint_percent: u32 = 50,
    /// [colors.bright] white_fg：palette 15 作为**前景**时替换成该色（null = 不替换）
    bright_white_fg: ?u32 = null,
    /// [colors.selection]
    selection_bg: ?u32 = null,
    selection_fg: ?u32 = null,
};

/// 接受 terminal.color.RGB 与 page.Cell.RGB 两种结构（字段相同）。
fn rgbOf(c: anytype) u32 {
    return (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
}

pub fn mix(bg: u32, fg: u32, percent: u32) u32 {
    const p = @min(percent, 100);
    const rb = (bg >> 16) & 0xff;
    const gb = (bg >> 8) & 0xff;
    const bb = bg & 0xff;
    const rf = (fg >> 16) & 0xff;
    const gf = (fg >> 8) & 0xff;
    const bf = fg & 0xff;
    const r = (rb * (100 - p) + rf * p) / 100;
    const g = (gb * (100 - p) + gf * p) / 100;
    const b = (bb * (100 - p) + bf * p) / 100;
    return (r << 16) | (g << 8) | b;
}

fn resolveFg(rs: *const gh.RenderState, c: gh.RenderState.Cell) ?u32 {
    if (c.raw.style_id == 0) return null;
    return switch (c.style.fg_color) {
        .none => null,
        .rgb => |rgb| rgbOf(rgb),
        .palette => |idx| rgbOf(rs.colors.palette[idx]),
    };
}

fn resolveBg(rs: *const gh.RenderState, c: gh.RenderState.Cell) ?u32 {
    switch (c.raw.content_tag) {
        .bg_color_rgb => return rgbOf(c.raw.content.color_rgb),
        .bg_color_palette => return rgbOf(rs.colors.palette[c.raw.content.color_palette.data]),
        else => {},
    }
    if (c.raw.style_id == 0) return null;
    return switch (c.style.bg_color) {
        .none => null,
        .rgb => |rgb| rgbOf(rgb),
        .palette => |idx| rgbOf(rs.colors.palette[idx]),
    };
}

/// 计算一个单元格最终的前景/背景色。`selected` 表示该格处于选区内。
pub fn resolve(
    rs: *const gh.RenderState,
    c: gh.RenderState.Cell,
    selected: bool,
    p: Params,
) Resolved {
    var fg = resolveFg(rs, c) orelse rgbOf(rs.colors.foreground);
    // palette 15 作前景时的替换：inbox conhost 会把"SGR 1 无颜色"归一化成 bright white，
    // 浅色主题下就成了白字白底（第五轮实机取证）。背景不受影响。
    if (p.bright_white_fg) |w| {
        if (c.raw.style_id != 0) switch (c.style.fg_color) {
            .palette => |idx| if (idx == 15) {
                fg = w;
            },
            else => {},
        };
    }
    var bg = resolveBg(rs, c) orelse rgbOf(rs.colors.background);

    if (p.bold_bright and c.raw.style_id != 0 and c.style.flags.bold) {
        switch (c.style.fg_color) {
            .palette => |idx| if (idx < 8) {
                fg = rgbOf(rs.colors.palette[idx + 8]);
            },
            .none, .rgb => {},
        }
    }

    if (selected) {
        if (p.selection_bg) |sb| bg = sb;
        if (p.selection_fg) |sf| fg = sf;
        if (p.selection_bg == null and p.selection_fg == null) {
            const tmp = bg;
            bg = fg;
            fg = tmp;
        }
    }

    if (c.raw.style_id != 0) {
        if (c.style.flags.inverse) {
            const tmp = bg;
            bg = fg;
            fg = tmp;
        }
        if (c.style.flags.faint and p.faint) fg = mix(bg, fg, p.faint_percent);
        if (c.style.flags.invisible) fg = bg;
    }

    return .{ .fg = fg, .bg = bg };
}

// ---------------------------------------------------------------------------
// 单测：直接构造 Cell（不依赖终端），覆盖 Windows 侧用到的每一条配色语义。
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testRs() gh.RenderState {
    var rs: gh.RenderState = .empty;
    rs.colors.background = .{ .r = 0xF3, .g = 0xF1, .b = 0xE9 };
    rs.colors.foreground = .{ .r = 0x30, .g = 0x32, .b = 0x38 };
    rs.colors.palette[0] = .{ .r = 0x30, .g = 0x32, .b = 0x38 };
    rs.colors.palette[1] = .{ .r = 0xB9, .g = 0x4B, .b = 0x4B };
    rs.colors.palette[9] = .{ .r = 0xD4, .g = 0x5B, .b = 0x55 };
    return rs;
}

/// Cell 里 fg_color 的实际类型（terminal.style.Style.Color，未从模块导出）。
const CellColor = @TypeOf(@as(gh.RenderState.Cell, undefined).style.fg_color);

fn pal(i: u8) CellColor {
    return .{ .palette = i };
}

fn noColor() CellColor {
    return .none;
}

fn emptyCell() gh.RenderState.Cell {
    return std.mem.zeroInit(gh.RenderState.Cell, .{});
}

fn cellWith(fg: anytype, bold: bool, faint: bool, inverse: bool, invisible: bool) gh.RenderState.Cell {
    var c = emptyCell();
    c.raw.style_id = 1;
    c.style.flags.bold = bold;
    c.style.flags.faint = faint;
    c.style.flags.inverse = inverse;
    c.style.flags.invisible = invisible;
    c.style.fg_color = fg;
    return c;
}

test "默认前景/背景" {
    const rs = testRs();
    const c = emptyCell();
    const got = resolve(&rs, c, false, .{});
    try testing.expectEqual(@as(u32, 0x303238), got.fg);
    try testing.expectEqual(@as(u32, 0xF3F1E9), got.bg);
}

test "bold + bright：调色板 0-7 换成 8-15，默认前景不动" {
    const rs = testRs();
    const p: Params = .{ .bold_bright = true };
    // palette 1 → 9
    const c1 = cellWith(pal(1), true, false, false, false);
    try testing.expectEqual(@as(u32, 0xD45B55), resolve(&rs, c1, false, p).fg);
    // 默认前景：保持 #303238（曾经错成 palette[15] → 浅底浅字）
    const c2 = cellWith(noColor(), true, false, false, false);
    try testing.expectEqual(@as(u32, 0x303238), resolve(&rs, c2, false, p).fg);
    // 关闭开关时不变
    const c3 = cellWith(pal(1), true, false, false, false);
    try testing.expectEqual(@as(u32, 0xB94B4B), resolve(&rs, c3, false, .{}).fg);
}

test "faint 按 50% 向背景混合（与 ghostty faint-opacity / Rust dim 一致）" {
    const rs = testRs();
    const c = cellWith(pal(1), false, true, false, false);
    const got = resolve(&rs, c, false, .{});
    try testing.expectEqual(mix(0xF3F1E9, 0xB94B4B, 50), got.fg);
}

test "inverse 交换前景背景" {
    const rs = testRs();
    const c = cellWith(pal(1), false, false, true, false);
    const got = resolve(&rs, c, false, .{});
    try testing.expectEqual(@as(u32, 0xF3F1E9), got.fg);
    try testing.expectEqual(@as(u32, 0xB94B4B), got.bg);
}

test "invisible 前景=背景" {
    const rs = testRs();
    const c = cellWith(pal(1), false, false, false, true);
    const got = resolve(&rs, c, false, .{});
    try testing.expectEqual(got.bg, got.fg);
}

test "selection：无配置时反色，有配置时用配置色" {
    const rs = testRs();
    const c = cellWith(pal(1), true, false, false, false);
    const inv = resolve(&rs, c, true, .{});
    try testing.expectEqual(@as(u32, 0xB94B4B), inv.bg);
    try testing.expectEqual(@as(u32, 0xF3F1E9), inv.fg);

    const p: Params = .{ .selection_bg = 0x5579A8, .selection_fg = 0xFFFFFF };
    const cfg = resolve(&rs, c, true, p);
    try testing.expectEqual(@as(u32, 0x5579A8), cfg.bg);
    try testing.expectEqual(@as(u32, 0xFFFFFF), cfg.fg);
}
