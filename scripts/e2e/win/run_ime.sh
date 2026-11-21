#!/bin/bash
# IME 验收：本机有中文输入法时，用微软拼音输入 "nihao" 上屏"你好"；
# 没有输入法时 SKIP，并打印已安装输入法作为证据。
. "$(dirname "$0")/lib.sh"

IMES=$(powershell -NoProfile -Command "Get-WinUserLanguageList | ForEach-Object { \$_.InputMethodTips }" 2>/dev/null | tr -d '\r')
echo "已安装输入法提示:"
echo "$IMES" | sed 's/^/  /'

# 本机已知的“空壳”提示（只有键盘布局，没有真正的 IME 实现）：
#   0804:{E5A1B2C3-D4F5-6E7A-8B9C-0D1E2F3A4B5C}{B3C4D5E6-F7A8-9B0C-1D2E-3F4A5B6C7D8E}
# 除它之外还出现别的语言配置，才认为有可用输入法。
REAL=$(printf '%s
' "$IMES" | grep -v 'E5A1B2C3-D4F5-6E7A-8B9C-0D1E2F3A4B5C' | grep -c .)
if [ "${REAL:-0}" -eq 0 ]; then
    echo "SKIP IME：本机只装了键盘布局（无微软拼音等 IME），无法验证组词上屏；"
    echo "     需要装好输入法的机器再跑本用例。"
    summary
    exit 0
fi

start_instance ime1
powershell -NoProfile -ExecutionPolicy Bypass -File "$SEND" -cmdLike 'i\ime1' -keys 'nihao ' >/dev/null 2>&1
sleep 2
assert_grep "IME 上屏你好" "你好" "$(dump_file ime1)"
stop_instance ime1

summary
