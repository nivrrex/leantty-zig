//! 渲染：自有帧缓冲 + FreeType 字形缓存，按等宽网格画格。

const std = @import("std");
const font = @import("font.zig");
const gh = @import("ghostty-vt");

pub const Glyph = struct {
    w: u16,
    h: u16,
    left: i16,
    top: i16,
    advance: i16,
    bitmap: []u8,
    /// 1 = 灰度覆盖度；4 = BGRA（彩色 emoji 等）
    bpp: u8 = 1,
    /// BGRA 是否为预乘 alpha（由 shim 侧按数据判定）
    premul: bool = true,
};

pub const Mode = enum {
    /// 每帧全量重绘（阶段1 的做法）。
    full,
    /// 只重绘幽灵态里被标脏的行 + 光标移动涉及的行。
    dirty,
};

pub const CursorPos = struct { x: u16, y: u16 };

pub const Renderer = struct {
    alloc: std.mem.Allocator,
    mode: Mode = .full,
    prev_cursor: ?CursorPos = null,
    /// 上一帧实际重画的行数（供 bench 观察脏行判定的效果）。
    last_painted_rows: usize = 0,
    /// 滚动条信息（由 app 每帧设置；total <= len 时不画）。
    /// 光标闪烁的当前相位（false 时不画光标）
    show_cursor: bool = true,
    /// [colors.cursor] cursor：null 时用前景色
    cursor_color: ?u32 = null,
    /// [colors.cursor] text：block 光标里被"抠出来"的字符颜色，null 时用背景色
    cursor_text_color: ?u32 = null,
    /// [colors.selection] 选中态的前景/背景，null 时按反色处理
    selection_bg: ?u32 = null,
    selection_fg: ?u32 = null,
    /// [colors] draw_bold_text_with_bright_colors
    bold_bright: bool = false,
    sb_total: usize = 0,
    sb_offset: usize = 0,
    sb_len: usize = 0,
    handle: *font.Handle,
    metrics: font.Metrics,
    fb: []u32 = &.{},
    fb_w: u32 = 0,
    fb_h: u32 = 0,
    /// 键 = 码点 | (样式 << 21)：样式 0=normal 1=bold 2=italic 3=bold_italic
    cache: std.AutoHashMapUnmanaged(u32, Glyph) = .empty,
    /// 字形位图暂存。彩色位图是 4 字节/像素，且 CBDT 字体的 strike 可能很大
    /// （Noto Color Emoji 只有 128px → 128*128*4 = 64 KiB），按灰度 128x128 算会溢出。
    scratch: [144 * 144 * 4]u8 = undefined,

    /// families[0] 主字体，其余为回退链（空数组时用 "monospace"）。
    pub fn init(alloc: std.mem.Allocator, families: []const ?[*:0]const u8, px: u32) !Renderer {
        return initWithStyles(alloc, &.{}, families, px);
    }

    /// styles 为空时按单一 family 加载；非空时按 normal/bold/italic/bold_italic 加载。
    pub fn initWithStyles(
        alloc: std.mem.Allocator,
        styles: []const font.Style,
        fallbacks: []const ?[*:0]const u8,
        px: u32,
    ) !Renderer {
        const h = if (styles.len > 0)
            try font.openStyled(styles, fallbacks, px)
        else if (fallbacks.len == 0)
            try font.open(null, px)
        else
            try font.openMulti(fallbacks, px);
        errdefer font.tty_font_close(h);
        const m = try font.metrics(h);
        return .{ .alloc = alloc, .handle = h, .metrics = m };
    }

    pub fn deinit(self: *Renderer) void {
        var it = self.cache.valueIterator();
        while (it.next()) |g| self.alloc.free(g.bitmap);
        self.cache.deinit(self.alloc);
        if (self.fb.len > 0) self.alloc.free(self.fb);
        font.tty_font_close(self.handle);
    }

    pub fn framebuffer(self: *const Renderer) []const u32 {
        return self.fb;
    }

    pub fn setScrollbar(self: *Renderer, total: usize, offset: usize, len: usize) void {
        self.sb_total = total;
        self.sb_offset = offset;
        self.sb_len = len;
    }

    /// 纯函数：滚动条 thumb 的 (y, 高度)，以像素计；无滚动区返回 null。
    pub fn scrollbarThumb(total: usize, offset: usize, len: usize, pixels: u32) ?struct { y: u32, h: u32 } {
        if (total == 0 or pixels == 0 or total <= len) return null;
        const track: f64 = @floatFromInt(pixels);
        const t: f64 = @floatFromInt(total);
        var h: u32 = @intFromFloat(@max(track * @as(f64, @floatFromInt(len)) / t, 8.0));
        if (h > pixels) h = pixels;
        const max_off = total - len;
        const off_f: f64 = @floatFromInt(@min(offset, max_off));
        const travel: f64 = track - @as(f64, @floatFromInt(h));
        const y: u32 = @intFromFloat(travel * off_f / @as(f64, @floatFromInt(max_off)));
        return .{ .y = y, .h = h };
    }

    /// 画一帧。返回帧缓冲（0x00RRGGBB，小端字节序 B,G,R,X）。
    /// 注意：会清掉 `rs.dirty` 与已绘制行的 `row.dirty`（ghostty 的契约是
    /// 「处理完脏标记后由渲染方复位」），因此入参必须是可变引用。
    pub fn render(
        self: *Renderer,
        rs: *gh.RenderState,
        width: u32,
        height: u32,
    ) ![]const u32 {
        if (width == 0 or height == 0) return self.fb;
        const need = width * height;
        const resized = self.fb.len != need or self.fb_w != width or self.fb_h != height;
        if (resized) {
            if (self.fb.len > 0) self.alloc.free(self.fb);
            self.fb = try self.alloc.alloc(u32, need);
            self.prev_cursor = null;
        }
        self.fb_w = width;
        self.fb_h = height;

        const cols: u32 = @max(rs.cols, 1);
        const rows: u32 = @max(rs.rows, 1);
        const cell_w = @max(width / cols, 1);
        const cell_h = @max(height / rows, 1);

        const default_bg = rgbToU32(rs.colors.background);
        const default_fg = rgbToU32(rs.colors.foreground);
        // 光标色：配置给了就用配置的，否则沿用前景/反色逻辑
        self.cursor_color = if (rs.colors.cursor) |c| rgbToU32(c) else null;

        const cur_cursor: ?CursorPos = if (rs.cursor.visible)
            if (rs.cursor.viewport) |vp| .{ .x = vp.x, .y = @intCast(vp.y) } else null
        else
            null;

        // 全量条件：首帧/尺寸变化、调用方要求全量、或幽灵态自己报告 full。
        const full = self.mode == .full or rs.dirty == .full or resized;
        if (resized) @memset(self.fb, default_bg);

        self.last_painted_rows = 0;
        var y: usize = 0;
        while (y < rs.rows) : (y += 1) {
            const row = rs.row_data.get(y);
            const row_y: u16 = @intCast(y);
            // 光标移出/移入的那两行也必须重绘，否则旧光标残留。
            const cursor_hit = (cur_cursor != null and cur_cursor.?.y == row_y) or
                (self.prev_cursor != null and self.prev_cursor.?.y == row_y);
            if (!full and !row.dirty and !cursor_hit) continue;

            self.last_painted_rows += 1;
            self.paintRow(rs, y, cell_w, cell_h, default_bg, default_fg);
            rs.row_data.items(.dirty)[y] = false;

            if (cur_cursor != null and cur_cursor.?.y == row_y and self.show_cursor) {
                self.drawCursor(rs, @intCast(cur_cursor.?.x), @intCast(row_y), cell_w, cell_h, default_fg, default_bg);
            }
        }
        // 滚动条：右侧 4px，轨道用背景色淡化、滑块用前景色淡化
        if (scrollbarThumb(self.sb_total, self.sb_offset, self.sb_len, self.fb_h)) |thumb| {
            const bar_w = @min(@as(u32, 4), self.fb_w);
            const x = self.fb_w - bar_w;
            self.fillRect(x, 0, bar_w, self.fb_h, mix(default_bg, default_fg, 20));
            self.fillRect(x, thumb.y, bar_w, thumb.h, mix(default_bg, default_fg, 55));
        }

        self.prev_cursor = cur_cursor;
        rs.dirty = .false;
        return self.fb;
    }

    /// 画一整行：先铺背景，再逐个画字（宽字符跨两格）。
    fn paintRow(
        self: *Renderer,
        rs: *const gh.RenderState,
        y: usize,
        cell_w: u32,
        cell_h: u32,
        default_bg: u32,
        default_fg: u32,
    ) void {
        const row = rs.row_data.get(y);
        const cells = row.cells;
        const sel = row.selection; // [start, end) 单元格区间
        const py: u32 = @intCast(y);
        var x: usize = 0;
        while (x < rs.cols) : (x += 1) {
            const c = cells.get(x);
            const px: u32 = @intCast(x);

            // 宽字符判定用两个独立信号：自身标记 Wide，或下一格是 SpacerTail。
            const next_is_spacer = (x + 1 < rs.cols) and
                (cells.get(x + 1).raw.wide == .spacer_tail);
            const wide = c.raw.wide == .wide or next_is_spacer;

            // 续格（spacer）不铺背景：它的背景已由宽字符那一格按两格宽铺好。
            // 先铺后跳会造成"宽字右半被邻格背景擦掉"（本轮修掉的真实缺陷）。
            if (c.raw.wide == .spacer_tail or c.raw.wide == .spacer_head) continue;

            var bg = resolveBg(rs, c) orelse default_bg;
            var fg = resolveFg(rs, c) orelse default_fg;
            // [colors] draw_bold_text_with_bright_colors：只把调色板 0-7 的粗体换成 8-15。
            // 默认前景（无显式色）必须保持原样——之前把 `.none` 映射到 palette[15]，
            // 在浅色配色下就是"浅底浅字"，粗体反而看不见（与 alacritty 不一致）。
            if (self.bold_bright and c.raw.style_id != 0 and c.style.flags.bold) {
                switch (c.style.fg_color) {
                    .palette => |idx| if (idx < 8) {
                        fg = rgbToU32(rs.colors.palette[idx + 8]);
                    },
                    .none, .rgb => {},
                }
            }
            // SGR 7 反显、SGR 2 淡色、SGR 8 隐藏（alacritty 同口径）
            var invisible = false;
            if (c.raw.style_id != 0) {
                if (c.style.flags.inverse) {
                    const tmp = bg;
                    bg = fg;
                    fg = tmp;
                }
                if (c.style.flags.faint) fg = mix(bg, fg, 60);
                invisible = c.style.flags.invisible;
            }
            const selected = if (sel) |range| x >= range[0] and x < range[1] else false;
            if (selected) {
                if (self.selection_bg) |sb| bg = sb;
                if (self.selection_fg) |sf| fg = sf;
                if (self.selection_bg == null and self.selection_fg == null) {
                    const tmp = bg;
                    bg = fg;
                    fg = tmp;
                }
            }
            const draw_w = if (wide) cell_w * 2 else cell_w;
            self.fillRect(px * cell_w, py * cell_h, draw_w, cell_h, bg);

            const base: u21 = switch (c.raw.content_tag) {
                .codepoint, .codepoint_grapheme => c.raw.content.codepoint.data,
                .bg_color_palette, .bg_color_rgb => 0,
            };
            const extras: []const u21 = if (c.raw.content_tag == .codepoint_grapheme)
                c.grapheme
            else
                &.{};
            if (base == 0) {
                if (!invisible) self.drawDecorations(rs, c, px * cell_w, py * cell_h, draw_w, cell_h, fg);
                continue;
            }
            if (invisible) {
                self.drawDecorations(rs, c, px * cell_w, py * cell_h, draw_w, cell_h, fg);
                continue;
            }
            var style_idx: u2 = 0;
            if (c.raw.style_id != 0) {
                if (c.style.flags.bold) style_idx += 1;
                if (c.style.flags.italic) style_idx += 2;
            }
            self.drawGlyph(base, px * cell_w, py * cell_h, draw_w, cell_h, fg, wide, style_idx);
            for (extras) |cp| {
                self.drawGlyph(cp, px * cell_w, py * cell_h, draw_w, cell_h, fg, wide, style_idx);
            }
            self.drawDecorations(rs, c, px * cell_w, py * cell_h, draw_w, cell_h, fg);
            // OSC 8 超链接：没有 SGR 4 时补一条下划线提示可点击（打开链接见 REPORT 6.12）
            if (c.raw.hyperlink and (c.raw.style_id == 0 or c.style.flags.underline == .none)) {
                self.fillRect(px * cell_w, py * cell_h + cell_h -| 1, draw_w, 1, fg);
            }
        }
    }

    /// 按 DECSCUSR 的 visual_style 画光标。block 用前景色填充并用背景色重画字符（反色）；
    /// bar/underline 是细条；block_hollow 是空心框。
    fn drawCursor(
        self: *Renderer,
        rs: *const gh.RenderState,
        cx: u32,
        cy: u32,
        cell_w: u32,
        cell_h: u32,
        fg: u32,
        bg: u32,
    ) void {
        const x = cx * cell_w;
        const y = cy * cell_h;
        const stroke = self.cursor_color orelse fg;
        switch (rs.cursor.visual_style) {
            .bar => self.fillRect(x, y, @max(cell_w / 4, 1), cell_h, stroke),
            .underline => self.fillRect(
                x,
                y + cell_h -| @max(cell_h / 8, 2),
                cell_w,
                @max(cell_h / 8, 2),
                stroke,
            ),
            .block_hollow => {
                self.fillRect(x, y, cell_w, 1, stroke);
                self.fillRect(x, y + cell_h -| 1, cell_w, 1, stroke);
                self.fillRect(x, y, 1, cell_h, stroke);
                self.fillRect(x + cell_w -| 1, y, 1, cell_h, stroke);
            },
            else => {
                self.fillRect(x, y, cell_w, cell_h, stroke);
                if (cy < rs.rows and cx < rs.cols) {
                    const inner = self.cursor_text_color orelse bg;
                    const c = rs.row_data.get(cy).cells.get(cx);
                    const base: u21 = switch (c.raw.content_tag) {
                        .codepoint, .codepoint_grapheme => c.raw.content.codepoint.data,
                        .bg_color_palette, .bg_color_rgb => 0,
                    };
                    if (base != 0) {
                        const wide = c.raw.wide == .wide;
                        self.drawGlyph(base, x, y, if (wide) cell_w * 2 else cell_w, cell_h, inner, wide, 0);
                    }
                }
            },
        }
    }

    /// 叠加显示预编辑串（输入法组词草稿）：从 start_x/start_y 起逐格绘制，
    /// 每格铺一层背景并加下划线，与已有内容区分。
    pub fn drawPreedit(
        self: *Renderer,
        text: []const u8,
        start_x: u32,
        start_y: u32,
        cell_w: u32,
        cell_h: u32,
        fg: u32,
        bg: u32,
    ) void {
        if (text.len == 0) return;
        var cells: u32 = 0;
        var it = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (it.nextCodepoint()) |cp| {
            const wide = ghosttyWidth(cp) == 2;
            const span = if (wide) cell_w * 2 else cell_w;
            const cx = (start_x + cells) * cell_w;
            const cy = start_y * cell_h;
            self.fillRect(cx, cy, span, cell_h, bg);
            self.fillRect(cx, cy + cell_h -| 1, span, 1, fg);
            self.drawGlyph(@intCast(cp), cx, cy, span, cell_h, fg, wide, 0);
            cells += if (wide) 2 else 1;
        }
    }

    fn drawGlyph(
        self: *Renderer,
        cp: u21,
        cell_x: u32,
        cell_y: u32,
        cell_w: u32,
        cell_h: u32,
        fg: u32,
        center: bool,
        style: u2,
    ) void {
        const g = self.glyph(cp, style) orelse return;
        if (g.w == 0 or g.h == 0) return;
        if (g.bpp == 4) {
            self.drawColorGlyph(g, cell_x, cell_y, cell_w, cell_h);
            return;
        }
        // 宽字符占两格但字形只有 ~1 格宽：在两格内居中，避免右边留一道缝。
        const x_shift: i32 = if (center and g.advance > 0 and cell_w > @as(u32, @intCast(g.advance)))
            @intCast((cell_w - @as(u32, @intCast(g.advance))) / 2)
        else
            0;
        var gy: u32 = 0;
        while (gy < g.h) : (gy += 1) {
            var gx: u32 = 0;
            while (gx < g.w) : (gx += 1) {
                const a = g.bitmap[@as(usize, gy) * @as(usize, g.w) + @as(usize, gx)];
                if (a == 0) continue;
                const dx = @as(i32, @intCast(cell_x)) + @as(i32, @intCast(gx)) + g.left + x_shift;
                // 基线放在格顶 + ascent 处，字形按 top 相对基线上移；
                // 之前用 cell_h 计算，会把 "_" 这类下伸字形整体推出格子被裁掉。
                const baseline = @as(i32, @intCast(cell_y)) + self.metrics.ascent;
                const dy = baseline - @as(i32, g.top) + @as(i32, @intCast(gy));
                // 只画在本格内，越界丢弃（与 Rust 侧 blit 裁剪口径一致）
                if (dx < 0 or dy < 0) continue;
                const ux: u32 = @intCast(dx);
                const uy: u32 = @intCast(dy);
                if (ux < cell_x or ux >= cell_x + cell_w) continue;
                if (uy < cell_y or uy >= cell_y + cell_h) continue;
                if (ux >= self.fb_w or uy >= self.fb_h) continue;
                const idx = @as(usize, uy) * self.fb_w + ux;
                self.fb[idx] = blend(self.fb[idx], fg, a);
            }
        }
    }

    /// 下划线（单/双/波浪/点线/虚线）、删除线、上划线。
    /// 位置与粗细按格子尺寸推导，尽量贴近 alacritty 的观感。
    fn drawDecorations(
        self: *Renderer,
        rs: *const gh.RenderState,
        c: gh.RenderState.Cell,
        x: u32,
        y: u32,
        w: u32,
        h: u32,
        fg: u32,
    ) void {
        if (c.raw.style_id == 0) return;
        const f = c.style.flags;
        const thick = @max(h / 16, 1);
        if (f.underline != .none) {
            const uy = y + h -| (thick + @max(h / 12, 1));
            const color = switch (c.style.underline_color) {
                .none => fg,
                .rgb => |rgb| rgbToU32(rgb),
                .palette => |idx| rgbToU32(rs.colors.palette[idx]),
            };
            switch (f.underline) {
                .single => self.fillRect(x, uy, w, thick, color),
                .double => {
                    self.fillRect(x, uy -| thick, w, thick, color);
                    self.fillRect(x, uy + thick, w, thick, color);
                },
                .curly => {
                    // 简易波浪：每 4px 交替上下画一段
                    var i: u32 = 0;
                    while (i < w) : (i += 1) {
                        const up = ((i / 2) % 2) == 0;
                        self.fillRect(x + i, if (up) uy -| thick else uy, 1, thick, color);
                    }
                },
                .dotted => {
                    var i: u32 = 0;
                    while (i < w) : (i += 2) self.fillRect(x + i, uy, 1, thick, color);
                },
                .dashed => {
                    var i: u32 = 0;
                    while (i < w) : (i += 4) self.fillRect(x + i, uy, @min(2, w - i), thick, color);
                },
                .none => {},
            }
        }
        if (f.strikethrough) {
            self.fillRect(x, y + h / 2, w, thick, fg);
        }
        if (f.overline) {
            self.fillRect(x, y, w, thick, fg);
        }
    }

    /// 彩色字形（BGRA）：缩放到格子并铺满整格。
    /// 位图字体的 strike 往往比格子大得多（Noto Color Emoji 只有 128px），
    /// 且其 left/top 是按 128px 算的，直接套用会把字形画到行外——这里忽略
    /// left/top，按格子原点铺满（alacritty 对彩色字形也是这个口径）。
    fn drawColorGlyph(self: *Renderer, g: Glyph, cell_x: u32, cell_y: u32, cell_w: u32, cell_h: u32) void {
        const dw: u32 = @max(cell_w, 1);
        const dh: u32 = @max(cell_h, 1);
        const gw: u32 = @max(g.w, 1);
        const gh_: u32 = @max(g.h, 1);
        var ty: u32 = 0;
        while (ty < dh) : (ty += 1) {
            // 目标像素覆盖的源区间（面积平均）
            const sy0 = ty * gh_ / dh;
            const sy1 = @max((ty + 1) * gh_ / dh, sy0 + 1);
            var tx: u32 = 0;
            while (tx < dw) : (tx += 1) {
                const sx0 = tx * gw / dw;
                const sx1 = @max((tx + 1) * gw / dw, sx0 + 1);
                var r: u32 = 0;
                var gg: u32 = 0;
                var b: u32 = 0;
                var a: u32 = 0;
                var cnt: u32 = 0;
                var sy = sy0;
                while (sy < sy1 and sy < gh_) : (sy += 1) {
                    var sx = sx0;
                    while (sx < sx1 and sx < gw) : (sx += 1) {
                        const off = (@as(usize, sy) * gw + sx) * 4;
                        b += g.bitmap[off + 0];
                        gg += g.bitmap[off + 1];
                        r += g.bitmap[off + 2];
                        a += g.bitmap[off + 3];
                        cnt += 1;
                    }
                }
                if (cnt == 0) continue;
                var sr = r / cnt;
                var sg = gg / cnt;
                var sb = b / cnt;
                const sa = a / cnt;
                if (sa == 0) continue;
                if (!g.premul) {
                    sr = sr * sa / 255;
                    sg = sg * sa / 255;
                    sb = sb * sa / 255;
                }
                const px = cell_x + tx;
                const py = cell_y + ty;
                if (px >= self.fb_w or py >= self.fb_h) continue;
                const idx = @as(usize, py) * self.fb_w + px;
                self.fb[idx] = blendPremul(self.fb[idx], sr, sg, sb, sa);
            }
        }
    }

    fn glyph(self: *Renderer, cp: u21, style: u2) ?Glyph {
        const key: u32 = @as(u32, cp) | (@as(u32, style) << 21);
        if (self.cache.get(key)) |g| return g;
        var gw: c_int = 0;
        var gh_: c_int = 0;
        var left: c_int = 0;
        var top: c_int = 0;
        var adv: c_int = 0;
        var bpp: c_int = 1;
        var premul: c_int = 1;
        const n = font.tty_glyph_styled_ex(
            self.handle,
            cp,
            @intCast(style),
            &self.scratch,
            self.scratch.len,
            &gw,
            &gh_,
            &left,
            &top,
            &adv,
            &bpp,
            &premul,
        );
        if (n < 0) return null;
        const len: usize = @intCast(n);
        const bitmap = self.alloc.dupe(u8, self.scratch[0..len]) catch return null;
        const g: Glyph = .{
            .w = @intCast(gw),
            .h = @intCast(gh_),
            .left = @intCast(left),
            .top = @intCast(top),
            .advance = @intCast(adv),
            .bitmap = bitmap,
            .bpp = if (bpp == 4) 4 else 1,
            .premul = premul != 0,
        };
        self.cache.put(self.alloc, key, g) catch {
            self.alloc.free(bitmap);
            return null;
        };
        return g;
    }

    fn fillRect(self: *Renderer, x: u32, y: u32, w: u32, h: u32, color: u32) void {
        var row = y;
        while (row < y + h and row < self.fb_h) : (row += 1) {
            var col = x;
            while (col < x + w and col < self.fb_w) : (col += 1) {
                self.fb[@as(usize, row) * self.fb_w + col] = color;
            }
        }
    }
};

