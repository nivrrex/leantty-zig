#!/bin/sh
# 跨平台字体黄金文件校验：同一批字体 + 同一批码点，Linux（系统 FreeType）与
# Windows（vendored FreeType，经 wine 运行）各生成一份，逐字节比对。
#
# 用法：sh scripts/golden-check.sh
# 说明：
#   - 只比较"度量 + 单色字形位图哈希"，这两项必须逐字节一致；
#   - 彩色字形受字体格式影响（Linux 的系统 FreeType 带 PNG 支持 → CBDT 可用；
#     vendored 构建未带 libpng → CBDT 不支持），因此不进入逐字节比对，单独打印。
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1
ZIG="${ZIG:-zig}"
SYSTEM_ARGS=""
[ -d "${SYSTEM:-../vt-verify/zig-system}" ] && SYSTEM_ARGS="--system ${SYSTEM:-../vt-verify/zig-system}"
OUT="$ROOT/tests/golden"
FONTS=/tmp/gf

mkdir -p "$OUT"
if [ ! -f "$FONTS/main.ttf" ]; then
    mkdir -p "$FONTS"
    cp /usr/share/fonts/chinese/consola.ttf "$FONTS/main.ttf"
    cp /usr/share/fonts/truetype/wqy/wqy-zenhei.ttc "$FONTS/cjk.ttc"
    cp /usr/share/fonts/truetype/noto/NotoColorEmoji.ttf "$FONTS/emoji.ttf" 2>/dev/null
fi

CPS="41 67 6c 4F60 597D"

echo "== 构建 golden（Linux / Windows）=="
"$ZIG" build $SYSTEM_ARGS -Dwith-golden=true >/dev/null 2>&1 || { echo "linux golden build failed"; exit 1; }
"$ZIG" build -Dtarget=x86_64-windows-gnu -Dcpu=baseline -Dwith-golden=true --cache-dir .zig-cache-w64 $SYSTEM_ARGS >/dev/null 2>&1 \
    || { echo "windows golden build failed"; exit 1; }

echo "== Linux 侧 =="
./zig-out/bin/golden 32 "$FONTS/main.ttf" "$FONTS/cjk.ttc" -- $CPS > "$OUT/linux-x86_64.txt"
cat "$OUT/linux-x86_64.txt"

echo "== Windows 侧（wine，同一批字体）=="
cp "$FONTS/main.ttf" /tmp/w64/drive_c/main.ttf 2>/dev/null
cp "$FONTS/cjk.ttc" /tmp/w64/drive_c/cjk.ttc 2>/dev/null
if [ -d /tmp/w64/drive_c ]; then
    WINEARCH=win64 WINEPREFIX=/tmp/w64 WINEDEBUG=-all \
        wine zig-out/bin/golden.exe 32 'C:\main.ttf' 'C:\cjk.ttc' -- $CPS 2>/dev/null \
        | tr -d '\r' > "$OUT/windows-x86_64-wine.txt"
    cat "$OUT/windows-x86_64-wine.txt"
else
    echo "（wine 前缀 /tmp/w64 不存在，跳过 Windows 侧）"
fi

echo "== 逐字节比对 =="
if [ -f "$OUT/windows-x86_64-wine.txt" ]; then
    if diff -u "$OUT/linux-x86_64.txt" "$OUT/windows-x86_64-wine.txt"; then
        echo "PASS 字体度量与单色字形位图在两平台逐字节一致"
    else
        echo "FAIL 两平台字体输出不一致（见上面 diff）"
        exit 1
    fi
fi
