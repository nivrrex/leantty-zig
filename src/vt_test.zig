//! 单元测试：移植 Rust 侧 V4（网格断言 a-f）、V7（按键序列）、V8（快照不变性）。
//!
//! e2e 只能黑盒断言 dump 文本，覆盖不到「编码器字节」「owned 快照不变式」
//! 「宽格标记」这些内部契约；这些用例补的就是那部分。

const std = @import("std");
const gh = @import("ghostty-vt");
const vt = @import("vt.zig");
const config = @import("config.zig");
const toml = @import("toml.zig");
const framepace = @import("framepace.zig");
const render = @import("render.zig");

const alloc = std.testing.allocator;

fn newTerm(cols: u16, rows: u16) !*vt.Wrapper {
    return vt.Wrapper.create(alloc, cols, rows);
}

fn cellAt(term: *vt.Wrapper, x: u16, y: u16) gh.RenderState.Cell {
    return term.rs.row_data.get(y).cells.get(x);
}

fn codepointAt(term: *vt.Wrapper, x: u16, y: u16) u21 {
    const c = cellAt(term, x, y);
    return switch (c.raw.content_tag) {
        .codepoint, .codepoint_grapheme => c.raw.content.codepoint.data,
        .bg_color_palette, .bg_color_rgb => 0,
    };
}

fn resolvedFg(term: *vt.Wrapper, x: u16, y: u16) ?gh.color.RGB {
    const c = cellAt(term, x, y);
    if (c.raw.style_id == 0) return null;
    return switch (c.style.fg_color) {
        .none => null,
        .rgb => |rgb| rgb,
        .palette => |idx| term.rs.colors.palette[idx],
    };
}

fn rowTextUtf8(term: *vt.Wrapper, y: u16, cp_buf: []u21, out: []u8) ![]const u8 {
    const cps = rowText(term, y, cp_buf);
    var n: usize = 0;
    for (cps) |cp| {
        if (cp == 0) break;
        if (cp == ' ') {
            out[n] = ' ';
            n += 1;
            continue;
        }
        const len = std.unicode.utf8Encode(@intCast(cp), out[n..][0..4]) catch 0;
        n += len;
        if (n >= out.len - 4) break;
    }
    return out[0..n];
}

fn firstRowText(term: *vt.Wrapper, cp_buf: []u21, out: []u8) ![]const u8 {
    return rowTextUtf8(term, 0, cp_buf, out);
}

fn rowText(term: *vt.Wrapper, y: u16, buf: []u21) []const u21 {
    var n: usize = 0;
    var x: u16 = 0;
    while (x < term.rs.cols) : (x += 1) {
        buf[n] = codepointAt(term, x, y);
        n += 1;
    }
    return buf[0..n];
}

test "V4a 普通文本进网格" {
    const term = try newTerm(80, 24);
    defer term.destroy();
    term.feed("hello");
    try term.update();
    try std.testing.expectEqual(@as(u21, 'h'), codepointAt(term, 0, 0));
    try std.testing.expectEqual(@as(u21, 'e'), codepointAt(term, 1, 0));
    try std.testing.expectEqual(@as(u21, 'l'), codepointAt(term, 2, 0));
    try std.testing.expectEqual(@as(u21, 'l'), codepointAt(term, 3, 0));
    try std.testing.expectEqual(@as(u21, 'o'), codepointAt(term, 4, 0));
}

test "V4b SGR 红色前景与复位" {
    const term = try newTerm(80, 24);
    defer term.destroy();
    term.feed("\x1b[31mred\x1b[0m");
    try term.update();

    // ghostty 默认调色板 red = (204,102,102)
    const fg = resolvedFg(term, 0, 0) orelse return error.NoFg;
    try std.testing.expectEqual(@as(u8, 204), fg.r);
    try std.testing.expectEqual(@as(u8, 102), fg.g);
    try std.testing.expectEqual(@as(u8, 102), fg.b);

    // 复位之后不再有显式前景色
    try std.testing.expectEqual(@as(?gh.color.RGB, null), resolvedFg(term, 3, 0));
}

test "V4c 清屏后光标归位" {
    const term = try newTerm(80, 24);
    defer term.destroy();
    term.feed("hello\x1b[2J\x1b[H");
    try term.update();
    try std.testing.expectEqual(@as(u16, 0), term.rs.cursor.active.x);
    try std.testing.expectEqual(@as(u32, 0), term.rs.cursor.active.y);
    try std.testing.expectEqual(@as(u21, 0), codepointAt(term, 0, 0));
}

