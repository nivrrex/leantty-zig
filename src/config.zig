//! 配置解析（纯函数，便于单测）：命令行参数 + 环境变量 + 配置文件。
//!
//! 优先级：命令行 > 环境变量 > 配置文件 > 内置默认。
//! 与 Rust 侧的差异：Rust 只有 CLI(`--font`/`--font-size`) 与 env；
//! 本工程额外支持一个 `key = value` 配置文件（见 REPORT 6.8），
//! 键名与环境变量一一对应，非法值一律回落，不 panic。

const std = @import("std");
const toml = @import("toml.zig");

/// 一条键绑定（`[[keyboard.bindings]]` 的元素）。
/// 兼容两种写法：`key = "Ctrl+Shift+C"`，或 `key = "Insert"` + `mods = "Control"`。
pub const KeyBinding = struct { key: []const u8 = "", mods: []const u8 = "", action: []const u8 = "" };

/// 一条鼠标绑定（`[[mouse.bindings]]` 的元素）：mouse = "Left"/"Middle"/"Right"。
pub const MouseBinding = struct { button: []const u8 = "", action: []const u8 = "" };

/// [renderer] backend
pub const Backend = enum { auto, cpu, gpu };

/// 一个 8 位 RGB 颜色（配置里的 "#RRGGBB" / "0xRRGGBB" / "#RGB"）。
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    /// 解析失败返回 null（调用方负责告警），不 panic。
    pub fn parse(text: []const u8) ?Rgb {
        var s = std.mem.trim(u8, text, " \t");
        if (s.len == 0) return null;
        if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) s = s[2..];
        if (s.len > 0 and s[0] == '#') s = s[1..];
        if (s.len == 3) {
            const r = std.fmt.parseInt(u8, s[0..1], 16) catch return null;
            const g = std.fmt.parseInt(u8, s[1..2], 16) catch return null;
            const b = std.fmt.parseInt(u8, s[2..3], 16) catch return null;
            return .{ .r = r * 17, .g = g * 17, .b = b * 17 };
        }
        if (s.len != 6) return null;
        const r = std.fmt.parseInt(u8, s[0..2], 16) catch return null;
        const g = std.fmt.parseInt(u8, s[2..4], 16) catch return null;
        const b = std.fmt.parseInt(u8, s[4..6], 16) catch return null;
        return .{ .r = r, .g = g, .b = b };
    }
};

/// 字体样式（family + style，如 "Consolas" + "Bold"）。
pub const FontSpec = struct { family: ?[]const u8 = null, style: ?[]const u8 = null };

/// 光标形状（值名与 ghostty 的 cursor.Style 一致）。
pub const CursorStyle = enum { block, bar, underline, block_hollow };

