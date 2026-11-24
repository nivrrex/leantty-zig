#!/bin/bash
# 回退路径验收：**没有 conpty.dll / OpenConsole.exe** 时（inbox conhost）的行为。
#
# 为什么必须有这一项：`PSEUDOCONSOLE_WIN32_INPUT_MODE(0x4)` 只有 OpenConsole 认，
# inbox conhost 收到它连子进程都起不来（第八轮实测：探针文件一个不创建、窗口只有首帧）。
# 所以 flags 按实现选择，并且 kitty 标志也要清零——否则子进程照旧 push kitty 协议、
# 我们照旧发 CSI-u，而 inbox conhost 会把 CSI-u 丢掉：pi/vim 里 Ctrl+C 变成"什么都不发"。
#
# 断言（只看字节，不看截图）：
#   1) 启动日志含 `kernel32 (inbox conhost)` 与降级警告；
#   2) kitty 模式下 Ctrl+C = `03`、Ctrl+A = `01`（legacy，与 0.1.18 一致）；
#   3) 粘贴无 `ESC[200~` 标记，但正文仍在；
#   4) 子进程能起来（keydump 文件里有内容）。
#
# 用法（Git Bash）：
#   bash scripts/e2e/win/run_fallback.sh [exe 路径]
# 默认取 zig-out/bin/leantty.exe；脚本会把它单独拷到一个**没有 dll** 的临时目录再启动。
set -u
. "$(dirname "$0")/lib.sh"

case "$(uname -s)" in
*MSYS* | *MINGW* | *CYGWIN*) ;;
*)
    echo "SKIP: 仅 Windows（Git Bash）可跑"
    exit 0
    ;;
esac

SRC_EXE="${1:-$LEANTTY_EXE}"
ZIG_BIN="${ZIG:-zig}"
TAG="fallback"
FB_DIR="$(unixpath "$WORK")/fb-bin"
mkdir -p "$FB_DIR"
FB_EXE="$FB_DIR/leantty.exe"
cp -f "$(unixpath "$SRC_EXE")" "$FB_EXE" || {
    echo "FATAL: 拷贝 exe 失败：$SRC_EXE"
    exit 1
}

# 目录里绝不能有这两个文件，否则测的不是回退路径
for f in conpty.dll OpenConsole.exe; do
    if [ -e "$FB_DIR/$f" ]; then
        echo "FATAL: $FB_DIR 里存在 $f，回退路径测不了"
        exit 1
    fi
done

# 探针（Kitty push + 字节十六进制落盘）
PROBE="$FB_DIR/keydump.exe"
[ -x "$PROBE" ] || "$ZIG_BIN" cc -target x86_64-windows-gnu -O2 "$REPO/scripts/e2e/tools/keydump.c" -o "$PROBE" || {
    echo "FATAL: 探针编译失败"
    exit 1
}

KEYS="$(unixpath "$WORK")/$TAG-keys.txt"
rm -f "$KEYS"
LOG="$(log_file "$TAG")"
rm -f "$LOG"

press() { # $1=vk $2=mods（0=无 1=Shift 2=Ctrl 4=Alt）
    powershell -NoProfile -Command "
      \$sig='[DllImport(\"user32.dll\")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);'
      Add-Type -MemberDefinition \$sig -Name K -Namespace W | Out-Null
      \$vk=$1; \$mods=$2
      if (\$mods -band 1) { [W.K]::keybd_event(0x10,0,0,[UIntPtr]::Zero) }
      if (\$mods -band 2) { [W.K]::keybd_event(0x11,0,0,[UIntPtr]::Zero) }
      if (\$mods -band 4) { [W.K]::keybd_event(0x12,0,0,[UIntPtr]::Zero) }
      # 修饰键按下后要给系统/输入法一点时间：本机输入法会抢 Shift，间隔太短会让
      # 目标键按"无修饰"到达（实测：Shift+Insert 因此变成 ESC[2~ 而不是粘贴）。
      Start-Sleep -Milliseconds 120
      [W.K]::keybd_event(\$vk,0,0,[UIntPtr]::Zero)
      [W.K]::keybd_event(\$vk,0,2,[UIntPtr]::Zero)
      if (\$mods -band 4) { [W.K]::keybd_event(0x12,0,2,[UIntPtr]::Zero) }
      if (\$mods -band 2) { [W.K]::keybd_event(0x11,0,2,[UIntPtr]::Zero) }
      if (\$mods -band 1) { [W.K]::keybd_event(0x10,0,2,[UIntPtr]::Zero) }
    " >/dev/null 2>&1
}

echo "== 启动（无 dll）：$FB_EXE =="
# lib.sh 的 start_instance 用的是全局 LEANTTY_EXE，这里临时换掉
OLD_EXE="$LEANTTY_EXE"
LEANTTY_EXE="$(winpath "$FB_EXE")"
KEYDUMP_OUT="$(winpath "$KEYS")" LEANTTY_KDBG=1 \
    start_instance "$TAG" -e "$(winpath "$PROBE")" kitty
pid=$(instance_pid "$TAG")
if [ -z "$pid" ]; then
    echo "FAIL 启动: 实例没起来（可能退回 kernel32 时崩溃了）"
    FAIL=$((FAIL + 1))
    LEANTTY_EXE="$OLD_EXE"
    exit 1
fi
LEANTTY_EXE="$OLD_EXE"

assert_grep "回退实现是 kernel32" "kernel32 (inbox conhost)" "$LOG"
assert_grep "打出了降级警告" "回退到系统 conhost" "$LOG"

if ! powershell -NoProfile -ExecutionPolicy Bypass -File "$HERE/tools/focus.ps1" -processId "$pid" 2>/dev/null | grep -q FOCUS_OK; then
    echo "FATAL: 目标窗口没拿到前台，中止（避免按键发到别的窗口）"
    stop_instance "$TAG"
    exit 1
fi
sleep 1

echo "== 键盘（kitty 模式，但缺 dll → 必须退回 legacy） =="
press 0x43 2 # Ctrl+C
sleep 0.4
press 0x41 2 # Ctrl+A
sleep 0.4

assert_grep "子进程起来并有字节" "start" "$KEYS"
assert_grep "Ctrl+C 仍是 0x03" "^03 $" "$KEYS"
assert_grep "Ctrl+A 仍是 0x01" "^01 $" "$KEYS"

echo "== 粘贴（应无括号标记，正文仍在） =="
PAYLOAD="$(unixpath "$WORK")/$TAG-paste.txt"
printf 'alpha\r\nbeta\r\n' >"$PAYLOAD"
if ! set_clipboard_from_file "$PAYLOAD"; then
    echo "FAIL 粘贴: 剪贴板未被设置"
    FAIL=$((FAIL + 1))
fi
# 用 Ctrl+Shift+V 而不是 Shift+Insert：后者要单靠 Shift，本机输入法会把 Shift 抢走；
# Ctrl+Shift+V 是本项目的剪贴板快捷键，两条修饰键都有独立按键事件，注入更稳。
press 0x56 3 # Ctrl+Shift+V
sleep 1.2

assert_not_grep "没有 ESC[200~ 标记" "1b 5b 32 30 30 7e" "$KEYS"
assert_grep "正文 alpha 到达" "61 6c 70 68 61" "$KEYS"

stop_instance "$TAG"

echo
echo "===== fallback: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ] || exit 1
