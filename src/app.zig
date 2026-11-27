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
const vtcolors = @import("vtcolors.zig");
const conptyfix = @import("conptyfix.zig");
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
    /// [general] live_config_reload：配置文件变化时自动重新应用
    live_reload: bool = true,
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
    /// [colors] faint / faint_opacity：SGR 2 压暗开关与强度
    colors_bright_white_fg: ?config.Rgb = null,
    /// [font] synthetic_bold
    font_synthetic_bold: bool = true,
    /// [selection] semantic_escape_chars
    selection_escape_chars: ?[]const u8 = null,
    colors_faint: bool = true,
    colors_faint_opacity: f32 = 0.5,
};

pub fn run(alloc: std.mem.Allocator, cfg_in: Config, cfg_src: ?*config.Config) !void {
    var cfg = cfg_in; // 可重新加载（general.live_config_reload）
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
    buildStyles(&cfg, &style_bufs, &styles);

    var rend = try render.Renderer.initWithStyles(alloc, &styles, cfg.font_fallbacks, cfg.font_size);
    applyRenderColors(&cfg, &rend);
    // 颜色：光标/选区/粗体增亮（背景、前景与调色板已交给 ghostty 的 Terminal）
    if (getenv("LEANTTY_KDBG") != null) std.debug.print("kdbg renderer: faint={} pct={d}\n", .{ rend.faint, rend.faint_percent });
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
        "leantty",
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
            gpu_mode = true;
            reportBackend(win, "gpu");
        },
        .auto => {
            // auto 默认走 CPU + XShm：真机实测 GLX 呈现路径会被驱动的帧同步拖到
            // 数百 ms/帧甚至几十秒（wall 40s vs cpu 0.2s，同一 5MB 输出），
            // 而 SHM 路径稳定且更快。GL 保留为显式 opt-in（backend = "gpu"）。
            if (x11.tty_shm_ok(win) == 0 and x11.tty_gl_enable(win) != 0) {
                gpu_mode = true;
            reportBackend(win, "gpu");
            } else {
                std.debug.print("renderer: cpu (XShm)\n", .{});
            }
        },
    }

    // 输入法：没有 IBus 会话时返回 null，全部降级为无操作。
    colors_dump_path = if (getenv("APP_DUMP_COLORS")) |p| std.mem.span(p) else null;
    if (std.c.getenv("LEANTTY_CONPTY_ERASE_FIX")) |p| {
        conpty_fix = !std.mem.eql(u8, std.mem.span(p), "0");
    }
    conpty_fix_fixer.cursor_fix = if (std.c.getenv("LEANTTY_CONPTY_CURSOR_FIX")) |p|
        !std.mem.eql(u8, std.mem.span(p), "0")
    else
        true;
    if (std.c.getenv("LEANTTY_OUT_DUMP")) |p| {
        out_dump = c_fopen(p, "ab");
        if (out_dump == null) std.debug.print("leantty: 打不开 LEANTTY_OUT_DUMP={s}\n", .{std.mem.span(p)});
    }
    defer if (out_dump) |f| {
        _ = c_fclose(f);
        out_dump = null;
    };
    ibus = x11.tty_ibus_open();
    if (ibus == null) {
        std.debug.print("ibus: 不可用（{s}），输入法功能关闭\n", .{if (x11.tty_ibus_unavailable_reason()) |r| std.mem.span(r) else "会话不可用"});
    } else {
        // 同时启用 IBus 与 XIM 会互相抢键，留 IBus（可拿预编辑）。
        std.debug.print("ibus: 已连接\n", .{});
        // 启动即把焦点交给输入法：若 WM 没有发 FocusIn，rime 不会进入组词状态。
        x11.tty_ibus_focus(ibus, 1);
    }

    var p = try pty.Pty.spawn(cfg.shell, cfg.command, cfg.cwd, cfg.cols, cfg.rows);
    defer p.close();

    const vt_colors = if (cfg_src) |src| vtcolors.of(src) else vtcolors.ofConfig(&cfg);
    const term = try vt.Wrapper.createWithColors(alloc, cfg.cols, cfg.rows, cfg.scrollback_lines, vt_colors);
    defer term.destroy();
    if (cfg.selection_escape_chars) |chars| term.setEscapeChars(chars);

    defer rend.deinit();
    // 只重画幽灵态标脏的行：稀疏更新（打字、光标移动）实测快一个数量级以上，
    // 滚动输出时幽灵态会报 full，自动退回全量。
    rend.mode = .dirty;

    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();

    const xfd = x11.tty_fd(win);
    var pixel_w: u32 = cfg.cols * cell_w;
    var pixel_h: u32 = cfg.rows * cell_h;
    var buf: [256 * 1024]u8 = undefined;
    var bg_verts: std.ArrayList(render.GpuBgVert) = .empty;
    defer bg_verts.deinit(alloc);
    var glyph_verts: std.ArrayList(render.GpuGlyphVert) = .empty;
    defer glyph_verts.deinit(alloc);
    var running = true;
    var pacer: framepace.Pacer = .{};

    while (running) {
        // 有待写的粘贴数据时顺便等 master 可写（否则大粘贴会卡在缓冲满的状态）
        const pty_events: i16 = std.posix.POLL.IN |
            @as(i16, if (p.hasPending()) std.posix.POLL.OUT else 0);
        var fds = [2]std.posix.pollfd{
            .{ .fd = xfd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = p.master, .events = pty_events, .revents = 0 },
        };
        const wait_ms: i32 = if (drag_edge != 0) 30 else 100;
        const ready = std.posix.poll(&fds, wait_ms) catch 0;
        if (ready > 0 and p.hasPending()) _ = p.flush();

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

        // 配置热加载（[general] live_config_reload）：节流 400ms，只做一次 stat。
        // 重载成功后必须强制出一帧：否则空闲窗口不重绘，用户改完配置"看着没反应"，
        // APP_DUMP_SNAPSHOT 也一直读到旧值（Windows 侧同一缺陷，实机测出）。
        if (maybeReloadConfig(alloc, &cfg, cfg_src, &rend, term, &p, pixel_w, pixel_h)) {
            pacer.force = true;
        }

        // PTY → VT。每帧最多处理有限个块：子进程狂刷输出（例如误把脚本当 shell 跑）
        // 时若无上限会一直卡在这个循环里，X 请求发不出去、事件也不读，
        // 真机上把整个 X 服务器拖死过一次（见 REPORT 6.22）。
        var prev_had_data = false;
        var pty_chunks: u32 = 0;
        var backlog = false;
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
            // LEANTTY_OUT_DUMP=<path>：把 PTY 输出原样追加落盘（诊断"残留字符"等渲染问题）。
            if (out_dump) |f| _ = c_fwrite(buf[0..n].ptr, 1, n, f);
            var chunk: []const u8 = buf[0..n];
            // ConPTY 的行重写擦除不足（Windows 上的 Tab 补全残留）由 conptyfix 补 ESC[K]；
            // Linux 侧默认关闭，同名环境变量可用于重放验证。
            if (conpty_fix) {
                chunk = conpty_fix_fixer.feed(chunk, &conpty_fix_buf);
            }
            term.feed(chunk);
        } else backlog = true; // 达到块数上限：还有数据没吃完
        const had_data = pty_chunks > 0;
        if (had_data and prev_had_data) backlog = true; // 连续两轮都有数据 → 处于突发中
        prev_had_data = had_data;
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
        // 输出积压时先不画：合并帧，避免被呈现/交换序列限速（真机 GPU + vsync 下实测 0.1 MB/s）。
        if (backlog and !pacer.force) {
            _ = std.posix.poll(&fds, 0) catch 0;
            continue;
        }
        if (!(dirty or cursor_changed or sb_changed or pacer.force)) {
            // 什么都不用画：睡到下一个事件（或 100ms），把 CPU 让出去
            _ = std.posix.poll(&fds, 100) catch 0;

        // 拖选自动滚动：指针贴住视口上/下边缘时，即使鼠标不再移动也要持续滚动
        if (drag_start != null and drag_edge != 0) {
            const now = nowMs();
            if (now - drag_edge_last_ms >= 30) {
                drag_edge_last_ms = now;
                // 每次滚 2 行：渲染一帧约 10–20ms，1 行/帧在手感上偏慢
                term.scrollDelta(if (drag_edge > 0) 2 else -2);
                if (drag_start) |anchor| {
                    _ = term.selectFromAnchor(
                        anchor,
                        @intCast(@max(drag_edge_cell.x, 0)),
                        @intCast(@max(drag_edge_cell.y, 0)),
                    );
                }
                pacer.force = true;
            }
        }
            continue;
        }
        rend.setScrollbar(sb.total, sb.offset, sb.len);
        // 渲染前把"当前是否真的有选区"喂进去：ghostty 的 RenderState 在选区清空后
        // 不会重写行的 row.selection，渲染侧必须自己判断（见 render.zig 的字段注释）。
        rend.selection_active = term.hasSelection();
        if (colors_dump_path) |path| dumpColors(path, term, &rend);
        if (gpu_mode) {
            const gpu_t0 = timer.nowNs();
            bg_verts.clearRetainingCapacity();
            glyph_verts.clearRetainingCapacity();
            rend.buildGpuFrame(&term.rs, win, pixel_w, pixel_h, &bg_verts, &glyph_verts, rend.show_cursor) catch |err| {
                kdbg("kdbg gpu build error {}\n", .{err});
            };
            x11.tty_gl_draw(
                win,
                @intCast(pixel_w),
                @intCast(pixel_h),
                bg_verts.items.ptr,
                @intCast(bg_verts.items.len * @sizeOf(render.GpuBgVert)),
                glyph_verts.items.ptr,
                @intCast(glyph_verts.items.len * @sizeOf(render.GpuGlyphVert)),
            );
            last_painted_cursor = .{
                .x = if (cur_vp) |vp| vp.x else 0,
                .y = if (cur_vp) |vp| vp.y else 0,
                .visible = cur_vis,
            };
            last_sb = .{ .total = sb.total, .offset = sb.offset, .len = sb.len };
            pacer.record(now_ms, @as(f64, @floatFromInt(timer.nowNs() - gpu_t0)) / 1_000_000.0);
            continue;
        }
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
            const selected = cellcolor.inSelection(row.selection, x);
            const col = cellcolor.resolve(rs, c, selected, .{
                .bold_bright = rend.bold_bright,
                .faint = rend.faint,
                .bright_white_fg = rend.bright_white_fg,
                .faint_percent = rend.faint_percent,
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
        p.write(term.alloc, commit[0..@intCast(n)]);
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

/// 报告实际使用的呈现后端（GPU 时附 GL_RENDERER，用户可据此确认有没有吃到显卡）。
fn reportBackend(win: *x11.Ctx, kind: []const u8) void {
    if (x11.tty_gl_renderer(win)) |rz| {
        std.debug.print("renderer: {s} ({s})\n", .{ kind, std.mem.span(rz) });
    } else {
        std.debug.print("renderer: {s}\n", .{kind});
    }
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
                p.write(term.alloc, tmp[0..n]);
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
            p.write(term.alloc, &[_]u8{byte});
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
    kdbg("kdbg encode len={d}\n", .{bytes.len});
    if (bytes.len > 0) {
        followBottom(term);
        p.write(term.alloc, bytes);
        kdbg("kdbg pty pending={d}\n", .{p.pending.items.len});
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
/// 把 `[font]` 的四个样式槽转成 NUL 结尾字符串交给 shim（启动与热加载共用）。
fn buildStyles(cfg: *const Config, bufs: *[4][2][128]u8, styles: *[4]font.Style) void {
    for (&styles.*) |*st| st.* = .{};
    for (cfg.font_styles, 0..) |spec, i| {
        var fam_slice: ?[]const u8 = spec.family;
        if (fam_slice == null and i == 0) {
            if (cfg.font_family) |fz| fam_slice = std.mem.span(fz);
        }
        if (fam_slice) |f| {
            if (f.len + 1 <= bufs[i][0].len) {
                @memcpy(bufs[i][0][0..f.len], f);
                bufs[i][0][f.len] = 0;
                styles[i].family = @ptrCast(&bufs[i][0]);
            }
        }
        if (spec.style) |st| {
            if (st.len + 1 <= bufs[i][1].len) {
                @memcpy(bufs[i][1][0..st.len], st);
                bufs[i][1][st.len] = 0;
                styles[i].style = @ptrCast(&bufs[i][1]);
            }
        }
    }
}

/// 渲染侧的配色参数（光标/选区/粗体增亮/淡色）。启动与热加载共用，
/// 保证两条路径不会漂移（真实缺陷：热加载只更新了 VT 调色板、忘了选区色）。
fn applyRenderColors(cfg: *const Config, rend: *render.Renderer) void {
    if (cfg.colors_cursor) |c| rend.cursor_color = @as(u32, c.r) << 16 | @as(u32, c.g) << 8 | c.b;
    if (cfg.colors_cursor_text) |c| rend.cursor_text_color = @as(u32, c.r) << 16 | @as(u32, c.g) << 8 | c.b;
    rend.selection_bg = null;
    rend.selection_fg = null;
    if (cfg.colors_selection_bg) |c| rend.selection_bg = @as(u32, c.r) << 16 | @as(u32, c.g) << 8 | c.b;
    if (cfg.colors_selection_fg) |c| rend.selection_fg = @as(u32, c.r) << 16 | @as(u32, c.g) << 8 | c.b;
    rend.synthetic_bold = cfg.font_synthetic_bold;
    rend.bold_bright = cfg.colors_bold_bright;
    rend.bright_white_fg = null;
    if (cfg.colors_bright_white_fg) |c| rend.bright_white_fg = @as(u32, c.r) << 16 | @as(u32, c.g) << 8 | c.b;
    rend.faint = cfg.colors_faint;
    rend.faint_percent = @intFromFloat(std.math.clamp(cfg.colors_faint_opacity, 0.0, 1.0) * 100.0 + 0.5);
}

/// 热加载时重建的键位/鼠标绑定。指向模块级静态缓冲，生命周期与进程一致
/// （app.Config 里存的是切片，不能指向已出栈的局部数组）。
var reload_bindings: [16]config.KeyBinding = undefined;
var reload_mouse_bindings: [16]config.MouseBinding = undefined;

fn reloadKeybindings(src: *const config.Config) []const config.KeyBinding {
    var n: usize = 0;
    for (src.keybindings) |maybe| {
        const b = maybe orelse continue;
        if (b.key.len == 0 or b.action.len == 0) continue;
        if (n >= reload_bindings.len) break;
        reload_bindings[n] = b;
        n += 1;
    }
    return reload_bindings[0..n];
}

fn reloadMouseBindings(src: *const config.Config) []const config.MouseBinding {
    var n: usize = 0;
    for (src.mouse_bindings) |maybe| {
        const b = maybe orelse continue;
        if (b.button.len == 0 or b.action.len == 0) continue;
        if (n >= reload_mouse_bindings.len) break;
        reload_mouse_bindings[n] = b;
        n += 1;
    }
    return reload_mouse_bindings[0..n];
}

/// `[general] live_config_reload` 的节流与变更检测状态。
var reload_checked_ns: u64 = 0;
var reload_mtime: i64 = 0;
var reload_size: u64 = 0;
var reload_seen_once = false;

/// LEANTTY_OUT_DUMP=<path>：把 PTY 输出原样落盘的句柄（诊断用）。
var out_dump: ?*anyopaque = null;
/// ConPTY 行重写补丁是否启用（Linux 默认关闭，仅用于重放验证）。
var conpty_fix: bool = false;
var conpty_fix_buf: [256 * 1024 + 4096]u8 = undefined;
var conpty_fix_fixer: conptyfix.Fixer = .{};

var colors_dump_path: ?[]const u8 = null;
/// GPU 直画是否启用（backend=gpu 且 GL 就绪）。
var gpu_mode: bool = false;
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

var drag_start: ?vt.Wrapper.Anchor = null;
/// 本次左键按下时的格子。松开时若还停在同一格，就是"单击"——不建选区、不写剪贴板。
/// 早前单击也会建 1 格选区，配合 `[selection] save_to_clipboard = true` 就把它写进 CLIPBOARD，
/// 于是"双击选词后右键 Paste"粘出来的是点击处那一个字符（用户实测）。
var drag_press_cell: ?Cell = null;
/// 拖选时指针贴在视口上/下边缘：主循环按 ~30ms 的节奏继续滚动并扩展选区。
var drag_edge: i8 = 0;
var drag_edge_cell: Cell = .{ .x = 0, .y = 0 };
var drag_edge_last_ms: i64 = 0;
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

const scrollbar = @import("scrollbar.zig");

/// 像素坐标是否落在右缘滚动条条带上（命中时不做选区，与 Rust 版一致）。
fn onScrollbar(ev_x: c_int, pixel_w: u32) bool {
    return scrollbar.hitsBar(ev_x, pixel_w);
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
    if (writer.written().len > 0) p.write(term.alloc, writer.written());
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
    const anchor = drag_start orelse return;
    const cur = cellOf(ev.x, ev.y);
    const rows: i32 = @intCast(term.rows());
    // 指针越过视口上下边界：先滚一行，再把选区扩展到边界格
    if (cur.y <= 0) {
        term.scrollDelta(-1);
        drag_edge = -1;
        drag_edge_cell = .{ .x = @max(cur.x, 0), .y = 0 };
    } else if (cur.y >= rows - 1) {
        term.scrollDelta(1);
        drag_edge = 1;
        drag_edge_cell = .{ .x = @max(cur.x, 0), .y = @intCast(rows - 1) };
    } else {
        drag_edge = 0;
        drag_edge_cell = cur;
    }
    _ = term.selectFromAnchor(anchor, @intCast(@max(drag_edge_cell.x, 0)), @intCast(@max(drag_edge_cell.y, 0)));
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
    const anchor = drag_start orelse return;
    drag_start = null;
    drag_edge = 0;
    if (ev.button != 1) {
        drag_press_cell = null;
        return;
    }
    const cur = cellOf(ev.x, ev.y);
    // 单击（按下与松开都在同一格）：只当作"清选区"，不建 1 格选区、不碰剪贴板。
    if (drag_press_cell) |pc| {
        drag_press_cell = null;
        if (pc.x == cur.x and pc.y == cur.y) return;
    }
    if (term.selectFromAnchor(anchor, @intCast(@max(cur.x, 0)), @intCast(@max(cur.y, 0)))) {
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

/// 配置热加载（`[general] live_config_reload`，alacritty 默认开启）。
///
/// 策略：**以当前配置为底**、把文件内容重新叠加一遍（所以 CLI/环境变量的覆盖不会丢），
/// 然后只应用"运行期能安全换掉"的部分：配色、字体（含字号/家族）、键位与鼠标绑定、
/// 光标形状/闪烁、滚动倍数、选区行为、动态标题开关。
/// 进程级参数（shell/command、行列数、scrollback 行数、渲染后端）无法在运行中替换，
/// 检测到变化时打印一行提示，与 alacritty 的处理一致。
fn reloadConfig(
    alloc: std.mem.Allocator,
    cfg: *Config,
    cfg_src: ?*config.Config,
    rend: *render.Renderer,
    term: *vt.Wrapper,
    p: *pty.Pty,
    pixel_w: u32,
    pixel_h: u32,
) bool {
    const path = config.watch_path orelse return false;
    const io = gh.TinyIo.init.io();
    const limit: std.Io.Limit = .limited(4 * 1024 * 1024);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, limit) catch |err| {
        kdbg("kdbg reload: 读不到 {s}（{t}），跳过\n", .{ path, err });
        return false;
    };
    defer alloc.free(text);

    const src = cfg_src orelse return false;
    // 以"启动时那份 config.Config"为底重新叠加文件内容：这样 CLI/环境变量的覆盖不会丢，
    // 也不会把文件里没写的键退回默认值。
    var next_src = src.*;
    var next = cfg.*;
    var warnings: std.ArrayList(u8) = .empty;
    defer warnings.deinit(alloc);
    // Windows 编辑器常写 UTF-16/带 BOM；与 main 的加载路径用同一套解码（返回静态缓冲，
    // 不需要释放）。
    const decoded = config.decodeText(text);
    config.applyToml(&next_src, alloc, decoded, &warnings) catch {};
    src.* = next_src;
    // 把可热改的字段搬进 app.Config（其他字段保持启动时的值）
    next.colors_bg = next_src.colors_bg;
    next.colors_fg = next_src.colors_fg;
    next.colors_cursor = next_src.colors_cursor;
    next.colors_cursor_text = next_src.colors_cursor_text;
    next.colors_selection_bg = next_src.colors_selection_bg;
    next.colors_selection_fg = next_src.colors_selection_fg;
    next.colors_palette = next_src.colors_palette;
    next.colors_bold_bright = next_src.colors_bold_bright;
    next.colors_bright_white_fg = next_src.colors_bright_white_fg;
    next.colors_faint = next_src.colors_faint;
    next.colors_faint_opacity = next_src.colors_faint_opacity;
    next.font_synthetic_bold = next_src.font_synthetic_bold;
    // 字号语义与启动路径一致：`font.size` 是点，像素 = 点 × dpi / 72；
    // `APP_FONT_SIZE`（e2e/bench 用）本身就是像素，不换算。
    if (std.c.getenv("APP_FONT_SIZE") == null) {
        const dpi_raw: c_int = x11.tty_x_dpi();
        const dpi: f64 = if (dpi_raw > 0) @floatFromInt(dpi_raw) else 96.0;
        const px_f = @as(f64, @floatFromInt(next_src.font_size)) * dpi / 72.0;
        next.font_size = @min(@as(u32, @intFromFloat(@round(@max(px_f, 4.0)))), 512);
    } else {
        next.font_size = next_src.font_size;
    }
    next.cursor_style = next_src.cursor_style;
    next.cursor_blink = next_src.cursor_blink;
    next.scroll_multiplier = next_src.scroll_multiplier;
    next.save_to_clipboard = next_src.save_to_clipboard;
    next.dynamic_title = next_src.dynamic_title;
    next.selection_escape_chars = next_src.selection_escape_chars;
    next.live_reload = next_src.live_reload;
    next.keybindings = reloadKeybindings(&next_src);
    next.mouse_bindings = reloadMouseBindings(&next_src);

    // 1) 配色：VT 的调色板/前景背景 + 渲染侧的选区/光标/粗体/淡色
    term.setColors(vtcolors.of(&next_src)) catch {};
    applyRenderColors(&next, rend);
    term.setDefaultCursorStyle(next.cursor_style);

    // 2) 各处运行时开关
    save_to_clipboard = next.save_to_clipboard;
    scroll_multiplier = if (next.scroll_multiplier == 0) 3 else next.scroll_multiplier;
    dynamic_title = next.dynamic_title;
    if (next.cursor_blink != blink_enabled) {
        blink_enabled = next.cursor_blink;
        blink_on = true;
        blink_last_ms = nowMs();
    }
    keybindings = next.keybindings;
    mouse_bindings = next.mouse_bindings;
    if (next.selection_escape_chars) |chars| term.setEscapeChars(chars);

    // 3) 字体：字号/家族/样式/合成粗体变了才重建渲染器（字形缓存在渲染器里，必须换掉）
    const font_changed = next.font_size != cfg.font_size or
        next.font_synthetic_bold != cfg.font_synthetic_bold or
        !fontStylesEqual(&next, cfg);
    if (font_changed) {
        var style_bufs: [4][2][128]u8 = undefined;
        var styles: [4]font.Style = .{ .{}, .{}, .{}, .{} };
        buildStyles(&next, &style_bufs, &styles);
        if (render.Renderer.initWithStyles(alloc, &styles, next.font_fallbacks, next.font_size)) |newr| {
            const nr = newr;
            rend.deinit();
            rend.* = nr;
            applyRenderColors(&next, rend);
            cell_w = next.cell_w orelse @as(u32, @intCast(@max(rend.metrics.advance, 1)));
            cell_h = next.cell_h orelse @as(u32, @intCast(@max(
                if (rend.metrics.line_height > 0)
                    rend.metrics.line_height
                else
                    rend.metrics.ascent + rend.metrics.descent,
                1,
            )));
            const cols: u16 = @intCast(@max(pixel_w / cell_w, 1));
            const rows: u16 = @intCast(@max(pixel_h / cell_h, 1));
            term.resize(cols, rows);
            p.resize(cols, rows);
            rend.mode = .full;
        } else |err| {
            std.debug.print("config: 重新加载字体失败（{t}），保留原字体\n", .{err});
        }
    }

    // 4) 需要重启的项：只提示，不假装生效
    var restart: [128]u8 = undefined;
    var rw = std.Io.Writer.fixed(&restart);
    if (next.cols != cfg.cols or next.rows != cfg.rows) rw.writeAll("行列数 ") catch {};
    if (next.scrollback_lines != cfg.scrollback_lines) rw.writeAll("scrollback ") catch {};
    if (next.backend != cfg.backend) rw.writeAll("渲染后端 ") catch {};
    if (next.command.len != 0 and cfg.command.len == 0) rw.writeAll("启动命令 ") catch {};
    if (rw.end > 0) std.debug.print("config: 以下改动需重启才生效：{s}\n", .{rw.buffered()});

    cfg.* = next;
    blink_on = true;
    kdbg("kdbg reload: 已重新加载 {s}\n", .{path});
    return true;
}

fn fontStylesEqual(a: *const Config, b: *const Config) bool {
    for (a.font_styles, b.font_styles) |x, y| {
        const fx = x.family orelse "";
        const fy = y.family orelse "";
        const sx = x.style orelse "";
        const sy = y.style orelse "";
        if (!std.mem.eql(u8, fx, fy) or !std.mem.eql(u8, sx, sy)) return false;
    }
    const fa: []const u8 = if (a.font_family) |p| std.mem.span(p) else "";
    const fb: []const u8 = if (b.font_family) |p| std.mem.span(p) else "";
    return std.mem.eql(u8, fa, fb) and a.cell_w == b.cell_w and a.cell_h == b.cell_h;
}

/// 每 ~400ms 看一次配置文件的 mtime/size，变了就重载。
fn maybeReloadConfig(
    alloc: std.mem.Allocator,
    cfg: *Config,
    cfg_src: ?*config.Config,
    rend: *render.Renderer,
    term: *vt.Wrapper,
    p: *pty.Pty,
    pixel_w: u32,
    pixel_h: u32,
) bool {
    if (!cfg.live_reload) return false;
    const path = config.watch_path orelse {
        kdbg("kdbg reload: watch_path 为空，热加载关闭\n", .{});
        return false;
    };
    const now = timer.nowNs();
    if (reload_checked_ns != 0 and now - reload_checked_ns < 400 * std.time.ns_per_ms) return false;
    reload_checked_ns = now;
    // NUL 结尾：shim 收 C 字符串
    var nbuf: [512]u8 = undefined;
    if (path.len + 1 > nbuf.len) return false;
    @memcpy(nbuf[0..path.len], path);
    nbuf[path.len] = 0;
    var size: i64 = -1;
    const stamp = x11.tty_file_stamp(@ptrCast(&nbuf), &size);
    if (stamp < 0) return false;
    if (!reload_seen_once) {
        reload_seen_once = true;
        reload_mtime = stamp;
        reload_size = @intCast(size);
        return false;
    }
    if (stamp == reload_mtime and @as(i64, @intCast(reload_size)) == size) return false;
    reload_mtime = stamp;
    reload_size = @intCast(size);
    return reloadConfig(alloc, cfg, cfg_src, rend, term, p, pixel_w, pixel_h);
}

/// 粘贴事件：把剪贴板文本写进 PTY；程序开启 DEC 2004 时用 bracketed paste 包裹。
///
/// 文本不再走事件结构里那 128 字节的 `text[]`（长粘贴会被截断、中文被切成半个
/// UTF-8 字符 → 乱码），改为向 shim 取整块数据（`tty_paste_take`），写完后 `tty_paste_done`。
fn handlePaste(term: *vt.Wrapper, p: *pty.Pty, ev: *const x11.Event) void {
    const alloc = term.alloc;
    if (ev.text_len <= 0) return;
    const ctx = clip_ctx orelse return;
    var len: c_int = 0;
    const ptr = x11.tty_paste_take(ctx, &len) orelse return;
    defer x11.tty_paste_done(ctx);
    if (len <= 0) return;
    var text = ptr[0..@intCast(len)];
    // 兜底：剪贴板里可能是无效 UTF-8（或上一次写入被半截截断的残留）。
    // 只写到最后一个完整字符为止，宁可少写一个字符，也不把半个字符送进 PTY。
    if (!std.unicode.utf8ValidateSlice(text)) {
        var end: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            const l = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
            if (i + l > text.len) break;
            if (!std.unicode.utf8ValidateSlice(text[i .. i + l])) break;
            i += l;
            end = i;
        }
        text = text[0..end];
    }
    kdbg("kdbg paste len={d} bracketed={}\n", .{ text.len, term.bracketedPaste() });
    if (getenv("LEANTTY_PASTE_DUMP")) |path_z| { // 诊断：把收到的粘贴原样落盘
        var pbuf: [512]u8 = undefined;
        const path = std.mem.span(path_z);
        if (path.len + 1 <= pbuf.len) {
            @memcpy(pbuf[0..path.len], path);
            pbuf[path.len] = 0;
            if (c_fopen(@ptrCast(&pbuf), "wb")) |f| {
                _ = c_fwrite(text.ptr, 1, text.len, f);
                _ = c_fclose(f);
            }
        }
    }
    followBottom(term);
    if (term.bracketedPaste()) p.write(alloc, "\x1b[200~");
    p.write(alloc, text);
    if (term.bracketedPaste()) p.write(alloc, "\x1b[201~");
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
            drag_press_cell = null;
            // `[selection] save_to_clipboard = true` 时双击也要写 CLIPBOARD：
            // 右键绑的是 "Paste"（读 CLIPBOARD），只写 PRIMARY 的话粘出来的是上一次的旧内容。
            if (save_to_clipboard) copySelectionTo(term, writer, 0);
            copyCurrentSelection(term, writer, 1);
            return;
        }
        if (last_click.count >= 3 and term.selectLineAt(pos.x, pos.y)) {
            drag_start = null;
            drag_press_cell = null;
            if (save_to_clipboard) copySelectionTo(term, writer, 0);
            copyCurrentSelection(term, writer, 1);
            return;
        }

        drag_start = term.selectAnchor(@intCast(pos.x), @intCast(pos.y));
        drag_press_cell = pos;
        drag_edge = 0;
        term.clearSelection();
        return;
    }

    // 右缘滚动条条带：不当作选区起点（与 Rust 版 hit_scrollbar 同口径）
    if (!term.mouseReporting() and button == 1 and onScrollbar(ev.x, pixel_w)) return;

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
