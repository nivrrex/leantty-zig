//! leantty（Zig 版）入口：命令行 / 环境变量 / TOML 配置文件 → 运行。
//!
//! 与 Rust 侧（v0.2.3）对齐的约定：
//! - 配置文件路径：`--config-file/--config` > `LEANTTY_CONFIG` >
//!   `$XDG_CONFIG_HOME/leantty/leantty.toml` > `~/.config/leantty/leantty.toml`
//! - 字段优先级：命令行 > `APP_*` 环境变量 > 配置文件 > 内置默认
//! - 命令行：`-h/--help`、`-V/--version`、`--config-file[=]`、`--working-directory[=]`、
//!   `-e/--command`、`--font`、`--font-size`；另加本实现的 `--cols/--rows/--cell-*`
//! - 配置文件格式：TOML，支持 Rust `leantty.toml` schema 的子集（见 config.zig）
//! - 文件缺失/字段非法：stderr 提示后回落，不退出

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");

const is_windows = builtin.os.tag == .windows;
const app = if (!is_windows) @import("app.zig") else struct {};
const app_win = if (is_windows) @import("app_win.zig") else struct {};
const x11 = if (!is_windows) @import("x11.zig") else struct {};

extern fn w32_read_file(path: [*:0]const u8, buf: [*]u8, cap: c_int) c_int;

const version = "0.1.3";

var file_buf: [64 * 1024]u8 = undefined;
var font_family_buf: [256]u8 = undefined;
var dump_buf: [512]u8 = undefined;
var fallback_bufs: [8][128]u8 = undefined;

/// 配置文件文本解码：
///   - UTF-8 BOM（EF BB BF）剥掉。Windows 编辑器/PowerShell 重定向常写 BOM，
///     带 BOM 时首个 `[section]` 解析失败、整段键退化成顶层未知字段（实测配色完全不生效）。
///   - UTF-16 BOM（FF FE / FE FF）就地转 UTF-8。
///   - 其它原样返回（CRLF 由 TOML 解析器容忍，实测无需处理）。
fn decodeConfigText(raw: []const u8) []const u8 {
    if (raw.len >= 3 and raw[0] == 0xEF and raw[1] == 0xBB and raw[2] == 0xBF) return raw[3..];
    const utf16le = raw.len >= 2 and raw[0] == 0xFF and raw[1] == 0xFE;
    const utf16be = raw.len >= 2 and raw[0] == 0xFE and raw[1] == 0xFF;
    if (!utf16le and !utf16be) return raw;
    const decode_state = struct {
        var buf: [32768]u8 = undefined;
    };
    var n: usize = 0;
    var i: usize = 2;
    while (i + 1 < raw.len and n + 4 <= decode_state.buf.len) : (i += 2) {
        const unit: u21 = if (utf16le)
            @as(u21, raw[i]) | (@as(u21, raw[i + 1]) << 8)
        else
            (@as(u21, raw[i]) << 8) | @as(u21, raw[i + 1]);
        if (unit == 0) continue;
        n += std.unicode.utf8Encode(unit, decode_state.buf[n..][0..4]) catch 0;
    }
    return decode_state.buf[0..n];
}

fn configPath(env: anytype, cli: ?[]const u8, out: *[512]u8) ?[:0]const u8 {
    const join = struct {
        fn f(buf: *[512]u8, parts: []const []const u8) ?[:0]const u8 {
            var n: usize = 0;
            for (parts) |p| {
                if (n + p.len + 1 > buf.len) return null;
                @memcpy(buf[n..][0..p.len], p);
                n += p.len;
            }
            buf[n] = 0;
            return buf[0..n :0];
        }
    }.f;

    if (cli) |v| {
        if (v.len > 0) return join(out, &.{v});
    }
    if (env.get("LEANTTY_CONFIG")) |v| {
        if (v.len > 0) return join(out, &.{v});
    }
    if (env.get("XDG_CONFIG_HOME")) |v| {
        if (v.len > 0) return join(out, &.{ v, "/leantty/leantty.toml" });
    }
    // Windows 没有 HOME 也没有 XDG_CONFIG_HOME（cmd.exe 下都为空），
    // 之前因此读不到配置 → 用户看到"配置不生效、仍是黑底"。
    if (is_windows) {
        if (env.get("APPDATA")) |v| {
            if (v.len > 0) return join(out, &.{ v, "\\leantty\\leantty.toml" });
        }
        if (env.get("USERPROFILE")) |v| {
            if (v.len > 0) return join(out, &.{ v, "\\.config\\leantty\\leantty.toml" });
        }
    }
    if (env.get("HOME")) |v| {
        if (v.len > 0) return join(out, &.{ v, "/.config/leantty/leantty.toml" });
    }
    return null;
}

