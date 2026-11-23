#!/bin/sh
# 快速冒烟（目标 < 30 秒）：按键字节、粘贴、文字显示、配色。
# 与 run_all.sh 的区别：不截图、不做窗口管理断言，全部走"探针落盘 + dump 文本"，
# 便于在每次改动后随手跑一遍（run_all/附加 e2e 留给阶段收口）。
#
# 用法：sh scripts/e2e/smoke.sh [二进制路径]
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/scripts/e2e/out"
mkdir -p "$OUT"
APP_BIN="${1:-$ROOT/zig-out/bin/leantty}"
DISPLAY_NO=98
PASS=0; FAIL=0
ok()   { echo "PASS $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

for tool in Xvfb xdotool openbox; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: 缺少 $tool"; exit 1; }
done
[ -x "$APP_BIN" ] || { echo "FATAL: $APP_BIN 不存在"; exit 1; }

# 清理本轮 display 的残留（Xvfb 与 openbox），只动自己的 display
if [ -e "/tmp/.X${DISPLAY_NO}-lock" ] || xdpyinfo -display ":$DISPLAY_NO" >/dev/null 2>&1; then
    pkill -f "Xvfb :${DISPLAY_NO} " 2>/dev/null; sleep 0.4; rm -f "/tmp/.X${DISPLAY_NO}-lock"
fi
for pid in $(pgrep -x openbox 2>/dev/null); do
    tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -qx "DISPLAY=:${DISPLAY_NO}" && kill "$pid" 2>/dev/null
done
Xvfb :$DISPLAY_NO -screen 0 800x600x24 >"$OUT/smoke-xvfb.log" 2>&1 &
XVFB_PID=$!
DISPLAY=:$DISPLAY_NO openbox >"$OUT/smoke-openbox.log" 2>&1 &
WM_PID=$!
sleep 0.8
export DISPLAY=:$DISPLAY_NO

: > "$OUT/smoke-empty.toml"
export LEANTTY_CONFIG="$OUT/smoke-empty.toml"
: > "$OUT/smoke.log"
APP_PID=""
stop_app() { [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; [ -n "$APP_PID" ] && wait "$APP_PID" 2>/dev/null; APP_PID=""; [ -n "${WID:-}" ] && xdotool windowfocus "$WID" >/dev/null 2>&1; }
trap 'kill $XVFB_PID $WM_PID ${APP_PID:-} 2>/dev/null' EXIT INT TERM

# 启动 $APP_BIN，最多等 4 秒拿窗口
start() { # $1.. app 参数
    stop_app
    "$APP_BIN" "$@" >>"$OUT/smoke.log" 2>&1 &
    APP_PID=$!
    WID=""
    i=0
    while [ $i -lt 40 ]; do
        WID=$(xdotool search --pid "$APP_PID" 2>/dev/null | tail -1)
        [ -n "$WID" ] && break
        sleep 0.1; i=$((i+1))
    done
    [ -n "$WID" ] || return 1
    xdotool windowfocus "$WID" >/dev/null 2>&1
    sleep 0.25
    return 0
}

# ---------- 1. 按键字节（方向键/编辑键/Ctrl 组合）----------
ZIG="${ZIG:-/root/Desktop/tty/vt-verify/toolchain/zig/zig}"
KEYDUMP="$OUT/keydump"
[ -x "$KEYDUMP" ] || "$ZIG" cc -O1 "$ROOT/scripts/e2e/tools/keydump.c" -o "$KEYDUMP" >/dev/null 2>&1
if [ -x "$KEYDUMP" ] && start -e "$KEYDUMP"; then
    KF="$OUT/keydump.txt"; : > "$KF"
    export KEYDUMP_OUT="$KF"
    # 探针是子进程：它的环境变量要在启动前给，这里重启一次
    stop_app
    KEYDUMP_OUT="$KF" "$APP_BIN" -e "$KEYDUMP" >>"$OUT/smoke.log" 2>&1 &
    APP_PID=$!
    i=0; WID=""
    while [ $i -lt 40 ]; do WID=$(xdotool search --pid "$APP_PID" 2>/dev/null | tail -1); [ -n "$WID" ] && break; sleep 0.1; i=$((i+1)); done
    xdotool windowfocus "$WID" >/dev/null 2>&1; sleep 0.4

    xdotool key --window "$WID" Up;    sleep 0.15
    xdotool key --window "$WID" Down;  sleep 0.15
    xdotool key --window "$WID" Right; sleep 0.15
    xdotool key --window "$WID" Left;  sleep 0.15
    xdotool key --window "$WID" Home;  sleep 0.15
    xdotool key --window "$WID" End;   sleep 0.15
    xdotool key --window "$WID" Prior; sleep 0.15
    xdotool key --window "$WID" Next;  sleep 0.15
    xdotool key --window "$WID" Insert; sleep 0.15
    xdotool key --window "$WID" Delete; sleep 0.3
    # 探针会先写一行 start（再在退出时写 eof），断言时剔除；十六进制统一去掉空格再比对
    hex=$(grep -vE '^(start|eof)$' "$KF" 2>/dev/null | tr -d '\n\t ' )
    want="1b5b41 1b5b42 1b5b43 1b5b44 1b5b48 1b5b46 1b5b357e 1b5b367e 1b5b327e 1b5b337e"
    want=$(printf '%s' "$want" | tr -d ' ')
    if [ "$hex" = "$want" ]; then ok "keys-arrows-edit"; else bad "keys-arrows-edit" "got: $hex"; fi

    stop_app

    # Ctrl 组合：Ctrl+A → 01，Ctrl+E → 05（alacritty/xterm 口径）。
    # 用独立实例与独立落盘文件：探针的 FILE* 有写偏移，同一文件里 truncate 会写出空洞。
    KF2="$OUT/keydump-ctrl.txt"
    stop_app
    rm -f "$KF2"
    KEYDUMP_OUT="$KF2" "$APP_BIN" -e "$KEYDUMP" >>"$OUT/smoke.log" 2>&1 &
    APP_PID=$!
    i=0; WID=""
    while [ $i -lt 40 ]; do WID=$(xdotool search --pid "$APP_PID" 2>/dev/null | tail -1); [ -n "$WID" ] && break; sleep 0.1; i=$((i+1)); done
    xdotool windowfocus "$WID" >/dev/null 2>&1; sleep 0.3
    xdotool key --window "$WID" ctrl+a; sleep 0.15
    xdotool key --window "$WID" ctrl+e; sleep 0.25
    hex=$(grep -vE '^(start|eof)$' "$KF2" 2>/dev/null | tr -d '\n\t ' )
    if [ "$hex" = "0105" ]; then ok "keys-ctrl"; else bad "keys-ctrl" "got: $hex"; fi
    stop_app
else
    bad "keys-arrows-edit" "探针编译或启动失败"
fi

# ---------- 2. 文本显示（UTF-8 + 宽字符）----------
D="$OUT/smoke-text.dump"; rm -f "$D"
if APP_DUMP_SNAPSHOT="$D" start -e /bin/sh -c 'printf "正文 ABC 中文测试\n"; sleep 5'; then
    if grep -q "中文测试" "$D" 2>/dev/null; then ok "text-utf8"; else bad "text-utf8" "$(head -2 "$D" 2>/dev/null | tail -1)"; fi
    head -1 "$D" | grep -q "wide=[1-9]" && ok "text-wide" || bad "text-wide" "$(head -1 "$D" 2>/dev/null)"
else
    bad "text-utf8" "启动失败"
fi
stop_app

# ---------- 3. 粘贴（含 bracketed 包裹 + 大段）----------
if command -v xclip >/dev/null 2>&1 && [ -x "$KEYDUMP" ]; then
    printf '第一行\n第二行\n' > "$OUT/smoke-paste.txt"
    xclip -selection clipboard < "$OUT/smoke-paste.txt"
    KF="$OUT/keydump-paste.txt"; : > "$KF"
    stop_app
    KEYDUMP_OUT="$KF" "$APP_BIN" -e "$KEYDUMP" >>"$OUT/smoke.log" 2>&1 &
    APP_PID=$!
    i=0; WID=""
    while [ $i -lt 40 ]; do WID=$(xdotool search --pid "$APP_PID" 2>/dev/null | tail -1); [ -n "$WID" ] && break; sleep 0.1; i=$((i+1)); done
    xdotool windowfocus "$WID" >/dev/null 2>&1; sleep 0.4
    xdotool key --window "$WID" ctrl+shift+v; sleep 0.6
    hex=$(grep -vE '^(start|eof)$' "$KF" 2>/dev/null | tr -d '\n\t ' )
    case "$hex" in
        1b5b3230307e*1b5b3230317e) ok "paste-bracketed" ;;   # ESC[200~ ... ESC[201~
        *) bad "paste-bracketed" "got: $hex" ;;
    esac
    stop_app
