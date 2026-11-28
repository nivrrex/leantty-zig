#!/bin/sh
# GPU 直画与 CPU 对拍：整帧逐像素比较（允许 1 LSB 舍入），并验证 emoji 彩色像素存在。
# 需要 Xvfb（llvmpipe 也能跑 GLX），不需要真显卡。
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
. "$ROOT/scripts/e2e/x11_common.sh"
DISP="${GPU_PARITY_DISPLAY:-:77}"
OUT="${OUT:-/tmp/gpu-parity}"
APP="$ROOT/zig-out/bin/leantty"
PASS=0
FAIL=0
mkdir -p "$OUT"

x11_kill_stale_display "${DISP#:}" || exit 1
Xvfb "$DISP" -screen 0 1400x900x24 >"$OUT/xvfb.log" 2>&1 &
XVFB_PID=$!
DISPLAY="$DISP" openbox >"$OUT/openbox.log" 2>&1 &
WM_PID=$!
APP_PID=""
cleanup() {
  [ -z "$APP_PID" ] || kill "$APP_PID" 2>/dev/null || true
  kill "$XVFB_PID" "$WM_PID" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
sleep 1.5

shot() { # $1=backend
  printf '[window]\ndimensions = { columns = 80, lines = 24 }\n[font]\nsize = 13.0\nfallback = ["Noto Color Emoji"]\n[colors.primary]\nbackground = "#F3F1E9"\nforeground = "#303238"\n[renderer]\nbackend = "%s"\n' "$1" >"$OUT/$1.toml"
  DISPLAY="$DISP" "$APP" --config-file "$OUT/$1.toml" -e /bin/sh -c \
    'printf "GPU parity 你好 ABC 0123 illl\n\033[1mBOLD\033[0m \033[4mUND\033[0m \033[7mREV\033[0m \033[2mDIM\033[0m\n\033[42m  BG  \033[0m\n\360\237\230\200\360\237\230\201\n"; sleep 5' \
    >"$OUT/$1.log" 2>&1 &
  APP_PID=$!
  sleep 3
  W=$(DISPLAY="$DISP" timeout 3 xdotool search --pid "$APP_PID" 2>/dev/null | tail -1)
  if [ -n "${W:-}" ]; then
    DISPLAY="$DISP" timeout 5 import -window "$W" "$OUT/$1.png" 2>/dev/null
  fi
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
  sleep 0.4
}

shot cpu
shot gpu
if grep -q "renderer: gpu" "$OUT/gpu.log"; then
  echo "PASS gpu-backend-active"
  PASS=$((PASS + 1))
else
  echo "FAIL gpu-backend-active（GL 不可用）"
  FAIL=$((FAIL + 1))
fi

if python3 - "$OUT" <<'PY'; then
import sys
from PIL import Image, ImageChops
out = sys.argv[1]
try:
    a = Image.open(f"{out}/cpu.png").convert("RGB")
    b = Image.open(f"{out}/gpu.png").convert("RGB")
except (OSError, ValueError):
    print("FAIL gpu-parity（缺截图）")
    raise SystemExit(2)
if a.size != b.size:
    print(f"FAIL gpu-parity 尺寸不一致: {a.size} != {b.size}")
    raise SystemExit(2)
d = ImageChops.difference(a, b)
n = 0
rounding = 0
for y in range(d.height):
    for x in range(d.width):
        delta = max(abs(v) for v in d.getpixel((x, y)))
        if delta > 1:
            n += 1
        elif delta:
            rounding += 1
print(f"{'PASS' if n == 0 else 'FAIL'} gpu-pixel-parity pixels_diff={n}/{d.width*d.height} rounding_1lsb={rounding}")
if n:
    raise SystemExit(1)

def colored_pixels(im):
    return sum(
        1
        for y in range(im.height)
        for x in range(im.width)
        for r, g, b in [im.getpixel((x, y))]
        if max(r, g, b) - min(r, g, b) > 30 and max(r, g, b) > 80
    )

ca, cb = colored_pixels(a), colored_pixels(b)
print(f"{'PASS' if ca and cb else 'FAIL'} gpu-emoji-color cpu={ca} gpu={cb}")
raise SystemExit(0 if ca and cb else 1)
PY
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

echo "===== GPU 直画对拍: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
