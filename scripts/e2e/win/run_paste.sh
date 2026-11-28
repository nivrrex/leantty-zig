#!/bin/bash
# 粘贴/复制链路验收：
#   A 中文 + 多行（findstr 即时回显）
#   B Shift+Insert 等价快捷键
#   C >64 KiB（300 KB）：靠 LEANTTY_KDBG 的 clipboard-read 扩容与 pty-write 长度断言
#   D CRLF 载荷：每行只出现一次（换行归一不重复）
#   E Ctrl+Insert 复制（无选区 → 全屏）
# shellcheck source=scripts/e2e/win/lib.sh
. "$(dirname "$0")/lib.sh"

P="$WORK/paste"
mkdir -p "$(unixpath "$P")"
PU="$(unixpath "$P")"

# 载荷（LF）
printf '第一行\n第二行\n你好世界\n' >"$PU/zh.txt"
# 载荷（CRLF，模拟 Windows 编辑器）
printf 'alpha\r\nbeta\r\ngamma\r\n' >"$PU/crlf.txt"
# 300 KB 载荷
python - "$PU/heavy.txt" <<'PY'
import sys, io
line = '0123456789abcdef\n'          # 17 字节
n = 300 * 1024 // len(line)
io.open(sys.argv[1], 'wb').write((line * n).encode())
PY
HEAVY_SIZE=$(stat -c %s "$PU/heavy.txt")

echo "== A 中文 + 多行（Ctrl+Shift+V） =="
if ! set_clipboard_from_file "$PU/zh.txt"; then
  echo "FAIL A: 剪贴板未被设置"
  FAIL=$((FAIL + 1))
fi
start_instance pasteA -e 'cmd.exe /c findstr .'
powershell -NoProfile -ExecutionPolicy Bypass -File "$SEND" -cmdLike 'i\pasteA' -keys '^+v' >/dev/null 2>&1
sleep 1.5
assert_grep "A 第一行" "第一行" "$(dump_file pasteA)"
assert_grep "A 第二行" "第二行" "$(dump_file pasteA)"
assert_grep "A 你好世界" "你好世界" "$(dump_file pasteA)"
# 每行都会出现两次：控制台回显 + 程序输出，所以只断言内容存在性
stop_instance pasteA

echo "== B Shift+Insert =="
if ! set_clipboard_from_file "$PU/zh.txt"; then
  echo "FAIL B: 剪贴板未被设置"
  FAIL=$((FAIL + 1))
fi
start_instance pasteB -e 'cmd.exe /c findstr .'
powershell -NoProfile -ExecutionPolicy Bypass -File "$SEND" -cmdLike 'i\pasteB' -keys '+{INSERT}' >/dev/null 2>&1
sleep 1.5
assert_grep "B 中文" "你好世界" "$(dump_file pasteB)"
stop_instance pasteB

echo "== C >64 KiB（300 KB, $HEAVY_SIZE 字节） =="
if ! set_clipboard_from_file "$PU/heavy.txt"; then
  echo "FAIL C: 剪贴板未被设置"
  FAIL=$((FAIL + 1))
fi
start_instance pasteC -e 'cmd.exe /c more'
powershell -NoProfile -ExecutionPolicy Bypass -File "$SEND" -cmdLike 'i\pasteC' -keys '^+v' >/dev/null 2>&1
sleep 2.5
assert_grep "C 扩容重读" "clipboard-read cap=262144 -> -" "$(log_file pasteC)"
assert_grep "C 全部写入 PTY" "pty-write $HEAVY_SIZE bytes" "$(log_file pasteC)"
assert_not_grep "C 没有截断痕迹" "clipboard-read cap=262144 -> [0-9]* bytes" "$(log_file pasteC)"
stop_instance pasteC

echo "== D CRLF 载荷不重复换行 =="
if ! set_clipboard_from_file "$PU/crlf.txt"; then
  echo "FAIL D: 剪贴板未被设置"
  FAIL=$((FAIL + 1))
fi
start_instance pasteD -e 'cmd.exe /c findstr .'
powershell -NoProfile -ExecutionPolicy Bypass -File "$SEND" -cmdLike 'i\pasteD' -keys '^+v' >/dev/null 2>&1
sleep 2.5
# 控制台回显与程序输出共用同一光标位置，可能互相覆盖，所以只断言：
#   * 三行内容都到了（内容完整性）
#   * 前 6 行里没有空行（CRLF 若被重复归一，会多出空行）
head6="$(dump_text pasteD | sed -n '1,6p')"
assert_eq "D 前 6 行无空行" "0" "$(printf '%s
' "$head6" | grep -c '^$')"
assert_grep "D alpha" "alpha" "$(dump_file pasteD)"
assert_grep "D beta" "beta" "$(dump_file pasteD)"
assert_grep "D gamma" "gamma" "$(dump_file pasteD)"
stop_instance pasteD

echo "== E Ctrl+Insert 复制（无选区 → 全屏） =="
printf 'COPY-MARKER-123\n' >"$PU/copy.txt"
set_clipboard_from_file "$PU/copy.txt" || true
start_instance pasteE -e 'cmd.exe /k'
powershell -NoProfile -ExecutionPolicy Bypass -File "$SEND" -cmdLike 'i\pasteE' -keys 'echo COPIED-LINE-ABC{ENTER}' >/dev/null 2>&1
sleep 1.2
powershell -NoProfile -ExecutionPolicy Bypass -File "$SEND" -cmdLike 'i\pasteE' -keys '^{INSERT}' >/dev/null 2>&1
sleep 0.8
get_clipboard_to_file "$PU/clip_out.txt"
assert_grep "E 剪贴板含屏幕内容" "COPIED-LINE-ABC" "$PU/clip_out.txt"
stop_instance pasteE

summary