pub const Config = struct {
    shell: []const u8 = "/bin/sh",
    cols: u16 = 80,
    rows: u16 = 24,
    font_family: ?[]const u8 = null,
    /// 像素字号（Rust 侧是 pt 的 f32；这里取整到像素）。
    font_size: u32 = 11,
    /// null = 按字体度量自动推导（与 Rust 的 cell_metrics 一致）
    cell_w: ?u32 = null,
    cell_h: ?u32 = null,
    dump_path: ?[]const u8 = null,
    /// -e/--command：以该 argv 启动（空则用 shell）
    command: []const []const u8 = &.{},
    /// [scrolling] multiplier：滚轮一格滚动多少行（默认 3）。
    scroll_multiplier: u32 = 3,
    /// [window] dynamic_title：窗口标题跟随 OSC 0/2（默认开）。
    dynamic_title: bool = true,
    /// [cursor] blink：光标闪烁（默认关；程序可用 DECSCUSR 强制开）。
    cursor_blink: bool = false,
    /// [cursor] style：默认光标形状（block / bar / underline / block_hollow）。
    /// 与 ghostty 的 cursor.style 同名同值；程序仍可用 DECSCUSR（CSI q）覆盖。
    /// 之前它被列在“未实现，已忽略”清单里，导致 block_hollow 在两端都无法触达。
    cursor_style: ?CursorStyle = null,
    /// [renderer] backend（auto：先试 GPU，失败回落 CPU）。
    backend: Backend = .auto,
    /// [scrolling] history（0 表示用 ghostty 默认）。
    scrollback_lines: u64 = 0,
    /// [selection] save_to_clipboard：拖拽选区时是否同时写 CLIPBOARD。
    save_to_clipboard: bool = true,
    /// [colors.primary] / [colors.cursor] / [colors.selection]
    colors_bg: ?Rgb = null,
    colors_fg: ?Rgb = null,
    colors_cursor: ?Rgb = null,
    colors_cursor_text: ?Rgb = null,
    colors_selection_bg: ?Rgb = null,
    colors_selection_fg: ?Rgb = null,
    /// [colors.normal] 0-7 + [colors.bright] 8-15（下标 0-7 / 8-15）
    colors_palette: [16]?Rgb = @splat(null),
    /// [colors] faint：是否对 SGR 2（dim）做压暗；false 时按原色绘制（与 Rust 版 Windows 行为一致）
    colors_faint: bool = true,
    /// [colors] faint_opacity：压暗强度（0..1，0 = 完全不压暗，1 = 完全变背景色）。
    /// 默认 0.5，等价于 ghostty 的 faint-opacity。
    colors_faint_opacity: f32 = 0.5,
    /// [colors] draw_bold_text_with_bright_colors
    colors_bold_bright: bool = false,
    /// [font] normal / bold / italic / bold_italic
    font_normal: FontSpec = .{},
    font_bold: FontSpec = .{},
    font_italic: FontSpec = .{},
    font_bold_italic: FontSpec = .{},
    /// [font] fallback 的字体族（最多 8 个，按顺序回退）。
    font_fallbacks: [8]?[]const u8 = .{ null, null, null, null, null, null, null, null },
    /// [keyboard] bindings（最多 16 条，按配置顺序匹配）。
    keybindings: [16]?KeyBinding =
        .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
    /// [[mouse.bindings]]
    mouse_bindings: [16]?MouseBinding =
        .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
    /// [window] position（未设置时由 WM 决定）。
    window_x: ?i32 = null,
    window_y: ?i32 = null,
};

/// 环境变量/配置文件共用的键名。
pub const keys = struct {
    pub const shell = "shell";
    pub const cols = "cols";
    pub const rows = "rows";
    pub const font_family = "font_family";
    pub const font_size = "font_size";
    pub const cell_w = "cell_w";
    pub const cell_h = "cell_h";
    pub const dump_snapshot = "dump_snapshot";
};

/// 从 `xxx.bindings[3].field` 里取 3。
fn bindingIndex(key: []const u8) ?usize {
    const open = std.mem.indexOfScalar(u8, key, '[') orelse return null;
    const close = std.mem.indexOfScalar(u8, key, ']') orelse return null;
    return std.fmt.parseInt(usize, key[open + 1 .. close], 10) catch null;
}

fn parseU32(v: []const u8) ?u32 {
    return std.fmt.parseInt(u32, std.mem.trim(u8, v, " \t"), 10) catch null;
}

/// 字号：接受 `14` 与 `14.5` 两种写法（Rust 侧是 f32），四舍五入到整数像素。
pub fn parseFontSize(v: []const u8) ?u32 {
    const t = std.mem.trim(u8, v, " \t");
    if (t.len == 0) return null;
    if (std.mem.indexOfScalar(u8, t, '.') == null) return parseU32(t);
    const f = std.fmt.parseFloat(f32, t) catch return null;
    if (f <= 0 or f > 512) return null;
    return @intFromFloat(@round(f));
}