test "V4d scrollback 行数与末行内容" {
    const term = try newTerm(24, 24);
    defer term.destroy();
    var i: usize = 1;
    while (i <= 60) : (i += 1) {
        var buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "line {d}\r\n", .{i});
        term.feed(line);
    }
    try term.update();

    try std.testing.expect(term.scrollbackRows() >= 36);
    try std.testing.expectEqual(@as(u16, 24), term.rs.cols);

    // 视口最后一行（24 行终端，60 行输出 + 换行）应有 "line 59" 或 "line 60"
    var found = false;
    var cp_buf: [256]u21 = undefined;
    var y: u16 = 0;
    while (y < term.rs.rows) : (y += 1) {
        const cps = rowText(term, y, &cp_buf);
        var text: [256]u8 = undefined;
        var n: usize = 0;
        for (cps) |cp| {
            if (cp == 0) break;
            const len = std.unicode.utf8Encode(@intCast(cp), text[n..][0..4]) catch 0;
            n += len;
        }
        if (std.mem.indexOf(u8, text[0..n], "line 60") != null or
            std.mem.indexOf(u8, text[0..n], "line 59") != null)
        {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "V4e 宽字符占两格（Wide + SpacerTail）" {
    const term = try newTerm(80, 24);
    defer term.destroy();
    term.feed("你好abc");
    try term.update();

    try std.testing.expectEqual(gh.Cell.Wide.wide, cellAt(term, 0, 0).raw.wide);
    try std.testing.expectEqual(gh.Cell.Wide.spacer_tail, cellAt(term, 1, 0).raw.wide);
    try std.testing.expectEqual(gh.Cell.Wide.wide, cellAt(term, 2, 0).raw.wide);
    try std.testing.expectEqual(gh.Cell.Wide.spacer_tail, cellAt(term, 3, 0).raw.wide);
    try std.testing.expectEqual(@as(u21, 'a'), codepointAt(term, 4, 0));
    try std.testing.expectEqual(gh.Cell.Wide.narrow, cellAt(term, 4, 0).raw.wide);
}

test "V4f alternate screen 进出" {
    const term = try newTerm(80, 24);
    defer term.destroy();
    term.feed("main-content");
    term.feed("\x1b[?1049h");
    term.feed("alt-content");
    try term.update();
    try std.testing.expect(term.alternate());
    try std.testing.expectEqual(@as(u64, 0), term.scrollbackRows());

    term.feed("\x1b[?1049l");
    try term.update();
    try std.testing.expect(!term.alternate());
    try std.testing.expectEqual(@as(u21, 'm'), codepointAt(term, 0, 0));
}

test "V7 普通模式按键字节" {
    const term = try newTerm(80, 24);
    defer term.destroy();

    const Case = struct { key: gh.input.Key, mods: gh.input.KeyMods = .{}, want: []const u8 };
    const cases = [_]Case{
        .{ .key = .arrow_up, .want = "\x1b[A" },
        .{ .key = .arrow_down, .want = "\x1b[B" },
        .{ .key = .arrow_right, .want = "\x1b[C" },
        .{ .key = .arrow_left, .want = "\x1b[D" },
        .{ .key = .enter, .want = "\r" },
        .{ .key = .backspace, .want = "\x7f" },
        .{ .key = .tab, .want = "\t" },
        .{ .key = .escape, .want = "\x1b" },
        .{ .key = .f1, .want = "\x1bOP" },
        .{ .key = .home, .want = "\x1b[H" },
        .{ .key = .end, .want = "\x1b[F" },
        .{ .key = .tab, .mods = .{ .shift = true }, .want = "\x1b[Z" },
        .{ .key = .key_c, .mods = .{ .ctrl = true }, .want = "\x03" },
        .{ .key = .key_d, .mods = .{ .ctrl = true }, .want = "\x04" },
    };

    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();

    for (cases) |c| {
        writer.clearRetainingCapacity();
        const ev: gh.input.KeyEvent = .{
            .action = .press,
            .key = c.key,
            .mods = c.mods,
            .unshifted_codepoint = 0,
        };
        try term.encodeKey(ev, &writer.writer);
        try std.testing.expectEqualStrings(c.want, writer.written());
    }
}

test "V7 应用光标键模式（DECCKM）方向键变 SS3" {
    const term = try newTerm(80, 24);
    defer term.destroy();
    term.feed("\x1b[?1h"); // DECCKM on
    try term.update();

    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();

    const cases = [_]struct { key: gh.input.Key, want: []const u8 }{
        .{ .key = .arrow_up, .want = "\x1bOA" },
        .{ .key = .arrow_down, .want = "\x1bOB" },
        .{ .key = .arrow_right, .want = "\x1bOC" },
        .{ .key = .arrow_left, .want = "\x1bOD" },
    };
    for (cases) |c| {
        writer.clearRetainingCapacity();
        try term.encodeKey(.{ .action = .press, .key = c.key }, &writer.writer);
        try std.testing.expectEqualStrings(c.want, writer.written());
    }
}

test "V7 功能键 F1-F12 字节" {
    const term = try newTerm(80, 24);
    defer term.destroy();

    const cases = [_]struct { key: gh.input.Key, want: []const u8 }{
        .{ .key = .f1, .want = "\x1bOP" },
        .{ .key = .f2, .want = "\x1bOQ" },
        .{ .key = .f3, .want = "\x1bOR" },
        .{ .key = .f4, .want = "\x1bOS" },
        .{ .key = .f5, .want = "\x1b[15~" },
        .{ .key = .f6, .want = "\x1b[17~" },
        .{ .key = .f7, .want = "\x1b[18~" },
        .{ .key = .f8, .want = "\x1b[19~" },
        .{ .key = .f9, .want = "\x1b[20~" },
        .{ .key = .f10, .want = "\x1b[21~" },
        .{ .key = .f11, .want = "\x1b[23~" },
        .{ .key = .f12, .want = "\x1b[24~" },
    };

    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    for (cases) |c| {
        writer.clearRetainingCapacity();
        try term.encodeKey(.{ .action = .press, .key = c.key }, &writer.writer);
        try std.testing.expectEqualStrings(c.want, writer.written());
    }
}

test "V7 小键盘与修饰组合矩阵" {
    const term = try newTerm(80, 24);
    defer term.destroy();

    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();

    // 小键盘数字/运算键
    const numpad_cases = [_]struct { key: gh.input.Key, want: []const u8 }{
        .{ .key = .numpad_0, .want = "0" },
        .{ .key = .numpad_9, .want = "9" },
        .{ .key = .numpad_enter, .want = "\r" },
        .{ .key = .numpad_add, .want = "+" },
        .{ .key = .numpad_subtract, .want = "-" },
        .{ .key = .numpad_multiply, .want = "*" },
        .{ .key = .numpad_divide, .want = "/" },
        .{ .key = .numpad_decimal, .want = "." },
    };
    for (numpad_cases) |c| {
        writer.clearRetainingCapacity();
        try term.encodeKey(.{ .action = .press, .key = c.key }, &writer.writer);
        try std.testing.expectEqualStrings(c.want, writer.written());
    }

    // 修饰组合：Shift/Ctrl/Alt + 方向键 → CSI 1;<mod>A/B/C/D
    const mod_cases = [_]struct {
        key: gh.input.Key,
        mods: gh.input.KeyMods,
        want: []const u8,
    }{
        .{ .key = .arrow_up, .mods = .{ .shift = true }, .want = "\x1b[1;2A" },
        .{ .key = .arrow_down, .mods = .{ .shift = true }, .want = "\x1b[1;2B" },
        .{ .key = .arrow_right, .mods = .{ .ctrl = true }, .want = "\x1b[1;5C" },
        .{ .key = .arrow_left, .mods = .{ .ctrl = true }, .want = "\x1b[1;5D" },
        .{ .key = .arrow_up, .mods = .{ .alt = true }, .want = "\x1b[1;3A" },
        .{ .key = .home, .mods = .{ .shift = true }, .want = "\x1b[1;2H" },
        .{ .key = .end, .mods = .{ .ctrl = true }, .want = "\x1b[1;5F" },
    };
    for (mod_cases) |c| {
        writer.clearRetainingCapacity();
        try term.encodeKey(.{ .action = .press, .key = c.key, .mods = c.mods }, &writer.writer);
        try std.testing.expectEqualStrings(c.want, writer.written());
    }

    // Alt+字母 → ESC 前缀
    writer.clearRetainingCapacity();
    try term.encodeKey(.{
        .action = .press,
        .key = .key_x,
        .mods = .{ .alt = true },
        .unshifted_codepoint = 'x',
    }, &writer.writer);
    try std.testing.expectEqualStrings("\x1bx", writer.written());
}

test "viewport 滚动：top/bottom/delta 改变可见首行" {
    const term = try newTerm(24, 24);
    defer term.destroy();
    var i: usize = 1;
    while (i <= 60) : (i += 1) {
        var buf: [32]u8 = undefined;
        term.feed(try std.fmt.bufPrint(&buf, "line {d}\r\n", .{i}));
    }
    try term.update();

    var cp_buf: [64]u21 = undefined;
    var text_buf: [256]u8 = undefined;
    const bottom_first = try firstRowText(term, &cp_buf, &text_buf);
    try std.testing.expect(std.mem.startsWith(u8, bottom_first, "line "));

    term.scrollTop();
    try term.update();
    const top_first = try firstRowText(term, &cp_buf, &text_buf);
    try std.testing.expect(!std.mem.eql(u8, bottom_first, top_first));

    // 顶部应能看到最早的内容（hello 或 line 1）
    var saw_early = std.mem.indexOf(u8, top_first, "hello") != null or
        std.mem.indexOf(u8, top_first, "line 1") != null or
        std.mem.indexOf(u8, top_first, "line 2") != null;
    if (!saw_early) {
        // 首行可能是宽字符续格/空行，扫描前 3 行
        var y: u16 = 0;
        while (y < 3) : (y += 1) {
            const t = try rowTextUtf8(term, y, &cp_buf, &text_buf);
            if (std.mem.indexOf(u8, t, "hello") != null or std.mem.indexOf(u8, t, "line 1") != null) {
                saw_early = true;
            }
        }
    }
    try std.testing.expect(saw_early);

    term.scrollBottom();
    try term.update();
    const back = try firstRowText(term, &cp_buf, &text_buf);
    try std.testing.expectEqualStrings(bottom_first, back);
}

test "viewport 滚动：delta 的方向与步长" {
    const term = try newTerm(24, 24);
    defer term.destroy();
    var i: usize = 1;
    while (i <= 60) : (i += 1) {
        var buf: [32]u8 = undefined;
        term.feed(try std.fmt.bufPrint(&buf, "line {d}\r\n", .{i}));
    }
    try term.update();

    // 注意：firstRowText 返回的是传入缓冲区切片，比较前必须各自独立缓冲，
    // 否则后一次读取会把前一次的内容覆盖掉（本轮就踩过这个坑）。
    var cp_buf: [64]u21 = undefined;
    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;

    const before = try std.fmt.allocPrint(alloc, "{s}", .{try firstRowText(term, &cp_buf, &buf_a)});
    defer alloc.free(before);

    // 负 delta：向更早的内容滚
    term.scrollDelta(-3);
    try term.update();
    const up = try std.fmt.allocPrint(alloc, "{s}", .{try firstRowText(term, &cp_buf, &buf_b)});
    defer alloc.free(up);
    try std.testing.expect(!std.mem.eql(u8, before, up));

    // 正 delta：滚回底部
    term.scrollDelta(1000);
    try term.update();
    const back = try std.fmt.allocPrint(alloc, "{s}", .{try firstRowText(term, &cp_buf, &buf_a)});
    defer alloc.free(back);
    try std.testing.expectEqualStrings(before, back);

    // 越界向上滚会 clamp 在顶部，且首行应是最早的内容
    term.scrollDelta(-100000);
    try term.update();
    const top = try std.fmt.allocPrint(alloc, "{s}", .{try firstRowText(term, &cp_buf, &buf_b)});
    defer alloc.free(top);
    try std.testing.expect(top.len > 0);
    try std.testing.expect(!std.mem.eql(u8, top, before));
}

test "复制：无选区时全选并格式化为纯文本" {
    const term = try newTerm(40, 6);
    defer term.destroy();
    term.feed("copy-me\r\nsecond line\r\n");
    try term.update();

    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();

    const ok = try term.copySelection(&writer.writer);
    try std.testing.expect(ok);
    const text = writer.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "copy-me") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "second line") != null);
    // 纯文本输出不应带 SGR/OSC 等转义
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[") == null);
}

