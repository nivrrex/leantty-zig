#!/bin/bash
# 配置热加载（Windows）：改配置文件后不重启应生效；live_config_reload=false 时不生效。
#
# 断言方式：APP_DUMP_SNAPSHOT 首行的 bg= 值（Windows 侧同样支持这个钩子）。
#
# 用法（Git Bash）：bash scripts/e2e/win/run_reload.sh [exe]
set -u
. "$(dirname "$0")/lib.sh"

case "$(uname -s)" in
*MSYS* | *MINGW* | *CYGWIN*) ;;
*)
    echo "SKIP: 仅 Windows（Git Bash）可跑"
    exit 0
    ;;
esac

CFG="$(unixpath "$WORK")/reload.toml"
cfg_bg() { # $1=背景色 $2=live_config_reload(true/false)
    cat >"$CFG" <<TOMLEOF
[general]
live_config_reload = $2

[colors.primary]
background = "#$1"
TOMLEOF
}

header_bg() { # $1=dump 路径
    head -1 "$1" 2>/dev/null | grep -o 'bg=[0-9a-f]*' | cut -d= -f2
}

echo "== A 开启热加载：改文件后不重启即变色 =="
cfg_bg 111111 true
D="$WORK\\reload.dump"
rm -f "$(unixpath "$D")"
APP_DUMP_SNAPSHOT="$D" start_instance reload-on
pid=$(instance_pid reload-on)
if [ -z "$pid" ]; then
    echo "FAIL 启动: 实例没起来"
    FAIL=$((FAIL + 1))
else
    sleep 1
    got=$(header_bg "$(dump_file reload-on)")
    assert_eq "A 初始配色" "111111" "$got"
    cfg_bg 223344 true
    sleep 1.5
    got=$(header_bg "$(dump_file reload-on)")
    assert_eq "A 改文件后自动生效" "223344" "$got"
    if kill -0 "$pid" 2>/dev/null; then
        echo "PASS A 进程未重启（pid=$pid）"
        PASS=$((PASS + 1))
    else
        echo "FAIL A 进程被重启了"
        FAIL=$((FAIL + 1))
    fi
    stop_instance reload-on
fi

echo "== B 关闭热加载：改文件保持原样 =="
cfg_bg 101010 false
D="$WORK\\reload-off.dump"
rm -f "$(unixpath "$D")"
APP_DUMP_SNAPSHOT="$D" start_instance reload-off
if [ -z "$(instance_pid reload-off)" ]; then
    echo "FAIL 启动: 实例没起来"
    FAIL=$((FAIL + 1))
else
    sleep 1
    got=$(header_bg "$(dump_file reload-off)")
    assert_eq "B 初始配色" "101010" "$got"
    cfg_bg abcdef false
    sleep 1.5
    got=$(header_bg "$(dump_file reload-off)")
    assert_eq "B 关闭热加载后不生效" "101010" "$got"
    stop_instance reload-off
fi

echo
echo "===== reload: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ] || exit 1
