//! 字体绑定：fontconfig 查文件 + FreeType 光栅化（实现见 shim.c）。

pub const Handle = opaque {};

/// 与 shim.h 的 tty_font_style 对应：family/style 为 NUL 结尾字符串（NULL 表示回落）。
pub const Style = extern struct {
    family: ?[*:0]const u8 = null,
    style: ?[*:0]const u8 = null,
};

pub extern fn tty_font_open(
    family: ?[*:0]const u8,
    pixel_size: c_int,
    path_out: ?[*]u8,
    path_cap: c_int,
) ?*Handle;
pub extern fn tty_font_open_multi(
    families: [*]const ?[*:0]const u8,
    count: c_int,
    pixel_size: c_int,
    path_out: ?[*]u8,
    path_cap: c_int,
) ?*Handle;
pub extern fn tty_font_close(handle: *Handle) void;
pub extern fn tty_font_metrics(
    handle: *Handle,
    ascent: *c_int,
    descent: *c_int,
    line_height: *c_int,
    advance: *c_int,
) c_int;
pub extern fn tty_font_open_styled(
    styles: [*]const Style,
    n_styles: c_int,
    fallbacks: ?[*]const ?[*:0]const u8,
    n_fallbacks: c_int,
    pixel_size: c_int,
    path_out: ?[*]u8,
    path_cap: c_int,
) ?*Handle;
pub extern fn tty_glyph_styled_ex(
    h: *Handle,
    codepoint: u32,
    style: c_int,
    out: [*]u8,
    cap: c_int,
    w: *c_int,
    h_: *c_int,
    left: *c_int,
    top: *c_int,
    advance: *c_int,
    bpp: *c_int,
    premul: *c_int,
) c_int;

pub extern fn tty_glyph_styled(
    handle: *Handle,
    codepoint: u32,
    style: c_int,
    out: [*]u8,
    cap: c_int,
    gw: *c_int,
    gh: *c_int,
    left: *c_int,
    top: *c_int,
    advance: *c_int,
) c_int;
pub extern fn tty_glyph(
    handle: *Handle,
    codepoint: u32,
    out: [*]u8,
    cap: c_int,
    gw: *c_int,
    gh: *c_int,
    left: *c_int,
    top: *c_int,
    advance: *c_int,
) c_int;

pub const Metrics = struct {
    ascent: i32,
    descent: i32,
    line_height: i32,
    advance: i32,
};

pub fn open(family: ?[*:0]const u8, pixel_size: u32) !*Handle {
    return tty_font_open(family, @intCast(pixel_size), null, 0) orelse error.FontNotFound;
}

/// families[0] 是主字体，其余是回退链。
/// 四种样式（normal/bold/italic/bold_italic）+ 回退链。
pub fn openStyled(styles: []const Style, fallbacks: []const ?[*:0]const u8, pixel_size: u32) !*Handle {
    return tty_font_open_styled(
        styles.ptr,
        @intCast(styles.len),
        fallbacks.ptr,
        @intCast(fallbacks.len),
        @intCast(pixel_size),
        null,
        0,
    ) orelse error.FontNotFound;
}

pub fn openMulti(families: []const ?[*:0]const u8, pixel_size: u32) !*Handle {
    if (families.len == 0) return error.FontNotFound;
    return tty_font_open_multi(families.ptr, @intCast(families.len), @intCast(pixel_size), null, 0) orelse error.FontNotFound;
}

pub fn metrics(h: *Handle) !Metrics {
    var m: Metrics = .{ .ascent = 0, .descent = 0, .line_height = 0, .advance = 0 };
    if (tty_font_metrics(h, &m.ascent, &m.descent, &m.line_height, &m.advance) != 0)
        return error.FontMetrics;
    return m;
}