test "选区：selectRange 后复制只包含选区内容" {
    const term = try newTerm(40, 6);
    defer term.destroy();
    term.feed("alpha\r\nbravo\r\ncharlie\r\n");
    try term.update();

    // 只选第 2 行（y=1, x=0..5）
    try std.testing.expect(term.selectRange(0, 1, 5, 1));

    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    try std.testing.expect(try term.copySelection(&writer.writer));
    const text = writer.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "bravo") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "alpha") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "charlie") == null);

    term.clearSelection();
    try term.update();
}

test "grapheme：组合字符整簇保留" {
    const term = try newTerm(20, 3);
    defer term.destroy();
    // e + U+0301（组合尖音符）
    term.feed("e\u{301}x");
    try term.update();

    const c = cellAt(term, 0, 0);
    try std.testing.expectEqual(gh.Cell.ContentTag.codepoint_grapheme, c.raw.content_tag);
    // cell.grapheme 只放附加码点，基字符在 raw.content.codepoint
    try std.testing.expectEqual(@as(u21, 'e'), c.raw.content.codepoint.data);
    try std.testing.expectEqual(@as(usize, 1), c.grapheme.len);
    try std.testing.expectEqual(@as(u21, 0x301), c.grapheme[0]);
    // 下一个字符仍在第 2 格（组合字符不额外占格）
    try std.testing.expectEqual(@as(u21, 'x'), codepointAt(term, 1, 0));
}

