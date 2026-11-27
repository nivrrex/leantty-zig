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
extern fn w32_file_exists(path: [*:0]const u8) c_int;
extern fn w32_init_console() void;

const version = "0.1.24";

var file_buf: [64 * 1024]u8 = undefined;
var font_family_buf: [256]u8 = undefined;
var dump_buf: [512]u8 = undefined;
var fallback_bufs: [8][128]u8 = undefined;

/// 配置文件文本解码：
///   - UTF-8 BOM（EF BB BF）剥掉。Windows 编辑器/PowerShell 重定向常写 BOM，
///     带 BOM 时首个 `[section]` 解析失败、整段键退化成顶层未知字段（实测配色完全不生效）。
///   - UTF-16 BOM（FF FE / FE FF）就地转 UTF-8。
///   - 其它原样返回（CRLF 由 TOML 解析器容忍，实测无需处理）。
/// 便携配置是否存在：只做一次 stat，不存在就当没有（不报错）。
fn portable_exists(env: anytype, dir: []const u8) bool {
    _ = env;
    var buf: [512]u8 = undefined;
    const sep = if (is_windows) "\\" else "/";
    const path = std.fmt.bufPrint(&buf, "{s}{s}leantty.toml", .{ dir, sep }) catch return false;
    if (is_windows) {
        var wbuf: [512]u8 = undefined;
        if (path.len + 1 > wbuf.len) return false;
        @memcpy(wbuf[0..path.len], path);
        wbuf[path.len] = 0;
        return w32_file_exists(@ptrCast(&wbuf)) != 0;
    }
    var zbuf: [512]u8 = undefined;
    if (path.len + 1 > zbuf.len) return false;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    return x11.tty_file_exists(@ptrCast(&zbuf)) != 0;
}

fn path_is_file(path: [:0]const u8) bool {
    if (is_windows) return w32_file_exists(path.ptr) != 0;
    return x11.tty_file_exists(path.ptr) != 0;
}

