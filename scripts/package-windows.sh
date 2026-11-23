#!/bin/sh
# 生成 Windows 便携包：leantty-zig-<ver>-windows-x86_64.zip
# 用法：sh scripts/package-windows.sh [版本号]
# 依赖：zig 工具链、x86_64-w64-mingw32-windres（图标资源）、python3（zip）
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

VER="${1:-0.1.0}"
NAME="leantty-zig-${VER}-windows-x86_64"
BUILD="$ROOT/build/win"
STAGE="$BUILD/$NAME"

ZIG="${ZIG:-/root/Desktop/tty/vt-verify/toolchain/zig/zig}"
SYSTEM="${SYSTEM:-../vt-verify/zig-system}"

echo "== 交叉编译（ReleaseFast，含图标资源）=="
"$ZIG" build -Dtarget=x86_64-windows-gnu -Dcpu=baseline -Doptimize=ReleaseFast \
    --cache-dir .zig-cache-w64 --system "$SYSTEM"

rm -rf "$BUILD"
mkdir -p "$STAGE"
install -m 0755 zig-out/bin/leantty.exe "$STAGE/leantty.exe"
install -m 0644 README.md "$STAGE/README.md"
install -m 0644 LICENSE "$STAGE/LICENSE"
# FreeType 以 FTL 分发，二进制包需随附其许可全文
install -m 0644 vendor/freetype/docs/FTL.TXT "$STAGE/FTL.TXT"
# conpty.dll / OpenConsole.exe（Windows Terminal 的 OpenConsole，MIT）：
# 有了它们，括号粘贴标记与 kitty 键盘协议才能完整到达子进程；缺省程序会回退 inbox conhost。
if [ -f vendor/conpty/conpty.dll ]; then
    install -m 0644 vendor/conpty/conpty.dll "$STAGE/conpty.dll"
    install -m 0644 vendor/conpty/OpenConsole.exe "$STAGE/OpenConsole.exe"
    install -m 0644 vendor/conpty/NOTICE.md "$STAGE/CONPTY-NOTICE.md"
fi
if [ -f config/leantty.example.toml ]; then
    install -m 0644 config/leantty.example.toml "$STAGE/leantty.toml"
fi
cat > "$STAGE/run.cmd" <<'EOF'
@echo off
rem 便携运行：同目录下的 leantty.toml 会被自动读取（也可用 --config-file 指定）。
"%~dp0leantty.exe" %*
EOF

mkdir -p "$ROOT/dist"
python3 - "$STAGE" "$ROOT/dist/$NAME.zip" <<'PY'
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for root, _dirs, files in os.walk(stage):
        for f in sorted(files):
            full = os.path.join(root, f)
            z.write(full, os.path.relpath(full, stage))
print("zip ok:", out, os.path.getsize(out), "bytes")
PY
ls -l "$ROOT/dist/$NAME.zip"
