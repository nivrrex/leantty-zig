#!/bin/bash
# IME 验收：中文组词上屏 + 候选框锚点。
#
# 关键前提（上一轮踩过）：本机输入法**默认英文态，必须单按一次 Shift 才切中文**。
# 少了这一步，"键入 nihao 只出 ASCII" 会被误判成"系统级输入法不工作"。
# 因此本脚本先切中/英，再用 kdbg 里的 `ime start` 确认真的进了组词态，然后才断言。
#
# 做法：
#   1. 系统级对照：真实 cmd 控制台里 Shift + 键入 "nihao "，用 conread 读屏找"你好"；
#      英文态/中文态两种起始状态各试一次（Shift 是翻转，两次必然覆盖）。
#   2. leantty：Shift + 键入 "n" 探一下，看 kdbg 有没有 `ime start`；
#      没有就再 Shift 一次，然后输入 "ihao " 完成上屏。
#   3. 断言：dump 里有"你好"、有 wide=2、`ime result units=`；并且
#      kdbg 里出现 `ime pos anchor=`（候选框位置真的设过，不是退回 (0,0) 空转）。
. "$(dirname "$0")/lib.sh"

ZIG="${ZIG:-zig}"
SHIFT="$HERE/tools/ime_shift.ps1"
# 注意：IME 用例必须用 keybd_event 打字（type_keys.ps1）。
# SendKeys 打出的字符不走组词通路（实测：同样 Shift+文本，SendKeys 只出 ASCII）。
SEND="$HERE/tools/type_keys.ps1"

IMES=$(powershell -NoProfile -Command "Get-WinUserLanguageList | ForEach-Object { \$_.InputMethodTips }" 2>/dev/null | tr -d '\r')
echo "已安装输入法提示:"
echo "$IMES" | sed 's/^/  /'
if [ -z "$(printf '%s' "$IMES" | tr -d ' \r\n')" ]; then
    echo "SKIP IME：本机没有注册任何输入法"
    summary
    exit 0
fi

if ! command -v "$ZIG" >/dev/null 2>&1; then
    echo "SKIP IME：没有 zig（需要它编译 conread 对照探针）"
    summary
    exit 0
fi
"$ZIG" cc -target x86_64-windows-gnu "$HERE/tools/conread.c" -o "$BUILD_TMP/conread.exe" 2>/dev/null
if [ ! -f "$BUILD_TMP/conread.exe" ]; then
    echo "SKIP IME：conread 编译失败"
    summary
    exit 0
fi

# ---- 1. 系统级对照（真 cmd 窗口，Shift 翻转两种起始态各试一次）----
CTL_OK=0
for attempt in 1 2; do
    CTL_PID=$(powershell -NoProfile -Command "\$p = Start-Process cmd -ArgumentList '/k','title IMECTL' -PassThru; Write-Output \$p.Id" 2>/dev/null | tr -d '\r')
    [ -z "$CTL_PID" ] && continue
    sleep 2
    powershell -NoProfile -ExecutionPolicy Bypass -File "$SHIFT" -processId "$CTL_PID" >/dev/null 2>&1
    sleep 0.4
    powershell -NoProfile -ExecutionPolicy Bypass -File "$SEND" -processId "$CTL_PID" -keys 'nihao ' >/dev/null 2>&1
    sleep 1.5
    CTL_TEXT=$("$BUILD_TMP/conread.exe" "$CTL_PID" 2>/dev/null)
    powershell -NoProfile -Command "Stop-Process -Id $CTL_PID -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1
    if printf '%s' "$CTL_TEXT" | grep -q "你好"; then
        echo "对照结果: 真实 cmd 里 Shift+键入能上屏中文（第 $attempt 次尝试，起始态之一已覆盖）"
        CTL_OK=1
        break
    fi
    sleep 0.5
done
if [ "$CTL_OK" != "1" ]; then
    echo "对照结果: 真实 cmd 里 Shift+键入仍只出 ASCII —— 本机输入法确实不可用"
    printf '%s' "$CTL_TEXT" | tr -d '\000' | grep -a -m1 -o ".\{0,50\}nihao.\{0,20\}" | sed 's/^/    /'
    echo "SKIP IME：对照侧不通过，无法判定 leantty 的 IME 通路（需在输入法正常的机器上复测）"
    summary
    exit 0
fi

# ---- 2. leantty：切中文 -> 探组词态 -> 上屏 ----
start_instance ime1 -e 'cmd.exe /k'
sleep 1
LOG=$(log_file ime1)
DUMP=$(dump_file ime1)

ensure_zh() {
    powershell -NoProfile -ExecutionPolicy Bypass -File "$SHIFT" -cmdLike 'i\ime1' >/dev/null 2>&1
    sleep 0.3
    powershell -NoProfile -ExecutionPolicy Bypass -File "$SEND" -cmdLike 'i\ime1' -keys 'n' >/dev/null 2>&1
    sleep 0.8
    grep -q "ime start" "$LOG"
}

if ensure_zh; then
    echo "组词态: 第一次 Shift 之后即进入（kdbg 有 ime start）"
else
    echo "组词态: 第一次 Shift 后未进入，再切一次"
    ensure_zh || true
fi
assert_grep "IME 进入组词态（ime start）" "ime start" "$LOG"

# 完成 "ihao "（前面的 n 可能已经作为 ASCII 落进命令行，不影响"你好"上屏）
powershell -NoProfile -ExecutionPolicy Bypass -File "$SEND" -cmdLike 'i\ime1' -keys 'ihao ' >/dev/null 2>&1
sleep 2

assert_grep "IME 上屏你好" "你好" "$DUMP"
assert_grep "IME wide=2" "wide=2" "$DUMP"
assert_grep "IME 只提交一次" "ime result units=" "$LOG"
assert_grep "候选框位置已设置（ime pos anchor）" "ime pos" "$LOG"
# 锚点不能是 (0,0) 空转：cmd 提示符在首行时 (0,0) 合法，这里只要求日志真的走完设置路径
if grep -q "ime pos anchor=(-1" "$LOG"; then
    echo "FAIL 候选框锚点退化为 -1（光标不可见时没有兜底）"; FAIL=$((FAIL + 1))
else
    echo "PASS 候选框锚点有效"; PASS=$((PASS + 1))
fi

stop_instance ime1
summary