/// 把一个键值对应用到配置上；未知键忽略，非法值保持原值。
/// `origin_cli` 为 true 时允许用 CLI 的键名（`--font` 等）。
/// 去掉值两侧的成对引号（配置文件里常见 `font_family = "X"`）。
fn unquote(v: []const u8) []const u8 {
    if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or
        (v[0] == '\'' and v[v.len - 1] == '\'')))
        return v[1 .. v.len - 1];
    return v;
}

pub fn apply(cfg: *Config, key: []const u8, value_in: []const u8) void {
    const value = unquote(value_in);
    if (std.mem.eql(u8, key, keys.shell) or std.mem.eql(u8, key, "SHELL")) {
        if (value.len > 0) cfg.shell = value;
    } else if (std.mem.eql(u8, key, keys.cols) or std.mem.eql(u8, key, "APP_COLS")) {
        if (parseU32(value)) |n| {
            if (n > 0 and n <= 1000) cfg.cols = @intCast(n);
        }
    } else if (std.mem.eql(u8, key, keys.rows) or std.mem.eql(u8, key, "APP_ROWS")) {
        if (parseU32(value)) |n| {
            if (n > 0 and n <= 1000) cfg.rows = @intCast(n);
        }
    } else if (std.mem.eql(u8, key, keys.font_family) or std.mem.eql(u8, key, "APP_FONT_FAMILY")) {
        if (value.len > 0) cfg.font_family = value;
    } else if (std.mem.eql(u8, key, keys.font_size) or std.mem.eql(u8, key, "APP_FONT_SIZE")) {
        if (parseFontSize(value)) |n| cfg.font_size = n;
    } else if (std.mem.eql(u8, key, keys.cell_w) or std.mem.eql(u8, key, "APP_CELL_W")) {
        if (parseU32(value)) |n| {
            if (n > 0 and n <= 256) cfg.cell_w = n;
        }
    } else if (std.mem.eql(u8, key, keys.cell_h) or std.mem.eql(u8, key, "APP_CELL_H")) {
        if (parseU32(value)) |n| {
            if (n > 0 and n <= 256) cfg.cell_h = n;
        }
    } else if (std.mem.eql(u8, key, keys.dump_snapshot) or std.mem.eql(u8, key, "APP_DUMP_SNAPSHOT")) {
        if (value.len > 0) cfg.dump_path = value;
    }
}

