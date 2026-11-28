#!/bin/bash
# Windows e2e 公共函数（Git Bash / MSYS 下运行）。
# 约定：
#   * 每个用例用唯一 tag 作为 --working-directory，清理只按 “exe 路径 + tag” 精确匹配，
#     绝不按进程名杀进程（开发机上可能正用着另一个 leantty 窗口）。
#   * 断言一律读 APP_DUMP_SNAPSHOT 的文本，不靠人看截图。
# 同一路径既是诊断输出目标也是重定向目标，不存在读写管道竞争。
# shellcheck disable=SC2094
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
LEANTTY_EXE="${LEANTTY_EXE:-$(cygpath -w "$REPO/zig-out/bin/leantty.exe" 2>/dev/null || echo "$REPO/zig-out/bin/leantty.exe")}"
WORK="${WORK:-$(cygpath -w "${TMPDIR:-/tmp}/leantty-e2e-win" 2>/dev/null || echo "/tmp/leantty-e2e-win")}"
# 以下两个变量由 source 本文件的用例脚本使用。
# shellcheck disable=SC2034
SHOT="$HERE/tools/shot.ps1"
# shellcheck disable=SC2034
SEND="$HERE/tools/send_keys.ps1"

PASS=0
FAIL=0

winpath() { cygpath -w "$1" 2>/dev/null || echo "$1"; }
unixpath() { cygpath -u "$1" 2>/dev/null || echo "$1"; }

mkdir -p "$(unixpath "$WORK")"
BUILD_TMP="${BUILD_TMP:-$(unixpath "$WORK")/bin}"
mkdir -p "$BUILD_TMP"
log_file() { echo "$(unixpath "$WORK")/$1.log"; }

# 只杀“自己启动的”实例：命令行同时含本仓库 exe 路径与 tag。
stop_instance() {
  local tag="$1"
  powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='leantty.exe'\" | Where-Object { \$_.CommandLine -like '*$(basename "$LEANTTY_EXE")*' -and \$_.CommandLine -like '*$tag*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" >/dev/null 2>&1
}

# start_instance <tag> [额外参数...]
# 环境：APP_DUMP_SNAPSHOT=<WORK>\i\<tag>\d.txt、LEANTTY_KDBG=1 → <WORK>/<tag>.log
start_instance() {
  local tag="$1"
  shift
  local dir="$WORK\\i\\$tag"
  mkdir -p "$(unixpath "$WORK")/i/$tag"
  # 0.1.3 起 exe 是 GUI 子系统，w32_init_console 会把 stdout/stderr 接到
  # 父控制台（或 NUL），shell 的 >log 重定向会被覆盖；诊断必须用 LEANTTY_KDBG_FILE。
  APP_DUMP_SNAPSHOT="$dir\d.txt" LEANTTY_KDBG=1 LEANTTY_KDBG_FILE="$(winpath "$(unixpath "$WORK")/$tag.log")" "$LEANTTY_EXE" --working-directory "$dir" "$@" >"$(unixpath "$WORK")/$tag.log" 2>&1 &
  sleep "${START_WAIT:-2.5}"
}

# 取实例的 Windows PID（按 exe 名 + tag 精确匹配，绝不按名字批量操作）
instance_pid() {
  powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='leantty.exe'\" | Where-Object { \$_.CommandLine -like '*$(basename "$LEANTTY_EXE")*' -and \$_.CommandLine -like '*$1*' } | Select-Object -First 1 -ExpandProperty ProcessId" 2>/dev/null | tr -d '
'
}

# 采样一个实例的 CPU 毫秒数与工作集 MB：输出 "cpu_ms ws_mb"
sample_instance() {
  local pid
  pid=$(instance_pid "$1")
  [ -z "$pid" ] && {
    echo "0 0"
    return
  }
  powershell -NoProfile -Command "\$p = Get-Process -Id $pid -ErrorAction SilentlyContinue; if (\$p) { Write-Output (\$p.TotalProcessorTime.TotalMilliseconds.ToString('0') + ' ' + (\$p.WorkingSet64/1MB).ToString('0.0')) } else { Write-Output '0 0' }" 2>/dev/null | tr -d '
'
}

dump_file() { echo "$(unixpath "$WORK")/i/$1/d.txt"; }
dump_header() { head -1 "$(dump_file "$1")" 2>/dev/null; }
dump_text() { tail -n +2 "$(dump_file "$1")" 2>/dev/null; }

assert_eq() { # name want got
  if [ "$2" = "$3" ]; then
    echo "PASS $1: $3"
    PASS=$((PASS + 1))
  else
    echo "FAIL $1: want=[$2] got=[$3]"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep() { # name pattern file
  if grep -q -- "$2" "$3" 2>/dev/null; then
    echo "PASS $1: $(grep -m1 -- "$2" "$3")"
    PASS=$((PASS + 1))
  else
    echo "FAIL $1: 未匹配 [$2] ($3)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_grep() { # name pattern file
  if grep -q -- "$2" "$3" 2>/dev/null; then
    echo "FAIL $1: 不应出现 [$2]: $(grep -m1 -- "$2" "$3")"
    FAIL=$((FAIL + 1))
  else
    echo "PASS $1: 未出现 [$2]"
    PASS=$((PASS + 1))
  fi
}

summary() {
  echo
  echo "== 汇总: PASS=$PASS FAIL=$FAIL =="
  [ "$FAIL" -eq 0 ]
}

# 设置剪贴板（内容取自文件，避免命令行转义问题）。
# 必须回读校验：剪贴板可能被别的进程占用，Set-Clipboard 失败是静默的，
# 上一轮实测就因此把“旧剪贴板内容”当成了本轮载荷。返回非 0 表示没设成功。
set_clipboard_from_file() {
  local f="$1" tmp="$WORK/.clip_check.txt"
  for _ in 1 2 3 4 5; do
    powershell -NoProfile -Command "Set-Clipboard -Value ([IO.File]::ReadAllText('$(winpath "$f")'))" >/dev/null 2>&1
    # 用文件比对而不是命令替换：PowerShell 的 stdout 编码会把中文变成乱码
    powershell -NoProfile -Command "[IO.File]::WriteAllText('$(winpath "$tmp")', (Get-Clipboard -Raw))" >/dev/null 2>&1
    if cmp -s "$(unixpath "$tmp")" "$f"; then return 0; fi
    sleep 0.3
  done
  echo "WARN: 剪贴板设置失败（可能被占用）：$f"
  return 1
}

get_clipboard_to_file() {
  powershell -NoProfile -Command "[IO.File]::WriteAllText('$(winpath "$1")', (Get-Clipboard -Raw))" >/dev/null 2>&1
}
