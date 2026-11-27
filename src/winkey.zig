//! Windows 虚拟键码（VK_*）→ ghostty 的 `input.Key` 映射。
//!
//! 抽成独立模块的原因有两个：
//!   1. 纯映射与编码可以在 Linux 上单测（ghostty-vt 是共用依赖），
//!      不必等 Windows 实机才发现"方向键没反应"；
//!   2. app_win.zig 只在 Windows 编译，放在里面的映射写错了没人测。

const gh = @import("ghostty-vt");

pub fn functionKey(idx: u32) gh.input.Key {
    return @fromBackingInt(@intCast(@backingInt(gh.input.Key.f1) + @as(c_int, @intCast(idx))));
}

pub fn numpadDigit(idx: u32) gh.input.Key {
    return @fromBackingInt(@intCast(@backingInt(gh.input.Key.numpad_0) + @as(c_int, @intCast(idx))));
}

/// VK → Key；不认识的返回 null（交给 DefWindowProc，例如 F13+、VK_PACKET）。
pub fn vkToKey(vk: u32) ?gh.input.Key {
    return switch (vk) {
        0x0D => .enter,
        0x08 => .backspace,
        0x09 => .tab,
        0x1B => .escape,
        0x25 => .arrow_left,
        0x26 => .arrow_up,
        0x27 => .arrow_right,
        0x28 => .arrow_down,
        0x24 => .home,
        0x23 => .end,
        0x21 => .page_up,
        0x22 => .page_down,
        0x2D => .insert,
        0x2E => .delete,
        0x20 => .space,
        0x70...0x7B => functionKey(vk - 0x70),
        0x60...0x69 => numpadDigit(vk - 0x60),
        0x6A => .numpad_multiply,
        0x6B => .numpad_add,
        0x6D => .numpad_subtract,
        0x6E => .numpad_decimal,
        0x6F => .numpad_divide,
        0x6C => .numpad_separator,
        0x41...0x5A => letterKey(vk - 0x41),
        0x30...0x39 => digitKey(vk - 0x30),
        0xBA => .semicolon,
        0xBB => .equal,
        0xBC => .comma,
        0xBD => .minus,
        0xBE => .period,
        0xBF => .slash,
        0xC0 => .backquote,
        0xDB => .bracket_left,
        0xDC => .backslash,
        0xDD => .bracket_right,
        0xDE => .quote,
        else => null,
    };
}

fn letterKey(idx: u32) gh.input.Key {
    // ghostty 的字母键是连续的：key_a..key_z
    return @fromBackingInt(@intCast(@backingInt(gh.input.Key.key_a) + @as(c_int, @intCast(idx))));
}

fn digitKey(idx: u32) gh.input.Key {
    return @fromBackingInt(@intCast(@backingInt(gh.input.Key.digit_0) + @as(c_int, @intCast(idx))));
}

// ---------------------------------------------------------------------------
// 单测：用 ghostty 的编码器把每个特殊键编码出来，断言是标准 xterm 序列。
// 这几条测试在 Linux 上就能跑，能抓住"映射错/编码为空"这类问题。
// ---------------------------------------------------------------------------
const std = @import("std");
const testing = std.testing;
const vt = @import("vt.zig");

fn encodeVk(term: *vt.Wrapper, vk: u32, mods: gh.input.KeyMods, out: []u8) []const u8 {
    const key = vkToKey(vk) orelse return out[0..0];
    const ev: gh.input.KeyEvent = .{
        .action = .press,
        .key = key,
        .mods = mods,
        .unshifted_codepoint = 0,
        .utf8 = "",
    };
    var w = std.Io.Writer.fixed(out);
    var opts = gh.input.KeyEncodeOptions.fromTerminal(&term.term);
    opts.alt_esc_prefix = true;
    gh.input.encodeKey(&w, ev, opts) catch return out[0..0];
    return w.buffered();
}

test "Windows 方向键/编辑键编码为标准 xterm 序列" {
    const alloc = std.heap.page_allocator;
    const term = try vt.Wrapper.create(alloc, 80, 24);
    defer term.destroy();

    var buf: [64]u8 = undefined;
    const cases = [_]struct { vk: u32, want: []const u8 }{
        .{ .vk = 0x25, .want = "\x1b[D" }, // VK_LEFT
        .{ .vk = 0x26, .want = "\x1b[A" }, // VK_UP
        .{ .vk = 0x27, .want = "\x1b[C" }, // VK_RIGHT
        .{ .vk = 0x28, .want = "\x1b[B" }, // VK_DOWN
        .{ .vk = 0x24, .want = "\x1b[H" }, // VK_HOME
        .{ .vk = 0x23, .want = "\x1b[F" }, // VK_END
        .{ .vk = 0x21, .want = "\x1b[5~" }, // VK_PRIOR
        .{ .vk = 0x22, .want = "\x1b[6~" }, // VK_NEXT
        .{ .vk = 0x2D, .want = "\x1b[2~" }, // VK_INSERT
        .{ .vk = 0x2E, .want = "\x1b[3~" }, // VK_DELETE
        .{ .vk = 0x0D, .want = "\r" }, // VK_RETURN
        .{ .vk = 0x1B, .want = "\x1b" }, // VK_ESCAPE
        .{ .vk = 0x09, .want = "\t" }, // VK_TAB（补全键；发成 CR 会让 shell 直接执行）
        .{ .vk = 0x08, .want = "\x7f" }, // VK_BACK：DECBKM 关时退格发 DEL（alacritty 同口径）
    };
    for (cases) |c| {
        const got = encodeVk(term, c.vk, .{}, &buf);
        if (!std.mem.eql(u8, got, c.want)) {
            std.debug.print("\nvk=0x{x} 编码结果 {any}，期望 {any}\n", .{ c.vk, got, c.want });
        }
        try testing.expectEqualStrings(c.want, got);
    }
}

