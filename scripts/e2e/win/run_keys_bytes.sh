#!/bin/bash
# 按键字节矩阵（Windows，Git Bash）：把每个按键（组合）在终端里产生的字节**原样**抓下来。
#
# 为什么需要它：截图/窗口文本只能看出"程序有没有反应"，看不出终端到底发了什么。
# 方向键/Shift+Enter 这类问题必须看到字节才能判断是"没发""发错协议形式"还是"被别处吞掉"。
#
# 用法：
#   bash scripts/e2e/win/run_keys_bytes.sh <exe 路径> [模式] [输出目录]
#     模式：default | app | kitty | kitty-all | modify   （见 scripts/e2e/tools/keydump.c）
#   bash scripts/e2e/win/run_keys_bytes.sh --diff <exeA> <exeB> [模式]   # 两个终端逐键对比
#
# 依赖：Git Bash、PowerShell 5.1、zig（编译探针用，可用 ZIG= 指定路径）。真实按键用 keybd_event，
# 不用 SendKeys（SendKeys 走另一条通路，已证明不可靠）。
set -u
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
ZIG_BIN="${ZIG:-zig}"
HERE="$ROOT/scripts/e2e/win"

# --- 探针 ---
compile_probe() {
  local out="$1"
  [ -x "$out" ] && return 0
  "$ZIG_BIN" cc -target x86_64-windows-gnu -O2 "$ROOT/scripts/e2e/tools/keydump.c" -o "$out" || return 1
}

# --- 按键矩阵：名称|按键序列（PowerShell SendKeys 语法不合适，这里用 VK 码逐个按下/抬起）---
# 格式：label vk [mods]
#   mods: 0=无 1=Shift 2=Ctrl 4=Alt（与代码里的位一致）
MATRIX=(
  "Up 0x26 0" "Down 0x28 0" "Left 0x25 0" "Right 0x27 0"
  "Home 0x24 0" "End 0x23 0" "PgUp 0x21 0" "PgDn 0x22 0"
  "Ins 0x2D 0" "Del 0x2E 0" "Tab 0x09 0" "Esc 0x1B 0"
  "Bksp 0x08 0" "Enter 0x0D 0" "F1 0x70 0" "F5 0x74 0"
  "S-Up 0x26 1" "S-Left 0x25 1" "C-Right 0x27 2" "A-Up 0x26 4"
  "S-Enter 0x0D 1" "C-Enter 0x0D 2" "A-Enter 0x0D 4"
  "C-a 0x41 2" "C-e 0x45 2" "C-S-a 0x41 3" "A-x 0x58 4"
)

press_one() { # $1=vk $2=mods
  powershell -NoProfile -Command "
      \$sig='[DllImport(\"user32.dll\")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);'
      Add-Type -MemberDefinition \$sig -Name K -Namespace W | Out-Null
      \$vk=$1; \$mods=$2
      if (\$mods -band 1) { [W.K]::keybd_event(0x10,0,0,[UIntPtr]::Zero) }
      if (\$mods -band 2) { [W.K]::keybd_event(0x11,0,0,[UIntPtr]::Zero) }
      if (\$mods -band 4) { [W.K]::keybd_event(0x12,0,0,[UIntPtr]::Zero) }
      [W.K]::keybd_event(\$vk,0,0,[UIntPtr]::Zero)
      [W.K]::keybd_event(\$vk,0,2,[UIntPtr]::Zero)
      if (\$mods -band 4) { [W.K]::keybd_event(0x12,0,2,[UIntPtr]::Zero) }
      if (\$mods -band 2) { [W.K]::keybd_event(0x11,0,2,[UIntPtr]::Zero) }
      if (\$mods -band 1) { [W.K]::keybd_event(0x10,0,2,[UIntPtr]::Zero) }
    " >/dev/null 2>&1
}

