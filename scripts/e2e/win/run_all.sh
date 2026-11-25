#!/bin/bash
# Windows e2e 全量：配置矩阵 → 光标 → 粘贴 → 选区高亮 → 鼠标上报 → IME（上屏 + 候选框锚点）→ 稳定性 → 缺 dll 的回退路径 → 拖放文件。
# 用法（Git Bash）：
#   LEANTTY_EXE='C:\path\to\leantty.exe' bash scripts/e2e/win/run_all.sh
# 说明：只操作自己按 tag 启动的实例，不会影响正在使用的 leantty 窗口。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 先清空剪贴板：上一轮/别的窗口残留的内容会让 run_paste 的"300KB 扩容"用例读到旧载荷
# （实测过：残留 23 字节的 alpha/beta/gamma 导致 pasteC 三条假失败）。
powershell -NoProfile -Command "Set-Clipboard -Value ''" >/dev/null 2>&1 || true
rc=0
for s in run_config_matrix run_cursor run_paste run_select run_mouse run_ime run_ime_tui run_stability run_fallback run_dnd; do
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
