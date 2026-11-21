//! app：X11 事件循环 + PTY 读取 + 键路由 + 渲染 + 快照 dump。
//!
//! 与 Rust 侧的差异（有意）：单线程 poll 驱动 X11 与 PTY，没有读线程、
//! 没有 EventLoopProxy 唤醒，因此不存在 Rust 侧那类 "wake 关闭后误报" 路径。

const std = @import("std");
const gh = @import("ghostty-vt");
const cellcolor = @import("cellcolor.zig");
const x11 = @import("x11.zig");
const pty = @import("pty.zig");
const vt = @import("vt.zig");
const render = @import("render.zig");
const timer = @import("timer.zig");
const framepace = @import("framepace.zig");
const font = @import("font.zig");
const config = @import("config.zig");

/// 格子像素尺寸：默认 8x16（与 Rust 侧一致，e2e 按此断言 cols/rows）。
/// 可用 APP_CELL_W / APP_CELL_H 覆盖（字号较大时需要更大的格子，否则字形会被裁）。
pub var cell_w: u32 = 8;
pub var cell_h: u32 = 16;

pub const Config = struct {
    shell: []const u8,
    cols: u16 = 80,
    rows: u16 = 24,
    font_family: ?[*:0]const u8 = null,
    font_size: u32 = 11,
    /// null = 自动（按字体度量）
    cell_w: ?u32 = null,
    cell_h: ?u32 = null,
    dump_path: ?[]const u8 = null,
    /// -e/--command：以该 argv 启动（空则用 shell）
    command: []const []const u8 = &.{},
    /// --working-directory
    cwd: ?[]const u8 = null,
    /// [scrolling] history（0 = ghostty 默认）
    scrollback_lines: u64 = 0,
    /// [keyboard] bindings
    keybindings: []const config.KeyBinding = &.{},
    /// [mouse] bindings
    mouse_bindings: []const config.MouseBinding = &.{},
    /// 渲染后端（auto 先试 GPU，失败回落 CPU）
    backend: config.Backend = .auto,
    /// 字体回退链（[font] fallback 的 family 列表）
    font_fallbacks: []const ?[*:0]const u8 = &.{},
    /// 四种样式（normal/bold/italic/bold_italic）的 family+style
    font_styles: [4]config.FontSpec = .{ .{}, .{}, .{}, .{} },
    /// [window] dynamic_title
    dynamic_title: bool = true,
    /// [cursor] blink
    cursor_blink: bool = false,
    /// [cursor] style：默认光标形状（程序仍可用 DECSCUSR 覆盖）
    cursor_style: ?config.CursorStyle = null,
    /// [scrolling] multiplier
    scroll_multiplier: u32 = 3,
    /// [selection] save_to_clipboard
    save_to_clipboard: bool = true,
    /// [window] position
    window_x: ?i32 = null,
    window_y: ?i32 = null,
    /// [colors.primary]
    colors_bg: ?config.Rgb = null,
    colors_fg: ?config.Rgb = null,
    /// [colors.cursor]
    colors_cursor: ?config.Rgb = null,
    colors_cursor_text: ?config.Rgb = null,
    /// [colors.selection]
    colors_selection_bg: ?config.Rgb = null,
    colors_selection_fg: ?config.Rgb = null,
    /// [colors.normal] + [colors.bright]
    colors_palette: [16]?config.Rgb = @splat(null),
    /// [colors] draw_bold_text_with_bright_colors
    colors_bold_bright: bool = false,
};

