# 构建 leantty-zig

## 依赖

| 项 | 版本 / 说明 |
|---|---|
| Zig | 0.17.x（开发用 0.17.1） |
| libghostty 源码 | pin 在提交 `0b8b9984e`（与 Rust 版 `leantty` 同一个 pin） |
| FreeType | Linux 用系统包（`libfreetype-dev`）；Windows 构建用仓库内 vendored 副本 |
| fontconfig | 仅 Linux（`libfontconfig-dev`） |
| X11 / Xext / GL / GLX | 仅 Linux（`libx11-dev`、`libxext-dev`、`libgl1-mesa-dev`） |
| IBus + GLib | 仅 Linux，且**只需头文件**（`libibus-1.0-dev`、`libglib2.0-dev`）：库在运行期 `dlopen`，不参与链接 |
| mingw windres | 仅生成 Windows 图标资源时用（`binutils-mingw-w64-x86-64`） |

## `build.zig.zon` 期望的目录

VT 核心声明为本地路径依赖：

```zig
.ghostty = .{ .path = ".deps/ghostty-src" },
```

一条命令满足它：

```sh
./scripts/fetch-ghostty.sh      # 克隆 pin 0b8b9984e 到 .deps/ghostty-src（约 230 MB）
```

已经有 ghostty 检出？把它软链或移动成 `.deps/ghostty-src`，或直接改 `build.zig.zon` 里那一行路径。

## Linux

```sh
zig build -Doptimize=ReleaseFast              # → zig-out/bin/leantty
zig build test                                # 单元测试
sh scripts/e2e/run_all.sh                     # Xvfb 下的端到端用例
```

可选参数：`-Dfreetype-include=...`、`-Dibus-include=...`（头文件不在常规位置时）；
`--system <目录>` 仅在离线复用预取依赖时需要，正常在线构建可省略。

## Windows（在 Linux 上交叉编译）

```sh
zig build -Dtarget=x86_64-windows-gnu -Dcpu=baseline -Doptimize=ReleaseFast
```

Windows 目标会用仓库内的 `vendor/freetype` 编译 FreeType，并用 `x86_64-w64-mingw32-windres`
预编译图标资源 `assets/icon/leantty.rc`（该命令须在 `PATH` 上）。

## 打包

```sh
sh scripts/package-deb.sh <版本号>     # dist/leantty-zig_<版本号>_amd64.deb
sh scripts/package-windows.sh <版本号> # dist/leantty-zig-<版本号>-windows-x86_64.zip
```

两个脚本都会先重新构建，再在 `build/` 下组织文件并把产物写到 `dist/`。

图标由 `assets/icon/leantty.svg` 生成；PNG 与 `leantty.ico` 已随仓库提交，打包不需要
`rsvg-convert`，需要重新生成时：

```sh
for s in 16 24 32 48 64 128 256 512; do
  rsvg-convert -w $s -h $s assets/icon/leantty.svg -o assets/icon/png/leantty-$s.png
done
convert assets/icon/png/leantty-{16,24,32,48,64,128,256}.png assets/icon/leantty.ico
```
