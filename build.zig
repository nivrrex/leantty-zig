const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    // Windows 目标默认用 gnu ABI + baseline CPU：本机没有 MSVC/Windows SDK，msvc 目标
    // 直接报 LibCStdLibHeaderNotFound；而默认解析（native）的 Debug 测试构建下，
    // ghostty 的宽度查表把「你好」判成窄字符，vt_test V4e/V8 两条用例稳定失败
    // （2/2 次、清空缓存可复现），显式 baseline 稳定 26/26 全绿。指令级原因未定位，
    // 先固定 baseline 保证可复现。显式 -Dtarget / -Dcpu 仍然覆盖这里。
    const target = b.standardTargetOptions(.{
        .default_target = if (builtin.os.tag == .windows) .{
            .abi = .gnu,
            .cpu_model = .baseline,
        } else .{},
    });
    const optimize = b.standardOptimizeOption(.{});
    // Debian/Devuan 的 FreeType 头文件不在默认搜索路径下，用构建选项传入，
    // 不在源码里硬编码本机路径。
    const freetype_include = b.option(
        []const u8,
        "freetype-include",
        "FreeType 头文件目录（ft2build.h 所在）",
    ) orelse "/usr/include/freetype2";

    const dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"app-runtime" = "none",
    });

    // Release 构建默认 strip：Zig 的 ReleaseFast 会带整套 DWARF，
    // 不 strip 时产物从 2.3 MB 涨到 12.4 MB（纯调试信息）。
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .debug,
    });
    mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    const is_windows = target.result.os.tag == .windows;
    if (is_windows) {
        mod.addCSourceFile(.{
            .file = b.path("src/win32.c"),
            .flags = &.{ "-std=c11", "-O2" },
        });
        // 字体层与 Linux 共用一份 FreeType 光栅器（"FreeType everywhere"）：
        // 直接编 vendored FreeType，避免 Windows 侧再走 GDI（无彩色字形、无 >BMP cmap）。
        mod.addCSourceFile(.{
            .file = b.path("src/font_ft.c"),
            .flags = &.{ "-std=c11", "-O2" },
        });
        mod.addIncludePath(b.path("vendor/freetype/include"));
        mod.addIncludePath(b.path("vendor/freetype/src"));
        mod.addIncludePath(b.path("vendor/freetype"));
        mod.addIncludePath(b.path("vendor/freetype/src/gzip"));
        const ft_flags = [_][]const u8{
            "-std=c11",
            "-O2",
            "-DFT2_BUILD_LIBRARY",
            "-DFT_CONFIG_MODULES_H=\"ftmodule.h\"",
            "-DFT_CONFIG_OPTIONS_H=\"ftoption_custom.h\"",
        };
        const ft_sources = [_][]const u8{
            "src/base/ftbase.c",     "src/base/ftsystem.c", "src/base/ftinit.c",
            "src/base/ftdebug.c",    "src/base/ftmm.c",     "src/base/ftsynth.c",
            "src/base/ftbitmap.c",   "src/base/ftglyph.c",  "src/gzip/ftgzip.c",
            "src/autofit/autofit.c", "src/cff/cff.c",       "src/psaux/psaux.c",
            "src/pshinter/pshinter.c", "src/psnames/psnames.c", "src/raster/raster.c",
            "src/sfnt/sfnt.c",       "src/smooth/smooth.c", "src/truetype/truetype.c",
            "src/sdf/sdf.c",         "src/gzip/ftgzip.c",
        };
        for (ft_sources) |src| {
            mod.addCSourceFile(.{
                .file = b.path(b.fmt("vendor/freetype/{s}", .{src})),
                .flags = &ft_flags,
            });
        }
        // 图标资源（与 Rust 版同一份 leantty.svg 生成的 .ico）：用 mingw windres 预编译成 COFF 对象。
        // 构建前若缺少对象则在此生成，保证 -Dtarget=windows 时 exe 一定带图标。
        const icon_rc = b.path("assets/icon/leantty.rc");
        const icon_obj = b.addSystemCommand(&.{
            "x86_64-w64-mingw32-windres",
            "-i",
        });
        icon_obj.addFileArg(icon_rc);
        icon_obj.addArgs(&.{ "-O", "coff", "-o" });
        const icon_out = icon_obj.addOutputFileArg("leantty_icon.o");
        icon_obj.setCwd(b.path("assets/icon"));
        mod.addObjectFile(icon_out);
    } else {
        mod.addCSourceFile(.{
            .file = b.path("src/shim.c"),
            .flags = &.{ "-std=c11", "-O2", "-Wall", "-Wextra" },
        });
        mod.addCSourceFile(.{
            .file = b.path("src/font_ft.c"),
            .flags = &.{ "-std=c11", "-O2", "-Wall", "-Wextra" },
        });
    }
    // IBus（内联预编辑）：依赖 libibus + glib。路径用构建选项传入，
    // 默认值是 Debian/Devuan 上的常见位置，可覆盖。
    const ibus_include = b.option(
        []const u8,
        "ibus-include",
        "IBus/GLib 头文件目录（逗号分隔）",
    ) orelse "/usr/local/include/ibus-1.0,/usr/include/glib-2.0,/usr/lib/x86_64-linux-gnu/glib-2.0/include";
    if (!is_windows) {
        mod.addCSourceFile(.{
            .file = b.path("src/ibus.c"),
            .flags = &.{ "-std=c11", "-O2" },
        });
    }
    if (!is_windows) {
        var inc_it = std.mem.tokenizeAny(u8, ibus_include, ",:");
        while (inc_it.next()) |inc| mod.addIncludePath(.{ .cwd_relative = inc });
        mod.linkSystemLibrary("ibus-1.0", .{});
        mod.linkSystemLibrary("glib-2.0", .{});
        mod.linkSystemLibrary("gobject-2.0", .{});
    }
    mod.addIncludePath(b.path("src"));
    if (!is_windows) {
        mod.addIncludePath(.{ .cwd_relative = freetype_include });
        mod.linkSystemLibrary("X11", .{});
        mod.linkSystemLibrary("Xext", .{});
        mod.linkSystemLibrary("fontconfig", .{});
        mod.linkSystemLibrary("freetype", .{});
        mod.linkSystemLibrary("util", .{});
        // GPU 呈现：GLX + OpenGL（llvmpipe 也可用）
        mod.linkSystemLibrary("GL", .{});
        mod.linkSystemLibrary("GLX", .{});
    } else {
        mod.linkSystemLibrary("gdi32", .{});
        mod.linkSystemLibrary("user32", .{});
        // IME：ImmGetContext / ImmSetCompositionWindow / ImmSetCandidateWindow
        mod.linkSystemLibrary("imm32", .{});
    }

    const exe = b.addExecutable(.{ .name = "leantty", .root_module = mod });
    b.installArtifact(exe);

    // 单元测试：只覆盖 VT 层（不依赖 X11/字体），与 e2e 的黑盒断言互补。
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/vt_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    // 渲染基准 + full/dirty 逐帧对拍（需要字体，故带上 shim）
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    bench_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    bench_mod.addCSourceFile(.{
        .file = b.path("src/shim.c"),
        .flags = &.{ "-std=c11", "-O2" },
    });
    bench_mod.addIncludePath(b.path("src"));
    bench_mod.addIncludePath(.{ .cwd_relative = freetype_include });
    bench_mod.linkSystemLibrary("X11", .{});
    bench_mod.linkSystemLibrary("Xext", .{});
    bench_mod.linkSystemLibrary("fontconfig", .{});
    bench_mod.linkSystemLibrary("freetype", .{});
    bench_mod.linkSystemLibrary("util", .{});
    bench_mod.linkSystemLibrary("GL", .{});
    bench_mod.linkSystemLibrary("GLX", .{});
    const bench = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench);
    b.step("bench", "渲染基准 + full/dirty 对拍").dependOn(&run_bench.step);

    // 跨平台字体黄金文件工具（控制台程序，wine 下可跑，用于 Linux/Windows 字形层对拍）：
    //   zig build -Dwith-golden=true            → zig-out/bin/golden
    //   zig build -Dwith-golden=true -Dtarget=x86_64-windows-gnu ... → golden.exe
    if (b.option(bool, "with-golden", "构建 tools/golden 字体黄金文件工具") orelse false) {
        const gmod = b.createModule(.{ .target = target, .optimize = optimize });
        gmod.addCSourceFile(.{ .file = b.path("src/font_ft.c"), .flags = &.{ "-std=c11", "-O2" } });
        gmod.addCSourceFile(.{ .file = b.path("tools/golden.c"), .flags = &.{ "-std=c11", "-O2" } });
        gmod.link_libc = true;
        if (is_windows) {
            gmod.addIncludePath(b.path("vendor/freetype/include"));
            gmod.addIncludePath(b.path("vendor/freetype/src"));
            gmod.addIncludePath(b.path("vendor/freetype"));
            gmod.addIncludePath(b.path("vendor/freetype/src/gzip"));
            const gflags = [_][]const u8{
                "-std=c11", "-O2", "-DFT2_BUILD_LIBRARY",
                "-DFT_CONFIG_MODULES_H=\"ftmodule.h\"",
                "-DFT_CONFIG_OPTIONS_H=\"ftoption_custom.h\"",
            };
            const gsrc = [_][]const u8{
                "src/base/ftbase.c",       "src/base/ftsystem.c",  "src/base/ftinit.c",
                "src/base/ftdebug.c",      "src/base/ftmm.c",      "src/base/ftsynth.c",
                "src/base/ftbitmap.c",     "src/base/ftglyph.c",   "src/gzip/ftgzip.c",
                "src/autofit/autofit.c",   "src/cff/cff.c",        "src/psaux/psaux.c",
                "src/pshinter/pshinter.c", "src/psnames/psnames.c", "src/raster/raster.c",
                "src/sfnt/sfnt.c",         "src/smooth/smooth.c",  "src/truetype/truetype.c",
                "src/sdf/sdf.c",           "src/gzip/ftgzip.c",
            };
            for (gsrc) |g| {
                gmod.addCSourceFile(.{
                    .file = b.path(b.fmt("vendor/freetype/{s}", .{g})),
                    .flags = &gflags,
                });
            }
        } else {
            gmod.addIncludePath(.{ .cwd_relative = freetype_include });
            gmod.linkSystemLibrary("freetype", .{});
        }
        const gexe = b.addExecutable(.{ .name = "golden", .root_module = gmod });
        b.installArtifact(gexe);
    }

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "运行 VT 层单元测试").dependOn(&run_tests.step);
    b.step("run", "运行 leantty").dependOn(&b.addRunArtifact(exe).step);
}