pub fn run(alloc: std.mem.Allocator, cfg: Config) !void {
    save_to_clipboard = cfg.save_to_clipboard;
    scroll_multiplier = if (cfg.scroll_multiplier == 0) 3 else cfg.scroll_multiplier;
    dynamic_title = cfg.dynamic_title;
    blink_enabled = cfg.cursor_blink;
    keybindings = cfg.keybindings;
    mouse_bindings = cfg.mouse_bindings;
    // 字体先于窗口加载：格子尺寸要么显式给定，要么按字体度量推导
    // 宽 = 'M' 的 advance；高 = FreeType 的 height（含 line gap），与 alacritty 的行距口径一致。
    // 之前用 ascent+descent，行距比 alacritty 紧（同配置 33px vs 37px），整体显得稠密。
    // 四种样式各自的 family/style 都转成 NUL 结尾字符串再交给 shim。
    var style_bufs: [4][2][128]u8 = undefined;
    var styles: [4]font.Style = .{ .{}, .{}, .{}, .{} };
    for (cfg.font_styles, 0..) |spec, i| {
        var fam_slice: ?[]const u8 = spec.family;
        if (fam_slice == null and i == 0) {
            if (cfg.font_family) |fz| fam_slice = std.mem.span(fz);
        }
        if (fam_slice) |f| {
            if (f.len + 1 <= style_bufs[i][0].len) {
                @memcpy(style_bufs[i][0][0..f.len], f);
                style_bufs[i][0][f.len] = 0;
                styles[i].family = @ptrCast(&style_bufs[i][0]);
            }
        }
        if (spec.style) |st| {
            if (st.len + 1 <= style_bufs[i][1].len) {
                @memcpy(style_bufs[i][1][0..st.len], st);
                style_bufs[i][1][st.len] = 0;
                styles[i].style = @ptrCast(&style_bufs[i][1]);
            }
        }
    }
    if (cfg.font_styles[0].family == null) {
        if (cfg.font_family) |fz| {
            const f = std.mem.span(fz);
            if (f.len + 1 <= style_bufs[0][0].len) {
                @memcpy(style_bufs[0][0][0..f.len], f);
                style_bufs[0][0][f.len] = 0;
                styles[0].family = @ptrCast(&style_bufs[0][0]);
            }
        }
    }

    var rend = try render.Renderer.initWithStyles(alloc, &styles, cfg.font_fallbacks, cfg.font_size);
    // 颜色：光标/选区/粗体增亮（背景、前景与调色板已交给 ghostty 的 Terminal）
    if (cfg.colors_cursor) |c| rend.cursor_color = @as(u32, c.r) << 16 | @as(u32, c.g) << 8 | c.b;
    if (cfg.colors_cursor_text) |c| rend.cursor_text_color = @as(u32, c.r) << 16 | @as(u32, c.g) << 8 | c.b;
    if (cfg.colors_selection_bg) |c| rend.selection_bg = @as(u32, c.r) << 16 | @as(u32, c.g) << 8 | c.b;
    if (cfg.colors_selection_fg) |c| rend.selection_fg = @as(u32, c.r) << 16 | @as(u32, c.g) << 8 | c.b;
    rend.bold_bright = cfg.colors_bold_bright;
    cell_w = cfg.cell_w orelse @as(u32, @intCast(@max(rend.metrics.advance, 1)));
    cell_h = cfg.cell_h orelse @as(u32, @intCast(@max(
        if (rend.metrics.line_height > 0)
            rend.metrics.line_height
        else
            rend.metrics.ascent + rend.metrics.descent,
        1,
    )));

    const win = try x11.openAt(
        cfg.cols * cell_w,
        cfg.rows * cell_h,
        "tty",
        cfg.window_x orelse -1,
        cfg.window_y orelse -1,
    );
    clip_ctx = win;
    defer {
        if (ibus) |h| x11.tty_ibus_close(h);
        ibus = null;
        clip_ctx = null;
        vt.setClipboardSink(null);
        x11.tty_close(win);
    }
    vt.setClipboardSink(&clipboardSink);

    // 渲染后端：auto 先试 GPU（GLX 纹理四边形），失败回落 SHM/CPU。
    switch (cfg.backend) {
        .cpu => {},
        .gpu => {
            if (x11.tty_gl_enable(win) == 0) {
                std.debug.print("leantty: GPU 后端不可用（backend=gpu 要求 GPU）\n", .{});
                return error.GpuUnavailable;
            }
        },
        .auto => {
            if (x11.tty_gl_enable(win) == 0) {
                std.debug.print("leantty: GPU 不可用，回落 CPU 呈现\n", .{});
            }
        },
    }

    // 输入法：没有 IBus 会话时返回 null，全部降级为无操作。
    colors_dump_path = if (getenv("APP_DUMP_COLORS")) |p| std.mem.span(p) else null;
    ibus = x11.tty_ibus_open();
    if (ibus == null) {
        std.debug.print("ibus: 不可用（无会话），输入法功能关闭\n", .{});
    } else {
        // 同时启用 IBus 与 XIM 会互相抢键，留 IBus（可拿预编辑）。
        std.debug.print("ibus: 已连接\n", .{});
        // 启动即把焦点交给输入法：若 WM 没有发 FocusIn，rime 不会进入组词状态。
        x11.tty_ibus_focus(ibus, 1);
    }

    var p = try pty.Pty.spawn(cfg.shell, cfg.command, cfg.cwd, cfg.cols, cfg.rows);
    defer p.close();

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
    const term = try vt.Wrapper.createWithColors(alloc, cfg.cols, cfg.rows, cfg.scrollback_lines, vt_colors);
    defer term.destroy();

    defer rend.deinit();
    // 只重画幽灵态标脏的行：稀疏更新（打字、光标移动）实测快一个数量级以上，
    // 滚动输出时幽灵态会报 full，自动退回全量。
    rend.mode = .dirty;

    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();

    const xfd = x11.tty_fd(win);
    var pixel_w: u32 = cfg.cols * cell_w;
    var pixel_h: u32 = cfg.rows * cell_h;
    var buf: [8192]u8 = undefined;
    var running = true;
    var pacer: framepace.Pacer = .{};

    while (running) {
        var fds = [2]std.posix.pollfd{
            .{ .fd = xfd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = p.master, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&fds, 100) catch 0;

        // X11 事件
        var ev: x11.Event = undefined;
        while (true) {
            const got = x11.tty_next_event(win, &ev);
            if (got < 0) break;
            if (got == 0) continue;
            switch (@as(x11.EventKind, @fromBackingInt(@intCast(ev.type)))) {
                .key => handleKey(term, &p, &writer, &ev),
                .resize => {
                    pacer.force = true;
                    pixel_w = @intCast(@max(ev.width, 1));
                    pixel_h = @intCast(@max(ev.height, 1));
                    const cols: u16 = @intCast(@max(pixel_w / cell_w, 1));
                    const rows: u16 = @intCast(@max(pixel_h / cell_h, 1));
                    term.resize(cols, rows);
                    p.resize(cols, rows);
                },
                .expose => {
                    pacer.force = true;
                },
                .button => handleButton(term, &p, &writer, &ev, pixel_w, pixel_h),
                .paste => handlePaste(term, &p, &ev),
                .key_release => {
                    // 修饰键释放：只在"轻按"时交给输入法（rime 靠 Shift 的按下+释放切换
                    // 中英文）。若按下期间还按过别的键（Shift+A、Ctrl+Shift+C 等），
                    // 释放不再上报——否则引擎会把组合键里的 Shift 当成切换键，
                    // 中文模式下打一个大写字母就被踢回英文（真机实测过）。
                    const bare = mod_held != null and mod_held.? == ev.keysym and !mod_dirty;
                    mod_held = null;
                    mod_dirty = false;
                    if (bare) {
                        if (ibus) |h| _ = x11.tty_ibus_process_key(h, ev.keysym, ev.keycode, (ev.state & 0xff) | ibus_release_mask);
                        kdbg("kdbg release ks=0x{x} bare=1 -> ibus\n", .{ev.keysym});
                    } else {
                        kdbg("kdbg release ks=0x{x} bare=0 (combo) -> dropped\n", .{ev.keysym});
                    }
                },
                .focus_in => {
                    kdbg("kdbg focus_in -> ibus focus 1\n", .{});
                    if (ibus) |h| x11.tty_ibus_focus(h, 1);
                },
                .focus_out => {
                    kdbg("kdbg focus_out -> ibus focus 0\n", .{});
                    if (ibus) |h| x11.tty_ibus_focus(h, 0);
                },
                .motion => handleMotion(term, &p, &writer, &ev, pixel_w, pixel_h),
                .button_release => handleButtonRelease(term, &p, &writer, &ev, pixel_w, pixel_h),
                .close => running = false,
                _ => {},
            }
        }

        // 输入法：驱动信号分发，取走提交文本/预编辑串
        pumpIbus(term, &p);

        // PTY → VT。每帧最多处理有限个块：子进程狂刷输出（例如误把脚本当 shell 跑）
        // 时若无上限会一直卡在这个循环里，X 请求发不出去、事件也不读，
        // 真机上把整个 X 服务器拖死过一次（见 REPORT 6.22）。
        var pty_chunks: u32 = 0;
        while (pty_chunks < 64) : (pty_chunks += 1) {
            const n = p.read(&buf) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    running = false;
                    break;
                },
            };
            if (n == 0) {
                running = false;
                break;
            }
            term.feed(buf[0..n]);
        }
        if (p.tryWait()) |_| running = false;
        if (!running) break;

        try term.update();
        if (cfg.dump_path) |path| dumpSnapshot(alloc, path, term);

        // 自适应帧间隔：渲染太重时自动降帧，避免背靠背重绘
        const now_ms = @divTrunc(@as(i64, @intCast(timer.nowNs())), 1_000_000);
        if (!pacer.due(now_ms)) {
            _ = std.posix.poll(&fds, 5) catch 0;
            continue;
        }
        const render_t0 = timer.nowNs();
        // 动态标题（OSC 0/2）
        if (dynamic_title) {
            const title = term.term.title.items;
            const changed = title.len != last_title_len or
                !std.mem.eql(u8, title, last_title[0..last_title_len]);
            if (changed) {
                const n = @min(title.len, last_title.len - 1);
                @memcpy(last_title[0..n], title[0..n]);
                last_title_len = n;
                last_title[n] = 0;
                x11.tty_set_title(win, @ptrCast(&last_title));
            }
        }

        // 光标闪烁：程序可用 DECSCUSR 请求闪烁（rs.cursor.blinking），配置文件也可开
        // 闪烁只在配置显式开启时生效：程序用 DECSCUSR 请求的闪烁不再自动采纳
        //（用户决定不做「4」，避免未配置时出现意外闪烁）。
        const want_blink = blink_enabled;
        if (want_blink) {
            if (blink_last_ms == 0 or now_ms - blink_last_ms >= blink_interval_ms) {
                blink_last_ms = now_ms;
                blink_on = !blink_on;
                pacer.force = true;
            }
        } else {
            blink_on = true;
        }
        rend.show_cursor = blink_on;

        const sb = term.scrollbar();
        // 变化检测：VT 脏、光标移动、滚动条变化、或调用方强制（输入/滚轮/焦点）。
        const cur_vp = term.rs.cursor.viewport;
        const cur_vis = term.rs.cursor.visible;
        const cursor_changed = blk: {
            const old = last_painted_cursor orelse break :blk true;
            if (old.visible != cur_vis) break :blk true;
            if (cur_vp) |vp| break :blk (old.x != vp.x or old.y != vp.y);
            break :blk false;
        };
        const sb_changed = sb.total != last_sb.total or sb.offset != last_sb.offset or sb.len != last_sb.len;
        const dirty = term.rs.dirty != .false;
        if (!(dirty or cursor_changed or sb_changed or pacer.force)) {
            // 什么都不用画：睡到下一个事件（或 100ms），把 CPU 让出去
            _ = std.posix.poll(&fds, 100) catch 0;
            continue;
        }
        rend.setScrollbar(sb.total, sb.offset, sb.len);
        if (colors_dump_path) |path| dumpColors(path, term, &rend);
        const fb = rend.render(&term.rs, pixel_w, pixel_h) catch |err| {
            std.debug.print("render: {}\n", .{err});
            continue;
        };
        // 预编辑串叠加在光标处（输入法组词草稿）
        if (preedit_len > 0) {
            if (term.rs.cursor.viewport) |vp| {
                const fg = rgbOf(term.rs.colors.foreground);
                const bg = rgbOf(term.rs.colors.background);
                rend.drawPreedit(preedit_buf[0..preedit_len], vp.x, vp.y, cell_w, cell_h, fg, bg);
            }
        }
        // 候选窗跟随光标：光标或预编辑变化时都重新上报
        if (ibus) |h| {
            if (term.rs.cursor.viewport) |vp| {
                const pos = .{ @as(u32, vp.x), @as(u32, vp.y) };
                if (last_cursor_report == null or
                    last_cursor_report.?.x != pos[0] or
                    last_cursor_report.?.y != pos[1] or
                    preedit_len > 0)
                {
                    last_cursor_report = .{ .x = pos[0], .y = pos[1] };
                    var ox: c_int = 0;
                    var oy: c_int = 0;
                    _ = x11.tty_window_origin(win, &ox, &oy);
                    // 对齐 Rust v0.2.3：X11 上输入法只接受一个点，锚点放在光标格
                    // 下方、宽度给两格，避免候选窗盖住正在输入的行。
                    x11.tty_ibus_set_cursor(
                        h,
                        ox + @as(c_int, @intCast(pos[0] * cell_w)),
                        oy + @as(c_int, @intCast((pos[1] + 1) * cell_h)),
                        @intCast(cell_w * 2),
                        @intCast(cell_h),
                    );
                }
            }
        }
        x11.tty_present(win, fb.ptr, @intCast(pixel_w), @intCast(pixel_h));
        last_painted_cursor = .{
            .x = if (cur_vp) |vp| vp.x else 0,
            .y = if (cur_vp) |vp| vp.y else 0,
            .visible = cur_vis,
        };
        last_sb = .{ .total = sb.total, .offset = sb.offset, .len = sb.len };
        pacer.record(now_ms, @as(f64, @floatFromInt(timer.nowNs() - render_t0)) / 1_000_000.0);
    }
}