test "鼠标格式：x10 / SGR1006 / urxvt1015 / utf8-1005 / SGR-Pixels1016" {
    const Case = struct {
        name: []const u8,
        setup: []const u8,
        px: f32,
        py: f32,
        want: []const u8,
    };
    const cases = [_]Case{
        // 默认 x10：CSI M <b+32> <x+33> <y+33>；pos(40,32) → 格 (5,2)
        .{ .name = "x10", .setup = "\x1b[?1000h", .px = 40, .py = 32, .want = "\x1b[M \x26#" },
        // SGR 1006：CSI < <b> ; <x+1> ; <y+1> M
        .{ .name = "sgr", .setup = "\x1b[?1000h\x1b[?1006h", .px = 40, .py = 32, .want = "\x1b[<0;6;3M" },
        // urxvt 1015：CSI <b+32> ; <x+1> ; <y+1> M
        .{ .name = "urxvt", .setup = "\x1b[?1000h\x1b[?1015h", .px = 40, .py = 32, .want = "\x1b[32;6;3M" },
        // SGR-Pixels 1016：坐标是像素而不是格子
        .{ .name = "pixels", .setup = "\x1b[?1000h\x1b[?1016h", .px = 40, .py = 32, .want = "\x1b[<0;40;32M" },
        // utf8 1005：坐标 >127 时用 UTF-8 多字节编码；格 200 → 200+33=233 → 0xC3 0xA9
        .{ .name = "utf8", .setup = "\x1b[?1000h\x1b[?1005h", .px = 1600, .py = 32, .want = "\x1b[M \xc3\xa9#" },
    };

    for (cases) |c| {
        const term = try newTerm(300, 24);
        defer term.destroy();
        term.feed(c.setup);
        try term.update();

        var writer: std.Io.Writer.Allocating = .init(alloc);
        defer writer.deinit();
        const ev: gh.input.MouseEncodeEvent = .{
            .action = .press,
            .button = .left,
            .pos = .{ .x = c.px, .y = c.py },
        };
        try term.encodeMouseEx(ev, 300, 24, 8, 16, true, &writer.writer);
        try std.testing.expectEqualStrings(c.want, writer.written());
    }
}

