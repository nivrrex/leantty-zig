#!/bin/sh
# 生成 Debian 包（amd64）：leantty-zig_<ver>_amd64.deb
# 用法：sh scripts/package-deb.sh [版本号]
# 依赖：zig 工具链、dpkg-deb、rsvg-convert（图标已预生成为 PNG，正常不需要）
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

VER="${1:?用法: sh scripts/package-deb.sh <版本号>}"
PKG="leantty-zig"
ARCH=amd64
BUILD="$ROOT/build/deb"
STAGE="$BUILD/${PKG}_${VER}_${ARCH}"

ZIG="${ZIG:-zig}"
SYSTEM="${SYSTEM:-}"

zig_build() {
  if [ -n "$SYSTEM" ]; then
    "$ZIG" build --system "$SYSTEM" "$@"
  else
    "$ZIG" build "$@"
  fi
}

# 发布构建必须固定 **baseline** CPU：不加 -Dcpu 时 zig 按构建机的 native CPU 编，
# 生成的二进制会带 AVX/AVX2 指令，在较老的机器上直接 SIGILL（用户实测：本机编的 deb
# 在另一台 office-pc 上 `非法指令`）。基准测试要 native 请显式传 -Dcpu=native。
echo "== 构建（ReleaseFast, cpu=baseline）=="
zig_build -Doptimize=ReleaseFast -Dcpu=baseline

# 提示性检查：产物里仍会看到 AVX/ymm —— 那是 highway / simdutf 的**多版本代码 + 运行时
# cpuid 分派**（它们按检测结果选 SSE/AVX2/AVX512 路径），不是编译时用了 native。
# 真正要紧的是：我们自己的代码与 C shim 必须按 baseline 编（`-Dcpu=baseline` 已传，
# 编译命令里能看到 `-mcpu baseline`）。这里只统计并打印，便于对比"是否意外用了 zmm"。
simd_note=$(objdump -d zig-out/bin/leantty 2>/dev/null | grep -cE "%ymm" || true)
zmm_note=$(objdump -d zig-out/bin/leantty 2>/dev/null | grep -cE "%zmm" || true)
echo "   指令统计：ymm=$simd_note（highway 运行时分派） zmm=$zmm_note"
if [ "${zmm_note:-0}" -gt 0 ]; then
  echo "FATAL: 产物含 AVX-512（zmm）指令，绝大多数机器会 SIGILL" >&2
  exit 1
fi

rm -rf "$BUILD"
mkdir -p "$STAGE/DEBIAN" \
  "$STAGE/usr/bin" \
  "$STAGE/usr/share/applications" \
  "$STAGE/usr/share/doc/$PKG"

echo "== 安装文件 =="
install -m 0755 zig-out/bin/leantty "$STAGE/usr/bin/leantty"
install -m 0644 packaging/linux/leantty.desktop "$STAGE/usr/share/applications/leantty.desktop"
for s in 16 24 32 48 64 128 256 512; do
  d="$STAGE/usr/share/icons/hicolor/${s}x${s}/apps"
  mkdir -p "$d"
  install -m 0644 "assets/icon/png/leantty-$s.png" "$d/leantty.png"
done
install -m 0644 README.md "$STAGE/usr/share/doc/$PKG/README.md"
if [ -f LICENSE ]; then install -m 0644 LICENSE "$STAGE/usr/share/doc/$PKG/copyright"; fi
# 说明与第三方许可（README 里对 vendor/freetype 的引用要能在安装后找到）
install -m 0644 vendor/freetype/docs/FTL.TXT "$STAGE/usr/share/doc/$PKG/FTL.TXT"

echo "== 依赖 =="
# 只列 readelf -d 里直接 NEEDED 的库对应包（ldd 推导会把 glx-diversions 这类
# 转移包、本机自编的 /usr/local 库也算进来，得到的 Depends 不可安装）。
# IBus/GLib/GObject 已在运行期 dlopen（见 src/ibus.c），不再进 Depends：
# 它们的包名跨发行版不稳定（bookworm 的 libglib2.0-0/gobject-2.0-0
# vs trixie 的 *-t64），写死会导致包在别的发行版上装不上。
DEPS="libc6, libx11-6, libxext6, libfontconfig1, libfreetype6, libgl1, libglx0"
# 输入法可选：装了才启用 IBus 内联预编辑
RECOMMENDS="libibus-1.0-5"

SIZE=$(du -sk "$STAGE" | cut -f1)
cat >"$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $VER
Section: x11
Priority: optional
Architecture: $ARCH
Depends: $DEPS
Recommends: $RECOMMENDS
Conflicts: leantty
Replaces: leantty
Installed-Size: $SIZE
Maintainer: leantty-zig contributors <noreply@example.invalid>
Homepage: https://github.com/nivrrex/leantty-zig
Description: Lightweight terminal emulator (Zig implementation)
 A small terminal emulator written in Zig on top of libghostty's VT core.
 .
 Backends: CPU framebuffer or OpenGL (GLX) presentation; IBus input method
 (including Shift-to-toggle), scrollback with scrollbar, selection and
 clipboard, TOML configuration compatible with the Rust leantty.
EOF

echo "== 打包 =="
mkdir -p "$ROOT/dist"
dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$ROOT/dist/${PKG}_${VER}_${ARCH}.deb" >/dev/null
ls -l "$ROOT/dist/${PKG}_${VER}_${ARCH}.deb"
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
dpkg-deb -c "$ROOT/dist/${PKG}_${VER}_${ARCH}.deb" >"$LIST"
sed -n '1,14p' "$LIST"