var last_cursor_report: ?struct { x: u32, y: u32 } = null;
/// 上一帧呈现时的光标位置/滚动条状态：用于在"屏幕没有任何变化"时跳过渲染与呈现
/// （此前每一轮 pacer 到期都会重画并 XShmPutImage，空闲时白烧 ~12% CPU）。
var last_painted_cursor: ?struct { x: u32, y: u32, visible: bool } = null;
var last_sb: struct { total: usize, offset: usize, len: usize } = .{ .total = 0, .offset = 0, .len = 0 };
/// [selection] save_to_clipboard：拖拽选中时是否同时写 CLIPBOARD。
var save_to_clipboard: bool = true;
/// [scrolling] multiplier：滚轮一格滚多少行
var scroll_multiplier: u32 = 3;
/// 动态标题开关与上次设置的标题
var dynamic_title: bool = true;
var last_title: [256]u8 = undefined;
var last_title_len: usize = 0;
/// 光标闪烁
var blink_enabled: bool = false;
var blink_on: bool = true;
var blink_last_ms: i64 = 0;
const blink_interval_ms: i64 = 530;
/// [keyboard] bindings（运行时副本）
var keybindings: []const config.KeyBinding = &.{};
var mouse_bindings: []const config.MouseBinding = &.{};

/// 与 Windows 侧 app_win.zig::dumpColors 同格式：`row col fg bg`（十六进制），
/// 只输出有内容或带属性的格子，便于两个平台逐行 diff。
fn dumpColors(path: []const u8, term: *vt.Wrapper, rend: *const render.Renderer) void {
    const rs = &term.rs;
    var path_buf: [512]u8 = undefined;
    if (path.len + 1 > path_buf.len) return;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const f = c_fopen(@ptrCast(&path_buf), "w") orelse return;
    defer _ = c_fclose(f);
    const default_bg = rgbOf(rs.colors.background);
    const default_fg = rgbOf(rs.colors.foreground);
    var buf: [4096]u8 = undefined;
    var y: usize = 0;
    while (y < rs.rows) : (y += 1) {
        const row = rs.row_data.get(y);
        var x: usize = 0;
        while (x < rs.cols) : (x += 1) {
            const c = row.cells.get(x);
            if (c.raw.content_tag == .codepoint and c.raw.content.codepoint.data == 0) continue;
            const selected = if (row.selection) |r| (x >= r[0] and x < r[1]) else false;
            const col = cellcolor.resolve(rs, c, selected, .{
                .bold_bright = rend.bold_bright,
                .selection_bg = rend.selection_bg,
                .selection_fg = rend.selection_fg,
            });
            var w = std.Io.Writer.fixed(&buf);
            w.print("{d} {d} {x:0>6} {x:0>6}\n", .{ y, x, col.fg, col.bg }) catch continue;
            _ = c_fwrite(&buf, 1, w.end, f);
        }
    }
    _ = default_bg;
    _ = default_fg;
}

