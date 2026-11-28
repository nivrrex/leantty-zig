#!/bin/bash
# 候选框锚点回归：全屏 TUI（备用屏 + 光标不在首行）里，候选框必须锚到**真实光标格**。
#
# 背景（第三轮实测）：旧实现的锚点取自"是否画光标"的那两个格值。
# TUI 普遍隐藏光标（或处在闪烁灭相）→ cursor_x/y = -1 → 夹成 (0,0) →
# position_ime 里的"位置没变，早退"直接命中 → 一次 ImmSetCandidateWindow 都不发，
# 候选框停在 IME 的默认位置。表现就是"盲输能出汉字，但看不见候选框"。
#
# 断言：kdbg 里出现 `ime pos anchor=(<altui 请求的格>)`，且不是 (0,0)。
# shellcheck source=scripts/e2e/win/lib.sh
. "$(dirname "$0")/lib.sh"

ZIG="${ZIG:-zig}"
SHIFT="$HERE/tools/ime_shift.ps1"
TYPE="$HERE/tools/type_keys.ps1"
ROW=20
COL=5

if ! command -v "$ZIG" >/dev/null 2>&1; then
  echo "SKIP IME-TUI：没有 zig（需要它编译 altui 用例程序）"
  summary
  exit 0
fi
"$ZIG" cc -target x86_64-windows-gnu "$HERE/tools/altui.c" -o "$BUILD_TMP/altui.exe" 2>/dev/null
if [ ! -f "$BUILD_TMP/altui.exe" ]; then
  echo "SKIP IME-TUI：altui 编译失败"
  summary
  exit 0
fi

mkdir -p "$(unixpath "$WORK")/i/ime2"
cp "$BUILD_TMP/altui.exe" "$(unixpath "$WORK")/i/ime2/altui.exe"

# 注意：CreateProcess 解析相对 exe 名用的是**本进程自己的 cwd**（不是 --working-directory），
# 所以这里必须给绝对路径，否则会 ConPTY 启动失败。
ALTUI_WIN="$(winpath "$(unixpath "$WORK")/i/ime2/altui.exe")"
start_instance ime2 -e "$ALTUI_WIN $ROW $COL 40"
LOG=$(log_file ime2)

# 切中文并用一个字符探是否真的进了组词态（Shift 是翻转，两种起始态都能覆盖）
ensure_zh() {
  powershell -NoProfile -ExecutionPolicy Bypass -File "$SHIFT" -cmdLike 'i\ime2' >/dev/null 2>&1
  sleep 0.3
  powershell -NoProfile -ExecutionPolicy Bypass -File "$TYPE" -cmdLike 'i\ime2' -keys 'n' >/dev/null 2>&1
  sleep 0.8
  grep -q "ime start" "$LOG"
}
ensure_zh || {
  echo "组词态: 再切一次"
  ensure_zh || true
}

assert_grep "TUI 里进入组词态" "ime start" "$LOG"
assert_grep "候选框锚到 TUI 光标格（x=$((COL - 1)),y=$((ROW - 1))）" \
  "ime pos anchor=($((COL - 1)),$((ROW - 1)))" "$LOG"
assert_not_grep "锚点未退化为 (0,0)" "ime pos anchor=(0,0)" "$LOG"
assert_grep "候选框位置被 IME 接受（回读 style）" "rb style=" "$LOG"

stop_instance ime2
summary
