#!/bin/bash
# Tab 补全验收（Windows）：确认 Tab 到底是"按键事件"还是"字面制表符"。
#
# 背景：0.1.19 起 ConPTY 走 OpenConsole + PSEUDOCONSOLE_WIN32_INPUT_MODE，输入流被解释成
# "win32 输入记录 + 字面文本"。用户实测 cmd 里按 Tab 补全会**新起一行**（像插入了制表符），
# 怀疑 `\t` 被当成字面文本插进输入缓冲，而不是 VK_TAB 按键事件。
#
# 本脚本做三件事：
#   A 字节探针：子进程是 keydump（裸读 stdin），按 Tab 后看收到的是不是 0x09；
#   B 屏幕探针：子进程是 cmd，输入 `cd C:\Win` + Tab，把屏幕 dump 出来（人看是否换行）；
#   C A/B：同一序列加 `LEANTTY_WIN_INPUT_RECORDS=1`（改发 win32 输入记录 `CSI Vk;Sc;Uc;Kd;Cs;Rc _`）。
#
# 用法（Git Bash）：
#   bash scripts/e2e/win/run_tab.sh [exe]
set -u
. "$(dirname "$0")/lib.sh"

case "$(uname -s)" in
*MSYS* | *MINGW* | *CYGWIN*) ;;
*)
    echo "SKIP: 仅 Windows（Git Bash）可跑"
    exit 0
    ;;
esac

ZIG_BIN="${ZIG:-zig}"
EXE="${1:-$LEANTTY_EXE}"
D="$WORK\\tab"
mkdir -p "$(unixpath "$WORK")/i/tab"
DU="$(unixpath "$WORK")/tab"
mkdir -p "$DU"

KEYDUMP="$DU/keydump.exe"
[ -x "$KEYDUMP" ] || "$ZIG_BIN" cc -target x86_64-windows-gnu -O2 "$REPO/scripts/e2e/tools/keydump.c" -o "$KEYDUMP" || {
    echo "FATAL: keydump 编译失败"
    exit 1
}

press_tab() {
    powershell -NoProfile -Command "
      \$sig='[DllImport(\"user32.dll\")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);'
      Add-Type -MemberDefinition \$sig -Name K -Namespace W | Out-Null
      [W.K]::keybd_event(0x09,0,0,[UIntPtr]::Zero)
      Start-Sleep -Milliseconds 60
      [W.K]::keybd_event(0x09,0,2,[UIntPtr]::Zero)
    " >/dev/null 2>&1
}

run_case() { # $1=标签 $2=是否发记录(0/1) $3=子进程模式(probe|cmd)
    local tag="tab-$1"
    local kf="$DU/keys-$1.txt"
    : >"$kf"
    stop_instance "$tag"
    mkdir -p "$(unixpath "$WORK")/i/$tag"
    local d="$WORK\\i\\$tag\\d.txt"
    if [ "$3" = probe ]; then
        if [ "$2" = 1 ]; then
            KEYDUMP_OUT="$(winpath "$kf")" LEANTTY_WIN_INPUT_RECORDS=1 start_instance "$tag" -e "$(winpath "$KEYDUMP")"
        else
            KEYDUMP_OUT="$(winpath "$kf")" start_instance "$tag" -e "$(winpath "$KEYDUMP")"
        fi
    else
        if [ "$2" = 1 ]; then
            LEANTTY_WIN_INPUT_RECORDS=1 APP_DUMP_SNAPSHOT="$d" start_instance "$tag"
        else
            APP_DUMP_SNAPSHOT="$d" start_instance "$tag"
        fi
    fi
    local pid; pid=$(instance_pid "$tag")
    if [ -z "$pid" ]; then
        echo "FAIL $tag: 实例没起来"
        FAIL=$((FAIL + 1))
        return
    fi
    if ! powershell -NoProfile -ExecutionPolicy Bypass -File "$HERE/tools/focus.ps1" -processId "$pid" 2>/dev/null | grep -q FOCUS_OK; then
        echo "FATAL: 窗口没拿到前台，中止（避免按键发到别的窗口）"
        stop_instance "$tag"
        return
    fi
    sleep 1
    if [ "$3" = cmd ]; then
        # 只输入前缀，让 Tab 有机会补全（C:\Windows 一定存在）
        powershell -NoProfile -ExecutionPolicy Bypass -File "$SEND" -cmdLike "i\\$tag" -keys 'cd C:\Win' >/dev/null 2>&1
        sleep 0.5
    fi
    press_tab
    sleep 1
    if [ "$3" = probe ]; then
        echo "--- $1：keydump 收到的字节 ---"
        tr -s ' ' '\n' <"$kf" | grep -E '^[0-9a-f]{2}$' | tr '\n' ' '
        echo
    else
        echo "--- $1：屏幕（前 3 行） ---"
        tail -n +2 "$(dump_file "$tag")" 2>/dev/null | head -3 | cat -A | head -3
    fi
    stop_instance "$tag"
}

echo "== A 字节探针（默认发送方式）=="
run_case a 0 probe
echo "== B 屏幕探针（cmd + Tab，默认发送方式）=="
run_case b 0 cmd
echo "== C 屏幕探针（cmd + Tab，改发 win32 输入记录）=="
run_case c 1 cmd
echo "== D 字节探针（改发 win32 输入记录时子进程看到什么）=="
run_case d 1 probe

echo
echo "判读："
echo "  A 若出现 09 → 终端确实把 Tab 字节送到了子进程；B 里换行说明 ConPTY 把 \\t 当字面文本，"
echo "  需要 C（win32 输入记录）。A 若是 0d/其他 → 问题在我们自己的编码。"