fn rgbOf(c: anytype) u32 {
    return (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | @as(u32, c.b);
}

/// 向 PTY 写字节前调用：非备用屏且未开启鼠标上报时，把视口拉回底部。
/// 语义对齐 Rust `follow::should_follow`（只有"会写 PTY 的交互"才回底）。
fn followBottom(term: *vt.Wrapper) void {
    if (term.alternate() or term.mouseReporting()) return;
    term.scrollBottom();
}

/// 取提交文本写 PTY，并刷新预编辑串。
fn pumpIbus(term: *vt.Wrapper, p: *pty.Pty) void {
    const h = ibus orelse return;
    x11.tty_ibus_pump(h);

    var commit: [512]u8 = undefined;
    const n = x11.tty_ibus_take_commit(h, &commit, commit.len);
    if (n > 0) {
        followBottom(term);
        p.write(commit[0..@intCast(n)]);
    }

    var cursor: c_int = 0;
    var visible: c_int = 0;
    const plen = x11.tty_ibus_take_preedit(h, &preedit_buf, preedit_buf.len, &cursor, &visible);
    preedit_len = if (visible != 0) @intCast(plen) else 0;
    preedit_cursor = cursor;
}

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// IBus 的释放标志（IBUS_RELEASE_MASK），必须与 (state & 0xff) 分开按位加。
const ibus_release_mask: c_uint = 1 << 30;

/// Shift_L..Hyper_R 的 keysym 区间（0xffe1-0xffee 去掉 Caps_Lock/Shift_Lock）。
fn isModifierKeysym(ks: c_uint) bool {
    return (ks >= 0xffe1 and ks <= 0xffe4) or (ks >= 0xffe7 and ks <= 0xffee);
}

fn kdbg(comptime fmt: []const u8, args: anytype) void {
    if (getenv("LEANTTY_KDBG") != null) std.debug.print(fmt, args);
}

fn handleKey(
    term: *vt.Wrapper,
    p: *pty.Pty,
    writer: *std.Io.Writer.Allocating,
    ev: *const x11.Event,
) void {
    const shift = (ev.state & x11.shift_mask) != 0;
    const ctrl = (ev.state & x11.control_mask) != 0;
    const alt = (ev.state & x11.mod1_mask) != 0;

    kdbg("kdbg ks=0x{x} ctrl={} shift={} alt={} nb={d}\n", .{ ev.keysym, ctrl, shift, alt, keybindings.len });

    // 单按修饰键：先交给输入法（rime 记录 Shift 按下、在释放时切换中英文），
    // 修饰键本身不产生文本，也不进入绑定/编码器。
    if (isModifierKeysym(ev.keysym)) {
        if (mod_held == null) {
            mod_held = ev.keysym;
            mod_dirty = false;
        }
        if (ibus) |h| _ = x11.tty_ibus_process_key(h, ev.keysym, ev.keycode, ev.state & 0xff);
        return;
    }
    // 修饰键持有期间按了别的键 → 这不是"轻按"，释放时不能触发输入法切换
    mod_dirty = true;

    // 1) 用户显式绑定优先（配置意图高于输入法）
    for (keybindings) |binding| {
        var spec_buf: [128]u8 = undefined;
        const spec_text: []const u8 = if (binding.mods.len == 0)
            binding.key
        else blk: {
            const joined = std.fmt.bufPrint(&spec_buf, "{s}+{s}", .{ binding.mods, binding.key }) catch break :blk binding.key;
            break :blk joined;
        };
        const spec = parseKeySpec(spec_text) orelse continue;
        if (spec.ctrl != ctrl or spec.shift != shift or spec.alt != alt) continue;
        if (!keyMatches(spec.key, ev.keysym)) continue;
        const action = actionFromName(binding.action) orelse continue;
        kdbg("kdbg   binding hit {s} -> {s}\n", .{ spec_text, binding.action });
        switch (action) {
            .copy => copySelectionTo(term, writer, 0),
            .paste => {
                if (clip_ctx) |ctx| _ = x11.tty_clipboard_request(ctx, 0);
            },
            .scroll_page_up => term.scrollDelta(-@as(isize, term.rows())),
            .scroll_page_down => term.scrollDelta(@as(isize, term.rows())),
            .scroll_top => term.scrollTop(),
            .scroll_bottom => term.scrollBottom(),
            .quit => std.process.exit(0),
        }
        return;
    }

    // 2) 输入法：keysym 为 0（合成事件）时不交给它，避免"吞键但不上屏"
    if (ibus) |h| {
        if (ev.keysym != 0) {
            const handled = x11.tty_ibus_process_key(h, ev.keysym, ev.keycode, ev.state & 0xff);
            kdbg("kdbg   ibus handled={d}\n", .{handled});
            if (handled != 0) {
                pumpIbus(term, p);
                return;
            }
        }
    }

    // Insert 家族默认语义（对齐 alacritty 惯例）：Ctrl+Insert=Copy、Shift+Insert=Paste。
    // 未在配置里绑定时也直接处理，避免落到编码器发出终端不认识的 CSI 2;5~（shell 里表现为 "5~"）。
    if (ev.keysym == x11.ks.insert) {
        // shift 优先（含 Ctrl+Shift+Insert），再 ctrl；这样任何 Insert+修饰组合
        // 都不会落到编码器发 CSI 2;5~（shell 里显示成 "5~"）。
        if (shift and !alt) {
            if (clip_ctx) |ctx| _ = x11.tty_clipboard_request(ctx, 0);
            return;
        }
        if (ctrl and !alt) {
            copySelectionTo(term, writer, 0);
            return;
        }
    }

    // 文本优先：无 Ctrl/Alt 时可打印字符直接写 PTY（不经过编码器，
    // 避免 Rust 侧那个"缺 unshifted codepoint 导致空字节"的路径）。
    if (!ctrl and !alt) {
        if (codepointFor(ev.keysym)) |cp| {
            var tmp: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &tmp) catch 0;
            if (n > 0) {
                followBottom(term);
                p.write(tmp[0..n]);
                return;
            }
        }
    }

    // 复制：Ctrl+Shift+C（当前无鼠标选区，退化为全选复制）
    if (ctrl and shift and (ev.keysym == 'c' or ev.keysym == 'C')) {
        copySelectionTo(term, writer, 0);
        return;
    }

    // 粘贴：Ctrl+Shift+V 或 Shift+Insert
    if ((ctrl and shift and (ev.keysym == 'v' or ev.keysym == 'V')) or
        (shift and ev.keysym == x11.ks.insert))
    {
        _ = x11.tty_clipboard_request(clip_ctx orelse return, 0);
        return;
    }

    // viewport 滚动：Shift+PageUp/Down/Home/End（终端模拟器惯例）
    if (shift and !ctrl and !alt) {
        switch (ev.keysym) {
            x11.ks.page_up => {
                term.scrollDelta(-@as(isize, term.rows()));
                return;
            },
            x11.ks.page_down => {
                term.scrollDelta(@as(isize, term.rows()));
                return;
            },
            x11.ks.home => {
                term.scrollTop();
                return;
            },
            x11.ks.end => {
                term.scrollBottom();
                return;
            },
            else => {},
        }
    }

    // 经典 Ctrl 组合的 C0 映射：ghostty 的 legacy 表里缺 '['（vim 里 Ctrl+[ 必须等于 ESC），
    // 且 Ctrl+Shift+字母 它发 CSI u，而 alacritty/xterm 发 C0。这里按 alacritty 口径补齐，
    // 保证 vim/emacs/shell 的既有习惯不被破坏（与 alacritty 逐字节对拍得到）。
    if (ctrl and !alt) {
        if (ctrlC0(ev.keysym)) |byte| {
            followBottom(term);
            p.write(&[_]u8{byte});
            return;
        }
    }

    const key = keyFor(ev.keysym) orelse .unidentified;
    // 编码器（ghostty 的 legacy 路径）依赖 utf8 做 Ctrl+<char> 的 C0 转换、
    // CSI u 判断等。之前这里恒为空，导致 Ctrl+/ Ctrl+[ Ctrl+\ Ctrl+Shift+字母
    // 全部编不出字节（与 alacritty 逐字节对拍发现的 6 处差异里占 4 处）。
    var utf8_buf: [4]u8 = undefined;
    var utf8: []const u8 = "";
    const unshifted: u21 = unshiftedFor(ev.keysym) orelse 0;
    if (codepointFor(ev.keysym)) |cp| {
        const n = std.unicode.utf8Encode(cp, &utf8_buf) catch 0;
        if (n > 0) utf8 = utf8_buf[0..n];
    }
    const mods: gh.input.KeyMods = .{
        .shift = shift,
        .ctrl = ctrl,
        .alt = alt,
    };
    // shift 若已体现在 utf8 字符里（A vs a、! vs 1），就算作"被消费"，
    // 与 ghostty 自己的 apprt 约定一致。
    const consumed: gh.input.KeyMods = .{
        .shift = shift and unshifted != 0 and utf8.len > 0 and
            codepointFor(ev.keysym) != unshifted,
    };
    const event: gh.input.KeyEvent = .{
        .action = .press,
        .key = key,
        .mods = mods,
        .consumed_mods = consumed,
        .utf8 = utf8,
        .unshifted_codepoint = unshifted,
    };
    writer.clearRetainingCapacity();
    term.encodeKey(event, &writer.writer) catch |err| {
        std.debug.print("encode: {}\n", .{err});
        return;
    };
    const bytes = writer.written();
    if (bytes.len > 0) {
        followBottom(term);
        p.write(bytes);
    }
}

