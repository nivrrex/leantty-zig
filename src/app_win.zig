//! Windows 后端：ConPTY 终端 + GDI/DIB 双缓冲呈现 + IME + 剪贴板 + 鼠标上报。
//!
//! 分工：平台细节（ConPTY、GDI、消息、IME、剪贴板）在 `src/win32.c`；
//! 本文件只做「窗口事件 → 终端输入序列」「终端渲染状态 → 单元格」的翻译，
//! 按键编码与鼠标编码复用 ghostty 的 `input` 模块（与 Linux 侧同一套逻辑）。
//!
//! 线程约定：单线程事件循环；ConPTY 输出用 PeekNamedPipe 轮询，不起工作线程。

const std = @import("std");
const gh = @import("ghostty-vt");
const cellcolor = @import("cellcolor.zig");
const vt = @import("vt.zig");
const config = @import("config.zig");
const paste = @import("paste.zig");

const w32 = struct {
    pub const Cell = extern struct {
        cp: u32,
        fg: u32,
        bg: u32,
        wide: u8,
        attrs: u8,
    };
    pub const Event = extern struct {
        type: c_int,
        vk: c_uint,
        codepoint: c_uint,
        state: c_uint,
        action: c_uint,
        button: c_uint,
        x: c_int,
        y: c_int,
        width: c_int,
        height: c_int,
        cols: c_int,
        rows: c_int,
        delta: c_int,
    };

    pub extern fn w32_init_console() void;
    pub extern fn w32_fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
    pub extern fn w32_fwrite(ptr: *const anyopaque, size: usize, n: usize, f: *anyopaque) c_int;
    pub extern fn w32_fclose(f: *anyopaque) c_int;

    pub extern fn w32_open(
        cols: c_int,
        rows: c_int,
        cell_w: c_int,
        cell_h: c_int,
        title: [*:0]const u8,
        family: ?[*:0]const u8,
        font_px: c_int,
    ) ?*anyopaque;
    pub extern fn w32_close(ctx: ?*anyopaque) void;
    pub extern fn w32_next_event(ctx: ?*anyopaque, out: *Event) c_int;
    pub extern fn w32_present(
        ctx: ?*anyopaque,
        cells: [*]const Cell,
        cols: c_int,
        rows: c_int,
        cursor_x: c_int,
        cursor_y: c_int,
        anchor_x: c_int,
        anchor_y: c_int,
        focused: c_int,
        default_fg: u32,
        default_bg: u32,
        cursor_style: c_int,
        cursor_color: u32,
        cursor_text_color: u32,
    ) void;
    pub extern fn w32_spawn(ctx: ?*anyopaque, cmdline: [*:0]const u8, cwd: ?[*:0]const u8) c_int;
    pub extern fn w32_read(ctx: ?*anyopaque, buf: [*]u8, cap: c_int) c_int;
    pub extern fn w32_write(ctx: ?*anyopaque, buf: [*]const u8, len: c_int) void;
    pub extern fn w32_alive(ctx: ?*anyopaque) c_int;
    pub extern fn w32_resize_pty(ctx: ?*anyopaque, cols: c_int, rows: c_int) void;
    pub extern fn w32_grid(ctx: ?*anyopaque, cols: *c_int, rows: *c_int) void;
    pub extern fn w32_cell_size(ctx: ?*anyopaque, cell_w: *c_int, cell_h: *c_int) void;
    pub extern fn w32_clipboard_read(buf: [*]u8, cap: c_int) c_int;
    pub extern fn w32_clipboard_write(text: [*]const u8, len: c_int) void;
};

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

/// 单调毫秒（自开机起算，不受系统时间调整影响）。
fn nowMs() i64 {
    return @intCast(GetTickCount64());
}

const EV_KEY = 1;
const EV_CHAR = 2;
const EV_RESIZE = 3;
const EV_CLOSE = 4;
const EV_WHEEL = 5;
const EV_MOUSE = 7;
const EV_FOCUS = 8;
const EV_COPY = 9;
const EV_PASTE = 10;

const MOUSE_PRESS = 0;
const MOUSE_RELEASE = 1;
const MOUSE_MOTION = 2;

const BTN_LEFT = 1;
const BTN_RIGHT = 2;
const BTN_MIDDLE = 3;

/// 粘贴缓冲区（单实例、单线程，故用文件级缓冲；只增不减，避免每次粘贴分配）。
var paste_buf: [256 * 1024]u8 = undefined;

/// [colors] draw_bold_text_with_bright_colors 与 [colors.selection]，由 run() 设置；
/// presentFrame 逐帧读取（与 Linux 侧 renderer 字段同语义）。
/// APP_DUMP_COLORS=<path>：把非默认配色的单元格导出成文本（Windows 侧无 GUI 自动化时的取证手段）。
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

var colors_dump_path: ?[]const u8 = null;

var draw_bold_with_bright: bool = false;
var faint_enabled: bool = true;
var faint_percent: u32 = 50;
var selection_bg: ?u32 = null;
var selection_fg: ?u32 = null;

/// OSC 52 等由程序发起的剪贴板写入（ghostty 回调不带 userdata，单实例足够）。
fn clipboardSink(text: []const u8) void {
    if (text.len == 0) return;
    w32.w32_clipboard_write(text.ptr, @intCast(text.len));
}