else
    bad "paste-bracketed" "缺少 xclip 或探针"
fi

# ---------- 4. 配色（dump 头与调色板）----------
printf '[colors.primary]\nbackground = "#101010"\nforeground = "#C0C0C0"\n' > "$OUT/smoke-colors.toml"
D="$OUT/smoke-colors.dump"; rm -f "$D"
if LEANTTY_CONFIG="$OUT/smoke-colors.toml" APP_DUMP_SNAPSHOT="$D" start -e /bin/sh -c 'printf "x\n"; sleep 5'; then
    head -1 "$D" | grep -q "bg=101010" && ok "colors-bg" || bad "colors-bg" "$(head -1 "$D" 2>/dev/null)"
else
    bad "colors-bg" "启动失败"
fi
stop_app

# ---------- 5. 拖选自动滚动（拖到底部后按住，视口要跟着滚）----------
D="$OUT/smoke-autoscroll.dump"; rm -f "$D"
if APP_DUMP_SNAPSHOT="$D" start -e /bin/sh -c 'seq 1 200; sleep 8'; then
    sleep 0.3
    # 先把视口往上翻几屏，否则输出结束时视口已经在最底部，没有可滚的空间
    xdotool key --window "$WID" shift+Prior; sleep 0.15
    xdotool key --window "$WID" shift+Prior; sleep 0.15
    xdotool key --window "$WID" shift+Prior; sleep 0.35
    first_before=$(sed -n 2p "$D" 2>/dev/null | tr -d '\r')
    eval "$(xdotool getwindowgeometry --shell "$WID")"
    xdotool mousemove --window "$WID" 100 100 mousedown 1
    sleep 0.15
    xdotool mousemove --window "$WID" 300 $((HEIGHT - 3))
    sleep 1.2
    xdotool mouseup 1
    sleep 0.4
    first_after=$(sed -n 2p "$D" 2>/dev/null | tr -d '\r')
    if [ "$first_before" != "$first_after" ] && [ -n "$first_after" ]; then
        ok "select-autoscroll ($first_before -> $first_after)"
    else
        bad "select-autoscroll" "视口没滚动（首行仍是 $first_before）"
    fi
else
    bad "select-autoscroll" "启动失败"
fi
stop_app

echo "===== smoke: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
