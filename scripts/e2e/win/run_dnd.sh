#!/bin/bash
# 拖放文件（Windows，Git Bash）：把文件"拖"进 leantty 窗口，路径应写进子进程 stdin。
#
# 做法：用 tools/dropfiles.c 构造一个真实的 HDROP 并给窗口发 WM_DROPFILES
# （等价于从资源管理器拖进来）；子进程用 keydump 裸读 stdin，断言收到的字节。
#
# 期望字节与 alacritty 同口径（`paste(path + " ", true)`）：
#   程序开了 bracketed paste 时 = ESC[200~ + 路径 + 空格 + ESC[201~；
#   多个文件用空格连接、每个路径后一个空格。
#
# 用法（Git Bash）：
#   bash scripts/e2e/win/run_dnd.sh [exe]
set -u
. "$(dirname "$0")/lib.sh"
HERE="$REPO/scripts/e2e/win"
ZIG_BIN="${ZIG:-zig}"

case "$(uname -s)" in
*MSYS* | *MINGW* | *CYGWIN*) ;;
*)
    echo "SKIP: 仅 Windows（Git Bash）可跑"
    exit 0
    ;;
esac

D="$WORK\\dnd"
mkdir -p "$(unixpath "$WORK")/i/dnd"
DU="$(unixpath "$WORK")/dnd"
mkdir -p "$DU"

# 探针与发送器
KEYDUMP="$DU/keydump.exe"
[ -x "$KEYDUMP" ] || "$ZIG_BIN" cc -target x86_64-windows-gnu -O2 "$REPO/scripts/e2e/tools/keydump.c" -o "$KEYDUMP" || {
    echo "FATAL: keydump 编译失败"
    exit 1
}
DROP="$DU/dropfiles.exe"
[ -x "$DROP" ] || "$ZIG_BIN" cc -target x86_64-windows-gnu -O2 "$HERE/tools/dropfiles.c" -o "$DROP" || {
    echo "FATAL: dropfiles 编译失败"
    exit 1
}

# 载荷：文件名含空格（最容易被"没加引号/没转义"的实现弄坏）
F1="$DU/drop file.txt"
F2="$DU/第二个 文件.txt"
printf 'one\n' >"$F1"
printf 'two\n' >"$F2"

run_case() { # $1=标签 $2..=要拖的文件
    local tag="dnd-$1"
    local kf="$DU/keys-$1.txt"
    : >"$kf"
    shift
    KEYDUMP_OUT="$(winpath "$kf")" LEANTTY_KDBG=1 start_instance "$tag" -e "$(winpath "$KEYDUMP")"
    local pid
    pid=$(instance_pid "$tag")
    if [ -z "$pid" ]; then
        echo "FAIL $tag: 实例没起来"
        FAIL=$((FAIL + 1))
        return
    fi
    # 顶层窗口句柄：WM_DROPFILES 必须发给窗口本身（不是子窗口/进程）
    local hwnd
    hwnd=$(powershell -NoProfile -Command "(Get-Process -Id $pid).MainWindowHandle" 2>/dev/null | tr -d '\r\n')
    if [ -z "$hwnd" ] || [ "$hwnd" = "0" ]; then
        echo "FAIL $tag: 拿不到窗口句柄（pid=$pid）"
        FAIL=$((FAIL + 1))
        stop_instance "$tag"
        return
    fi
    local args=()
    local f
    for f in "$@"; do args+=("$(winpath "$f")"); done
    "$DROP" "$hwnd" "${args[@]}" >/dev/null 2>&1
    sleep 1
    stop_instance "$tag"
    # keydump 每读一次写一行十六进制；这里断言"标记 + 文件名"都出现过
    local hx="$DU/hex-$1.txt"
    tr -s ' ' '\n' <"$kf" | grep -E '^[0-9a-f]{2}$' | tr '\n' ' ' >"$hx"
    # drop file.txt → 64 72 6f 70 20 66 69 6c 65 2e 74 78 74
    assert_grep "$tag 有 bracketed 起点" "1b 5b 32 30 30 7e" "$hx"
    assert_grep "$tag 有 bracketed 终点" "1b 5b 32 30 31 7e" "$hx"
    assert_grep "$tag 路径带空格完整" "64 72 6f 70 20 66 69 6c 65 2e 74 78 74" "$hx"
}

echo "== A. 单个文件 =="
run_case a "$F1"

echo "== B. 两个文件（空格连接） =="
run_case b "$F1" "$F2"

echo
echo "===== dnd: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ] || exit 1