pub fn run(alloc: std.mem.Allocator, cfg: config.Config, cwd: ?[]const u8) !void {
    // GUI 子系统：先接父控制台（从 cmd 启动时能看到诊断），否则丢掉 stdout/stderr。
    w32.w32_init_console();
    var family_buf: [128]u8 = undefined;
    var family: ?[*:0]const u8 = null;
    if (cfg.font_family) |f| {
        if (f.len + 1 <= family_buf.len) {
            @memcpy(family_buf[0..f.len], f);
            family_buf[f.len] = 0;
            family = @ptrCast(&family_buf);
        }
    }

    // cell_w/cell_h 为 0 时由平台层按字体度量推导（对齐 Rust 的 cell_metrics）。
    const cw: c_int = if (cfg.cell_w) |v| @intCast(v) else 0;
    const ch: c_int = if (cfg.cell_h) |v| @intCast(v) else 0;

    const win = w32.w32_open(
        @intCast(cfg.cols),
        @intCast(cfg.rows),
        cw,
        ch,
        "leantty",
        family,
        @intCast(cfg.font_size),
    ) orelse return error.Win32OpenFailed;
    defer w32.w32_close(win);

    var cols: c_int = 0;
    var rows: c_int = 0;
    w32.w32_grid(win, &cols, &rows);
    var cell_w: c_int = 0;
    var cell_h: c_int = 0;
    w32.w32_cell_size(win, &cell_w, &cell_h);

    // 命令行：-e 指定则按空格拼接；否则 cmd.exe（ConPTY 输出一律 UTF-8）。
    var cmd_buf: [1024]u8 = undefined;
    var cmd_len: usize = 0;
    if (cfg.command.len > 0) {
        for (cfg.command) |part| {
            if (cmd_len + part.len + 2 > cmd_buf.len) break;
            @memcpy(cmd_buf[cmd_len..][0..part.len], part);
            cmd_len += part.len;
            cmd_buf[cmd_len] = ' ';
            cmd_len += 1;
        }
    } else {
        const def = "cmd.exe /K chcp 65001>nul";
        @memcpy(cmd_buf[0..def.len], def);
        cmd_len = def.len;
    }
    if (cmd_len == 0) return error.EmptyCommand;
    cmd_buf[cmd_len - 1] = 0; // 去掉尾随空格（cmd_len 指向已写入长度+1）
    const cmd_z: [*:0]const u8 = @ptrCast(&cmd_buf);

    // 子进程工作目录：--working-directory 优先，否则继承本进程
    var cwd_buf: [1024]u8 = undefined;
    var cwd_z: ?[*:0]const u8 = null;
    if (cwd) |d| {
        if (d.len + 1 <= cwd_buf.len) {
            @memcpy(cwd_buf[0..d.len], d);
            cwd_buf[d.len] = 0;
            cwd_z = @ptrCast(&cwd_buf);
        }
    }

    if (w32.w32_spawn(win, cmd_z, cwd_z) != 0) {
        std.debug.print("leantty: ConPTY 启动失败（需要 Windows 10 1809 及以上）\n", .{});
        return error.SpawnFailed;
    }

    vt.setClipboardSink(&clipboardSink);
    defer vt.setClipboardSink(null);

    // 配色：与 Linux 侧（app.zig）同一套：[colors.primary] / [colors.cursor] /
    // [colors.normal|bright]。之前 Windows 侧直接调 createWithScrollback，
    // 配置虽然解析成功却从未传给 ghostty —— 这是「配置不生效、仍是黑底」的
    // 第四个根因（Windows 专属）。
    colors_dump_path = if (getenv("APP_DUMP_COLORS")) |p| std.mem.span(p) else null;
    draw_bold_with_bright = cfg.colors_bold_bright;
    faint_enabled = cfg.colors_faint;
    faint_percent = @intFromFloat(std.math.clamp(cfg.colors_faint_opacity, 0.0, 1.0) * 100.0 + 0.5);
    if (cfg.colors_selection_bg) |c| selection_bg = (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
    if (cfg.colors_selection_fg) |c| selection_fg = (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;

    var vt_colors: vt.Wrapper.Colors = .{};
    if (cfg.colors_bg) |c| vt_colors.background = .{ .r = c.r, .g = c.g, .b = c.b };
    if (cfg.colors_fg) |c| vt_colors.foreground = .{ .r = c.r, .g = c.g, .b = c.b };
    if (cfg.colors_cursor) |c| vt_colors.cursor = .{ .r = c.r, .g = c.g, .b = c.b };
    if (cfg.cursor_style) |st| vt_colors.cursor_style = switch (st) {
        .block => .block,
        .bar => .bar,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
    for (cfg.colors_palette, 0..) |maybe, i| {
        if (maybe) |c| vt_colors.palette[i] = .{ .r = c.r, .g = c.g, .b = c.b };
    }

    const term = try vt.Wrapper.createWithColors(
        alloc,
        @intCast(cols),
        @intCast(rows),
        cfg.scrollback_lines,
        vt_colors,
    );
    defer term.destroy();

    // 光标颜色：配置的 [colors.cursor] cursor/text 优先，否则用终端默认（前景色）
    const cursor_color_cfg: ?u32 = if (cfg.colors_cursor) |c|
        (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b
    else
        null;
    const cursor_text_cfg: ?u32 = if (cfg.colors_cursor_text) |c|
        (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b
    else
        null;

    var cells = try alloc.alloc(w32.Cell, @intCast(cols * rows));
    defer alloc.free(cells);

    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();

    var out_buf: [16384]u8 = undefined;
    var focused = true;
    var needs_present = true;
    var running = true;

    // 光标闪烁：与 Linux 侧同口径——只在配置 [cursor] blink 显式开启时闪，
    // 程序用 DECSCUSR 请求的闪烁不自动采纳（避免未配置时意外闪烁）。
    var blink_on = true;
    var blink_last_ms: i64 = 0;
    const blink_interval_ms: i64 = 530;

    // 鼠标选区状态
    var drag = false;
    var anchor_x: c_int = 0;
    var anchor_y: c_int = 0;
    var click_count: u32 = 0;
    var click_ms: i64 = 0;
    var click_x: c_int = -1;
    var click_y: c_int = -1;

    // 快照节流：最多每 50ms 落一次盘，但保证末态一定落盘（见循环里的 flush）
    var last_dump: i64 = 0;
    var dump_dirty = false;

    while (running) {
        var activity = false;

        var ev: w32.Event = undefined;
        while (w32.w32_next_event(win, &ev) != 0) {
            activity = true;
            switch (ev.type) {
                EV_CLOSE => running = false,
                EV_FOCUS => {
                    focused = ev.x != 0;
                    needs_present = true;
                },
                EV_KEY => {
                    handleKey(term, win, &writer, &ev, alloc);
                    needs_present = true;
                },
                EV_COPY => {
                    // 控制字符（0x03）的回声由平台层吞掉，这里只管复制
                    copyToClipboard(term, &writer);
                },
                EV_PASTE => {
                    pasteFromClipboard(term, win, alloc);
                    needs_present = true;
                },
                EV_CHAR => {
                    const cp: u32 = ev.codepoint;
                    var tmp: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(cp), &tmp) catch 0;
                    if (n > 0) writeInput(term, win, tmp[0..n]);
                    needs_present = true;
                },
                EV_RESIZE => {
                    const new_cols = ev.cols;
                    const new_rows = ev.rows;
                    if (new_cols != cols or new_rows != rows) {
                        resizeTerm(alloc, term, win, &cells, &cols, &rows, new_cols, new_rows);
                        w32.w32_cell_size(win, &cell_w, &cell_h);
                    }
                    needs_present = true;
                },
                EV_WHEEL => {
                    handleWheel(term, &writer, win, &ev, cell_w, cell_h);
                    needs_present = true;
                },
                EV_MOUSE => {
                    handleMouse(term, win, &writer, &ev, cell_w, cell_h, &cfg, alloc, .{
                        .drag = &drag,
                        .anchor_x = &anchor_x,
                        .anchor_y = &anchor_y,
                        .click_count = &click_count,
                        .click_ms = &click_ms,
                        .click_x = &click_x,
                        .click_y = &click_y,
                    });
                    needs_present = true;
                },
                else => {},
            }
        }

        // 子进程输出
        while (true) {
            const n = w32.w32_read(win, &out_buf, out_buf.len);
            if (n <= 0) break;
            term.feed(out_buf[0..@intCast(n)]);
            activity = true;
        }
        if (w32.w32_alive(win) == 0) running = false;

        if (activity) dump_dirty = true;

        // 闪烁计时：到点翻转并重绘（空闲时也要跑，否则光标永远停在亮态）
        if (cfg.cursor_blink) {
            const now = nowMs();
            if (blink_last_ms == 0 or now - blink_last_ms >= blink_interval_ms) {
                blink_last_ms = now;
                blink_on = !blink_on;
                needs_present = true;
                // 闪烁也算内容变化：否则 APP_DUMP_SNAPSHOT 会停在上一相位，
                // e2e 只能读到陈旧的 cursor_visible（实测过）。
                dump_dirty = true;
            }
        } else {
            blink_on = true;
        }

        if (activity or needs_present) {
            try term.update();
            presentFrame(term, cells, win, @intCast(cols), @intCast(rows), focused, blink_on, .{
                .cursor_color = cursor_color_cfg,
                .cursor_text_color = cursor_text_cfg,
            });
            needs_present = false;
        }

        // 快照：内容变化后最多等 50ms 落盘；即使此后不再有输出，也一定会写一次，
        // 避免自动化测试读到"上一帧"的旧内容（实测过：首帧先落地、后续被节流吞掉）。
        if (cfg.dump_path) |path| {
            const now = nowMs();
            if (dump_dirty and now - last_dump >= 50) {
                last_dump = now;
                dump_dirty = false;
                dumpSnapshot(alloc, path, term, blink_on);
            }
        }

        if (!running) break;
        // 轮询节流：ConPTY 输出靠这条路径拉取，1ms 足够跟上交互输出。
        Sleep(if (activity) 1 else 4);
    }

    // 退出前再落一次快照，避免最后几帧内容丢失
    if (cfg.dump_path) |path| dumpSnapshot(alloc, path, term, blink_on);
}

/// LEANTTY_KDBG=1 时把诊断打到 stderr（0.1.5 起 GUI 子系统下由
/// w32_init_console 的 freopen 接到 LEANTTY_KDBG_FILE）。
fn kdbg(comptime fmt: []const u8, args: anytype) void {
    if (getenv("LEANTTY_KDBG") != null) std.debug.print(fmt, args);
}

fn writeInput(term: *vt.Wrapper, win: ?*anyopaque, bytes: []const u8) void {
    if (bytes.len == 0) return;
    followBottom(term);
    w32.w32_write(win, bytes.ptr, @intCast(bytes.len));
}

fn followBottom(term: *vt.Wrapper) void {
    if (term.alternate() or term.mouseReporting()) return;
    term.scrollBottom();
}

// ---------------------------------------------------------------------------
// 键盘
// ---------------------------------------------------------------------------

/// Win32 虚拟键码 → ghostty 的物理键。返回 null 表示交给文本通道（WM_CHAR）。
fn vkToKey(vk: c_uint) ?gh.input.Key {
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

fn numpadDigit(idx: c_uint) gh.input.Key {
    return @fromBackingInt(@intCast(@backingInt(gh.input.Key.numpad_0) + @as(c_int, @intCast(idx))));
}

fn functionKey(idx: c_uint) gh.input.Key {
    return @fromBackingInt(@intCast(@backingInt(gh.input.Key.f1) + @as(c_int, @intCast(idx))));
}

fn digitKey(idx: c_uint) gh.input.Key {
    return @fromBackingInt(@intCast(@backingInt(gh.input.Key.digit_0) + @as(c_int, @intCast(idx))));
}

fn letterKey(idx: c_uint) gh.input.Key {
    return @fromBackingInt(@intCast(@backingInt(gh.input.Key.key_a) + @as(c_int, @intCast(idx))));
}

/// Alt 组合要带字符正文（ghostty 的 legacy 编码靠 utf8 生成 ESC 前缀）。
/// 只覆盖美式布局的有 ASCII 字符的键；Alt+其他键按无字符处理。
fn vkAsciiChar(vk: c_uint, shift: bool) ?u21 {
    if (vk >= 0x41 and vk <= 0x5A) {
        const base: u21 = @intCast('a' + (vk - 0x41));
        return if (shift) base - 32 else base;
    }
    if (vk >= 0x30 and vk <= 0x39) {
        const digits = "0123456789";
        const shifted = ")!@#$%^&*(";
        return if (shift) shifted[vk - 0x30] else digits[vk - 0x30];
    }
    if (vk == 0x20) return ' ';
    const pair: ?[2]u8 = switch (vk) {
        0xBA => .{ ';', ':' },
        0xBB => .{ '=', '+' },
        0xBC => .{ ',', '<' },
        0xBD => .{ '-', '_' },
        0xBE => .{ '.', '>' },
        0xBF => .{ '/', '?' },
        0xC0 => .{ '`', '~' },
        0xDB => .{ '[', '{' },
        0xDC => .{ '\\', '|' },
        0xDD => .{ ']', '}' },
        0xDE => .{ '\'', '"' },
        else => null,
    };
    if (pair) |p| return if (shift) p[1] else p[0];
    return null;
}

fn handleKey(
    term: *vt.Wrapper,
    win: ?*anyopaque,
    writer: *std.Io.Writer.Allocating,
    ev: *const w32.Event,
    alloc: std.mem.Allocator,
) void {
    const shift = (ev.state & 1) != 0;
    const ctrl = (ev.state & 2) != 0;
    const alt = (ev.state & 4) != 0;

    // 插入键区的剪贴板惯例（与 Linux 侧一致）：Ctrl+Insert = 复制、Shift+Insert = 粘贴。
    // 必须在编码前返回，否则 CSI 2~ 会同时发给子进程。
    if (ev.vk == 0x2D) { // VK_INSERT
        if (ctrl and !shift and !alt) {
            copyToClipboard(term, writer);
            return;
        }
        if (shift and !ctrl and !alt) {
            pasteFromClipboard(term, win, alloc);
            return;
        }
    }

    const key = vkToKey(ev.vk) orelse return;

    // Alt 组合要带字符正文：ghostty 的 legacy 编码靠 utf8 生成 ESC 前缀。
    var utf8_buf: [4]u8 = undefined;
    var utf8: []const u8 = "";
    var unshifted: u21 = 0;
    if (alt and !ctrl) {
        if (vkAsciiChar(ev.vk, false)) |base| {
            unshifted = base;
            const ch = vkAsciiChar(ev.vk, shift) orelse base;
            const n = std.unicode.utf8Encode(ch, &utf8_buf) catch 0;
            if (n > 0) utf8 = utf8_buf[0..n];
        }
    }

    const event: gh.input.KeyEvent = .{
        .action = .press,
        .key = key,
        .mods = .{ .shift = shift, .ctrl = ctrl, .alt = alt },
        .unshifted_codepoint = if (utf8.len > 0) unshifted else 0,
        .utf8 = utf8,
    };

    var opts = gh.input.KeyEncodeOptions.fromTerminal(&term.term);
    // Alt 作为 ESC 前缀（xterm 默认行为；Windows 侧没有 option-as-alt 的歧义）
    opts.alt_esc_prefix = true;

    writer.clearRetainingCapacity();
    gh.input.encodeKey(&writer.writer, event, opts) catch return;
    const bytes = writer.written();
    if (bytes.len > 0) writeInput(term, win, bytes);
}

// ---------------------------------------------------------------------------
// 剪贴板
// ---------------------------------------------------------------------------

fn copyToClipboard(term: *vt.Wrapper, writer: *std.Io.Writer.Allocating) void {
    writer.clearRetainingCapacity();
    const ok = term.copySelection(&writer.writer) catch false;
    const text = writer.written();
    if (ok and text.len > 0) w32.w32_clipboard_write(text.ptr, @intCast(text.len));
}

fn pasteFromClipboard(term: *vt.Wrapper, win: ?*anyopaque, alloc: std.mem.Allocator) void {
    // 剪贴板可能远大于静态缓冲：w32_clipboard_read 在 cap 不足时返回
    // -(需要字节数 + 1)，这里按需扩容重读（之前直接把截断当成功，
    // 表现为“长文本粘贴丢失/什么都不发生”）。
    var heap: ?[]u8 = null;
    defer if (heap) |h| alloc.free(h);

    var n = w32.w32_clipboard_read(&paste_buf, paste_buf.len);
    var raw: []u8 = &paste_buf;
    if (n <= -2) {
        const need: usize = @intCast(-(n + 1));
        const buf = alloc.alloc(u8, need + 2) catch return;
        heap = buf;
        raw = buf;
        n = w32.w32_clipboard_read(buf.ptr, @intCast(buf.len));
    }
    if (n <= 0) return;

    // 载荷归一（见 paste.zig）：NUL 丢弃、CRLF/CR/LF → CR；
    // 对端要求 bracketed paste 时再用 LF 代替 CR（ConPTY 会丢 200~/201~ 并把 CR 变双 CR）。
    const src_len: usize = @intCast(n);
    const bracketed = term.bracketedPaste();
    const len = paste.normalize(raw[0..src_len], bracketed);
    if (len == 0) return;

    // 必须**一次性**写入整段（含 bracketed paste 的包裹序列）。
    // ConPTY 的输入侧是 VT 解析器：WriteFile 一次 = 一个输入批次，
    // 批尾不完整的转义序列会被当成散键（ESC → Escape，"[200~" 变成字面字符），
    // 于是程序收不到 ?2004 包裹、把每个换行当 Enter —— 表现为"多行粘贴逐行提交"
    // （用户实机 0.1.7 复现；Linux 直写 PTY 主端，无此问题，见 REPORT 6.56）。
    kdbg("[win] paste len={d} bracketed={}\n", .{ len, bracketed });
    const pre: []const u8 = if (bracketed) "\x1b[200~" else "";
    const post: []const u8 = if (bracketed) "\x1b[201~" else "";
    const total = pre.len + len + post.len;
    var stack_buf: [8192]u8 = undefined;
    var out_heap: ?[]u8 = null;
    defer if (out_heap) |h| alloc.free(h);
    const out: []u8 = if (total <= stack_buf.len) stack_buf[0..total] else blk: {
        const b = alloc.alloc(u8, total) catch {
            // 分配失败：退回逐段写（至少不会完全丢粘贴），并留下诊断
            if (bracketed) writeInput(term, win, pre);
            writeInput(term, win, raw[0..len]);
            if (bracketed) writeInput(term, win, post);
            return;
        };
        out_heap = b;
        break :blk b;
    };
    @memcpy(out[0..pre.len], pre);
    @memcpy(out[pre.len..][0..len], raw[0..len]);
    @memcpy(out[pre.len + len ..][0..post.len], post);
    writeInput(term, win, out);
}

// ---------------------------------------------------------------------------
// 鼠标
// ---------------------------------------------------------------------------

fn modsOf(ev: *const w32.Event) gh.input.KeyMods {
    return .{
        .shift = (ev.state & 1) != 0,
        .ctrl = (ev.state & 2) != 0,
        .alt = (ev.state & 4) != 0,
    };
}

fn buttonOf(b: c_uint) ?gh.input.MouseButton {
    return switch (b) {
        BTN_LEFT => .left,
        BTN_RIGHT => .right,
        BTN_MIDDLE => .middle,
        else => null,
    };
}

fn encodeMouseEvent(
    term: *vt.Wrapper,
    win: ?*anyopaque,
    writer: *std.Io.Writer.Allocating,
    action: gh.input.MouseAction,
    button: ?gh.input.MouseButton,
    mods: gh.input.KeyMods,
    x_px: c_int,
    y_px: c_int,
    any_pressed: bool,
    cell_w: c_int,
    cell_h: c_int,
) void {
    const event: gh.input.MouseEncodeEvent = .{
        .action = action,
        .button = button,
        .mods = mods,
        .pos = .{ .x = @floatFromInt(x_px), .y = @floatFromInt(y_px) },
    };
    writer.clearRetainingCapacity();
    term.encodeMouseEx(
        event,
        @intCast(term.rs.cols),
        @intCast(term.rs.rows),
        @intCast(cell_w),
        @intCast(cell_h),
        any_pressed,
        &writer.writer,
    ) catch return;
    const bytes = writer.written();
    if (bytes.len > 0) writeInput(term, win, bytes);
}

const ClickState = struct {
    drag: *bool,
    anchor_x: *c_int,
    anchor_y: *c_int,
    click_count: *u32,
    click_ms: *i64,
    click_x: *c_int,
    click_y: *c_int,
};

fn cellAt(ev: *const w32.Event, cell_w: c_int, cell_h: c_int, cols: c_int, rows: c_int) struct { x: c_int, y: c_int } {
    var cx = if (cell_w > 0) @divTrunc(ev.x, cell_w) else 0;
    var cy = if (cell_h > 0) @divTrunc(ev.y, cell_h) else 0;
    if (cx < 0) cx = 0;
    if (cy < 0) cy = 0;
    const max_x = if (cols > 0) cols - 1 else 0;
    const max_y = if (rows > 0) rows - 1 else 0;
    if (cx > max_x) cx = max_x;
    if (cy > max_y) cy = max_y;
    return .{ .x = cx, .y = cy };
}

fn handleMouse(
    term: *vt.Wrapper,
    win: ?*anyopaque,
    writer: *std.Io.Writer.Allocating,
    ev: *const w32.Event,
    cell_w: c_int,
    cell_h: c_int,
    cfg: *const config.Config,
    alloc: std.mem.Allocator,
    st: ClickState,
) void {
    const cols: c_int = @intCast(term.rs.cols);
    const rows: c_int = @intCast(term.rs.rows);
    const pos = cellAt(ev, cell_w, cell_h, cols, rows);
    kdbg("[mouse] act={d} btn={d} cell=({d},{d}) drag={} cnt={d} anchor=({d},{d}) sel={}\n", .{
        ev.action, ev.button, pos.x, pos.y, st.drag.*, st.click_count.*,
        st.anchor_x.*, st.anchor_y.*, term.hasSelection(),
    });

    if (term.mouseReporting()) {
        const action: gh.input.MouseAction = switch (ev.action) {
            MOUSE_PRESS => .press,
            MOUSE_RELEASE => .release,
            else => .motion,
        };
        encodeMouseEvent(
            term,
            win,
            writer,
            action,
            buttonOf(ev.button),
            modsOf(ev),
            ev.x,
            ev.y,
            ev.action != MOUSE_RELEASE,
            cell_w,
            cell_h,
        );
        return;
    }

    switch (ev.action) {
        MOUSE_PRESS => {
            // 鼠标绑定（[[mouse.bindings]]）：与 Linux 侧同一套配置口径，
            // Right/Middle/Left → Copy/Paste。不在终端里硬编码
            // “右键=粘贴”，以免与 Linux 行为不一致。
            if (ev.button != BTN_LEFT) {
                const name = switch (ev.button) {
                    BTN_RIGHT => "Right",
                    BTN_MIDDLE => "Middle",
                    else => "",
                };
                if (mouseAction(cfg.mouse_bindings, name)) |act| {
                    switch (act) {
                        .copy => copyToClipboard(term, writer),
                        .paste => pasteFromClipboard(term, win, alloc),
                    }
                    return;
                }
                return;
            }
            const now = nowMs();
            const near = @abs(pos.x - st.click_x.*) <= 1 and @abs(pos.y - st.click_y.*) <= 1;
            if (now - st.click_ms.* < 500 and near) {
                st.click_count.* += 1;
            } else {
                st.click_count.* = 1;
            }
            st.click_ms.* = now;
            st.click_x.* = pos.x;
            st.click_y.* = pos.y;

            switch (st.click_count.*) {
                1 => {
                    st.drag.* = true;
                    st.anchor_x.* = pos.x;
                    st.anchor_y.* = pos.y;
                    term.clearSelection();
                },
                2 => {
                    _ = term.selectWordAt(@intCast(pos.x), @intCast(pos.y));
                    st.drag.* = false;
                },
                else => {
                    _ = term.selectLineAt(@intCast(pos.x), @intCast(pos.y));
                    st.click_count.* = 0;
                    st.drag.* = false;
                },
            }
        },
        MOUSE_MOTION => {
            // 只在格子真的变了才建选区：Windows 在按下/抬起之间也会投递"没动"的
            // WM_MOUSEMOVE，若照此调用 selectRange 会留下 1 格选区（黑框），
            // 用户看到的就是"选完文字再点一下，选框不消失"（见 REPORT 6.53）。
            if (st.drag.* and (pos.x != st.anchor_x.* or pos.y != st.anchor_y.*)) {
                // 真的拖出格子了：这是拖拽选区，不是连击的一部分。
                // 否则"选完文字后马上单击"会被当成双击 → 选词 → 选框看起来没消失。
                st.click_count.* = 0;
                _ = term.selectRange(
                    @intCast(st.anchor_x.*),
                    @intCast(st.anchor_y.*),
                    @intCast(pos.x),
                    @intCast(pos.y),
                );
            }
        },
        MOUSE_RELEASE => {
            if (ev.button != BTN_LEFT) return;
            const was_drag = st.drag.*;
            st.drag.* = false;
            if (!was_drag or (pos.x == st.anchor_x.* and pos.y == st.anchor_y.*)) {
                // 单击（没有拖出选区）：清掉可能残留的选区，行为与 Linux 侧一致。
                term.clearSelection();
            } else if (cfg.save_to_clipboard) {
                copyToClipboard(term, writer);
            }
        },
        else => {},
    }
}

/// [[mouse.bindings]] 里按键名找动作（只认 Copy/Paste 两种 Windows 可执行的动作）。
fn mouseAction(bindings: [16]?config.MouseBinding, name: []const u8) ?enum { copy, paste } {
    if (name.len == 0) return null;
    for (bindings) |maybe| {
        const mb = maybe orelse continue;
        if (mb.button.len == 0 or mb.action.len == 0) continue;
        if (!std.ascii.eqlIgnoreCase(mb.button, name)) continue;
        if (std.ascii.eqlIgnoreCase(mb.action, "Copy")) return .copy;
        if (std.ascii.eqlIgnoreCase(mb.action, "Paste")) return .paste;
    }
    return null;
}

fn handleWheel(
    term: *vt.Wrapper,
    writer: *std.Io.Writer.Allocating,
    win: ?*anyopaque,
    ev: *const w32.Event,
    cell_w: c_int,
    cell_h: c_int,
) void {
    if (term.mouseReporting()) {
        // 1000/1002/1006：滚轮按 button 4/5 上报
        const btn: gh.input.MouseButton = if (ev.delta > 0) .four else .five;
        encodeMouseEvent(term, win, writer, .press, btn, modsOf(ev), ev.x, ev.y, false, cell_w, cell_h);
        return;
    }
    const step: isize = 3;
    term.scrollDelta(if (ev.delta > 0) -step else step);
}

// ---------------------------------------------------------------------------
// 尺寸 / 呈现 / 快照
// ---------------------------------------------------------------------------

fn resizeTerm(
    alloc: std.mem.Allocator,
    term: *vt.Wrapper,
    win: ?*anyopaque,
    cells: *[]w32.Cell,
    cols: *c_int,
    rows: *c_int,
    new_cols: c_int,
    new_rows: c_int,
) void {
    if (new_cols < 1 or new_rows < 1) return;
    const need: usize = @intCast(new_cols * new_rows);
    const new_cells = alloc.realloc(cells.*, need) catch return;
    cells.* = new_cells;
    cols.* = new_cols;
    rows.* = new_rows;
    term.resize(@intCast(new_cols), @intCast(new_rows));
    w32.w32_resize_pty(win, new_cols, new_rows);
}

/// 光标绘制的可选项（颜色覆盖）。形状与闪烁由 DECSCUSR + 配置决定。
const CursorPaint = struct {
    cursor_color: ?u32 = null,
    cursor_text_color: ?u32 = null,
};

/// DECSCUSR 形状 → 平台层枚举（0=bar 1=block 2=underline 3=hollow）。
/// 顺序只与 src/win32.c 的 switch 对齐，与 ghostty 的枚举值无关。
fn cursorShape(style: anytype) c_int {
    return switch (style) {
        .bar => 0,
        .underline => 2,
        .block_hollow => 3,
        else => 1,
    };
}

fn presentFrame(
    term: *vt.Wrapper,
    cells: []w32.Cell,
    win: ?*anyopaque,
    cols: c_int,
    rows: c_int,
    focused: bool,
    blink_on: bool,
    paint: CursorPaint,
) void {
    const rs = &term.rs;
    const has_sel = term.hasSelection();
    const ucols: usize = @intCast(cols);
    const urows: usize = @intCast(rows);
    const default_bg = rgbToU32(rs.colors.background);
    const default_fg = rgbToU32(rs.colors.foreground);

    var y: usize = 0;
    while (y < urows) : (y += 1) {
        const row = rs.row_data.get(y);
        const row_cells = row.cells;
        // 选区高亮只以 "终端当前有没有选区" 为准：ghostty 的 RenderState.update
        // 在 selection == null 时不会重写各行的 row.selection，未重建的行会留下上一帧的
        // 区间 —— 表现为清掉选区后黑框仍在（见 FINDINGS-4 鼠标一节）。
        const sel = if (has_sel) row.selection else null;
        var x: usize = 0;
        while (x < ucols) : (x += 1) {
            const c = row_cells.get(x);
            const next_is_spacer = (x + 1 < ucols) and
                (row_cells.get(x + 1).raw.wide == .spacer_tail);
            const wide = c.raw.wide == .wide or next_is_spacer;

            const base: u32 = switch (c.raw.content_tag) {
                .codepoint, .codepoint_grapheme => c.raw.content.codepoint.data,
                .bg_color_palette, .bg_color_rgb => 0,
            };
            const selected = if (sel) |range| (x >= range[0] and x < range[1]) else false;
            // 取色走纯函数 cellcolor.resolve：Windows 与 Linux 同一套语义，
            // 且能在 Linux 上用单测覆盖（bold→bright / faint / inverse / invisible / selection）。
            const colors = cellcolor.resolve(rs, c, selected, .{
                .bold_bright = draw_bold_with_bright,
                .faint = faint_enabled,
                .faint_percent = faint_percent,
                .selection_bg = selection_bg,
                .selection_fg = selection_fg,
            });
            const fg = colors.fg;
            const bg = colors.bg;

            var attrs: u8 = 0;
            if (c.raw.style_id != 0) {
                if (c.style.flags.bold) attrs |= 1;
                if (c.style.flags.italic) attrs |= 2;
                if (c.style.flags.underline != .none) attrs |= 4;
                if (c.style.flags.strikethrough) attrs |= 8;
                if (c.style.flags.overline) attrs |= 16;
            }
            if (c.raw.hyperlink) attrs |= 4;

            const wide_flag: u8 = if (c.raw.wide == .spacer_tail or c.raw.wide == .spacer_head)
                2
            else if (wide)
                1
            else
                0;

            cells[y * ucols + x] = .{
                .cp = base,
                .fg = fg,
                .bg = bg,
                .wide = wide_flag,
                .attrs = attrs,
            };
        }
    }

    // 光标：可见性 = 程序未隐藏（rs.cursor.visible）且处于闪烁亮态；
    // 坐标由 viewport 给出（滚出视口时为 null → 不画）。
    var cursor_x: c_int = -1;
    var cursor_y: c_int = -1;
    // IME 锚点：只依赖 viewport，不看 visible/blink —— TUI 常隐藏光标，
    // 这里退化成 (0,0) 会把候选框钉到窗口左上角。
    var anchor_x: c_int = -1;
    var anchor_y: c_int = -1;
    if (rs.cursor.viewport) |vp| {
        anchor_x = @intCast(vp.x);
        anchor_y = @intCast(vp.y);
    }
    var shape: c_int = 1;
    if (rs.cursor.visible and blink_on) {
        if (rs.cursor.viewport) |vp| {
            cursor_x = @intCast(vp.x);
            cursor_y = @intCast(vp.y);
            shape = cursorShape(rs.cursor.visual_style);
        }
    }

    // 颜色优先级：配置 [colors.cursor] > 终端颜色（OSC 12 / 默认）> 前景色
    const cursor_color = paint.cursor_color orelse
        (if (rs.colors.cursor) |c| rgbToU32(c) else default_fg);
    const cursor_text = paint.cursor_text_color orelse default_bg;

    if (colors_dump_path) |path| dumpColors(path, rs, cells[0 .. @intCast(cols * rows)], @intCast(cols));
    w32.w32_present(
        win,
        cells.ptr,
        cols,
        rows,
        cursor_x,
        cursor_y,
        anchor_x,
        anchor_y,
        if (focused) 1 else 0,
        default_fg,
        default_bg,
        shape,
        cursor_color,
        cursor_text,
    );
}

/// 每帧重写：`row col fg bg`（十六进制，只输出与默认背景/前景不同的格子）。
fn dumpColors(path: []const u8, rs: *const gh.RenderState, cells: []const w32.Cell, cols: usize) void {
    var path_z: [512]u8 = undefined;
    if (path.len + 1 > path_z.len) return;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const f = w32.w32_fopen(@ptrCast(&path_z), "w") orelse return;
    defer _ = w32.w32_fclose(f);
    var buf: [4096]u8 = undefined;
    const hdr = "#cells v2 (row col fg bg)\n";
    _ = w32.w32_fwrite(hdr.ptr, 1, hdr.len, f);
    for (cells, 0..) |c, i| {
        if (c.cp == 0 and c.attrs == 0) continue;
        var w = std.Io.Writer.fixed(&buf);
        // 追加诊断列：style_id、bold、faint、inverse、invisible、fg 颜色来源
        const row = i / cols;
        const col = i % cols;
        const cell = rs.row_data.get(row).cells.get(col);
        var tag: [8]u8 = undefined;
        const tagname: []const u8 = switch (cell.style.fg_color) {
            .none => "none",
            .rgb => "rgb",
            .palette => |idx| std.fmt.bufPrint(&tag, "p{d}", .{idx}) catch "p?",
        };
        w.print("{d} {d} {x:0>6} {x:0>6} sid={d} bold={d} faint={d} inv={d} invis={d} fg={s}\n", .{
            row,
            col,
            c.fg,
            c.bg,
            cell.raw.style_id,
            @intFromBool(cell.raw.style_id != 0 and cell.style.flags.bold),
            @intFromBool(cell.raw.style_id != 0 and cell.style.flags.faint),
            @intFromBool(cell.raw.style_id != 0 and cell.style.flags.inverse),
            @intFromBool(cell.raw.style_id != 0 and cell.style.flags.invisible),
            tagname,
        }) catch continue;
        _ = w32.w32_fwrite(&buf, 1, w.end, f);
    }
}

fn rgbToU32(c: anytype) u32 {
    return (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | @as(u32, c.b);
}

fn resolveFg(rs: *const gh.RenderState, c: gh.RenderState.Cell) ?u32 {
    if (c.raw.style_id == 0) return null;
    return switch (c.style.fg_color) {
        .none => null,
        .rgb => |rgb| rgbToU32(rgb),
        .palette => |idx| rgbToU32(rs.colors.palette[idx]),
    };
}

fn resolveBg(rs: *const gh.RenderState, c: gh.RenderState.Cell) ?u32 {
    switch (c.raw.content_tag) {
        .bg_color_rgb => return rgbToU32(c.raw.content.color_rgb),
        .bg_color_palette => return rgbToU32(rs.colors.palette[c.raw.content.color_palette.data]),
        else => {},
    }
    if (c.raw.style_id == 0) return null;
    return switch (c.style.bg_color) {
        .none => null,
        .rgb => |rgb| rgbToU32(rgb),
        .palette => |idx| rgbToU32(rs.colors.palette[idx]),
    };
}

fn mix(bg: u32, fg: u32, percent: u32) u32 {
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

/// 快照 dump：格式与 Rust / Linux 侧逐字一致，e2e 断言按此解析。
fn dumpSnapshot(alloc: std.mem.Allocator, path: []const u8, term: *vt.Wrapper, blink_on: bool) void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);

    var wide: usize = 0;
    var spacer: usize = 0;
    var y: usize = 0;
    while (y < term.rs.rows) : (y += 1) {
        const cells = term.rs.row_data.get(y).cells;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(alloc);
        var x: usize = 0;
        while (x < term.rs.cols) : (x += 1) {
            const c = cells.get(x);
            switch (c.raw.wide) {
                .wide => wide += 1,
                .spacer_tail, .spacer_head => spacer += 1,
                .narrow => {},
            }
            if (c.raw.wide == .spacer_tail or c.raw.wide == .spacer_head) continue;
            const base: u21 = switch (c.raw.content_tag) {
                .codepoint, .codepoint_grapheme => c.raw.content.codepoint.data,
                .bg_color_palette, .bg_color_rgb => 0,
            };
            const extras: []const u21 = if (c.raw.content_tag == .codepoint_grapheme)
                c.grapheme
            else
                &.{};
            if (base == 0) {
                line.append(alloc, ' ') catch return;
            } else {
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(base, &tmp) catch 0;
                if (n > 0) line.appendSlice(alloc, tmp[0..n]) catch return;
                for (extras) |cp| {
                    const m = std.unicode.utf8Encode(cp, &tmp) catch 0;
                    if (m > 0) line.appendSlice(alloc, tmp[0..m]) catch return;
                }
            }
        }
        var end = line.items.len;
        while (end > 0 and line.items[end - 1] == ' ') end -= 1;
        text.appendSlice(alloc, line.items[0..end]) catch return;
        text.append(alloc, '\n') catch return;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    // 头部字段与 Linux 侧（app.zig::dumpSnapshot）逐字一致，e2e 按此断言。
    const header = std.fmt.allocPrint(
        alloc,
        "# cols={d} rows={d} wide={d} spacer={d} alternate={} cursor={s} cursor_visible={d} bg={x:0>2}{x:0>2}{x:0>2} fg={x:0>2}{x:0>2}{x:0>2}\n",
        .{
            term.rs.cols,
            term.rs.rows,
            wide,
            spacer,
            term.alternate(),
            @tagName(term.rs.cursor.visual_style),
            @intFromBool(term.rs.cursor.visible and blink_on),
            term.rs.colors.background.r,
            term.rs.colors.background.g,
            term.rs.colors.background.b,
            term.rs.colors.foreground.r,
            term.rs.colors.foreground.g,
            term.rs.colors.foreground.b,
        },
    ) catch return;
    defer alloc.free(header);
    out.appendSlice(alloc, header) catch return;
    out.appendSlice(alloc, text.items) catch return;

    var pbuf: [512]u8 = undefined;
    if (path.len + 1 > pbuf.len) return;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const f = c_fopen(@ptrCast(&pbuf), "w") orelse return;
    defer _ = c_fclose(f);
    _ = c_fwrite(out.items.ptr, 1, out.items.len, f);
}

extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fwrite(ptr: *const anyopaque, size: usize, n: usize, f: *anyopaque) usize;
extern fn fclose(f: *anyopaque) c_int;

fn c_fopen(p: [*:0]const u8, m: [*:0]const u8) ?*anyopaque {
    return fopen(p, m);
}
fn c_fwrite(ptr: *const anyopaque, size: usize, n: usize, f: *anyopaque) usize {
    return fwrite(ptr, size, n, f);
}
fn c_fclose(f: *anyopaque) c_int {
    return fclose(f);
}
