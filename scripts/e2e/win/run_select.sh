#!/bin/bash
# 选区高亮回归：拖选 -> 单击后黑框必须消失。
#
# 背景（第四轮）：0.1.7 的 handleMouse 已经会 clearSelection，日志里 sel=false，
# 但屏幕上的选区框不消失 —— 根因在渲染侧：ghostty 的 RenderState.update 在
# selection == null 时不重写各行的 row.selection，未重建的行保留上一帧的区间。
# presentFrame 现在只按 term.hasSelection() 决定是否相信 row.selection。
#
# 判据用像素差，因为缺陷只在画面上，dump/日志都看不出：
#   A 未选 -> B 拖选后：选区带内差异必须明显（> 20）
#   A 未选 -> C 单击后：同一带内差异必须很小（< 6）
# shellcheck source=scripts/e2e/win/lib.sh
# shellcheck disable=SC2015
. "$(dirname "$0")/lib.sh"

SHOT="$HERE/tools/shot.ps1"
MOUSE="$HERE/tools/mouse_gesture.ps1"
DIFF="$HERE/tools/imgdiff.ps1"

for f in "$SHOT" "$MOUSE" "$DIFF"; do
  [ -f "$f" ] || {
    echo "SKIP 选区：缺工具 $f"
    summary
    exit 0
  }
done

TAG=sel1
DIR="$(unixpath "$WORK")/i/$TAG"
mkdir -p "$DIR"
python - "$DIR/lines.txt" <<'PY'
import sys, io
io.open(sys.argv[1], 'w', encoding='utf-8', newline='\r\n').write(
    ''.join('line %02d ---------- end\r\n' % i for i in range(1, 21)))
PY
printf '@echo off\r\ntype %s\\i\\%s\\lines.txt\r\n' "$WORK" "$TAG" >"$DIR/lines.bat"

start_instance $TAG -e 'cmd.exe /k lines.bat'
PID=$(instance_pid $TAG)
LOG=$(log_file $TAG)
[ -z "$PID" ] && {
  echo "FAIL 选区：实例没起来"
  FAIL=$((FAIL + 1))
  summary
  exit 1
}

# 取 cell 尺寸（app_win 首帧日志：cell=8x23）
CELL=$(grep -m1 "first-frame" "$LOG" | sed -n 's/.*cell=\([0-9]*\)x\([0-9]*\).*/\1 \2/p')
CW=${CELL%% *}
CH=${CELL##* }
[ -z "$CW" ] && {
  CW=8
  CH=18
}
echo "cell=${CW}x${CH} pid=$PID"

shot() { powershell -NoProfile -ExecutionPolicy Bypass -File "$SHOT" -processId "$PID" -out "$1" >/dev/null 2>&1; }
A="$(unixpath "$WORK")/sel_A.png"
B="$(unixpath "$WORK")/sel_B.png"
C="$(unixpath "$WORK")/sel_C.png"

sleep 1
shot "$A"
powershell -NoProfile -ExecutionPolicy Bypass -File "$MOUSE" -processId "$PID" -path '5,3>40,8' -cellW "$CW" -cellH "$CH" -wait 600 >/dev/null 2>&1
sleep 1
shot "$B"
powershell -NoProfile -ExecutionPolicy Bypass -File "$MOUSE" -processId "$PID" -path '5,3' -cellW "$CW" -cellH "$CH" -wait 600 >/dev/null 2>&1
sleep 1.5
shot "$C"

# 选区带：第 3~8 行（0 基），留一点行高余量
TOP=$((CH * 3))
BOT=$((CH * 9))
MAD_AB=$(powershell -NoProfile -ExecutionPolicy Bypass -File "$DIFF" -a "$(winpath "$A")" -b "$(winpath "$B")" -top "$TOP" -bottom "$BOT" 2>/dev/null | sed -n 's/^MAD //p')
MAD_AC=$(powershell -NoProfile -ExecutionPolicy Bypass -File "$DIFF" -a "$(winpath "$A")" -b "$(winpath "$C")" -top "$TOP" -bottom "$BOT" 2>/dev/null | sed -n 's/^MAD //p')
MAD_AB=${MAD_AB:-0}
MAD_AC=${MAD_AC:-999}

awk -v v="$MAD_AB" 'BEGIN { exit !(v > 20) }' && {
  echo "PASS 拖选后画面有选区高亮 (MAD=$MAD_AB)"
  PASS=$((PASS + 1))
} || {
  echo "FAIL 拖选后画面没有变化 (MAD=$MAD_AB)"
  FAIL=$((FAIL + 1))
}

awk -v v="$MAD_AC" 'BEGIN { exit !(v < 6) }' && {
  echo "PASS 单击后选区框消失 (MAD=$MAD_AC)"
  PASS=$((PASS + 1))
} || {
  echo "FAIL 单击后画面仍与未选中不同 (MAD=$MAD_AC)"
  FAIL=$((FAIL + 1))
}

grep -q "\[mouse\].*sel=false" "$LOG" && {
  echo "PASS 单击后 sel=false"
  PASS=$((PASS + 1))
} || {
  echo "FAIL 日志里没有 sel=false"
  FAIL=$((FAIL + 1))
}

stop_instance $TAG
summary
