#!/bin/sh
# 按键编码矩阵：以 alacritty 逐字节对拍得到的期望值为准（ghostty 与 xterm 一致的部分优先），
# 在独立 Xvfb 上跑，关闭 IBus（unset DBUS_SESSION_BUS_ADDRESS），测纯编码路径。
#
# 断言方式：把每个按键喂给终端里的 python 探针，探针把已收字节的十六进制写入 OSC 2 标题，
# 脚本用 xprop 读标题并取增量。
#
# 两处与 alacritty 的有意分歧（期望值按 ghostty/xterm）：
#   KP_Enter        alacritty 发 0a，ghostty/xterm 与 leantty 发 0d
#   ctrl+shift+/    alacritty 发 3f，ghostty/xterm 与 leantty 发 7f
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/scripts/e2e/x11_common.sh"
DISP="${MATRIX_DISPLAY:-:76}"
PASS=0
FAIL=0
OUT="${MATRIX_OUT:-/tmp/keys-matrix}"
mkdir -p "$OUT"

cat >"$OUT/probe.py" <<'PY'
import os, termios, tty
fd = 0
old = termios.tcgetattr(fd)
try:
    tty.setraw(fd)
    acc = ""
    os.write(1, b"\x1b]2;\x07")
    while True:
        b = os.read(fd, 1)
        if not b:
            break
        acc += "%02x" % b[0]
        os.write(1, ("\x1b]2;%s\x07" % acc).encode())
finally:
    termios.tcsetattr(fd, termios.TCSANOW, old)
PY

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
sleep 2

start_app() {
  [ -z "$APP_PID" ] || kill "$APP_PID" 2>/dev/null || true
  DISPLAY="$DISP" env -u DBUS_SESSION_BUS_ADDRESS \
    "$ROOT/zig-out/bin/leantty" -e /usr/bin/python3 "$OUT/probe.py" \
    >"$OUT/app.log" 2>&1 </dev/null &
  APP_PID=$!
  i=0
  while [ $i -lt 30 ]; do
    sleep 0.2
    WID=$(DISPLAY="$DISP" timeout 2 xdotool search --pid "$APP_PID" 2>/dev/null | tail -1)
    [ -n "${WID:-}" ] && break
    i=$((i + 1))
  done
  [ -n "${WID:-}" ] || return 1
  DISPLAY="$DISP" timeout 3 wmctrl -i -a "$WID" >/dev/null 2>&1
  sleep 0.6
  return 0
}

# 每条：按键 | 期望十六进制
CASES='a=61
A=41
1=31
exclam=21
space=20
Return=0d
Tab=09
shift+Tab=1b5b5a
BackSpace=7f
Escape=1b
ctrl+a=01
ctrl+c=03
ctrl+z=1a
ctrl+space=00
ctrl+slash=1f
ctrl+bracketleft=1b
ctrl+backslash=1c
alt+a=1b61
alt+slash=1b2f
alt+1=1b31
alt+period=1b2e
Up=1b5b41
Down=1b5b42
Left=1b5b44
Right=1b5b43
Home=1b5b48
End=1b5b46
Prior=1b5b357e
Next=1b5b367e
Insert=1b5b327e
Delete=1b5b337e
F1=1b4f50
F4=1b4f53
F5=1b5b31357e
F12=1b5b32347e
KP_1=31
KP_Add=2b
KP_Decimal=2e
ctrl+Left=1b5b313b3544
shift+Up=1b5b313b3241
alt+Left=1b5b313b3344
ctrl+shift+a=01
ctrl+2=00
ctrl+8=7f
alt+BackSpace=1b7f
ctrl+BackSpace=08
shift+Delete=1b5b333b327e
alt+ctrl+a=1b01
ISO_Level3_Shift+a=61'

if ! start_app; then
  echo "FAIL keys-matrix (窗口未出现)"
  exit 1
fi

prev=""
for c in $CASES; do
  key=${c%=*}
  want=${c#*=}
  DISPLAY="$DISP" timeout 3 xdotool key --window "$WID" "$key" 2>/dev/null
  sleep 0.22
  cur=$(DISPLAY="$DISP" timeout 3 xprop -id "$WID" WM_NAME 2>/dev/null | sed 's/.*= "//; s/"$//')
  got=$(printf '%s' "$cur" | sed "s/^$prev//")
  prev="$cur"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL key $key: 期望 $want 实际 ${got:-(空)}"
    FAIL=$((FAIL + 1))
  fi
done
stop_app() {
  [ -z "$APP_PID" ] || kill "$APP_PID" 2>/dev/null || true
  [ -z "$APP_PID" ] || wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
}
stop_app
echo "===== 按键矩阵: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