fn helpText(writer: anytype, default_path: []const u8) void {
    writer.print(
        \\Usage: leantty [OPTIONS]
        \\
        \\Options:
        \\  -h, --help               Print this help and exit
        \\  -V, --version            Print version and exit
        \\      --config-file <PATH> Use the given configuration file
        \\      --working-directory <DIR>
        \\                           Start in this directory
        \\  -e, --command <PROGRAM> [ARGS...]
        \\                           Run PROGRAM instead of the shell; every following
        \\                           argument is passed to it verbatim
        \\      --font <FAMILY>      Override the configured font family
        \\      --font-size <PX>     Override the configured font size
        \\      --cols <N>           Override window columns
        \\      --rows <N>           Override window rows
        \\
        \\Environment:
        \\  LEANTTY_CONFIG            Configuration file path (used when --config-file is absent)
        \\
        \\Default configuration file: {s}
        \\
    , .{default_path}) catch {};
}

/// 命令行解析结果（与 Rust 的 Cli 枚举对应）。
const Cli = union(enum) {
    help,
    version,
    run: struct {
        config_file: ?[]const u8 = null,
        command: []const []const u8 = &.{},
        cwd: ?[]const u8 = null,
        font: ?[]const u8 = null,
        font_size: ?[]const u8 = null,
        cols: ?[]const u8 = null,
        rows: ?[]const u8 = null,
    },
};

