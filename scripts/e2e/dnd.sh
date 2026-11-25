#!/bin/sh
# 拖放文件（XDND）验收：把文件"拖"进 leantty 窗口，路径应当写进子进程 stdin。
#
# 断言方式：起一个裸读 stdin 的探针（keydump）当子进程，用 XDND 源探针
# （tools/xdnd_send.c）真发一轮 XdndEnter/Position/Drop，再把探针拿到的字节
# 与"期望字节"逐字节比较——期望值按 alacritty 的口径算：
#   程序开了 bracketed paste（keydump 会开 DEC 2004）时
#   = ESC[200~ + 路径 + 空格 + ESC[201~，多个文件用空格连接、每个后面一个空格。
#
# 用法：sh scripts/e2e/dnd.sh [二进制路径]
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/scripts/e2e/out"
mkdir -p "$OUT"
APP_BIN="${1:-$ROOT/zig-out/bin/leantty}"
ZIG="${ZIG:-/root/Desktop/tty/vt-verify/toolchain/zig/zig}"
DISPLAY_NO=97
PASS=0
FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }

for tool in Xvfb xdotool; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "FATAL: 缺少 $tool"
        exit 1
    }
done
[ -x "$APP_BIN" ] || {
    echo "FATAL: $APP_BIN 不存在"
    exit 1
}

# 只清理自己的 display
if [ -e "/tmp/.X${DISPLAY_NO}-lock" ] || xdpyinfo -display ":$DISPLAY_NO" >/dev/null 2>&1; then
    pkill -f "Xvfb :${DISPLAY_NO} " 2>/dev/null
    sleep 0.4
    rm -f "/tmp/.X${DISPLAY_NO}-lock"
fi
Xvfb :$DISPLAY_NO -screen 0 900x600x24 >"$OUT/dnd-xvfb.log" 2>&1 &
XVFB_PID=$!
DISPLAY=:$DISPLAY_NO openbox >"$OUT/dnd-openbox.log" 2>&1 &
WM_PID=$!
sleep 0.8
export DISPLAY=:$DISPLAY_NO
if command -v openbox >/dev/null 2>&1; then :; else WM_PID=""; fi

: >"$OUT/dnd-empty.toml"
export LEANTTY_CONFIG="$OUT/dnd-empty.toml"
: >"$OUT/dnd.log"

# 探针
KEYDUMP="$OUT/keydump"
[ -x "$KEYDUMP" ] || "$ZIG" cc -O1 "$ROOT/scripts/e2e/tools/keydump.c" -o "$KEYDUMP" >/dev/null 2>&1
XDND_SEND="$OUT/xdnd_send"
[ -x "$XDND_SEND" ] || "$ZIG" cc -O1 "$ROOT/scripts/e2e/tools/xdnd_send.c" -o "$XDND_SEND" -lX11 >/dev/null 2>&1
[ -x "$KEYDUMP" ] || {
    echo "FATAL: keydump 编译失败"
    exit 1
}
[ -x "$XDND_SEND" ] || {
    echo "FATAL: xdnd_send 编译失败"
    exit 1
}

# 载荷：带空格的目录 + 中文文件名（%XX 解码与 UTF-8 都能一起验到）
DROP_DIR="$OUT/dnd payload"
mkdir -p "$DROP_DIR"
F1="$DROP_DIR/文件 1.txt"
F2="$DROP_DIR/second file.txt"
printf 'one\n' >"$F1"
printf 'two\n' >"$F2"

APP_PID=""
WID=""
stop_app() {
    [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
    [ -n "$APP_PID" ] && wait "$APP_PID" 2>/dev/null
    APP_PID=""
}
trap 'stop_app; kill $XVFB_PID ${WM_PID:-} 2>/dev/null' EXIT INT TERM

start_app() { # $1.. 传给 leantty 的参数
    stop_app
    "$APP_BIN" "$@" >>"$OUT/dnd.log" 2>&1 &
    APP_PID=$!
    WID=""
    i=0
    while [ $i -lt 50 ]; do
        WID=$(xdotool search --pid "$APP_PID" 2>/dev/null | tail -1)
        [ -n "$WID" ] && break
        sleep 0.1
        i=$((i + 1))
    done
    [ -n "$WID" ] || return 1
    sleep 0.5
    return 0
}

# 期望字节：LF 分隔的十六进制，一行一个字节
expect_hex() { # $1=bracketed(0/1) 其余=路径
    python3 - "$@" <<'PY'
import sys
bracketed = sys.argv[1] == '1'
paths = sys.argv[2:]
data = b''
if bracketed:
    data += b'\x1b[200~'
for p in paths:
    data += p.encode('utf-8') + b' '
if bracketed:
    data += b'\x1b[201~'
print('\n'.join(f'{b:02x}' for b in data))
PY
}

# 取探针落盘的字节（每行 "xx xx xx "）
probe_hex() { # $1=文件
    tr -s ' ' '\n' <"$1" 2>/dev/null | grep -E '^[0-9a-f]{2}$'
}

run_drop_case() { # $1=标签 $2=期望hex $3..=要拖的路径
    label="$1"
    want="$2"
    shift 2
    KF="$OUT/dnd-$label.txt"
    : >"$KF"
    NO_BR=""
    case "$label" in nobr*) NO_BR=1 ;; esac
    # 注意：KEYDUMP_NO_BRACKETED 只在需要时"存在"——设成空串也算已设置（getenv 非 NULL），
    # 会让探针不开 DEC 2004，第一条用例就会误判成"没包裹"。
    if [ -n "$NO_BR" ]; then
        KEYDUMP_OUT="$KF" KEYDUMP_NO_BRACKETED=1 start_app -e "$KEYDUMP" || {
            bad "$label：窗口没起来"
            return
        }
    else
        KEYDUMP_OUT="$KF" start_app -e "$KEYDUMP" || {
            bad "$label：窗口没起来"
            return
        }
    fi
    out=$("$XDND_SEND" "$WID" "$@" 2>&1)
    rc=$?
    sleep 0.6
    got=$(probe_hex "$KF")
    if [ "$rc" -ne 0 ]; then
        bad "$label：xdnd_send 失败 rc=$rc" "$out"
        return
    fi
    if [ "$got" = "$want" ]; then
        ok "$label（$(printf '%s' "$got" | wc -l) 字节）"
    else
        # 失败时把两边都打出来，便于判断是"没收到""多了字节"还是"内容不对"
        echo "---- 期望 ----"
        printf '%s\n' "$want" | tr '\n' ' '
        echo
        echo "---- 实得 ----"
        printf '%s\n' "$got" | tr '\n' ' '
        echo
        bad "$label：字节不一致"
    fi
}

echo "== 1. 单个文件（路径含空格与非 ASCII） =="
run_drop_case one "$(expect_hex 1 "$F1")" "$F1"

echo "== 2. 两个文件（空格连接，每个后面一个空格） =="
run_drop_case two "$(expect_hex 1 "$F1" "$F2")" "$F1" "$F2"

echo "== 3. 程序没开 bracketed paste 时不包裹（KEYDUMP_NO_BRACKETED=1） =="
run_drop_case nobr "$(expect_hex 0 "$F1")" "$F1"

echo
echo "===== dnd: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ] || exit 1
