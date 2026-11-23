//! VT 层：直接使用 ghostty 的公共 Zig 模块（不经 C ABI）。
//!
//! 线程约定：本类型只允许渲染线程访问（与 Rust 侧 VtTerminal 一致），
//! PTY 读取在主循环内完成，不存在跨线程共享。

const std = @import("std");
const gh = @import("ghostty-vt");

/// 剪贴板写入回调（OSC 52 等由程序发起的写入）。
/// ghostty 的 effect 回调不带 userdata，本进程只允许一个终端实例，
/// 因此用一个显式的单槽指针；由 app 在启动时设置、退出时清空。
var clipboard_sink: ?*const fn (text: []const u8) void = null;

pub fn setClipboardSink(sink: ?*const fn (text: []const u8) void) void {
    clipboard_sink = sink;
}

fn ClipboardHooks(comptime H: type) type {
    return struct {
        fn write(_: *H, w: gh.clipboard.Write) void {
            const sink = clipboard_sink orelse {
                w.reply(.unsupported);
                return;
            };
            for (w.contents) |c| {
                if (gh.clipboard.isTextMime(c.mime)) {
                    sink(c.data);
                    w.reply(.{ .success = .{} });
                    return;
                }
            }
            w.reply(.unsupported);
        }

        /// 程序读剪贴板（OSC 52 "?"）：需要异步 X11 往返，回调是同步的，
        /// 这里明确拒绝（ghostty 文档也要求嵌入方自行决定是否放行）。
        fn read(_: *H, r: gh.clipboard.Read) void {
            r.reply(.denied);
        }
    };
}

/// viewport 内的 (x, y) 转成 PageList.Pin；越界取最近的有效位置。
fn pinAt(pages: *gh.PageList, x: u16, y: u16) ?gh.Pin {
    var pin = pages.getTopLeft(.viewport);
    if (y > 0) {
        pin = switch (pin.downOverflow(y)) {
            .offset => |p| p,
            .overflow => |o| o.end,
        };
    }
    if (x > 0) {
        pin = pin.rightWrap(x) orelse pin;
    }
    return pin;
}