/// 从 TOML（Rust 侧 leantty.toml 的 schema 子集）填充配置。
/// 认识并忽略的键在下面显式列出（避免误报"未知字段"）。
pub fn applyToml(cfg: *Config, alloc: std.mem.Allocator, text: []const u8, warn: *std.ArrayList(u8)) !void {
    var parsed = try toml.parse(alloc, text);
    defer parsed.deinit(alloc);

    const known = [_][]const u8{
        "window",                      "window.dimensions",      "window.dimensions.columns",
        "window.dimensions.lines",     "window.position",        "window.position.x",
        "window.position.y",           "window.padding",         "window.padding.x",
        "window.padding.y",            "window.dynamic_title",   "window.opacity",
        "scrolling",                   "scrolling.history",      "scrolling.multiplier",
        "font",                        "font.size",              "font.normal",
        "font.normal.family",          "font.normal.style",      "font.bold",
        "font.bold.family",            "font.bold.style",        "font.italic",
        "font.italic.family",          "font.italic.style",      "font.bold_italic",
        "font.bold_italic.family",     "font.bold_italic.style", "font.fallback",
        "renderer",                    "renderer.backend",       "selection",
        "colors.faint",                     "colors.faint_opacity",
        "selection.save_to_clipboard",
    };

    // [[keyboard.bindings]] / [[mouse.bindings]] 的字段已在上面的分支处理。

    const valid_actions = [_][]const u8{
        "Copy",        "Paste",          "ScrollPageUp", "ScrollPageDown",
        "ScrollToTop", "ScrollToBottom", "Quit",
    };
    const valid_buttons = [_][]const u8{ "Left", "Middle", "Right", "WheelUp", "WheelDown" };

    for (parsed.entries.items) |e| {
        var recognized = false;
        if (std.mem.eql(u8, e.key, "window.dimensions.columns")) {
            if (e.value == .int and e.value.int > 0 and e.value.int <= 1000) {
                cfg.cols = @intCast(e.value.int);
            }
            recognized = true;
        } else if (std.mem.eql(u8, e.key, "window.dimensions.lines")) {
            if (e.value == .int and e.value.int > 0 and e.value.int <= 1000) {
                cfg.rows = @intCast(e.value.int);
            }
            recognized = true;
        } else if (std.mem.eql(u8, e.key, "window.dynamic_title")) {
            if (e.value == .boolean) cfg.dynamic_title = e.value.boolean;
            recognized = true;
        } else if (std.mem.eql(u8, e.key, "cursor.blink")) {
            if (e.value == .boolean) cfg.cursor_blink = e.value.boolean;
            recognized = true;
        } else if (std.mem.eql(u8, e.key, "cursor.style")) {
            if (e.value == .string) {
                const v = std.mem.trim(u8, e.value.string, " \t\"");
                cfg.cursor_style = std.meta.stringToEnum(CursorStyle, v) orelse blk: {
                    try warn.appendSlice(alloc, "cursor.style 取值无法识别，已忽略: ");
                    try warn.appendSlice(alloc, v);
                    try warn.appendSlice(alloc, "\n");
                    break :blk cfg.cursor_style;
                };
            }
            recognized = true;
        } else if (std.mem.eql(u8, e.key, "window.position.x")) {
            if (e.value == .int) cfg.window_x = @intCast(e.value.int);
            recognized = true;
        } else if (std.mem.eql(u8, e.key, "window.position.y")) {
            if (e.value == .int) cfg.window_y = @intCast(e.value.int);
            recognized = true;
        } else if (std.mem.eql(u8, e.key, "font.size")) {
            switch (e.value) {
                .float => |f| if (f > 0 and f <= 512) {
                    cfg.font_size = @intFromFloat(@round(f));
                },
                .int => |n| if (n > 0 and n <= 512) {
                    cfg.font_size = @intCast(n);
                },
                else => {},
            }
            recognized = true;
        } else if (std.mem.startsWith(u8, e.key, "keyboard.bindings[")) {
            recognized = true;
            const idx = bindingIndex(e.key) orelse 0;
            if (idx < cfg.keybindings.len and e.value == .string) {
                var b = cfg.keybindings[idx] orelse KeyBinding{};
                const field = e.key[std.mem.lastIndexOfScalar(u8, e.key, '.').? + 1 ..];
                if (std.mem.eql(u8, field, "key")) b.key = e.value.string;
                if (std.mem.eql(u8, field, "mods")) b.mods = e.value.string;
                if (std.mem.eql(u8, field, "action")) b.action = e.value.string;
                cfg.keybindings[idx] = b;
            }
        } else if (std.mem.startsWith(u8, e.key, "mouse.bindings[")) {
            recognized = true;
            const idx = bindingIndex(e.key) orelse 0;
            if (idx < cfg.mouse_bindings.len and e.value == .string) {
                var b = cfg.mouse_bindings[idx] orelse MouseBinding{};
                const field = e.key[std.mem.lastIndexOfScalar(u8, e.key, '.').? + 1 ..];
                if (std.mem.eql(u8, field, "mouse")) b.button = e.value.string;
                if (std.mem.eql(u8, field, "button")) b.button = e.value.string;
                if (std.mem.eql(u8, field, "action")) b.action = e.value.string;
                cfg.mouse_bindings[idx] = b;
            }
        } else if (std.mem.startsWith(u8, e.key, "font.fallback[") and
            std.mem.endsWith(u8, e.key, "].family"))
        {
            if (e.value == .string and e.value.string.len > 0) {
                const bracket = std.mem.indexOfScalar(u8, e.key, '[') orelse 0;
                const close = std.mem.indexOfScalar(u8, e.key, ']') orelse 0;
                const idx = std.fmt.parseInt(usize, e.key[bracket + 1 .. close], 10) catch 0;
                if (idx < cfg.font_fallbacks.len) cfg.font_fallbacks[idx] = e.value.string;
            }
            recognized = true;
        } else if (std.mem.startsWith(u8, e.key, "font.") and
            (std.mem.endsWith(u8, e.key, ".family") or std.mem.endsWith(u8, e.key, ".style")) and
            !std.mem.startsWith(u8, e.key, "font.fallback"))
        {
            const spec: *FontSpec = if (std.mem.startsWith(u8, e.key, "font.normal"))
                &cfg.font_normal
            else if (std.mem.startsWith(u8, e.key, "font.bold_italic"))
                &cfg.font_bold_italic
            else if (std.mem.startsWith(u8, e.key, "font.bold"))
                &cfg.font_bold
            else if (std.mem.startsWith(u8, e.key, "font.italic"))
                &cfg.font_italic
            else
                &cfg.font_normal;
            if (e.value == .string and e.value.string.len > 0) {
                if (std.mem.endsWith(u8, e.key, ".family")) {
                    spec.family = e.value.string;
                    if (spec == &cfg.font_normal) cfg.font_family = e.value.string;
                } else {
                    spec.style = e.value.string;
                }
            }
            recognized = true;
        } else if (std.mem.eql(u8, e.key, "font.normal.family")) {
            if (e.value == .string and e.value.string.len > 0) cfg.font_family = e.value.string;
            recognized = true;
        } else if (std.mem.eql(u8, e.key, "scrolling.multiplier")) {
            if (e.value == .int and e.value.int > 0 and e.value.int <= 100) {
                cfg.scroll_multiplier = @intCast(e.value.int);
            }
            recognized = true;
        } else if (std.mem.eql(u8, e.key, "scrolling.history")) {
            if (e.value == .int and e.value.int >= 0) cfg.scrollback_lines = @intCast(e.value.int);
            recognized = true;
        } else if (std.mem.eql(u8, e.key, "selection.save_to_clipboard")) {
            if (e.value == .boolean) cfg.save_to_clipboard = e.value.boolean;
            recognized = true;
        } else if (std.mem.eql(u8, e.key, "colors.faint")) {
            if (e.value == .boolean) cfg.colors_faint = e.value.boolean;
            recognized = true;
        } else if (std.mem.eql(u8, e.key, "colors.faint_opacity")) {
            const v: f32 = switch (e.value) {
                .float => |f| @floatCast(f),
                .int => |i| @floatFromInt(i),
                else => cfg.colors_faint_opacity,
            };
            cfg.colors_faint_opacity = std.math.clamp(v, 0.0, 1.0);
            recognized = true;
        } else if (std.mem.eql(u8, e.key, "colors.draw_bold_text_with_bright_colors")) {
            if (e.value == .boolean) cfg.colors_bold_bright = e.value.boolean;
            recognized = true;
        } else if (std.mem.startsWith(u8, e.key, "colors.") and e.value == .string) {
            // colors.primary.background / colors.cursor.cursor / colors.normal.red ...
            recognized = true;
            const rgb = Rgb.parse(e.value.string) orelse {
                try warn.appendSlice(alloc, "颜色值无法解析，已忽略: ");
                try warn.appendSlice(alloc, e.value.string);
                try warn.appendSlice(alloc, "\n");
                return;
            };
            if (std.mem.eql(u8, e.key, "colors.primary.background")) {
                cfg.colors_bg = rgb;
            } else if (std.mem.eql(u8, e.key, "colors.primary.foreground")) {
                cfg.colors_fg = rgb;
            } else if (std.mem.eql(u8, e.key, "colors.cursor.cursor")) {
                cfg.colors_cursor = rgb;
            } else if (std.mem.eql(u8, e.key, "colors.cursor.text")) {
                cfg.colors_cursor_text = rgb;
            } else if (std.mem.eql(u8, e.key, "colors.selection.background")) {
                cfg.colors_selection_bg = rgb;
            } else if (std.mem.eql(u8, e.key, "colors.selection.foreground")) {
                cfg.colors_selection_fg = rgb;
            } else {
                const under = if (std.mem.startsWith(u8, e.key, "colors.normal."))
                    @as(usize, 0)
                else if (std.mem.startsWith(u8, e.key, "colors.bright."))
                    @as(usize, 8)
                else {
                    try warn.appendSlice(alloc, "未实现，已忽略: ");
                    try warn.appendSlice(alloc, e.key);
                    try warn.appendSlice(alloc, "\n");
                    return;
                };
                const name = e.key[std.mem.lastIndexOfScalar(u8, e.key, '.').? + 1 ..];
                const names = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" };
                for (names, 0..) |n, i| {
                    if (std.mem.eql(u8, name, n)) cfg.colors_palette[under + i] = rgb;
                }
            }
        } else if (std.mem.eql(u8, e.key, "renderer.backend")) {
            if (e.value == .string) {
                const b = e.value.string;
                if (std.mem.eql(u8, b, "gpu")) {
                    cfg.backend = .gpu;
                } else if (std.mem.eql(u8, b, "cpu")) {
                    cfg.backend = .cpu;
                } else if (std.mem.eql(u8, b, "auto")) {
                    cfg.backend = .auto;
                } else {
                    try warn.appendSlice(alloc, "renderer.backend 取值未知，按 auto 处理\n");
                }
            }
            recognized = true;
        }

        if (!recognized) {
            // 影响行为但本实现未支持的键：聚合到一条告警里
            // 会影响观感/行为但我们没实现的键：启动时明确告警，避免"配了没效果"
            //（配色静默忽略就是这么被发现的，见 REPORT 6.22）。
            const ignored_meaningful = [_][]const u8{
                "window.padding.x",          "window.padding.y",
                "window.opacity",            "window.decorations",
                "window.blur",               "window.startup_mode",
                "window.title",              "window.dynamic_padding",
                "window.resize_increments",  "font.offset.x",
                "font.offset.y",             "font.glyph_offset.x",
                "font.glyph_offset.y",       "font.builtin_box_drawing",
                "cursor.unfocused_hollow",
                "cursor.thickness",          "mouse.hide_when_typing",
                "terminal.osc52",            "terminal.shell_integration",
                "selection.semantic_escape_chars",
            };
            const ignored_prefixes = [_][]const u8{ "env.", "hints.", "bell.", "window.padding" };
            for (ignored_prefixes) |pfx| {
                if (std.mem.startsWith(u8, e.key, pfx)) {
                    try warn.appendSlice(alloc, "未实现，已忽略: ");
                    try warn.appendSlice(alloc, e.key);
                    try warn.appendSlice(alloc, "\n");
                    recognized = true;
                    break;
                }
            }
            if (recognized) continue;
            for (ignored_meaningful) |k| {
                if (std.mem.eql(u8, e.key, k)) {
                    try warn.appendSlice(alloc, "未实现，已忽略: ");
                    try warn.appendSlice(alloc, k);
                    try warn.appendSlice(alloc, "\n");
                    recognized = true;
                    break;
                }
            }
        }

        if (!recognized) {
            // 本实现未支持但属于 leantty/alacritty 配置的已知段落：静默忽略，
            // 避免用户的现成配置刷一堆"未知字段"告警（Rust 侧同样有 KNOWN 列表）。
            const silent_prefixes = [_][]const u8{
                "cursor", "mouse",    "keyboard", "bell",     "terminal",
                "env",    "hints",    "debug",     "perf",     "window", "scrolling",
                "font",   "renderer", "selection",
            };
            const top = if (std.mem.indexOfScalar(u8, e.key, '.')) |dot| e.key[0..dot] else e.key;
            for (silent_prefixes) |pfx| {
                if (std.mem.eql(u8, top, pfx)) {
                    recognized = true;
                    break;
                }
            }
        }

        // 绑定动作/按钮名的合法性（非法就告警，避免"配了却不生效"）
        if (recognized and e.value == .string and std.mem.endsWith(u8, e.key, ".action")) {
            var ok = false;
            for (valid_actions) |a| {
                if (std.mem.eql(u8, a, e.value.string)) ok = true;
            }
            if (!ok) {
                try warn.appendSlice(alloc, "未知的绑定动作，已忽略: ");
                try warn.appendSlice(alloc, e.value.string);
                try warn.appendSlice(alloc, "\n");
            }
        }
        if (recognized and e.value == .string and
            (std.mem.endsWith(u8, e.key, ".mouse") or std.mem.endsWith(u8, e.key, ".button")))
        {
            var ok = false;
            for (valid_buttons) |b| {
                if (std.ascii.eqlIgnoreCase(b, e.value.string)) ok = true;
            }
            if (!ok) {
                try warn.appendSlice(alloc, "未知的鼠标按钮，已忽略: ");
                try warn.appendSlice(alloc, e.value.string);
                try warn.appendSlice(alloc, "\n");
            }
        }

        if (!recognized) {
            var is_known = false;
            for (known) |k| {
                if (std.mem.eql(u8, e.key, k)) {
                    is_known = true;
                    break;
                }
            }
            if (!is_known) {
                try warn.appendSlice(alloc, "未知配置字段，已忽略: ");
                try warn.appendSlice(alloc, e.key);
                try warn.appendSlice(alloc, "\n");
            }
        }
    }
}

