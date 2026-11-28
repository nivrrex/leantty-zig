#!/bin/bash
# e2e 验收（阶段 B）：Xvfb + openbox + app + xdotool，断言经 APP_DUMP_SNAPSHOT 文本钩子。
# 一条命令跑全部用例；失败时保留 dump 与截图。变量全部来自环境/脚本位置推导。
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/scripts/e2e/x11_common.sh"
OUT="$ROOT/scripts/e2e/out"
mkdir -p "$OUT"
# per-case 日志与 app-run.log 追加写入，跨 run 残留会污染断言（如 stderr 不含 wake），每次开头清空
rm -f "$OUT"/case*.log "$OUT"/app-run.log
# 测试隔离：用空配置，避免读到用户 ~/.config/leantty/leantty.toml（字体/绑定会影响断言）
: >"$OUT/empty.toml"
export LEANTTY_CONFIG="$OUT/empty.toml"
DISPLAY_NO=99
APP_BIN="$ROOT/zig-out/bin/leantty"

for tool in Xvfb xdotool openbox import wmctrl; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "FATAL: $tool 未安装"
    exit 1
  }
done
[ -x "$APP_BIN" ] || {
  echo "FATAL: $APP_BIN 不存在，请先 zig build"
  exit 1
}

# display 卫生：上一轮被 SIGKILL 时会残留 Xvfb，旧 server 里卡住的按键会污染本轮断言
x11_kill_stale_display "$DISPLAY_NO" || exit 1

# 残留的 openbox（上一轮被 SIGKILL 时留下）会让焦点行为异常：断言里"打字没进窗口"全部失败。
# 只清 DISPLAY 指向本测试 display 的那些进程，避免影响用户桌面上的 openbox。
for pid in $(pgrep -x openbox 2>/dev/null); do
  if tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qx "DISPLAY=:${DISPLAY_NO}"; then
    kill "$pid" 2>/dev/null
  fi
done
Xvfb :$DISPLAY_NO -screen 0 1280x720x24 >"$OUT/xvfb.log" 2>&1 &
XVFB_PID=$!
openbox >"$OUT/openbox.log" 2>&1 &
WM_PID=$!
trap 'kill $XVFB_PID $WM_PID ${APP_PID:-} 2>/dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
sleep 1
export DISPLAY=:$DISPLAY_NO

PASS=0
FAIL=0
WID=""
APP_PID=""

start_app() { # $1 = dump 路径, $2 = 日志路径（默认 app-run.log）
  local log=${2:-$OUT/app-run.log}
  APP_CELL_W=8 APP_CELL_H=16 APP_DUMP_SNAPSHOT="$1" SHELL=/bin/dash "$APP_BIN" >>"$log" 2>&1 &
  APP_PID=$!
  local i=0
  WID=""
  while [ $i -lt 20 ]; do
    WID=$(xdotool search --pid "$APP_PID" 2>/dev/null | tail -1)
    [ -n "$WID" ] && break
    sleep 0.5
    i=$((i + 1))
  done
  if [ -z "$WID" ]; then
    echo "FAIL start_app: 未找到 tty 窗口"
    FAIL=$((FAIL + 1))
    return 1
  fi
  xdotool windowactivate "$WID" >/dev/null 2>&1
  xdotool windowfocus "$WID" >/dev/null 2>&1
  return 0
}

stop_app() {
  [ -n "$APP_PID" ] && kill $APP_PID 2>/dev/null
  [ -n "$APP_PID" ] && wait $APP_PID 2>/dev/null
  APP_PID=""
}

