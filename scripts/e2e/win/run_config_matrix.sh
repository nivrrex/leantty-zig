#!/bin/bash
# 配置矩阵（任务书 2 节 1.1–1.7）：全部用 APP_DUMP_SNAPSHOT 首行断言 bg=/fg=，
# 1.7 断言 stderr 的“未实现，已忽略”告警。
#
# 1.1 用临时 APPDATA 目录而不是真实的 %APPDATA%，避免改动开发机上的用户配置
# （代码路径完全一致：configPath() 读 env[APPDATA] + "\leantty\leantty.toml"）。
. "$(dirname "$0")/lib.sh"

CFG="$WORK/cfg"
mkdir -p "$(unixpath "$CFG")"
umask 022

printf '[colors.primary]\nbackground = "#f3f1e9"\nforeground = "#101010"\n' >"$(unixpath "$CFG")/light.toml"
printf '[colors.primary]\nbackground = "#102030"\nforeground = "#e0e0e0"\n' >"$(unixpath "$CFG")/alt.toml"
printf '[colors.primary]\nbackground = "#204060"\n' >"$(unixpath "$CFG")/bgonly.toml"
printf '[window.padding]\nx = 4\n' >"$(unixpath "$CFG")/unknown.toml"
python - "$(unixpath "$CFG")" <<'PY'
import sys, io, os
d = sys.argv[1]
s = '[colors.primary]\nbackground = "#f3f1e9"\nforeground = "#101010"\n'
io.open(os.path.join(d, 'bom.toml'), 'wb').write(b'\xef\xbb\xbf' + s.encode())
io.open(os.path.join(d, 'utf16.toml'), 'wb').write(b'\xff\xfe' + s.replace('\n', '\r\n').encode('utf-16-le'))
io.open(os.path.join(d, 'crlf.toml'), 'wb').write(s.replace('\n', '\r\n').encode())
PY

# 1.1：把配置放到 <临时 APPDATA>\leantty\leantty.toml，不设 LEANTTY_CONFIG
export APPDATA="$CFG\\appdata"
mkdir -p "$(unixpath "$APPDATA")/leantty"
cp "$(unixpath "$CFG")/light.toml" "$(unixpath "$APPDATA")/leantty/leantty.toml"
unset LEANTTY_CONFIG
echo "== 1.1 %APPDATA%\\leantty\\leantty.toml =="
start_instance cfg11 -e 'cmd.exe /c exit'
assert_grep "1.1 bg" "bg=f3f1e9 fg=101010" "$(dump_file cfg11)"
stop_instance cfg11

run_cfg() { # id file expected
    echo "== $1 $(basename "$2") =="
    export LEANTTY_CONFIG="$CFG\\$(basename "$2")"
    start_instance "$1" -e 'cmd.exe /c exit'
    assert_grep "$1" "$3" "$(dump_file "$1")"
    stop_instance "$1"
}

run_cfg cfg12 "$(unixpath "$CFG")/alt.toml" "bg=102030 fg=e0e0e0"
run_cfg cfg13 "$(unixpath "$CFG")/bom.toml" "bg=f3f1e9 fg=101010"
run_cfg cfg14 "$(unixpath "$CFG")/utf16.toml" "bg=f3f1e9 fg=101010"
run_cfg cfg15 "$(unixpath "$CFG")/crlf.toml" "bg=f3f1e9 fg=101010"
run_cfg cfg16 "$(unixpath "$CFG")/bgonly.toml" "bg=204060 fg=ffffff"

echo "== 1.7 未实现键的告警 =="
export LEANTTY_CONFIG="$CFG\\unknown.toml"
start_instance cfg17 -e 'cmd.exe /c exit'
assert_grep "1.7 告警" "未实现，已忽略: window.padding.x" "$(log_file cfg17)"
stop_instance cfg17

unset LEANTTY_CONFIG
summary