pub const Wrapper = struct {
    term: gh.Terminal,
    rs: gh.RenderState = .empty,
    stream: gh.TerminalStream,
    alloc: std.mem.Allocator,
    /// 双击选词的边界字符（[selection] semantic_escape_chars）；count=0 表示用默认空白。
    word_boundaries: [64]u21 = undefined,
    word_boundary_count: usize = 0,

    /// 必须在最终地址上原地初始化：`Terminal` 内部持有指向自身字段的指针
    /// （`screens.active`、stream handler 的 terminal 指针），按值返回会把它们
    /// 指向已失效的栈位置，随后 feed 直接 GPF。
    pub fn create(alloc: std.mem.Allocator, grid_cols: u16, grid_rows: u16) !*Wrapper {
        return createWithScrollback(alloc, grid_cols, grid_rows, 0);
    }

    /// 配置里的颜色（默认值与 ghostty 内置一致；null 表示不覆盖）。
    /// 默认光标形状（与 ghostty 的 cursor.Style 同名）。
    pub const CursorStyle = enum { block, bar, underline, block_hollow };

    pub const Colors = struct {
        background: ?gh.color.RGB = null,
        foreground: ?gh.color.RGB = null,
        cursor: ?gh.color.RGB = null,
        /// 仅设置**默认**形状；程序用 DECSCUSR（CSI q）仍可随时覆盖。
        cursor_style: ?CursorStyle = null,
        palette: [16]?gh.color.RGB = @splat(null),
    };

    /// scrollback_lines = 0 时用 ghostty 的默认（10_000 字节上限）。
    pub fn createWithScrollback(
        alloc: std.mem.Allocator,
        grid_cols: u16,
        grid_rows: u16,
        scrollback_lines: u64,
    ) !*Wrapper {
        return createWithColors(alloc, grid_cols, grid_rows, scrollback_lines, .{});
    }

    pub fn createWithColors(
        alloc: std.mem.Allocator,
        grid_cols: u16,
        grid_rows: u16,
        scrollback_lines: u64,
        colors: Colors,
    ) !*Wrapper {
        const self = try alloc.create(Wrapper);
        errdefer alloc.destroy(self);
        self.alloc = alloc;
        self.rs = .empty;
        // 颜色：palette 需要一份可被 OSC 4/10/11 覆盖的默认值，用 ghostty 内置表做底，
        // 逐项覆盖配置里给出的值。
        var term_colors: gh.Terminal.Colors = .default;
        // ghostty 的 RenderState 只有在 background 与 foreground **都存在**时才应用
        // 两者（见 render.zig 的 `bg_fg:` 块：任一为 null 就整体跳过）。
        // 因此只配置其中一侧时必须把另一侧补成默认值，否则配色整体失效
        // （实测：只写 background 时窗口仍是纯黑）。
        const default_bg: gh.color.RGB = .{ .r = 0, .g = 0, .b = 0 };
        const default_fg: gh.color.RGB = .{ .r = 0xff, .g = 0xff, .b = 0xff };
        if (colors.background != null or colors.foreground != null) {
            term_colors.background = gh.color.DynamicRGB.init(colors.background orelse default_bg);
            term_colors.foreground = gh.color.DynamicRGB.init(colors.foreground orelse default_fg);
        }
        if (colors.cursor) |c| term_colors.cursor = gh.color.DynamicRGB.init(c);
        if (colors.cursor) |c| term_colors.cursor = gh.color.DynamicRGB.init(c);
        var palette = gh.color.default;
        var palette_changed = false;
        for (colors.palette, 0..) |maybe, i| {
            if (maybe) |c| {
                palette[i] = c;
                palette_changed = true;
            }
        }
        if (palette_changed) term_colors.palette = try gh.color.DynamicPalette.init(alloc, palette);
        self.term = try gh.Terminal.init(gh.TinyIo.init.io(), alloc, .{
            .cols = grid_cols,
            .rows = grid_rows,
            .max_scrollback_lines = if (scrollback_lines > 0) @intCast(scrollback_lines) else null,
            .colors = term_colors,
        });
        // 默认光标形状：写进活动屏幕的 cursor.cursor_style，DECSCUSR 之后仍会覆盖它。
        if (colors.cursor_style) |st| {
            self.term.screens.active.cursor.cursor_style = switch (st) {
                .block => .block,
                .bar => .bar,
                .underline => .underline,
                .block_hollow => .block_hollow,
            };
        }
        // 自带 handler 以便挂剪贴板 effect；与 vtStream() 等价，只是多设了 effects。
        var handler = self.term.vtHandler();
        const Hooks = ClipboardHooks(@TypeOf(handler));
        handler.effects.clipboard_write = Hooks.write;
        handler.effects.clipboard_read = Hooks.read;
        self.stream = gh.TerminalStream.init(.{
            .allocator = self.term.gpa(),
            .handler = handler,
        });
        return self;
    }

    pub fn destroy(self: *Wrapper) void {
        self.rs.deinit(self.alloc);
        self.term.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn feed(self: *Wrapper, bytes: []const u8) void {
        self.stream.nextSlice(bytes);
    }

    pub fn resize(self: *Wrapper, new_cols: u16, new_rows: u16) void {
        self.term.resize(self.alloc, .{ .cols = new_cols, .rows = new_rows }) catch {};
    }

    /// 刷新渲染状态（等价于 C API 的 ghostty_render_state_update）。
    pub fn update(self: *Wrapper) !void {
        try self.rs.update(self.alloc, &self.term);
    }

    pub fn cols(self: *const Wrapper) u16 {
        return self.term.cols;
    }

    pub fn rows(self: *const Wrapper) u16 {
        return self.term.rows;
    }

    pub fn scrollbackRows(self: *const Wrapper) u64 {
        return self.term.screens.active.pages.total_rows - self.term.rows;
    }

    pub fn alternate(self: *const Wrapper) bool {
        return self.term.screens.active_key == .alternate;
    }

    /// viewport 滚动：delta>0 表示往更早的内容方向滚（见 ScrollViewport.delta 注释）。
    pub fn scrollDelta(self: *Wrapper, delta: isize) void {
        self.term.scrollViewport(.{ .delta = delta });
    }

    pub fn scrollTop(self: *Wrapper) void {
        self.term.scrollViewport(.top);
    }

    pub fn scrollBottom(self: *Wrapper) void {
        self.term.scrollViewport(.bottom);
    }

    /// 鼠标拖拽选区：传入 viewport 内的格子坐标（左上为 0,0）。
    /// 设置词边界字符；`chars` 是配置里的 UTF-8 串（alacritty 的 semantic_escape_chars）。
    pub fn setEscapeChars(self: *Wrapper, chars: []const u8) void {
        var n: usize = 0;
        // 默认边界：NUL / 空格 / Tab（ghostty 默认词边界里最常用的三个）
        for ([_]u21{ 0, ' ', '\t' }) |cp| {
            if (n < self.word_boundaries.len) {
                self.word_boundaries[n] = cp;
                n += 1;
            }
        }
        var it = std.unicode.Utf8Iterator{ .bytes = chars, .i = 0 };
        while (it.nextCodepoint()) |cp| {
            if (n >= self.word_boundaries.len) break;
            self.word_boundaries[n] = cp;
            n += 1;
        }
        self.word_boundary_count = n;
    }

    /// 返回是否创建成功；选区会写进 screen.selection，渲染状态据此高亮。
    /// 选区锚点（页面坐标，滚动后不会漂移）。
    pub const Anchor = gh.Pin;

    /// 把 viewport 坐标转成页面锚点（按下鼠标时抓一次）。
    pub fn selectAnchor(self: *const Wrapper, x: u16, y: u16) ?Anchor {
        return pinAt(&self.term.screens.active.pages, x, y);
    }

    /// 从页面锚点扩展到 (x, y)（viewport 坐标），用于拖选过程中滚动后继续扩展。
    pub fn selectFromAnchor(self: *Wrapper, anchor: Anchor, x: u16, y: u16) bool {
        const screen = self.term.screens.active;
        const end = pinAt(&screen.pages, x, y) orelse return false;
        if (screen.selection) |old| old.deinit(screen);
        screen.selection = gh.Selection.init(anchor, end, false);
        self.rs.dirty = .full;
        return true;
    }

    pub fn selectRange(self: *Wrapper, start_x: u16, start_y: u16, end_x: u16, end_y: u16) bool {
        const screen = self.term.screens.active;
        const pages = &screen.pages;
        const start = pinAt(pages, start_x, start_y) orelse return false;
        const end = pinAt(pages, end_x, end_y) orelse return false;
        if (screen.selection) |old| old.deinit(screen);
        screen.selection = gh.Selection.init(start, end, false);
        // 选区变化不影响"内容脏行"，必须显式要求一次全量重绘，否则高亮不出现。
        self.rs.dirty = .full;
        return true;
    }

    /// 双击选词：以 viewport 内 (x, y) 为锚点。
    pub fn selectWordAt(self: *Wrapper, x: u16, y: u16) bool {
        const screen = self.term.screens.active;
        const pin = pinAt(&screen.pages, x, y) orelse return false;
        // 边界来自 [selection] semantic_escape_chars（默认空白），与 alacritty 同义。
        if (self.word_boundary_count == 0) self.setEscapeChars("");
        const sel = screen.selectWord(pin, self.word_boundaries[0..self.word_boundary_count]) orelse return false;
        if (screen.selection) |old| old.deinit(screen);
        screen.selection = sel;
        self.rs.dirty = .full;
        return true;
    }

    /// 三击选整行。
    pub fn selectLineAt(self: *Wrapper, x: u16, y: u16) bool {
        const screen = self.term.screens.active;
        const pin = pinAt(&screen.pages, x, y) orelse return false;
        const sel = screen.selectLine(.{ .pin = pin }) orelse return false;
        if (screen.selection) |old| old.deinit(screen);
        screen.selection = sel;
        self.rs.dirty = .full;
        return true;
    }

    pub fn mode(self: *const Wrapper, m: gh.Mode) bool {
        return self.term.modes.get(m);
    }

    /// 当前屏是否有选区（e2e 与 [mouse] 日志用）。
    pub fn hasSelection(self: *const Wrapper) bool {
        return self.term.screens.active.selection != null;
    }

    pub fn clearSelection(self: *Wrapper) void {
        const screen = self.term.screens.active;
        if (screen.selection) |old| old.deinit(screen);
        screen.selection = null;
        self.rs.dirty = .full;
    }

    /// 复制：有选区就复制选区，没有就全选后复制（鼠标选区尚未实现，
    /// 先提供"全选复制"，行为在 REPORT 里登记）。
    /// 返回是否真的产出了内容。
    pub fn copySelection(self: *Wrapper, writer: *std.Io.Writer) !bool {
        const screen = self.term.screens.active;
        // selectAll() 只返回选区、不会写回 screen.selection，必须显式传给 formatter。
        const sel = screen.selection orelse screen.selectAll() orelse return false;

        var formatter: gh.formatter.TerminalFormatter = .init(&self.term, .{
            .emit = .plain,
            .unwrap = false,
            .trim = true,
        });
        formatter.content = .{ .selection = sel };
        try formatter.format(writer);
        if (writer.buffered().len > 0) return true;
        return false;
    }

    /// 滚动条信息（total/offset/len），用于绘制滚动条。
    pub fn scrollbar(self: *const Wrapper) struct { total: usize, offset: usize, len: usize } {
        const sb = self.term.screens.active.pages.scrollbar();
        return .{ .total = sb.total, .offset = sb.offset, .len = sb.len };
    }

    /// 程序是否要求把粘贴内容用 bracketed paste 包裹（DEC 2004）。
    pub fn bracketedPaste(self: *const Wrapper) bool {
        return self.term.modes.get(.bracketed_paste);
    }

    /// 应用是否打开了鼠标上报（1000/1002/1003）。
    pub fn mouseReporting(self: *const Wrapper) bool {
        const m = self.term.modes;
        return m.get(.mouse_event_normal) or
            m.get(.mouse_event_button) or
            m.get(.mouse_event_any) or
            m.get(.mouse_event_x10);
    }

    /// 鼠标上报编码（含 any_button_pressed，1002/1003 的 motion 需要）。
    pub fn encodeMouseEx(
        self: *Wrapper,
        event: gh.input.MouseEncodeEvent,
        grid_cols: u32,
        grid_rows: u32,
        cell_w: u32,
        cell_h: u32,
        any_button_pressed: bool,
        writer: *std.Io.Writer,
    ) !void {
        var opts = gh.input.MouseEncodeOptions.fromTerminal(&self.term, .{
            .screen = .{ .width = grid_cols * cell_w, .height = grid_rows * cell_h },
            .cell = .{ .width = cell_w, .height = cell_h },
            .padding = .{},
        });
        opts.any_button_pressed = any_button_pressed;
        try gh.input.encodeMouse(writer, event, opts);
    }

    /// 鼠标上报编码：格式与模式取自终端状态，坐标用像素换算成格子。
    pub fn encodeMouse(
        self: *Wrapper,
        event: gh.input.MouseEncodeEvent,
        grid_cols: u32,
        grid_rows: u32,
        cell_w: u32,
        cell_h: u32,
        writer: *std.Io.Writer,
    ) !void {
        // renderer_size.Size 未从 lib_vt 导出，用匿名结构体字面量让编译器按形参类型推断。
        const opts = gh.input.MouseEncodeOptions.fromTerminal(&self.term, .{
            .screen = .{ .width = grid_cols * cell_w, .height = grid_rows * cell_h },
            .cell = .{ .width = cell_w, .height = cell_h },
            .padding = .{},
        });
        try gh.input.encodeMouse(writer, event, opts);
    }

    /// 按键编码：选项取自终端当前模式（DECCKM、键区模式等）。
    pub fn encodeKey(
        self: *Wrapper,
        event: gh.input.KeyEvent,
        writer: *std.Io.Writer,
    ) !void {
        try gh.input.encodeKey(writer, event, .fromTerminal(&self.term));
    }
};