/// Ctrl+<键> 的经典 C0 字节（alacritty/xterm 口径）。不适用时返回 null，
/// 交给 ghostty 编码器（例如方向键、功能键、kitty 协议场景）。
fn ctrlC0(keysym: c_uint) ?u8 {
    return switch (keysym) {
        'a'...'z' => @intCast(keysym - 'a' + 1),
        'A'...'Z' => @intCast(keysym - 'A' + 1),
        ' ' => 0x00,
        '@' => 0x00,
        '[' => 0x1b,
        '\\' => 0x1c,
        ']' => 0x1d,
        '^' => 0x1e,
        '_' => 0x1f,
        '/' => 0x1f,
        '?' => 0x7f,
        else => null,
    };
}

/// keysym → 可打印码点（Unicode keysym 区间 + ASCII）。
fn codepointFor(keysym: c_uint) ?u21 {
    if (keysym >= 0x0100_0000 and keysym <= 0x0110_FFFF)
        return @intCast(keysym - 0x0100_0000);
    if (keysym >= 0x20 and keysym < 0x7f) return @intCast(keysym);
    return null;
}

fn unshiftedFor(keysym: c_uint) ?u21 {
    if (codepointFor(keysym)) |cp| {
        if (cp >= 'A' and cp <= 'Z') return @intCast(cp + 32);
        return cp;
    }
    return null;
}

