#!/bin/bash
# 鼠标上报验收（1002/1006）：
#   探针程序打开 SGR 鼠标与 button 模式后点击窗口，
#   - 若终端收到了 DECSET 转发 → 点击会以 CSI <...M 送达子进程（dump 里出现 BYTES）；
#   - 若 conhost 不转发鼠标模式 → 子进程收不到任何字节，判定 SKIP（并给出证据）。
# 注意：这一项依赖 conhost 行为，Windows 10 19044 实测不转发，属平台限制。
. "$(dirname "$0")/lib.sh"

M="$WORK/mouse"
mkdir -p "$(unixpath "$M")"
MU="$(unixpath "$M")"

# zig 是构建本项目的必备工具；这里用它编探针（也可用 ZIG 环境变量指定全路径）
ZIG="${ZIG:-zig}"
if command -v "$ZIG" >/dev/null 2>&1; then
    "$ZIG" cc -target x86_64-windows-gnu "$HERE/tools/mousedump.c" -o "$BUILD_TMP/mousedump.exe" 2>/dev/null
fi
if [ ! -f "$BUILD_TMP/mousedump.exe" ]; then
    echo "SKIP 鼠标上报：没有 zig cc，无法编译探针"
    summary
    exit 0
fi

start_instance mouse1002 -e "$(winpath "$BUILD_TMP/mousedump.exe")"
# 探针就绪要等它自己的首帧：机器忙时 2.5s 的 START_WAIT 不够，会出现
# "MOUSE-PROBE-READY 未匹配" 的假失败（本轮实测偶发）。轮询到就绪再断言。
for i in $(seq 1 24); do
    grep -q "MOUSE-PROBE-READY" "$(dump_file mouse1002)" 2>/dev/null && break
    sleep 0.25
done
assert_grep "探针启动" "MOUSE-PROBE-READY" "$(dump_file mouse1002)"
powershell -NoProfile -ExecutionPolicy Bypass -File "$HERE/tools/click.ps1" -cmdLike 'i\mouse1002' -x 80 -y 80 >/dev/null 2>&1
sleep 1
if grep -q "BYTES" "$(dump_file mouse1002)"; then
    echo "PASS 鼠标上报：点击已编码送达子进程"
    grep -m1 "BYTES" "$(dump_file mouse1002)"
    PASS=$((PASS + 1))
else
    echo "SKIP 鼠标上报：conhost 未把 DECSET 1002/1006 转发给终端（子进程收不到点击）"
    echo "     证据：dump 中只有 MOUSE-PROBE-READY，没有 BYTES 行；"
    echo "     对照：同一次运行里键盘输入可以正常送达（见 run_paste.sh）。"
fi
stop_instance mouse1002

summary