test "配置：优先级 CLI > env > 文件 > 默认" {
    // 文件层（含注释、引号、浮点字号）
    var cfg: config.Config = .{};
    const text =
        "# 注释行\n" ++
        "cols = 100\n" ++
        "rows = 30\n" ++
        "font_family = \"Noto Sans Mono\"\n" ++
        "font_size = 12.6\n" ++
        "cell_w = 9\n";
    config.parseConfigText(&cfg, text);
    try std.testing.expectEqual(@as(u16, 100), cfg.cols);
    try std.testing.expectEqual(@as(u16, 30), cfg.rows);
    try std.testing.expectEqualStrings("Noto Sans Mono", cfg.font_family.?);
    try std.testing.expectEqual(@as(u32, 13), cfg.font_size); // 12.6 四舍五入
    try std.testing.expectEqual(@as(u32, 9), cfg.cell_w);

    // 环境变量覆盖文件
    config.apply(&cfg, "APP_COLS", "120");
    try std.testing.expectEqual(@as(u16, 120), cfg.cols);

    // 命令行覆盖环境变量
    config.parseArgs(&cfg, &.{ "--cols", "90", "--font-size", "10" });
    try std.testing.expectEqual(@as(u16, 90), cfg.cols);
    try std.testing.expectEqual(@as(u32, 10), cfg.font_size);

    // 非法值一律回落，不 panic
    config.apply(&cfg, "APP_ROWS", "abc");
    config.apply(&cfg, "APP_FONT_SIZE", "-3");
    config.parseArgs(&cfg, &.{"--cols"}); // 缺少值
    try std.testing.expectEqual(@as(u16, 30), cfg.rows);
    try std.testing.expectEqual(@as(u32, 10), cfg.font_size);
    try std.testing.expectEqual(@as(u16, 90), cfg.cols);
}

