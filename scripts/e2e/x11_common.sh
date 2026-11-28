#!/bin/sh
# X11 e2e 公共清理：只按 display lock 中的精确 PID 清理陈旧 Xvfb。
# 本文件仅供 source，不改变调用方的 shell 选项。

x11_kill_stale_display() {
  _x11_no="$1"
  _x11_lock="/tmp/.X${_x11_no}-lock"
  [ -e "$_x11_lock" ] || return 0

  _x11_pid=""
  read -r _x11_pid <"$_x11_lock" 2>/dev/null || true
  case "$_x11_pid" in
    '' | *[!0-9]*) ;;
    *)
      if kill -0 "$_x11_pid" 2>/dev/null; then
        if [ -r "/proc/$_x11_pid/comm" ] && grep -qx 'Xvfb' "/proc/$_x11_pid/comm"; then
          kill "$_x11_pid" 2>/dev/null || true
          _x11_i=0
          while [ "$_x11_i" -lt 20 ] && kill -0 "$_x11_pid" 2>/dev/null; do
            sleep 0.1
            _x11_i=$((_x11_i + 1))
          done
        fi
      fi
      if ! kill -0 "$_x11_pid" 2>/dev/null; then
        rm -f "$_x11_lock"
      fi
      ;;
  esac
  if [ -e "$_x11_lock" ]; then
    echo "FATAL: display :$_x11_no 仍被占用，拒绝清理未知进程" >&2
    return 1
  fi
  return 0
}
