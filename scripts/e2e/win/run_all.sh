#!/bin/bash
# Windows e2e 全量：配置矩阵 → 光标 → 粘贴 → 鼠标上报 → IME（上屏 + 候选框锚点）→ 稳定性。
# 用法（Git Bash）：
#   LEANTTY_EXE='C:\path\to\leantty.exe' bash scripts/e2e/win/run_all.sh
# 说明：只操作自己按 tag 启动的实例，不会影响正在使用的 leantty 窗口。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for s in run_config_matrix run_cursor run_paste run_mouse run_ime run_ime_tui run_stability; do
    echo
    echo "########## $s ##########"
    bash "$HERE/$s.sh" || rc=1
done
echo
if [ "$rc" -eq 0 ]; then
    echo "结果：全部通过（含 SKIP 项，详见各节输出）"
else
    echo "结果：有失败项，见上方 FAIL 行"
fi
exit "$rc"