/// 解析配置文件文本：`key = value`，`#`/`;` 开头的行是注释。
pub fn parseConfigText(cfg: *Config, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        apply(cfg, key, value);
    }
}

/// 解析命令行参数，支持 `--font <v>`、`--font-size <v>`、`--cols <v>`、`--rows <v>`、
/// `--shell <v>`、`--cell-width <v>`、`--cell-height <v>`；未知参数忽略（与 Rust 一致）。
pub fn parseArgs(cfg: *Config, args: []const []const u8) void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const key: ?[]const u8 = if (std.mem.eql(u8, a, "--font"))
            "font_family"
        else if (std.mem.eql(u8, a, "--font-size"))
            "font_size"
        else if (std.mem.eql(u8, a, "--cols"))
            "cols"
        else if (std.mem.eql(u8, a, "--rows"))
            "rows"
        else if (std.mem.eql(u8, a, "--shell"))
            "shell"
        else if (std.mem.eql(u8, a, "--cell-width"))
            "cell_w"
        else if (std.mem.eql(u8, a, "--cell-height"))
            "cell_h"
        else
            null;
        if (key) |k| {
            if (i + 1 < args.len) {
                apply(cfg, k, args[i + 1]);
                i += 1;
            }
        }
    }
}

test "colors.faint / faint_opacity：解析与范围夹取" {
    // applyToml 会把键/取值拷到传入的分配器里（与 main.zig 一样用 arena 持有），
    // 这里同样用 arena，避免测试里逐条追踪释放。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warn: std.ArrayList(u8) = .empty;

    var c: Config = .{};
    try applyToml(&c, a,
        \\[colors]
        \\faint = false
        \\faint_opacity = 0.25
    , &warn);
    try std.testing.expectEqual(false, c.colors_faint);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), c.colors_faint_opacity, 1e-6);

    // 越界要夹到 0..1，而不是溢出或整条丢弃
    var c2: Config = .{};
    try applyToml(&c2, a,
        \\[colors]
        \\faint_opacity = 3.5
    , &warn);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c2.colors_faint_opacity, 1e-6);
}