test "TOML：section / 内联表 / 数组 / 注释 / 坏行" {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const text =
        "# 注释\n" ++
        "[window]\n" ++
        "position = { x = 60, y = 40 }\n" ++
        "dimensions = { columns = 100, lines = 28 }\n" ++
        "[font]\n" ++
        "size = 12.5\n" ++
        "normal = { family = \"Noto Sans Mono\", style = \"Regular\" }\n" ++
        "fallback = [ { family = \"HYQiHei\" } ]\n" ++
        "[scrolling]\n" ++
        "history = 5000\n" ++
        "this line is broken\n";

    var parsed = try toml.parse(a, text);
    defer parsed.deinit(a);
    try std.testing.expectEqual(@as(i64, 60), parsed.get("window.position.x").?.int);
    try std.testing.expectEqual(@as(i64, 100), parsed.get("window.dimensions.columns").?.int);
    try std.testing.expectEqual(@as(i64, 28), parsed.get("window.dimensions.lines").?.int);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), parsed.get("font.size").?.float, 0.001);
    try std.testing.expectEqualStrings("Noto Sans Mono", parsed.get("font.normal.family").?.string);
    try std.testing.expectEqualStrings("HYQiHei", parsed.get("font.fallback[0].family").?.string);
    try std.testing.expectEqual(@as(i64, 5000), parsed.get("scrolling.history").?.int);
    try std.testing.expect(parsed.skipped >= 1); // 坏行被跳过
    try std.testing.expect(parsed.get("scrolling.this line is broken") == null);
}

test "TOML → Config 映射（含未知字段告警与 backend 处理）" {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg: config.Config = .{};
    var warnings: std.ArrayList(u8) = .empty;
    defer warnings.deinit(a); // 与 append 用同一个 allocator

    const text =
        "[window]\n" ++
        "dimensions = { columns = 90, lines = 26 }\n" ++
        "position = { x = 12, y = 34 }\n" ++
        "[font]\n" ++
        "size = 12.6\n" ++
        "normal = { family = \"DejaVu Sans Mono\" }\n" ++
        "[scrolling]\n" ++
        "history = 7000\n" ++
        "[selection]\n" ++
        "save_to_clipboard = false\n" ++
        "[renderer]\n" ++
        "backend = \"gpu\"\n" ++
        "[nope]\n" ++
        "x = 1\n";

    try config.applyToml(&cfg, a, text, &warnings);
    try std.testing.expectEqual(@as(u16, 90), cfg.cols);
    try std.testing.expectEqual(@as(u16, 26), cfg.rows);
    try std.testing.expectEqual(@as(i32, 12), cfg.window_x.?);
    try std.testing.expectEqual(@as(i32, 34), cfg.window_y.?);
    try std.testing.expectEqual(@as(u32, 13), cfg.font_size); // 12.6 → 13
    try std.testing.expectEqualStrings("DejaVu Sans Mono", cfg.font_family.?);
    try std.testing.expectEqual(@as(u64, 7000), cfg.scrollback_lines);
    try std.testing.expect(!cfg.save_to_clipboard);
    try std.testing.expectEqual(config.Backend.gpu, cfg.backend); // 现在支持 gpu，不再告警
    try std.testing.expect(std.mem.indexOf(u8, warnings.items, "nope.x") != null);
}