fn configPath(env: anytype, cli: ?[]const u8, exe_dir: ?[]const u8, out: *[512]u8) ?[:0]const u8 {
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
    // 平台默认位置（可能存在也可能不存在）
    var def_buf: [512]u8 = undefined;
    const def: ?[:0]const u8 = blk: {
        if (env.get("XDG_CONFIG_HOME")) |v| {
            if (v.len > 0) break :blk join(&def_buf, &.{ v, "/leantty/leantty.toml" });
        }
        // Windows 没有 HOME 也没有 XDG_CONFIG_HOME（cmd.exe 下都为空），
        // 之前因此读不到配置 → 用户看到"配置不生效、仍是黑底"。
        if (is_windows) {
            if (env.get("APPDATA")) |v| {
                if (v.len > 0) break :blk join(&def_buf, &.{ v, "\\leantty\\leantty.toml" });
            }
            if (env.get("USERPROFILE")) |v| {
                if (v.len > 0) break :blk join(&def_buf, &.{ v, "\\.config\\leantty\\leantty.toml" });
            }
        }
        if (env.get("HOME")) |v| {
            if (v.len > 0) break :blk join(&def_buf, &.{ v, "/.config/leantty/leantty.toml" });
        }
        break :blk null;
    };
    if (def) |d| {
        // `d` 指向本函数栈上的 def_buf：必须复制进调用方的 out 再返回，
        // 否则返回的是悬空指针（0.1.12 起 %APPDATA% / XDG_CONFIG_HOME 分支
        // 打印出来的路径是对的、但随后 fopen 读的是被覆盖的栈内容 →
        // 表现为"config: 读不到该文件，使用默认值"，配置整份不生效）。
        if (path_is_file(d)) return join(out, &.{d});
        // 用户没有自己的配置时，退到"可执行文件同目录的 leantty.toml"（便携包用它）。
        // 顺序很重要：便携配置不能盖掉用户配置，否则改 ~/.config / %APPDATA% 会突然失效。
        if (exe_dir) |dir| {
            if (portable_exists(env, dir)) {
                if (join(out, &.{ dir, if (is_windows) "\\leantty.toml" else "/leantty.toml" })) |pp| return pp;
            }
        }
        return join(out, &.{d}); // 都不存在：把默认路径交回去，让启动日志能提示"读不到该文件"
    }
    if (exe_dir) |dir| {
        if (portable_exists(env, dir)) {
            if (join(out, &.{ dir, if (is_windows) "\\leantty.toml" else "/leantty.toml" })) |pp| return pp;
        }
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

/// `$SHELL` 是否是可直接 exec 的绝对路径（存在且可执行）。
fn shellUsable(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    std.Io.Dir.accessAbsolute(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
    return true;
}

/// `/bin/sh`、`/usr/bin/sh`、`sh` 这类 POSIX 兜底值：会话环境常这么设，
/// 但它不是用户的交互 shell（bash 以 sh 身份运行 → 提示符 `sh-5.2#`）。
fn isPosixShPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "sh") or
        std.mem.eql(u8, path, "/bin/sh") or
        std.mem.eql(u8, path, "/usr/bin/sh");
}

pub fn main(init: std.process.Init) !void {
    // GUI 子系统下 stderr 一开始是无效句柄：配置解析告警、`config:` 路径这类启动期输出
    // 必须在接上父控制台/日志文件之后再打，否则全部丢失（第五轮实机取证发现）。
    if (comptime is_windows) w32_init_console();
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

    // 可执行文件所在目录（便携配置 leantty.toml 就放在这里）
    var exe_dir_buf: [512]u8 = undefined;
    const exe_dir: ?[]const u8 = blk: {
        var pb: [512]u8 = undefined;
        const n = std.process.executablePath(init.io, &pb) catch break :blk null;
        const dir = std.fs.path.dirname(pb[0..n]) orelse break :blk null;
        if (dir.len == 0 or dir.len >= exe_dir_buf.len) break :blk null;
        @memcpy(exe_dir_buf[0..dir.len], dir);
        break :blk exe_dir_buf[0..dir.len];
    };

    var path_buf: [512]u8 = undefined;
    const default_path = configPath(env, null, exe_dir, &path_buf) orelse "(HOME/XDG_CONFIG_HOME 未设置)";

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
            //    启动时打印实际使用的路径：Windows 上 `%APPDATA%\leantty\leantty.toml`、
            //    可执行文件同目录的便携配置、`LEANTTY_CONFIG` 都可能存在，
            //    改错文件时"改了没生效"很难发现（见 REPORT 6.62）。
            if (configPath(env, run.config_file, exe_dir, &path_buf)) |path| {
                config.setWatchPath(path); // 供热加载（general.live_config_reload）重新读取
                std.debug.print("config: {s}\n", .{path});
                const n = if (is_windows)
                    w32_read_file(path, &file_buf, file_buf.len)
                else
                    x11.tty_read_file(path, &file_buf, file_buf.len);
                if (n <= 0) std.debug.print("config: 读不到该文件，使用默认值\n", .{});
                if (n > 0) {
                    const decoded = config.decodeText(file_buf[0..@intCast(n)]);
                    var warnings: std.ArrayList(u8) = .empty;
                    defer warnings.deinit(cfg_alloc); // 与 applyToml 的 append 同一 allocator
                    config.applyToml(&cfg, cfg_alloc, decoded, &warnings) catch {};
                    if (warnings.items.len > 0) std.debug.print("{s}", .{warnings.items});
                }
            }

            if (env.get("LEANTTY_KDBG") != null)
                std.debug.print("kdbg cfg: faint={} opacity={d:.2} bold_bright={}\n",
                    .{ cfg.colors_faint, cfg.colors_faint_opacity, cfg.colors_bold_bright });
            // 2) 环境变量
            const env_keys = [_][]const u8{
                "APP_COLS",   "APP_ROWS",   "APP_FONT_FAMILY",
                "APP_FONT_SIZE", "APP_CELL_W", "APP_CELL_H", "APP_DUMP_SNAPSHOT",
            };
            for (env_keys) |k| {
                if (env.get(k)) |v| config.apply(&cfg, k, v);
            }

            // shell 的优先级：配置文件显式给的 > $SHELL（可信时）> 登录 shell（/etc/passwd）。
            //
            // 两个实测坑：
            //  1) $SHELL 缺失（从 .desktop / 面板启动的常态）时早前兜底 /bin/sh，
            //     提示符变成 `sh-5.2#`（bash 以 sh 身份运行），而 alacritty 用登录 shell；
            //  2) LXDE 这类会话会把 SHELL 设成 `/bin/sh`（系统 shell，不是用户的交互 shell），
            //     照抄它仍然得到 `sh-5.2`。
            // 因此：$SHELL 必须是**存在的绝对路径**才采用；`/bin/sh`、`/usr/bin/sh`、裸 `sh`
            // 这类"POSIX 兜底值"与登录 shell 相同就照用，不同则优先登录 shell。
            if (!cfg.shell_explicit) {
                const login: ?[]const u8 = if (comptime is_windows) null else blk: {
                    const ls = x11.tty_login_shell() orelse break :blk null;
                    break :blk std.mem.span(ls);
                };
                var chosen: []const u8 = "/bin/sh";
                var source: []const u8 = "默认值";
                if (env.get("SHELL")) |v| {
                    if (v.len > 0 and (comptime !is_windows) and shellUsable(v) and !isPosixShPath(v)) {
                        chosen = v;
                        source = "SHELL";
                    }
                }
                if (std.mem.eql(u8, source, "默认值")) {
                    if (login) |ls| {
                        chosen = ls;
                        source = "登录 shell";
                    } else if (env.get("SHELL")) |v| {
                        if (v.len > 0) {
                            chosen = v;
                            source = "SHELL";
                        }
                    }
                }
                cfg.shell = chosen;
                std.debug.print("shell: {s}（来源：{s}）\n", .{ chosen, source });
            } else {
                std.debug.print("shell: {s}（来源：配置文件）\n", .{cfg.shell});
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
                // --working-directory 也要传给 Windows 后端的子进程
                // （之前 app_win 里 w32_spawn 的 cwd 恒为 null，-e 的工作目录被忽略）。
                try app_win.run(alloc, cfg, run.cwd, &cfg);
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
                .colors_bright_white_fg = cfg.colors_bright_white_fg,
                .font_synthetic_bold = cfg.font_synthetic_bold,
                .selection_escape_chars = cfg.selection_escape_chars,
                .colors_faint = cfg.colors_faint,
                .colors_faint_opacity = cfg.colors_faint_opacity,
                .live_reload = cfg.live_reload,
            }, &cfg);
        },
    }
}