fn parseCli(args: []const []const u8) Cli {
    var r: Cli = .{ .run = .{} };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) return .help;
        if (std.mem.eql(u8, a, "-V") or std.mem.eql(u8, a, "--version")) return .version;
        if (std.mem.eql(u8, a, "--config-file") or std.mem.eql(u8, a, "--config")) {
            if (i + 1 < args.len) {
                r.run.config_file = args[i + 1];
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, a, "--config-file=")) {
            r.run.config_file = a["--config-file=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--config=")) {
            r.run.config_file = a["--config=".len..];
            continue;
        }
        if (std.mem.eql(u8, a, "--working-directory")) {
            if (i + 1 < args.len) {
                r.run.cwd = args[i + 1];
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, a, "--working-directory=")) {
            r.run.cwd = a["--working-directory=".len..];
            continue;
        }
        if (std.mem.eql(u8, a, "-e") or std.mem.eql(u8, a, "--command")) {
            if (i + 1 < args.len) {
                r.run.command = args[i + 1 ..];
            }
            return r; // 其后所有参数都属于被运行的程序
        }
        if (std.mem.eql(u8, a, "--font")) {
            if (i + 1 < args.len) {
                r.run.font = args[i + 1];
                i += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--font-size")) {
            if (i + 1 < args.len) {
                r.run.font_size = args[i + 1];
                i += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--cols")) {
            if (i + 1 < args.len) {
                r.run.cols = args[i + 1];
                i += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--rows")) {
            if (i + 1 < args.len) {
                r.run.rows = args[i + 1];
                i += 1;
            }
            continue;
        }
        // 未知参数：与 Rust 一致，报错退出（Rust 返回 CliError 由调用方 exit 2）
        std.debug.print("leantty: unknown option '{s}'\n", .{a});
        std.process.exit(2);
    }
    return r;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const env = init.environ_map;
    // 配置解析会产生若干组合键字符串（toml.parse 用 allocPrint），且 cfg 里的
    // family/绑定等切片指向它们：用 arena 统一持有到进程结束，避免逐条泄漏。
    var cfg_arena = std.heap.ArenaAllocator.init(alloc);
    defer cfg_arena.deinit();
    const cfg_alloc = cfg_arena.allocator();

    var argv_buf: [128][]const u8 = undefined;
    var argc: usize = 0;
    var args_storage: ?std.ArrayList([]const u8) = null;
    defer if (args_storage) |*a| a.deinit(alloc);
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
        defer it.deinit();
        var first = true;
        while (it.next()) |arg| {
            if (first) {
                first = false;
                continue;
            }
            if (argc == argv_buf.len) break;
            if (is_windows) {
                const owned = try alloc.dupe(u8, arg);
                if (args_storage == null) args_storage = .empty;
                try args_storage.?.append(alloc, owned);
                argv_buf[argc] = args_storage.?.items[args_storage.?.items.len - 1];
            } else {
                argv_buf[argc] = arg;
            }
            argc += 1;
        }
    }

    var path_buf: [512]u8 = undefined;
    const default_path = configPath(env, null, &path_buf) orelse "(HOME/XDG_CONFIG_HOME 未设置)";

    const cli = parseCli(argv_buf[0..argc]);
    switch (cli) {
        .help => {
            var buf: [4096]u8 = undefined;
            var w = std.Io.File.stdout().writer(init.io, &buf);
            helpText(&w.interface, default_path);
            try w.interface.flush();
            return;
        },
        .version => {
            var buf: [128]u8 = undefined;
            var w = std.Io.File.stdout().writer(init.io, &buf);
            w.interface.print("leantty {s}\n", .{version}) catch {};
            try w.interface.flush();
            return;
        },
        .run => |run| {
            var cfg: config.Config = .{};

            // 1) 配置文件（最低优先级）
            if (configPath(env, run.config_file, &path_buf)) |path| {
                const n = if (is_windows)
                    w32_read_file(path, &file_buf, file_buf.len)
                else
                    x11.tty_read_file(path, &file_buf, file_buf.len);
                if (n > 0) {
                    const decoded = decodeConfigText(file_buf[0..@intCast(n)]);
                    var warnings: std.ArrayList(u8) = .empty;
                    defer warnings.deinit(cfg_alloc); // 与 applyToml 的 append 同一 allocator
                    config.applyToml(&cfg, cfg_alloc, decoded, &warnings) catch {};
                    if (warnings.items.len > 0) std.debug.print("{s}", .{warnings.items});
                }
            }

            // 2) 环境变量
            const env_keys = [_][]const u8{
                "SHELL",         "APP_COLS",   "APP_ROWS",   "APP_FONT_FAMILY",
                "APP_FONT_SIZE", "APP_CELL_W", "APP_CELL_H", "APP_DUMP_SNAPSHOT",
            };
            for (env_keys) |k| {
                if (env.get(k)) |v| config.apply(&cfg, k, v);
            }

            // 3) 命令行（最高优先级）
            if (run.font) |v| config.apply(&cfg, "font_family", v);
            if (run.font_size) |v| config.apply(&cfg, "font_size", v);
            if (run.cols) |v| config.apply(&cfg, "cols", v);
            if (run.rows) |v| config.apply(&cfg, "rows", v);

            // 传给 C 侧的字符串需要 NUL 结尾
            var font_family: ?[*:0]const u8 = null;
            if (cfg.font_family) |f| {
                if (f.len + 1 <= font_family_buf.len) {
                    @memcpy(font_family_buf[0..f.len], f);
                    font_family_buf[f.len] = 0;
                    font_family = @ptrCast(&font_family_buf);
                }
            }
            var dump_path: ?[]const u8 = null;
            if (cfg.dump_path) |d| {
                if (d.len + 1 <= dump_buf.len) {
                    @memcpy(dump_buf[0..d.len], d);
                    dump_buf[d.len] = 0;
                    dump_path = dump_buf[0..d.len];
                }
            }

            // 回退字体族 → NUL 结尾
            var fallbacks: [8]?[*:0]const u8 = .{ null, null, null, null, null, null, null, null };
            var n_fallback: usize = 0;
            for (cfg.font_fallbacks) |maybe| {
                const f = maybe orelse continue;
                if (f.len + 1 > fallback_bufs[n_fallback].len) continue;
                @memcpy(fallback_bufs[n_fallback][0..f.len], f);
                fallback_bufs[n_fallback][f.len] = 0;
                fallbacks[n_fallback] = @ptrCast(&fallback_bufs[n_fallback]);
                n_fallback += 1;
            }
            // 内置兜底：Symbola 提供单色 emoji/符号（alacritty 也是用单色符号字体渲染
            // 这些码点）。用户配置的回退链优先，这里只在末尾补，找不到会被 fontconfig 跳过。
            if (n_fallback < fallbacks.len) {
                const extra = [_][]const u8{ "Noto Color Emoji", "Symbola" };
                for (extra) |name| {
                    if (n_fallback >= fallbacks.len) break;
                    if (name.len + 1 > fallback_bufs[n_fallback].len) continue;
                    var dup = false;
                    for (fallbacks[0..n_fallback]) |fb| {
                        if (std.mem.eql(u8, std.mem.span(fb.?), name)) dup = true;
                    }
                    if (dup) continue;
                    @memcpy(fallback_bufs[n_fallback][0..name.len], name);
                    fallback_bufs[n_fallback][name.len] = 0;
                    fallbacks[n_fallback] = @ptrCast(&fallback_bufs[n_fallback]);
                    n_fallback += 1;
                }
            }

            // 键绑定：过滤空项后传给 app
            var bindings: [16]config.KeyBinding = undefined;
            var n_bindings: usize = 0;
            for (cfg.keybindings) |maybe| {
                const b = maybe orelse continue;
                if (b.key.len == 0 or b.action.len == 0) continue;
                if (n_bindings >= bindings.len) break;
                bindings[n_bindings] = b; // 整条拷贝：mods 不能丢
                n_bindings += 1;
            }

            cfg.command = run.command;

            // 字号语义对齐 alacritty：font.size 是**点**，像素 = 点 * dpi / 72。
            // 之前直接当像素用，在 Xft.dpi=144 的机器上字只有 alacritty 的一半，
            // 看起来"虚、模糊"（同配置并排实测：alacritty 单元格 17x37，我们 9x17）。
            // APP_FONT_SIZE 保留像素语义（e2e/bench 依赖确定尺寸）。
            if (env.get("APP_FONT_SIZE") == null) {
                // Windows 侧由 win32.c 自己按 GetDpiForWindow 缩放，这里只用 96 做点→逻辑像素；
                // Linux 侧读 Xft.dpi（winit/x11 的 96 基准同上）。
                const dpi_raw: c_int = if (comptime is_windows) 96 else x11.tty_x_dpi();
                const dpi: f64 = if (dpi_raw > 0) @floatFromInt(dpi_raw) else 96.0;
                const px_f = @as(f64, @floatFromInt(cfg.font_size)) * dpi / 72.0;
                const px: u32 = @intFromFloat(@round(@max(px_f, 4.0)));
                cfg.font_size = @min(px, 512);
            }

            // 鼠标绑定：同样过滤空项
            var mouse_bindings: [16]config.MouseBinding = undefined;
            var n_mouse: usize = 0;
            for (cfg.mouse_bindings) |maybe| {
                const b = maybe orelse continue;
                if (b.button.len == 0 or b.action.len == 0) continue;
                if (n_mouse >= mouse_bindings.len) break;
                mouse_bindings[n_mouse] = b;
                n_mouse += 1;
            }

            if (comptime is_windows) {
                try app_win.run(alloc, cfg);
                return;
            }

            try app.run(alloc, .{
                .keybindings = bindings[0..n_bindings],
                .mouse_bindings = mouse_bindings[0..n_mouse],
                .backend = cfg.backend,
                .dynamic_title = cfg.dynamic_title,
                .cursor_blink = cfg.cursor_blink,
                .cursor_style = cfg.cursor_style,
                .shell = cfg.shell,
                .font_fallbacks = fallbacks[0..n_fallback],
                .font_styles = .{ cfg.font_normal, cfg.font_bold, cfg.font_italic, cfg.font_bold_italic },
                .cols = cfg.cols,
                .rows = cfg.rows,
                .font_family = font_family,
                .font_size = cfg.font_size,
                .cell_w = cfg.cell_w,
                .cell_h = cfg.cell_h,
                .dump_path = dump_path,
                .command = run.command,
                .cwd = run.cwd,
                .scrollback_lines = cfg.scrollback_lines,
                .save_to_clipboard = cfg.save_to_clipboard,
                .window_x = cfg.window_x,
                .window_y = cfg.window_y,
                .colors_bg = cfg.colors_bg,
                .colors_fg = cfg.colors_fg,
                .colors_cursor = cfg.colors_cursor,
                .colors_cursor_text = cfg.colors_cursor_text,
                .colors_selection_bg = cfg.colors_selection_bg,
                .colors_selection_fg = cfg.colors_selection_fg,
                .colors_palette = cfg.colors_palette,
                .colors_bold_bright = cfg.colors_bold_bright,
            });
        },
    }
}