/// 粗略的字符宽度判断：CJK/全角区间算 2 格。用 ghostty 的 unicode 表更准，
/// 但这里只服务于预编辑串的排布，保持在渲染层内不引额外依赖。
fn ghosttyWidth(cp: u21) u8 {
    if (cp < 0x1100) return 1;
    if ((cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1FAFF))
        return 2;
    return 1;
}

fn rgbToU32(c: anytype) u32 {
    return (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | @as(u32, c.b);
}

fn resolveFg(rs: *const gh.RenderState, c: gh.RenderState.Cell) ?u32 {
    if (c.raw.style_id == 0) return null;
    const col = c.style.fg_color;
    return switch (col) {
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
    const col = c.style.bg_color;
    return switch (col) {
        .none => null,
        .rgb => |rgb| rgbToU32(rgb),
        .palette => |idx| rgbToU32(rs.colors.palette[idx]),
    };
}

/// 在 bg 与 fg 之间按百分比插值（用于滚动条淡化色）。
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

/// 覆盖度混合：dst*(1-a) + fg*a。
/// 之前写成 `fg*a`（把前景色乘上覆盖率、完全丢掉背景），在浅色背景下
/// 每个抗锯齿边缘都变成深色 → 笔画变粗、发虚发糊（用户反馈的"字体很虚"）。
/// 只有背景恰好是纯黑时 `fg*a` 才等价于正确结果，所以深色主题下不易察觉。
/// 预乘 alpha 的颜色合成：dst*(1-a) + src（src 已乘过 a）。
fn blendPremul(dst: u32, sr: u32, sg: u32, sb: u32, sa: u32) u32 {
    const ia: u32 = 255 - @min(sa, 255);
    const dr = (dst >> 16) & 0xff;
    const dg = (dst >> 8) & 0xff;
    const db = dst & 0xff;
    const r: u32 = @min((dr * ia) / 255 + sr, @as(u32, 255));
    const g: u32 = @min((dg * ia) / 255 + sg, @as(u32, 255));
    const b: u32 = @min((db * ia) / 255 + sb, @as(u32, 255));
    return (r << 16) | (g << 8) | b;
}

fn blend(dst: u32, fg: u32, alpha: u8) u32 {
    const a: u32 = alpha;
    const ia: u32 = 255 - a;
    const dr = (dst >> 16) & 0xff;
    const dg = (dst >> 8) & 0xff;
    const db = dst & 0xff;
    const fr = (fg >> 16) & 0xff;
    const fgc = (fg >> 8) & 0xff;
    const fb = fg & 0xff;
    const r = (dr * ia + fr * a) / 255;
    const g = (dg * ia + fgc * a) / 255;
    const b = (db * ia + fb * a) / 255;
    return (r << 16) | (g << 8) | b;
}