run_matrix() { # $1=exe $2=mode $3=outdir
  local exe="$1" mode="$2" out="$3"
  mkdir -p "$out"
  compile_probe "$out/keydump.exe" || {
    echo "FATAL: 探针编译失败"
    return 1
  }
  local args=()
  [ "$mode" != "default" ] && args=("$mode")
  local dump_win
  dump_win=$(cygpath -w "$out/keys.txt" 2>/dev/null || echo "$out\\keys.txt")
  rm -f "$out/keys.txt"
  KEYDUMP_OUT="$dump_win" "$exe" -e "$(cygpath -w "$out/keydump.exe" 2>/dev/null || echo "$out\\keydump.exe")" "${args[@]}" &
  local job=$!
  local pid=$job
  sleep 3
  # $! 是 MSYS 的 pid，不是 Windows pid；focus.ps1 要后者。
  # 用 -e 参数里的输出目录（每次运行唯一）在命令行里定位实例。
  # 定位实例的 Windows pid。必须同时满足两个条件，缺一不可：
  #   1) 命令行含**本次运行的完整输出目录**（唯一路径，带反斜杠）；
  #   2) 命令行含**本次启动用的 exe 完整路径**。
  # 教训：早先只用 basename（如 "A"）做 -like，而 -like 不区分大小写，
  # "*A*" 会命中用户自己开着的 E:\Compiler\Leantty\leantty.exe —— 误杀过用户的会话。
  local OUT_WIN
  OUT_WIN=$(cygpath -w "$out" 2>/dev/null || echo "$out")
  local EXE_WIN
  EXE_WIN=$(cygpath -w "$exe" 2>/dev/null || echo "$exe")
  if [ ${#OUT_WIN} -lt 8 ]; then
    echo "FATAL: 输出目录太短，拒绝按命令行匹配（防止误杀）：$OUT_WIN"
    return 1
  fi
  local wpid=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    wpid=$(powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { \$_.CommandLine -like ('*' + '$OUT_WIN' + '*') -and \$_.CommandLine -like ('*' + '$EXE_WIN' + '*') } | Select-Object -First 1 -ExpandProperty ProcessId" 2>/dev/null | tr -d '\r')
    [ -n "$wpid" ] && break
    sleep 0.5
  done
  if [ -z "$wpid" ]; then
    echo "FATAL: 找不到实例的 Windows pid（out=$OUT_WIN exe=$EXE_WIN）"
    kill "$job" 2>/dev/null
    return 1
  fi
  pid="$wpid"
  # keybd_event 发往**前台窗口**：每次按键前必须确认目标窗口在前台，
  # 否则方向键/Ctrl+A 会发到开发机上别的窗口（可能造成破坏）。
  if ! powershell -NoProfile -ExecutionPolicy Bypass -File "$HERE/tools/focus.ps1" -processId "$pid" 2>/dev/null | grep -q FOCUS_OK; then
    echo "FATAL: 目标窗口没能拿到前台（pid=$pid），中止，避免按键发到别的窗口"
    kill "$pid" 2>/dev/null
    return 1
  fi
  for row in "${MATRIX[@]}"; do
    # 矩阵行按空格拆成三个字段，这是有意的词法切分。
    # shellcheck disable=SC2086
    set -- $row
    local label="$1" vk="$2" mods="$3"
    if ! powershell -NoProfile -ExecutionPolicy Bypass -File "$HERE/tools/focus.ps1" -processId "$pid" 2>/dev/null | grep -q FOCUS_OK; then
      echo "ABORT: pid=$pid 失去前台，停止后续按键"
      kill "$pid" 2>/dev/null
      return 1
    fi
    # 记录分隔标记：写进探针文件不方便，这里靠"按键前后行号"切分
    local before
    before=$(wc -l <"$out/keys.txt" 2>/dev/null || echo 0)
    press_one "$vk" "$mods"
    sleep 0.18
    local after
    after=$(wc -l <"$out/keys.txt" 2>/dev/null || echo 0)
    if [ "$after" -gt "$before" ]; then
      printf "%-10s %s\n" "$label" "$(sed -n "$((before + 1)),$((after))p" "$out/keys.txt" | tr -d '\n')" >>"$out/table.txt"
    else
      printf "%-10s <无字节>\n" "$label" >>"$out/table.txt"
    fi
  done
  # $pid 已被换成 Windows pid：MSYS 的 kill 会把它当 MSYS pid 处理，可能误杀别进程。
  # 用 Stop-Process 精确结束自己启动的实例，再接回 bash 的作业 id。
  powershell -NoProfile -Command "\$p = Get-CimInstance Win32_Process -Filter 'ProcessId=$pid' -ErrorAction SilentlyContinue; if (\$p -and \$p.CommandLine -like ('*' + '$OUT_WIN' + '*')) { Stop-Process -Id $pid -Force } else { Write-Output 'SKIP-KILL not-ours' }" >/dev/null 2>&1
  kill "$job" 2>/dev/null
  wait "$job" 2>/dev/null
}

if [ "${1:-}" = "--diff" ]; then
  A="$2"
  B="$3"
  MODE="${4:-default}"
  run_matrix "$A" "$MODE" "$HERE/keys-a"
  run_matrix "$B" "$MODE" "$HERE/keys-b"
  echo "=== 逐键对比（$MODE）：A=$A  B=$B ==="
  paste -d'|' "$HERE/keys-a/table.txt" "$HERE/keys-b/table.txt" | awk -F'|' '{
        a=$1; b=$2;
        # 去掉 label 前缀后比较字节
        la=a; lb=b; sub(/^[^ ]+ +/,"",la); sub(/^[^ ]+ +/,"",lb);
        if (la==lb) printf "SAME  %s\n", a;
        else { printf "DIFF  %s\n       %s\n", a, b; }
    }'
  exit 0
fi

EXE="${1:?用法: run_keys_bytes.sh <exe> [模式] [输出目录]}"
MODE="${2:-default}"
OUT="${3:-$HERE/keys-$MODE}"
mkdir -p "$OUT"
: >"$OUT/table.txt"
run_matrix "$EXE" "$MODE" "$OUT"
echo "=== $EXE（$MODE）==="
cat "$OUT/table.txt"
