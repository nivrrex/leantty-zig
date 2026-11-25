#!/bin/bash
# 真源端拖放验证：用 GTK3 当拖放源（与 PCManFM/Thunar 同一套 gtkdnd），
# xdotool 真按鼠标拖到 leantty 窗口，断言子进程收到 "路径 + 空格"。
#
# 为什么要这一条：自制 X11 探针（tools/xdnd_send.c）直接给客户窗口发 ClientMessage，
# 绕过了"源如何定位目标窗口"这一步；真实 GTK 源会按指针位置找窗口（涉及重父化/WM 帧），
# 二者行为可能不同——用户实测 LXDE 下拖不进来，正是这一步的差异。
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="${DND_GTK_OUT:-$ROOT/scripts/e2e/out}"
mkdir -p "$OUT"
APP_BIN="${1:-$ROOT/zig-out/bin/leantty}"
DISPLAY_NO="${DND_GTK_DISPLAY:-94}"
PASS=0
FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }

# 依赖 python3-gi（GTK3）：没有就跳过，不让它变成"环境问题导致的全量失败"
if ! python3 -c "import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk" 2>/dev/null; then
    echo "SKIP: 缺少 python3-gi / GTK3（无法构造真实 GTK 拖放源）"
    exit 0
fi

if [ -e "/tmp/.X${DISPLAY_NO}-lock" ] || xdpyinfo -display ":$DISPLAY_NO" >/dev/null 2>&1; then
    pkill -f "Xvfb :${DISPLAY_NO} " 2>/dev/null
    sleep 0.4
    rm -f "/tmp/.X${DISPLAY_NO}-lock"
fi
Xvfb ":$DISPLAY_NO" -screen 0 1000x700x24 >"$OUT/dnd-gtk-xvfb.log" 2>&1 &
XVFB=$!
DISPLAY=":$DISPLAY_NO" openbox >"$OUT/dnd-gtk-openbox.log" 2>&1 &
WM=$!
sleep 1
export DISPLAY=":$DISPLAY_NO"

PAYLOAD="$OUT/dnd gtk payload.txt"
printf 'gtk\n' >"$PAYLOAD"
KD="$OUT/dnd-gtk-keys.txt"
: >"$KD"
LOG="$OUT/dnd-gtk-app.log"
: >"$LOG"

cleanup() {
    [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null
    [ -n "${SRC_PID:-}" ] && kill "$SRC_PID" 2>/dev/null
    kill "$XVFB" "$WM" 2>/dev/null
}
trap cleanup EXIT INT TERM

python3 "$ROOT/scripts/e2e/tools/dndsrc.py" "$PAYLOAD" 0 0 >"$OUT/dnd-gtk-src.log" 2>&1 &
SRC_PID=$!
LEANTTY_KDBG=1 KEYDUMP_OUT="$KD" "$APP_BIN" -e "$ROOT/scripts/e2e/out/keydump" >>"$LOG" 2>&1 &
APP_PID=$!
sleep 2.5

SRC_WIN=$(xdotool search --name "DND-SOURCE" | head -1)
DST_WIN=$(xdotool search --class "[Ll]eantty" | tail -1)
if [ -z "$SRC_WIN" ] || [ -z "$DST_WIN" ]; then
    bad "窗口没起来" "src=$SRC_WIN dst=$DST_WIN"
    exit 1
fi

eval "$(xdotool getwindowgeometry --shell "$SRC_WIN")"
sx=$((X + WIDTH / 2))
sy=$((Y + HEIGHT / 2))
eval "$(xdotool getwindowgeometry --shell "$DST_WIN")"
dx=$((X + WIDTH / 2))
dy=$((Y + HEIGHT / 2))

# 真拖：按下 → 分步移动（GTK 需要 motion 才会发 XdndPosition）→ 松开
xdotool mousemove "$sx" "$sy"
sleep 0.3
xdotool mousedown 1
sleep 0.2
for i in 1 2 3 4 5 6 7 8 9 10; do
    xdotool mousemove $((sx + (dx - sx) * i / 10)) $((sy + (dy - sy) * i / 10))
    sleep 0.12
done
sleep 0.4
xdotool mouseup 1
sleep 1.5

# tr 会把换行换成空格，末尾多一个：比较前去掉，否则永远"不一致"
got=$(tr -s ' ' '\n' <"$KD" | grep -E '^[0-9a-f]{2}$' | tr '\n' ' ')
got=${got% }
want=$(python3 -c "
import sys
p=sys.argv[1]
data=b'\x1b[200~'+p.encode()+b' \x1b[201~'
print(' '.join(f'{b:02x}' for b in data))" "$PAYLOAD")

if grep -q "xdnd enter" "$LOG"; then ok "收到 XdndEnter"; else bad "没有 XdndEnter（源没找到我们）"; fi
if grep -q "XdndDrop" "$LOG"; then ok "收到 XdndDrop"; else bad "没有 XdndDrop（源取消了拖放）"; fi
if [ "$got" = "$want" ]; then
    ok "子进程收到路径（$(printf '%s' "$got" | wc -w) 字节）"
else
    echo "---- 期望 ----"; printf '%s\n' "$want"
    echo "---- 实得 ----"; printf '%s\n' "$got"
    bad "路径字节不一致"
fi

echo
echo "===== dnd-gtk: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ] || exit 1