fn keyFor(keysym: c_uint) ?gh.input.Key {
    const k = x11.ks;
    return switch (keysym) {
        k.@"return" => .enter,
        k.tab => .tab,
        // X11 对 Shift+Tab 发的是 ISO_Left_Tab（0xfe20），不映射就会变成
        // unidentified → 什么都不发（alacritty 对同一按键发 CSI Z）。
        0xfe20 => .tab,
        k.backspace => .backspace,
        k.escape => .escape,
        k.home => .home,
        k.end => .end,
        k.insert => .insert,
        k.delete => .delete,
        k.page_up => .page_up,
        k.page_down => .page_down,
        k.left => .arrow_left,
        k.right => .arrow_right,
        k.up => .arrow_up,
        k.down => .arrow_down,
        0x20 => .space,
        0x30...0x39 => @fromBackingInt(@intCast(@backingInt(gh.input.Key.digit_0) + @as(c_int, @intCast(keysym - 0x30)))),
        0xffbe...0xffc9 => functionKey(keysym - 0xffbe), // F1..F12
        // 小键盘（数字锁定打开时才是这些 keysym）
        0xffb0...0xffb9 => numpadDigit(keysym - 0xffb0),
        0xff8d => .numpad_enter,
        0xffaa => .numpad_multiply,
        0xffab => .numpad_add,
        0xffac => .numpad_separator,
        0xffad => .numpad_subtract,
        0xffae => .numpad_decimal,
        0xffaf => .numpad_divide,
        0x41...0x5a => letterKey(keysym - 0x41),
        0x61...0x7a => letterKey(keysym - 0x61),
        else => null,
    };
}

fn numpadDigit(index: c_uint) gh.input.Key {
    return @fromBackingInt(@intCast(@backingInt(gh.input.Key.numpad_0) + @as(c_int, @intCast(index))));
}

fn functionKey(index: c_uint) gh.input.Key {
    return @fromBackingInt(@intCast(@backingInt(gh.input.Key.f1) + @as(c_int, @intCast(index))));
}

fn letterKey(index: c_uint) gh.input.Key {
    return @fromBackingInt(@intCast(@backingInt(gh.input.Key.key_a) + @as(c_int, @intCast(index))));
}

extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fwrite(ptr: *const anyopaque, size: usize, n: usize, f: *anyopaque) usize;
extern fn fclose(f: *anyopaque) c_int;

fn c_fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque {
    return fopen(path, mode);
}
fn c_fwrite(ptr: *const anyopaque, size: usize, n: usize, f: *anyopaque) usize {
    return fwrite(ptr, size, n, f);
}
fn c_fclose(f: *anyopaque) c_int {
    return fclose(f);
}

/// 剪贴板写出去的回调目标（X11 窗口句柄）。单实例，故用文件级单槽，
/// 由 run() 设置、退出时置空。
var clip_ctx: ?*x11.Ctx = null;
/// IBus 输入法手柄（NULL = 本环境没有输入法，静默降级）。
var ibus: ?*x11.Ibus = null;

/// 正在按住的修饰键 keysym，以及其按住期间是否按过非修饰键（"轻按"判定用）。
var mod_held: ?c_uint = null;
var mod_dirty: bool = false;
/// 当前预编辑串（输入法组词中的草稿），由渲染层叠加显示。
var preedit_buf: [512]u8 = undefined;
/// APP_DUMP_COLORS=<path>：导出每格最终配色（与 Windows 侧同格式），用于跨平台配色对照。
var colors_dump_path: ?[]const u8 = null;
var preedit_len: usize = 0;
var preedit_cursor: i32 = 0;

/// 键绑定动作（与 Rust 的 ConfigAction 子集对齐）
const Action = enum {
    copy,
    paste,
    scroll_page_up,
    scroll_page_down,
    scroll_top,
    scroll_bottom,
    quit,
};

