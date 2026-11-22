#!/bin/bash
# IME 验收：本机有中文输入法时，用微软拼音键入 "nihao " 断言上屏"你好"。
# 关键点：先做**系统级对照**——在真实 cmd 控制台里用同样的按键输入。
#   * cmd 里也打不出中文  → SKIP（本机输入法不工作，不是 leantty 的问题），附证据；
#   * cmd 里能打出中文、leantty 打不出 → FAIL（我们的 IME 通路有问题）。
. "$(dirname "$0")/lib.sh"

ZIG="${ZIG:-zig}"
IMES=$(powershell -NoProfile -Command "Get-WinUserLanguageList | ForEach-Object { \$_.InputMethodTips }" 2>/dev/null | tr -d '\r')
echo "已安装输入法提示:"
echo "$IMES" | sed 's/^/  /'

# 本机已知的空壳 tip（只有键盘布局、没有 IME 实现）
REAL=$(printf '%s\n' "$IMES" | grep -v 'E5A1B2C3-D4F5-6E7A-8B9C-0D1E2F3A4B5C' | grep -c .)
if [ "${REAL:-0}" -eq 0 ]; then
    echo "SKIP IME：本机只装了键盘布局（无微软拼音等 IME），无法验证组词上屏"
    summary
    exit 0
fi

# 编译控制台读取探针（IME 交叉对照用）
if command -v "$ZIG" >/dev/null 2>&1; then
    "$ZIG" cc -target x86_64-windows-gnu "$HERE/tools/conread.c" -o "$BUILD_TMP/conread.exe" 2>/dev/null
fi
if [ ! -f "$BUILD_TMP/conread.exe" ]; then
    echo "SKIP IME：没有 zig cc，无法编译控制台对照探针"
    summary
    exit 0
fi

echo "== 系统级对照：真实 cmd 控制台里键入 nihao =="
# 注意：这里必须是**真正的 cmd 控制台窗口**（不是 leantty 里的 cmd），
# 否则 conread 抓到的是 leantty 的（不存在的）控制台。
CTL_PID=$(powershell -NoProfile -Command "\$p = Start-Process cmd -ArgumentList '/k','title IMECTL' -PassThru; Write-Output \$p.Id" 2>/dev/null | tr -d '
')
sleep 2
powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class FZ { [DllImport(\"user32.dll\")] public static extern bool SetForegroundWindow(IntPtr h); }'; \$h=(Get-Process -Id $CTL_PID).MainWindowHandle; [void][FZ]::SetForegroundWindow(\$h); Start-Sleep -Milliseconds 700; [System.Windows.Forms.SendKeys]::SendWait('nihao ')" >/dev/null 2>&1
sleep 1.5
CTL_TEXT=$("$BUILD_TMP/conread.exe" "$CTL_PID" 2>/dev/null)
powershell -NoProfile -Command "Stop-Process -Id $CTL_PID -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1
if printf '%s' "$CTL_TEXT" | grep -q "你好"; then
    echo "对照结果: cmd 能上屏中文（输入法工作正常）"
else
    echo "对照结果: cmd 里也只出 ASCII —— 本机输入法未生效"
    printf '%s' "$CTL_TEXT" | tr -d '\000' | grep -a -m1 -o ".\{0,60\}nihao.\{0,20\}" | sed 's/^/    /' 
    echo "SKIP IME：输入法在系统层面就不工作（非 leantty 问题），本轮不判定 FAIL"
    summary
    exit 0
fi

echo "== leantty 内键入 nihao =="
start_instance ime1 -e 'cmd.exe /k'
powershell -NoProfile -ExecutionPolicy Bypass -File "$SEND" -cmdLike 'i\ime1' -keys 'nihao ' >/dev/null 2>&1
sleep 2
assert_grep "IME 上屏你好" "你好" "$(dump_file ime1)"
assert_grep "IME wide=2" "wide=2" "$(dump_file ime1)"
assert_grep "IME 只提交一次" "ime result units=" "$(log_file ime1)"
stop_instance ime1

summary
