#!/bin/sh
# e2e 复现脚本（阶段 A）：Xvfb + app + xdotool 输入 + 截图 + 日志。
# 变量全部来自环境/脚本位置推导，仓库内无绝对路径。
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/scripts/e2e/out"
mkdir -p "$OUT"
DISPLAY_NO=99
APP_BIN="$ROOT/zig-out/bin/leantty"

[ -x "$APP_BIN" ] || { echo "FATAL: $APP_BIN 不存在，请先 zig build"; exit 1; }
command -v Xvfb >/dev/null 2>&1 || { echo "FATAL: Xvfb 未安装"; exit 1; }
command -v xdotool >/dev/null 2>&1 || { echo "FATAL: xdotool 未安装"; exit 1; }

# 起 Xvfb（固定 display :99）
Xvfb :$DISPLAY_NO -screen 0 1280x720x24 >"$OUT/xvfb.log" 2>&1 &
XVFB_PID=$!
trap 'kill $XVFB_PID $WM_PID ${APP_PID:-} 2>/dev/null; exit 0' EXIT INT TERM
sleep 1
export DISPLAY=:$DISPLAY_NO
# 起窗口管理器（Xvfb 无 WM 时 xdotool activate/focus 与 winit 窗口管理异常）
openbox >"$OUT/openbox.log" 2>&1 &
WM_PID=$!
sleep 1

# 起 app（SHELL=/bin/sh）
SHELL=/bin/sh "$APP_BIN" >"$OUT/app.log" 2>&1 &
APP_PID=$!

# 等窗口出现（最多 10s）
WID=""
i=0
while [ $i -lt 20 ]; do
    WID=$(xdotool search --name "tty" 2>/dev/null | head -1)
    [ -n "$WID" ] && break
    sleep 0.5
    i=$((i+1))
done
[ -n "$WID" ] || { echo "FATAL: 未找到 tty 窗口"; xdotool search --name "" 2>/dev/null | head -3; exit 1; }
echo "窗口 WID=$WID"
xdotool windowactivate "$WID"
xdotool windowfocus "$WID"
sleep 0.5

# 输入 echo hello 回车
xdotool type --window "$WID" "echo hello_e2e"
xdotool key --window "$WID" Return
sleep 1

# 截图（辅助证据）
import -window root "$OUT/screenshot-repro.png" 2>/dev/null || xwd -root >"$OUT/screenshot-repro.xwd"
echo "截图已保存"

# 关 app
xdotool windowclose "$WID" 2>/dev/null
sleep 1
kill $APP_PID 2>/dev/null
wait $APP_PID 2>/dev/null
echo "复现完成：$OUT（app.log / screenshot-repro.png）"