test "Windows Ctrl/Shift + 方向键：带修饰的序列不是空的" {
    const alloc = std.heap.page_allocator;
    const term = try vt.Wrapper.create(alloc, 80, 24);
    defer term.destroy();

    var buf: [64]u8 = undefined;
    const got_ctrl = encodeVk(term, 0x27, .{ .ctrl = true }, &buf);
    try testing.expect(got_ctrl.len > 0);
    try testing.expect(got_ctrl[0] == 0x1b);
    const got_shift = encodeVk(term, 0x26, .{ .shift = true }, &buf);
    try testing.expect(got_shift.len > 0);
    try testing.expect(got_shift[0] == 0x1b);
}

test "Ctrl+字母：legacy 出 C0，kitty 出 CSI u（与 Rust 一致）" {
    const alloc = std.heap.page_allocator;
    const term = try vt.Wrapper.create(alloc, 80, 24);
    defer term.destroy();
    var buf: [64]u8 = undefined;

    // legacy：Ctrl+a → 0x01
    {
        const ev: gh.input.KeyEvent = .{
            .action = .press, .key = .key_a, .mods = .{ .ctrl = true },
            .utf8 = "a", .unshifted_codepoint = 'a',
        };
        var w = std.Io.Writer.fixed(&buf);
        const opts = gh.input.KeyEncodeOptions.fromTerminal(&term.term);
        gh.input.encodeKey(&w, ev, opts) catch {};
        try testing.expectEqualSlices(u8, &[_]u8{0x01}, w.buffered());
    }
    // kitty：Ctrl+a → ESC[97;5u
    term.feed("\x1b[>1u");
    {
        const ev: gh.input.KeyEvent = .{
            .action = .press, .key = .key_a, .mods = .{ .ctrl = true },
            .utf8 = "a", .unshifted_codepoint = 'a',
        };
        var w = std.Io.Writer.fixed(&buf);
        const opts = gh.input.KeyEncodeOptions.fromTerminal(&term.term);
        gh.input.encodeKey(&w, ev, opts) catch {};
        try testing.expect(std.mem.eql(u8, w.buffered(), "\x1b[97;5u"));
    }
    // kitty：Ctrl+Shift+a（Shift 由字符体现 → consumed）
    {
        const ev: gh.input.KeyEvent = .{
            .action = .press, .key = .key_a, .mods = .{ .ctrl = true, .shift = true },
            .consumed_mods = .{ .shift = true },
            .utf8 = "A", .unshifted_codepoint = 'a',
        };
        var w = std.Io.Writer.fixed(&buf);
        const opts = gh.input.KeyEncodeOptions.fromTerminal(&term.term);
        gh.input.encodeKey(&w, ev, opts) catch {};
    }
    // kitty：Alt+x
    {
        const ev: gh.input.KeyEvent = .{
            .action = .press, .key = .key_x, .mods = .{ .alt = true },
            .utf8 = "x", .unshifted_codepoint = 'x',
        };
        var w = std.Io.Writer.fixed(&buf);
        var opts = gh.input.KeyEncodeOptions.fromTerminal(&term.term);
        opts.alt_esc_prefix = true;
        gh.input.encodeKey(&w, ev, opts) catch {};
        try testing.expect(std.mem.eql(u8, w.buffered(), "\x1b[120;3u"));
    }
}

/// 回退到 inbox conhost 时把 kitty 键盘协议标志清零。
///
/// 为什么：CSI-u（`ESC[97;5u`）只有 OpenConsole 认，inbox conhost 收到会**丢弃**，
/// 于是 kitty 应用（pi/vim）里的 Ctrl+C、Ctrl+A 变成"什么都不发"——比 legacy 更糟。
/// 带 `conpty.dll` 时原样返回，行为不变。抽成纯函数以便在 Linux 上单测。
pub fn gateKittyFlags(comptime T: type, openconsole: bool, flags: T) T {
    return if (openconsole) flags else std.mem.zeroes(T);
}

test "gateKittyFlags: 无 OpenConsole 时清零，有则原样" {
    try testing.expectEqual(@as(u5, 0), gateKittyFlags(u5, false, 3));
    try testing.expectEqual(@as(u5, 3), gateKittyFlags(u5, true, 3));
    try testing.expectEqual(@as(u8, 0), gateKittyFlags(u8, false, 0xFF));
    try testing.expectEqual(@as(u8, 0xFF), gateKittyFlags(u8, true, 0xFF));
}
