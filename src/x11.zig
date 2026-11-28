//! X11 窗口绑定：只声明 shim.c 导出的扁平接口，不接触 Xlib 结构体。

pub const EventKind = enum(c_int) {
    key = 1,
    resize = 2,
    expose = 3,
    close = 4,
    button = 5,
    paste = 6,
    motion = 7,
    button_release = 8,
    focus_in = 9,
    focus_out = 10,
    key_release = 11,
    _,
};

pub const Event = extern struct {
    type: c_int,
    width: c_int,
    height: c_int,
    keycode: c_uint,
    state: c_uint,
    keysym: c_uint,
    text_len: c_int,
    text: [128]u8,
    button: c_int,
    x: c_int,
    y: c_int,
};

pub const Ctx = opaque {};

/// IBus 手柄（见 ibus.c）；NULL 表示没有可用的输入法会话。
pub const Ibus = opaque {};
pub extern fn tty_paste_take(ctx: *Ctx, len: *c_int) ?[*]const u8;
pub extern fn tty_paste_done(ctx: *Ctx) void;
pub extern fn tty_ibus_open() ?*Ibus;
pub extern fn tty_ibus_unavailable_reason() ?[*:0]const u8;
pub extern fn tty_ibus_close(h: ?*Ibus) void;
pub extern fn tty_ibus_focus(h: ?*Ibus, focused: c_int) void;
pub extern fn tty_ibus_process_key(h: ?*Ibus, keyval: c_uint, keycode: c_uint, state: c_uint) c_int;
pub extern fn tty_ibus_pump(h: ?*Ibus) void;
pub extern fn tty_ibus_set_cursor(h: ?*Ibus, x: c_int, y: c_int, w: c_int, h: c_int) void;
pub extern fn tty_ibus_take_commit(h: ?*Ibus, buf: [*]u8, cap: c_int) c_int;
pub extern fn tty_ibus_take_preedit(h: ?*Ibus, buf: [*]u8, cap: c_int, cursor: *c_int, visible: *c_int) c_int;

pub extern fn tty_open(width: c_int, height: c_int, title: [*:0]const u8) ?*Ctx;
pub extern fn tty_open_at(width: c_int, height: c_int, title: [*:0]const u8, x: c_int, y: c_int) ?*Ctx;
pub extern fn tty_close(ctx: *Ctx) void;
pub extern fn tty_next_event(ctx: *Ctx, out: *Event) c_int;
pub extern fn tty_present(ctx: *Ctx, pixels: [*]const u32, width: c_int, height: c_int) void;

/// GPU 直画：把字形放进图集，返回 uv4 = {u0,v0,u1,v1}。
pub extern fn tty_gl_atlas_put(ctx: *Ctx, bytes: [*]const u8, w: c_int, h: c_int, bgra: c_int, premul: c_int, uv4: *[4]f32) c_int;
pub extern fn tty_gl_atlas_reset(ctx: *Ctx) void;
/// 提交一帧（bg 顶点 + glyph 顶点）并交换缓冲。
pub extern fn tty_gl_draw(ctx: *Ctx, width: c_int, height: c_int, bg: ?*const anyopaque, bg_bytes: c_int, glyph: ?*const anyopaque, glyph_bytes: c_int) void;
pub extern fn tty_resize(ctx: *Ctx, width: c_int, height: c_int) void;
pub extern fn tty_fd(ctx: *Ctx) c_int;
pub extern fn tty_clipboard_set(ctx: *Ctx, utf8: [*]const u8, len: c_int) void;
pub extern fn tty_clipboard_set_primary(ctx: *Ctx, utf8: [*]const u8, len: c_int, which: c_int) void;
pub extern fn tty_clipboard_request(ctx: *Ctx, which: c_int) c_int;
pub extern fn tty_window_origin(ctx: *Ctx, x: *c_int, y: *c_int) c_int;
pub extern fn tty_x11_disable_xim(ctx: *Ctx) void;
pub extern fn tty_file_exists(path: [*:0]const u8) c_int;
pub extern fn tty_fopen_unbuffered(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
pub extern fn tty_read_file(path: [*:0]const u8, buf: [*]u8, cap: c_int) c_int;
/// 文件 mtime（纳秒；失败 -1）与字节数（*size；失败 -1）。配置热加载用它检测变化。
pub extern fn tty_file_stamp(path: [*:0]const u8, size: *i64) i64;
/// 登录 shell（/etc/passwd 的 pw_shell）；没有返回 null。
pub extern fn tty_login_shell() ?[*:0]const u8;
pub extern fn tty_gl_enable(ctx: *Ctx) c_int;
pub extern fn tty_set_title(ctx: *Ctx, title: [*:0]const u8) void;
/// X 资源的 Xft.dpi（无则 0）。
pub extern fn tty_x_dpi() c_int;
/// 当前 GL 渲染器名（未启用 GL 时返回 null）。
pub extern fn tty_gl_renderer(ctx: *Ctx) ?[*:0]const u8;
/// SHM 图像传输可用（CPU 呈现路径依赖）。
pub extern fn tty_shm_ok(ctx: *Ctx) c_int;

/// X11 修饰键掩码（X.h）
pub const shift_mask: c_uint = 1 << 0;
pub const control_mask: c_uint = 1 << 2;
pub const mod1_mask: c_uint = 1 << 3;

/// 常用 keysym（X11/keysymdef.h）
pub const ks = struct {
    pub const backspace: c_uint = 0xff08;
    pub const tab: c_uint = 0xff09;
    pub const @"return": c_uint = 0xff0d;
    pub const escape: c_uint = 0xff1b;
    pub const home: c_uint = 0xff50;
    pub const left: c_uint = 0xff51;
    pub const up: c_uint = 0xff52;
    pub const right: c_uint = 0xff53;
    pub const down: c_uint = 0xff54;
    pub const page_up: c_uint = 0xff55;
    pub const page_down: c_uint = 0xff56;
    pub const end: c_uint = 0xff57;
    pub const insert: c_uint = 0xff63;
    pub const delete: c_uint = 0xffff;
    pub const f1: c_uint = 0xffbe;
    pub const kp_enter: c_uint = 0xff8d;
};

pub fn open(width: u32, height: u32, title: [*:0]const u8) !*Ctx {
    return tty_open(@intCast(width), @intCast(height), title) orelse error.X11OpenFailed;
}

pub fn openAt(width: u32, height: u32, title: [*:0]const u8, x: i32, y: i32) !*Ctx {
    return tty_open_at(@intCast(width), @intCast(height), title, x, y) orelse error.X11OpenFailed;
}
