//! 滚动条几何（纯函数）。CPU/GPU 渲染、Windows 的 DIB 绘制与鼠标命中测试共用同一套口径，
//! 避免"某一侧画的是 4px、另一侧 12px"这类漂移。
//!
//! 宽度与 Rust 版一致：**12px**（Rust 从 4 → 8 → 12，原因是用户反馈"太窄、点不中"）。

const std = @import("std");

pub const width: u32 = 12;

pub const Thumb = struct { y: u32, h: u32 };

/// 滑块在像素轨上的位置与高度；无滚动区（内容不超一屏）返回 null。
pub fn thumb(total: usize, offset: usize, len: usize, pixels: u32) ?Thumb {
    if (total == 0 or pixels == 0 or total <= len) return null;
    const track: f64 = @floatFromInt(pixels);
    const t: f64 = @floatFromInt(total);
    // 滑块高度按可见比例，至少 8px（小窗口下仍然可见/可点）
    var h: u32 = @intFromFloat(@max(track * @as(f64, @floatFromInt(len)) / t, 8.0));
    if (h > pixels) h = pixels;
    const max_off = total - len;
    const off_f: f64 = @floatFromInt(@min(offset, max_off));
    const travel: f64 = track - @as(f64, @floatFromInt(h));
    const y: u32 = @intFromFloat(travel * off_f / @as(f64, @floatFromInt(max_off)));
    return .{ .y = y, .h = h };
}

/// 像素 x 是否落在右缘条带内（用于"点在滚动条上不要开始选区"）。
pub fn hitsBar(pixel_x: i64, pixel_w: u32) bool {
    if (pixel_w <= width) return false;
    return pixel_x >= @as(i64, @intCast(pixel_w - width));
}

test "无滚动区时不画滚动条" {
    try std.testing.expect(thumb(30, 0, 30, 600) == null);
    try std.testing.expect(thumb(0, 0, 0, 600) == null);
}

test "滑块位置：顶部在 0，底部贴住轨道末端" {
    // total 130 行、可见 30 行、轨道 600px
    const top = thumb(130, 0, 30, 600).?;
    try std.testing.expectEqual(@as(u32, 0), top.y);
    const full_h = @as(u32, @intFromFloat(600.0 * 30.0 / 130.0));
    try std.testing.expectEqual(full_h, top.h);
    const bottom = thumb(130, 100, 30, 600).?;
    try std.testing.expectEqual(@as(u32, 600 - full_h), bottom.y);
}

test "命中测试：右缘 12px 算条带" {
    try std.testing.expect(hitsBar(1088, 1100)); // 1100-12 = 1088
    try std.testing.expect(!hitsBar(1087, 1100));
    try std.testing.expect(!hitsBar(0, 8)); // 窗口比条带还窄时不判命中
}
