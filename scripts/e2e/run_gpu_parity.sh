#!/bin/sh
# GPU 直画（atlas + quad）与 CPU 光栅的逐像素对拍。
# 需要 Xvfb（llvmpipe 也能跑 GLX），不需要真显卡。
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
DISP="${GPU_PARITY_DISPLAY:-:77}"
OUT="${OUT:-/tmp/gpu-parity}"
APP="$ROOT/zig-out/bin/leantty"
PASS=0; FAIL=0
mkdir -p "$OUT"

pkill -f "Xvfb[ ]$DISP" 2>/dev/null
sleep 0.5
setsid nohup Xvfb "$DISP" -screen 0 1400x900x24 >"$OUT/xvfb.log" 2>&1 </dev/null &
sleep 1.5
DISPLAY="$DISP" setsid nohup openbox >"$OUT/openbox.log" 2>&1 </dev/null &
sleep 1

shot() { # $1=backend
    printf '[window]\ndimensions = { columns = 80, lines = 24 }\n[font]\nsize = 13.0\n[colors.primary]\nbackground = "#F3F1E9"\nforeground = "#303238"\n[renderer]\nbackend = "%s"\n' "$1" > "$OUT/$1.toml"
    pkill -x leantty 2>/dev/null; sleep 0.5
    DISPLAY="$DISP" "$APP" --config-file "$OUT/$1.toml" -e /bin/sh -c \
        'printf "GPU parity 你好 ABC 0123 illl\n\033[1mBOLD\033[0m \033[4mUND\033[0m \033[7mREV\033[0m \033[2mDIM\033[0m\n\033[42m  BG  \033[0m\n"; sleep 5' \
        >"$OUT/$1.log" 2>&1 &
    sleep 3
    W=$(DISPLAY="$DISP" timeout 3 xdotool search --class leantty | tail -1)
    [ -n "${W:-}" ] && DISPLAY="$DISP" timeout 5 import -window "$W" "$OUT/$1.png" 2>/dev/null
    pkill -x leantty 2>/dev/null
    sleep 0.4
}

shot cpu
shot gpu
grep -q "renderer: gpu" "$OUT/gpu.log" && {
    echo "PASS gpu-backend-active"; PASS=$((PASS+1))
} || {
    echo "FAIL gpu-backend-active（GL 不可用，跳过像素对拍）"; FAIL=$((FAIL+1))
}

python3 - "$OUT" <<'PY'
import sys
from PIL import Image, ImageChops
out = sys.argv[1]
try:
    a = Image.open(f"{out}/cpu.png").convert("RGB")
    b = Image.open(f"{out}/gpu.png").convert("RGB")
except Exception as e:
    print("FAIL gpu-parity（缺截图）"); raise SystemExit(2)
w, h = min(a.width, b.width), min(a.height, b.height)
a, b = a.crop((0, 0, w, h)), b.crop((0, 0, w, h))
d = ImageChops.difference(a, b).load()
n = sum(1 for y in range(h) for x in range(w) if sum(d[x, y]) > 18)
print(f"{'PASS' if n == 0 else 'FAIL'} gpu-parity pixels_diff={n}/{w*h}")
raise SystemExit(0 if n == 0 else 1)
PY
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

pkill -x leantty 2>/dev/null
echo "===== GPU 直画对拍: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