test "选区：流式（阅读顺序）而非矩形块" {
    const term = try newTerm(20, 5);
    defer term.destroy();
    term.feed("aaaaaaaaaa\r\nbbbbbbbbbb\r\ncccccccccc\r\ndddddddddd\r\n");
    try term.update();

    // 从第 0 行第 2 列拖到第 2 行第 3 列
    try std.testing.expect(term.selectRange(2, 0, 3, 2));
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    try std.testing.expect(try term.copySelection(&writer.writer));
    const text = writer.written();

    // 流式选择：中间整行 b 必须完整包含；末行只到第 3 列
    try std.testing.expect(std.mem.indexOf(u8, text, "bbbbbbbbbb") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cccc") != null);
    // 矩形块的话中间行只会包含 2..3 两列（"bb"），不会出现 10 个 b
    const b_run = std.mem.count(u8, text, "b");
    try std.testing.expectEqual(@as(usize, 10), b_run);
}

test "framepace：目标间隔与 EMA（对齐 Rust 参数）" {
    // 未采到样本 → 下限 8ms
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), framepace.targetIntervalMs(null), 0.001);
    // K=3：2ms → 8ms（下限）；10ms → 30ms；100ms → 100ms（上限）
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), framepace.targetIntervalMs(2.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), framepace.targetIntervalMs(10.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), framepace.targetIntervalMs(80.0), 0.001);
    // EMA：首次样本原样，之后 α=0.3
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), framepace.nextEma(null, 10.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 13.0), framepace.nextEma(10.0, 20.0), 0.001);

    var p: framepace.Pacer = .{};
    try std.testing.expect(p.due(0)); // force
    p.record(0, 10.0); // ema=10 → 间隔 30ms
    try std.testing.expect(!p.due(10));
    try std.testing.expect(p.due(30));
}

test "滚动条 thumb 几何" {
    // 无 scrollback（total == len）→ 不画
    try std.testing.expect(render.Renderer.scrollbarThumb(24, 0, 24, 384) == null);
    // 顶部：thumb 在 y=0
    const top = render.Renderer.scrollbarThumb(100, 0, 24, 384).?;
    try std.testing.expectEqual(@as(u32, 0), top.y);
    try std.testing.expect(top.h >= 8 and top.h <= 384);
    // 底部：thumb 贴底
    const bottom = render.Renderer.scrollbarThumb(100, 76, 24, 384).?;
    try std.testing.expectEqual(@as(u32, 384 - bottom.h), bottom.y);
    // 越界 offset 被 clamp
    const clampd = render.Renderer.scrollbarThumb(100, 9999, 24, 384).?;
    try std.testing.expectEqual(@as(u32, 384 - clampd.h), clampd.y);
}

test "OSC 8 超链接：单元格标记 hyperlink" {
    const term = try newTerm(40, 3);
    defer term.destroy();
    term.feed("\x1b]8;;https://example.com\x1b\\click\x1b]8;;\x1b\\ plain");
    try term.update();

    // "click" 五个格应带 hyperlink 标记，之后的 " plain" 不带
    var x: u16 = 0;
    var linked: usize = 0;
    while (x < 5) : (x += 1) {
        if (cellAt(term, x, 0).raw.hyperlink) linked += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), linked);
    try std.testing.expect(!cellAt(term, 6, 0).raw.hyperlink);
}

test "V8 自有快照在清屏与终端销毁后不变" {
    const term = try newTerm(20, 3);
    term.feed("abc你好");
    try term.update();

    // 拷一份自有数据（不持有 ghostty 内部引用）
    var owned: [20]u21 = undefined;
    var x: u16 = 0;
    while (x < term.rs.cols) : (x += 1) owned[x] = codepointAt(term, x, 0);
    var owned_wide: [20]gh.Cell.Wide = undefined;
    x = 0;
    while (x < term.rs.cols) : (x += 1) owned_wide[x] = cellAt(term, x, 0).raw.wide;

    term.feed("\x1b[2J\x1b[H");
    try term.update();

    // 清屏后当前网格为空，而拷贝出来的快照保持原值
    try std.testing.expectEqual(@as(u21, 0), codepointAt(term, 0, 0));
    try std.testing.expectEqual(@as(u21, 'a'), owned[0]);
    try std.testing.expectEqual(@as(u21, 'c'), owned[2]);
    try std.testing.expectEqual(@as(u21, 0x4f60), owned[3]);
    try std.testing.expectEqual(gh.Cell.Wide.wide, owned_wide[3]);
    try std.testing.expectEqual(gh.Cell.Wide.spacer_tail, owned_wide[4]);

    term.feed("xyz");
    try term.update();
    term.destroy();

    // 终端已销毁，快照仍可读
    try std.testing.expectEqual(@as(u21, 'a'), owned[0]);
    try std.testing.expectEqual(@as(u21, 0x597d), owned[5]);
}

