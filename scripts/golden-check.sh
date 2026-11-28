#!/bin/sh
# 跨平台字体黄金文件校验：同一批字体 + 同一批码点，Linux（系统 FreeType）与
# Windows（vendored FreeType，经 wine 运行）各生成一份，逐字节比对。
#
# 用法：sh scripts/golden-check.sh
# 返回：0=通过；1=构建/运行/比对失败；2=缺少 Windows/wine 环境，未验证。
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
ZIG="${ZIG:-zig}"
SYSTEM="${SYSTEM:-}"
OUT="${GOLDEN_OUT:-$ROOT/tests/golden}"
WINE_PREFIX="${WINE_PREFIX:-/tmp/w64}"
MAIN_FONT="${MAIN_FONT:-/usr/share/fonts/chinese/consola.ttf}"
CJK_FONT="${CJK_FONT:-/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$OUT" "$WORK/fonts"

for font in "$MAIN_FONT" "$CJK_FONT"; do
  [ -f "$font" ] || {
    echo "FATAL: 字体不存在: $font" >&2
    exit 1
  }
done
cp "$MAIN_FONT" "$WORK/fonts/main.ttf"
cp "$CJK_FONT" "$WORK/fonts/cjk.ttc"

zig_build() {
  if [ -n "$SYSTEM" ]; then
    "$ZIG" build --system "$SYSTEM" "$@"
  else
    "$ZIG" build "$@"
  fi
}

echo "== 构建 golden（Linux / Windows）=="
zig_build -Dwith-golden=true
zig_build -Dtarget=x86_64-windows-gnu -Dcpu=baseline -Dwith-golden=true --cache-dir .zig-cache-w64

echo "== Linux 侧 =="
./zig-out/bin/golden 32 "$WORK/fonts/main.ttf" "$WORK/fonts/cjk.ttc" -- 41 67 6c 4f60 597d >"$WORK/linux.txt"

if [ ! -d "$WINE_PREFIX/drive_c" ]; then
  rm -f "$OUT/windows-x86_64-wine.txt"
  echo "SKIP: wine 前缀不存在：$WINE_PREFIX（Windows 侧未验证）" >&2
  exit 2
fi
command -v wine >/dev/null 2>&1 || {
  echo "FATAL: 未找到 wine" >&2
  exit 1
}

cp "$WORK/fonts/main.ttf" "$WINE_PREFIX/drive_c/main.ttf"
cp "$WORK/fonts/cjk.ttc" "$WINE_PREFIX/drive_c/cjk.ttc"
echo "== Windows 侧（wine，同一批字体）=="
if ! WINEARCH=win64 WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all \
  wine zig-out/bin/golden.exe 32 'C:\main.ttf' 'C:\cjk.ttc' -- 41 67 6c 4f60 597d >"$WORK/windows.raw"; then
  echo "FAIL: Windows golden 运行失败" >&2
  exit 1
fi
tr -d '\r' <"$WORK/windows.raw" >"$WORK/windows.txt"

echo "== 逐字节比对 =="
diff -u "$WORK/linux.txt" "$WORK/windows.txt"
cp "$WORK/linux.txt" "$OUT/linux-x86_64.txt"
cp "$WORK/windows.txt" "$OUT/windows-x86_64-wine.txt"
echo "PASS 字体度量与单色字形位图在两平台逐字节一致"