fn actionFromName(name: []const u8) ?Action {
    const map = .{
        .{ "Copy", Action.copy },
        .{ "Paste", Action.paste },
        .{ "ScrollPageUp", Action.scroll_page_up },
        .{ "ScrollPageDown", Action.scroll_page_down },
        .{ "ScrollToTop", Action.scroll_top },
        .{ "ScrollToBottom", Action.scroll_bottom },
        .{ "Quit", Action.quit },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

/// 解析 "Ctrl+Shift+C" 这类描述；返回需要的修饰键与键名（小写字母或 keysym 名）。
fn parseKeySpec(spec: []const u8) ?struct { ctrl: bool, shift: bool, alt: bool, key: []const u8 } {
    var ctrl = false;
    var shift = false;
    var alt = false;
    var rest = spec;
    while (std.mem.indexOfScalar(u8, rest, '+')) |plus| {
        const mod = std.mem.trim(u8, rest[0..plus], " ");
        if (std.mem.eql(u8, mod, "Ctrl") or std.mem.eql(u8, mod, "Control")) {
            ctrl = true;
        } else if (std.mem.eql(u8, mod, "Shift")) {
            shift = true;
        } else if (std.mem.eql(u8, mod, "Alt")) {
            alt = true;
        } else return null;
        rest = rest[plus + 1 ..];
    }
    const key = std.mem.trim(u8, rest, " ");
    if (key.len == 0) return null;
    return .{ .ctrl = ctrl, .shift = shift, .alt = alt, .key = key };
}

/// 键名与 keysym 的匹配（字母不区分大小写；其余按 X11 常用名）。
fn keyMatches(spec_key: []const u8, keysym: c_uint) bool {
    if (spec_key.len == 1) {
        const c = spec_key[0];
        const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
        return keysym == lower or keysym == lower - 32;
    }
    const named = .{
        .{ "PageUp", x11.ks.page_up },
        .{ "PageDown", x11.ks.page_down },
        .{ "Home", x11.ks.home },
        .{ "End", x11.ks.end },
        .{ "Insert", x11.ks.insert },
        .{ "Delete", x11.ks.delete },
        .{ "Escape", x11.ks.escape },
        .{ "Enter", x11.ks.@"return" },
        .{ "Tab", x11.ks.tab },
        .{ "Space", 0x20 },
        .{ "KeypadInsert", 0xff9e },
        .{ "KeypadDelete", 0xff9f },
    };
    inline for (named) |entry| {
        if (std.mem.eql(u8, spec_key, entry[0])) return keysym == entry[1];
    }
    return false;
}

/// 拖拽选区状态：按下时的起始格。
const Cell = struct { x: u16, y: u16 };

var drag_start: ?Cell = null;
/// 鼠标上报用：是否有按键按下（1002 的 motion 只在按下期间上报）。
var mouse_down: bool = false;
/// 连击检测（双击选词、三击选行）。
var last_click: struct { cell: Cell, ms: i64, count: u8 } = .{
    .cell = .{ .x = 0, .y = 0 },
    .ms = 0,
    .count = 0,
};

fn nowMs() i64 {
    return @intCast(timer.nowNs() / 1_000_000);
}

fn cellOf(ev_x: c_int, ev_y: c_int) Cell {
    const px: u32 = @intCast(@max(ev_x, 0));
    const py: u32 = @intCast(@max(ev_y, 0));
    return .{
        .x = @intCast(@min(px / cell_w, @as(u32, 65535))),
        .y = @intCast(@min(py / cell_h, @as(u32, 65535))),
    };
}

fn gbuttonFor(button: u8) gh.input.MouseButton {
    return switch (button) {
        1 => .left,
        2 => .middle,
        3 => .right,
        4 => .four,
        5 => .five,
        else => .left,
    };
}

fn sendMouse(
    term: *vt.Wrapper,
    p: *pty.Pty,
    writer: *std.Io.Writer.Allocating,
    ev: *const x11.Event,
    pixel_w: u32,
    pixel_h: u32,
    action: gh.input.MouseAction,
    button: ?gh.input.MouseButton,
    dragging: bool,
) void {
    const mods: gh.input.KeyMods = .{
        .shift = (ev.state & x11.shift_mask) != 0,
        .ctrl = (ev.state & x11.control_mask) != 0,
        .alt = (ev.state & x11.mod1_mask) != 0,
    };
    writer.clearRetainingCapacity();
    const event: gh.input.MouseEncodeEvent = .{
        .action = action,
        .button = button,
        .mods = mods,
        .pos = .{ .x = @floatFromInt(ev.x), .y = @floatFromInt(ev.y) },
    };
    term.encodeMouseEx(event, pixel_w / cell_w, pixel_h / cell_h, cell_w, cell_h, dragging, &writer.writer) catch return;
    if (writer.written().len > 0) p.write(writer.written());
}

fn handleMotion(
    term: *vt.Wrapper,
    p: *pty.Pty,
    writer: *std.Io.Writer.Allocating,
    ev: *const x11.Event,
    pixel_w: u32,
    pixel_h: u32,
) void {
    if (term.mouseReporting()) {
        // 1002=按键期间上报 motion，1003=任何 motion 都上报
        const any_motion = term.mode(.mouse_event_any);
        const button_motion = term.mode(.mouse_event_button);
        if (any_motion or (button_motion and mouse_down)) {
            sendMouse(term, p, writer, ev, pixel_w, pixel_h, .motion, null, mouse_down);
        }
        return;
    }
    const start = drag_start orelse return;
    const cur = cellOf(ev.x, ev.y);
    _ = term.selectRange(start.x, start.y, cur.x, cur.y);
}

fn handleButtonRelease(
    term: *vt.Wrapper,
    p: *pty.Pty,
    writer: *std.Io.Writer.Allocating,
    ev: *const x11.Event,
    pixel_w: u32,
    pixel_h: u32,
) void {
    const button: u8 = @intCast(ev.button);
    if (term.mouseReporting()) {
        mouse_down = false;
        sendMouse(term, p, writer, ev, pixel_w, pixel_h, .release, gbuttonFor(button), false);
        return;
    }
    const start = drag_start orelse return;
    drag_start = null;
    if (ev.button != 1) return;
    const cur = cellOf(ev.x, ev.y);
    if (term.selectRange(start.x, start.y, cur.x, cur.y)) {
        if (save_to_clipboard) copySelectionTo(term, writer, 0);
        var local_writer: std.Io.Writer.Allocating = .init(term.alloc);
        defer local_writer.deinit();
        copySelectionTo(term, &local_writer, 1);
    }
}

fn copyCurrentSelection(term: *vt.Wrapper, writer: *std.Io.Writer.Allocating, which: c_int) void {
    copySelectionTo(term, writer, which);
}

/// 复制当前选区到指定 selection（0=CLIPBOARD, 1=PRIMARY）。
fn copySelectionTo(term: *vt.Wrapper, writer: *std.Io.Writer.Allocating, which: c_int) void {
    writer.clearRetainingCapacity();
    const ok = term.copySelection(&writer.writer) catch false;
    if (!ok) return;
    const ctx = clip_ctx orelse return;
    const text = writer.written();
    if (text.len == 0) return;
    x11.tty_clipboard_set_primary(ctx, text.ptr, @intCast(text.len), which);
}

pub fn clipboardSink(text: []const u8) void {
    const ctx = clip_ctx orelse return;
    x11.tty_clipboard_set(ctx, text.ptr, @intCast(text.len));
}

/// 粘贴事件：把剪贴板文本写进 PTY；程序开启 DEC 2004 时用 bracketed paste 包裹。
fn handlePaste(term: *vt.Wrapper, p: *pty.Pty, ev: *const x11.Event) void {
    if (ev.text_len <= 0) return;
    const n: usize = @intCast(ev.text_len);
    const text = ev.text[0..@min(n, ev.text.len)];
    followBottom(term);
    if (term.bracketedPaste()) p.write("\x1b[200~");
    p.write(text);
    if (term.bracketedPaste()) p.write("\x1b[201~");
}

/// 鼠标按键：开了上报就编码发给 PTY，否则滚轮用来滚 viewport。
fn handleButton(
    term: *vt.Wrapper,
    p: *pty.Pty,
    writer: *std.Io.Writer.Allocating,
    ev: *const x11.Event,
    pixel_w: u32,
    pixel_h: u32,
) void {
    const button: u8 = @intCast(ev.button);
    const is_wheel = button == 4 or button == 5;

    if (term.mouseReporting()) {
        mouse_down = true;
        sendMouse(term, p, writer, ev, pixel_w, pixel_h, .press, gbuttonFor(button), false);
        return;
    }

    // 鼠标绑定（[[mouse.bindings]]）：Right/Middle/Left → Copy/Paste
    const btn_name = switch (button) {
        1 => "Left",
        2 => "Middle",
        3 => "Right",
        4 => "WheelUp",
        5 => "WheelDown",
        else => "",
    };
    if (btn_name.len > 0 and !term.mouseReporting()) {
        for (mouse_bindings) |mb| {
            if (!std.ascii.eqlIgnoreCase(mb.button, btn_name)) continue;
            if (actionFromName(mb.action)) |act| {
                switch (act) {
                    .copy => copySelectionTo(term, writer, 0),
                    .paste => {
                        if (clip_ctx) |ctx| _ = x11.tty_clipboard_request(ctx, 0);
                    },
                    else => {},
                }
                return;
            }
        }
    }

    // 左键：连击检测 / 拖拽选区
    if (button == 1) {
        const pos = cellOf(ev.x, ev.y);
        const now = nowMs();
        const same_cell = pos.x == last_click.cell.x and pos.y == last_click.cell.y;
        last_click = if (same_cell and now - last_click.ms < 400)
            .{ .cell = pos, .ms = now, .count = last_click.count + 1 }
        else
            .{ .cell = pos, .ms = now, .count = 1 };

        if (last_click.count == 2 and term.selectWordAt(pos.x, pos.y)) {
            drag_start = null;
            copyCurrentSelection(term, writer, 1);
            return;
        }
        if (last_click.count >= 3 and term.selectLineAt(pos.x, pos.y)) {
            drag_start = null;
            copyCurrentSelection(term, writer, 1);
            return;
        }

        drag_start = pos;
        term.clearSelection();
        return;
    }

    // 中键：惯例是粘贴 PRIMARY（未开启鼠标上报时）
    if (!term.mouseReporting() and button == 2) {
        _ = x11.tty_clipboard_request(clip_ctx orelse return, 1);
        return;
    }

    if (!term.mouseReporting()) {
        if (is_wheel) {
            const step: isize = @intCast(scroll_multiplier);
            term.scrollDelta(if (button == 4) -step else step);
        }
        return;
    }

    // 走到这里说明未开启上报：滚轮已在上面的分支处理
}

/// 快照 dump：格式与 Rust 侧 APP_DUMP_SNAPSHOT 逐字一致，e2e 断言按此解析。
fn dumpSnapshot(alloc: std.mem.Allocator, path: []const u8, term: *vt.Wrapper) void {
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
            // 宽字符的续格（spacer）不出字符，否则 dump 里"你好"会变成"你 好"，
            // 与 Rust 侧 cell.chars 为空串的口径不一致。
            if (c.raw.wide == .spacer_tail or c.raw.wide == .spacer_head) continue;
            // 组合字符（e + U+0301 等）要整簇输出：cell.grapheme 只含附加码点，
            // 基字符仍在 raw.content.codepoint 里。
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

    var path_buf: [512]u8 = undefined;
    if (path.len + 1 > path_buf.len) return;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const f = c_fopen(@ptrCast(&path_buf), "w") orelse return;
    defer _ = c_fclose(f);
    _ = c_fwrite(out.items.ptr, 1, out.items.len, f);
}