test "resize 后网格尺寸与内容可读" {
    const term = try newTerm(80, 24);
    defer term.destroy();
    term.feed("hello");
    term.resize(120, 40);
    try term.update();
    try std.testing.expectEqual(@as(u16, 120), term.rs.cols);
    try std.testing.expectEqual(@as(u16, 40), term.rs.rows);
    try std.testing.expectEqual(@as(u21, 'h'), codepointAt(term, 0, 0));
}

test "TOML 数组表 [[x]] 与键盘/鼠标绑定字段" {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        "[[mouse.bindings]]\n" ++
        "mouse = \"Middle\"\n" ++
        "action = \"Copy\"\n" ++
        "[[mouse.bindings]]\n" ++
        "mouse = \"Right\"\n" ++
        "action = \"Paste\"\n" ++
        "[[keyboard.bindings]]\n" ++
        "key = \"Insert\"\n" ++
        "mods = \"Control\"\n" ++
        "action = \"Copy\"\n";
    var parsed = try toml.parse(a, text);
    defer parsed.deinit(a);
    try std.testing.expectEqualStrings("Right", parsed.get("mouse.bindings[1].mouse").?.string);
    try std.testing.expectEqualStrings("Insert", parsed.get("keyboard.bindings[0].key").?.string);

    var cfg: config.Config = .{};
    var warnings: std.ArrayList(u8) = .empty;
    defer warnings.deinit(a);
    try config.applyToml(&cfg, a, text, &warnings);
    try std.testing.expectEqualStrings("Middle", cfg.mouse_bindings[0].?.button);
    try std.testing.expectEqualStrings("Paste", cfg.mouse_bindings[1].?.action);
    try std.testing.expectEqualStrings("Control", cfg.keybindings[0].?.mods);
}

test "W-DECSCUSR：CSI q 四态（block/underline/bar）与 cursor.style/blink 解析" {
    // 配置解析会用调用方 allocator 记住字符串，这里用 arena 收口，避免泄漏误报。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const term = try vt.Wrapper.create(a, 80, 24);
    defer term.destroy();
    const Style = @TypeOf(term.rs.cursor.visual_style);

    // DECSCUSR: 1=block 3=underline 5=bar（2/4/6 是各自的 blink 变体，形状相同）
    const cases = [_]struct { seq: []const u8, want: Style }{
        .{ .seq = "\x1b[1 q", .want = .block },
        .{ .seq = "\x1b[3 q", .want = .underline },
        .{ .seq = "\x1b[5 q", .want = .bar },
        .{ .seq = "\x1b[2 q", .want = .block },
    };
    for (cases) |c| {
        term.feed(c.seq);
        try term.update();
        try std.testing.expectEqual(c.want, term.rs.cursor.visual_style);
    }

    // 配置侧：cursor.style 指定默认形状（hollow 只能从这里设置），cursor.blink 可解析。
    var cfg: config.Config = .{};
    var warnings: std.ArrayList(u8) = .empty;
    defer warnings.deinit(a);
    try config.applyToml(&cfg, a, "[cursor]\nstyle = \"block_hollow\"\nblink = true\n", &warnings);
    try std.testing.expectEqual(config.CursorStyle.block_hollow, cfg.cursor_style.?);
    try std.testing.expect(cfg.cursor_blink);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);

    const colors: vt.Wrapper.Colors = .{ .cursor_style = .block_hollow };
    const term2 = try vt.Wrapper.createWithColors(a, 80, 24, 0, colors);
    defer term2.destroy();
    try term2.update();
    try std.testing.expectEqual(@as(Style, .block_hollow), term2.rs.cursor.visual_style);
}