# 等 dump 文件出现 pattern（最多 5s）
wait_dump() { # $1 文件 $2 pattern
  local i=0
  while [ $i -lt 10 ]; do
    grep -q "$2" "$1" 2>/dev/null && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

assert_dump() { # $1 用例名 $2 文件 $3 pattern
  if wait_dump "$2" "$3"; then
    echo "PASS $1"
    PASS=$((PASS + 1))
  else
    echo "FAIL $1 (pattern: $3)"
    FAIL=$((FAIL + 1))
    cp "$2" "$OUT/$1-fail.dump" 2>/dev/null
    import -window root "$OUT/$1-fail.png" 2>/dev/null
  fi
}

assert_app_exits() { # $1 用例名（APP_PID 须全局）
  local i=0 alive=1
  while [ $i -lt 10 ]; do
    kill -0 $APP_PID 2>/dev/null || {
      alive=0
      break
    }
    sleep 0.5
    i=$((i + 1))
  done
  if [ $alive -eq 0 ]; then
    echo "PASS $1"
    PASS=$((PASS + 1))
  else
    echo "FAIL $1 (app 5s 内未退出)"
    FAIL=$((FAIL + 1))
    cp "$D" "$OUT/$1-fail.dump" 2>/dev/null
    import -window root "$OUT/$1-fail.png" 2>/dev/null
    ps -o pid,stat,wchan:20,cmd -p $APP_PID >"$OUT/$1-fail-ps.txt" 2>&1
    xdotool search --name tty >"$OUT/$1-fail-windows.txt" 2>&1
    wmctrl -l >"$OUT/$1-fail-wmctrl.txt" 2>&1
  fi
  stop_app
}

assert_no_wake() { # $1 用例名 $2 日志文件（app stderr 不含 wake）
  if grep -q wake "$2" 2>/dev/null; then
    echo "FAIL $1 (stderr 含 wake: $(grep wake "$2" | head -2))"
    FAIL=$((FAIL + 1))
  else
    echo "PASS $1"
    PASS=$((PASS + 1))
  fi
}

# 用例 1：echo hello_e2e 回显
D="$OUT/case1-hello.dump"
if start_app "$D"; then
  xdotool type --window "$WID" "echo hello_e2e"
  xdotool key --window "$WID" Return
  assert_dump "case1-hello_e2e" "$D" "hello_e2e"
  stop_app
fi

# 用例 2：中文回显 + 宽格标记（xdotool type UTF-8 不可靠时改 printf 路径）
D="$OUT/case2-cn.dump"
if start_app "$D"; then
  xdotool type --window "$WID" "echo 你好"
  xdotool key --window "$WID" Return
  cn_ok=0
  if wait_dump "$D" "你好"; then
    echo "PASS case2-cn (xdotool type UTF-8)"
    PASS=$((PASS + 1))
    cn_ok=1
  fi
  if [ "$cn_ok" -eq 0 ]; then
    xdotool type --window "$WID" "printf '\\344\\275\\240\\345\\245\\275'"
    xdotool key --window "$WID" Return
    if wait_dump "$D" "你好"; then
      echo "PASS case2-cn (printf 八进制回退)"
      PASS=$((PASS + 1))
      cn_ok=1
    fi
  fi
  if [ "$cn_ok" -eq 0 ]; then
    # 偶发失败多因 shell 尚未就绪：重试一次
    sleep 1
    xdotool type --window "$WID" "printf '\\344\\275\\240\\345\\245\\275'"
    xdotool key --window "$WID" Return
    if wait_dump "$D" "你好"; then
      echo "PASS case2-cn (printf 回退，重试后)"
      PASS=$((PASS + 1))
      cn_ok=1
    fi
  fi
  if [ "$cn_ok" -eq 0 ]; then
    echo "FAIL case2-cn (无 你好 输出)"
    FAIL=$((FAIL + 1))
    cp "$D" "$OUT/case2-cn-fail.dump" 2>/dev/null
  fi

  # 宽格标记：summary 行 wide>=2（你/好 各占 Wide）
  W=$(grep -o 'wide=[0-9]*' "$D" 2>/dev/null | head -1 | cut -d= -f2)
  if [ -n "$W" ] && [ "$W" -ge 2 ] 2>/dev/null; then
    echo "PASS case2-wide-marker (wide=$W)"
    PASS=$((PASS + 1))
  else
    echo "FAIL case2-wide-marker (wide=$W)"
    FAIL=$((FAIL + 1))
  fi
  stop_app
fi

# 用例 3：abc + Backspace + d 回车 → abd
D="$OUT/case3-backspace.dump"
if start_app "$D"; then
  xdotool type --window "$WID" "echo abc"
  xdotool key --window "$WID" BackSpace
  xdotool type --window "$WID" "d"
  xdotool key --window "$WID" Return
  assert_dump "case3-backspace-abd" "$D" "abd"
  stop_app
fi

# 用例 4：Ctrl-C 中断 sleep 100 后再 echo 标记串
D="$OUT/case4-ctrlc.dump"
if start_app "$D"; then
  xdotool type --window "$WID" "sleep 100"
  xdotool key --window "$WID" Return
  sleep 1
  xdotool key --window "$WID" ctrl+c
  sleep 1
  xdotool type --window "$WID" "echo MARK_CTRLC"
  xdotool key --window "$WID" Return
  assert_dump "case4-ctrlc" "$D" "MARK_CTRLC"
  stop_app
fi

# 用例 5：Ctrl-D 退出 shell 后 app 5s 内退出
D="$OUT/case5-ctrld.dump"
L="$OUT/case5-ctrl-d.log"
if start_app "$D" "$L"; then
  xdotool key --window "$WID" ctrl+d
  assert_app_exits "case5-ctrl-d-app-exits"
  assert_no_wake "case5-ctrl-d-no-wake" "$L"
fi

# 用例 6：关闭窗口（发 WM_DELETE 协议消息）后 app 5s 内退出
# 实测：run_all 序列环境下 wmctrl -c 的 WM_DELETE 丢失（python 协议直发有效，app 无缺陷）；
# xev 监听会覆盖窗口事件掩码干扰 winit，调试已移除（见 DECISIONS）。
D="$OUT/case6-close.dump"
L="$OUT/case6-close.log"
if start_app "$D" "$L"; then
  python3 "$ROOT/scripts/e2e/wm_send.py" "$WID"
  assert_app_exits "case6-windowclose-app-exits"
  assert_no_wake "case6-windowclose-no-wake" "$L"
fi

# 用例 7：resize 双侧一致（窗口 640x480 像素 → 80x30 格；stty size 一致）
D="$OUT/case7-resize.dump"
if start_app "$D"; then
  xdotool windowsize "$WID" 640 480
  assert_dump "case7-resize-cols" "$D" "cols=80"
  assert_dump "case7-resize-rows" "$D" "rows=30"
  xdotool type --window "$WID" "stty size"
  xdotool key --window "$WID" Return
  assert_dump "case7-stty-size" "$D" "30 80"
  stop_app
fi

# 用例 8：vim/less 交替屏（系统有 vim 或 less 时执行，否则跳过并说明）
if command -v vim >/dev/null 2>&1; then
  D="$OUT/case8-alt.dump"
  if start_app "$D"; then
    xdotool type --window "$WID" "vim"
    xdotool key --window "$WID" Return
    assert_dump "case8-alt-screen-on" "$D" "alternate=true"
    xdotool key --window "$WID" Escape
    xdotool type --window "$WID" ":q"
    xdotool key --window "$WID" Return
    assert_dump "case8-alt-screen-off" "$D" "alternate=false"
    stop_app
  fi
elif command -v less >/dev/null 2>&1; then
  D="$OUT/case8-alt.dump"
  if start_app "$D"; then
    xdotool type --window "$WID" "less"
    xdotool key --window "$WID" Return
    assert_dump "case8-alt-screen-on" "$D" "alternate=true"
    xdotool key --window "$WID" q
    assert_dump "case8-alt-screen-off" "$D" "alternate=false"
    stop_app
  fi
else
  echo "SKIP case8-alt-screen (vim/less 均未安装，无法构造交替屏)"
fi

# ---------- 拖放文件（XDND，真实 GTK 源）：单独 display，避免互相影响 ----------
if [ -f "$ROOT/scripts/e2e/dnd_gtk.sh" ]; then
  echo
  echo "########## dnd-gtk（GTK3 真源端拖放） ##########"
  if sh "$ROOT/scripts/e2e/dnd_gtk.sh" "$APP_BIN"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
fi

# ---------- 拖放文件（XDND）：单独的 display/实例，避免与上面用例互相影响 ----------
if [ -f "$ROOT/scripts/e2e/dnd.sh" ]; then
  echo
  echo "########## dnd（拖放文件，XDND） ##########"
  if sh "$ROOT/scripts/e2e/dnd.sh" "$APP_BIN"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
fi

echo "===== e2e 汇总: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
