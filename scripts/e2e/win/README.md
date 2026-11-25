# Windows 端到端用例（Git Bash / MSYS）

所有断言都读 `APP_DUMP_SNAPSHOT` 的文本（首行含 `cols/rows/wide/spacer/alternate/cursor/cursor_visible/bg/fg`），
不依赖人看截图；截图只作为附加产物。

## 运行

```bash
# 用刚构建好的二进制（默认找仓库内 zig-out/bin/leantty.exe）
bash scripts/e2e/win/run_all.sh

# 指定二进制 / 工作目录 / zig
LEANTTY_EXE='C:\work\out\bin\leantty.exe' WORK='C:\temp\e2e' bash scripts/e2e/win/run_all.sh
```

依赖：Git Bash、PowerShell 5.1、`zig`（仅 `run_mouse.sh` 编探针用，可用 `ZIG=` 指定全路径）。

## 用例

| 脚本 | 覆盖 | 断言要点 |
|---|---|---|
| `run_config_matrix.sh` | 配置 1.1–1.7 | `bg=`/`fg=` 实际值；1.7 断言 stderr 告警 |
| `run_cursor.sh` | 光标四态 + 闪烁 + 失焦可见 | `cursor=<形状>`、`cursor_visible` 在 0/1 间翻转；每态一张图 |
| `run_paste.sh` | 粘贴/复制：中文多行、Shift+Insert、>64 KiB、CRLF、Ctrl+Insert | 屏幕内容；`LEANTTY_KDBG` 的 `clipboard-read` 扩容与 `pty-write` 字节数 |
| `run_mouse.sh` | 鼠标上报 1002/1006 | 探针能收到点击 → PASS；conhost 不转发 → SKIP（附证据） |
| `run_ime.sh` | 输入法组词上屏 | **先单按 `Shift` 切中文**，再用 `keybd_event` 逐键打字（`SendKeys` 不走组词通路）；断言「你好」、`wide=2`、单次提交、日志里出现 `ime pos` |
| `run_ime_tui.sh` | TUI 候选框锚点 | 用 `tools/altui.c` 造「备用屏 + 光标在 (4,19)」现场，断言 `ime pos anchor=(4,19)` 且不是 `(0,0)`（0.1.6 修的缺陷） |
| `run_select.sh` | 选区高亮 | 拖选后用 `imgdiff.ps1` 比像素：单击后画面必须回到"无选区"基线（MAD≈0） |
| `run_stability.sh` | 10 万行输出 / 空闲 CPU / 内存 | 末行 `L100000`、峰值 WS < 200 MB、空闲 CPU < 2%、8 秒内存增长 < 8 MB |
| `run_fallback.sh` | 缺 `conpty.dll` 的回退路径 | 日志 `kernel32 (inbox conhost)` + 降级警告；`Ctrl+C=03`、`Ctrl+A=01`、粘贴无 `ESC[200~` |
| `run_dnd.sh` | 拖放文件 | `tools/dropfiles.c` 发 `WM_DROPFILES`，keydump 收到 `ESC[200~ + 路径 + 空格 + ESC[201~` |

## 前置：输入法默认英文态

测试机的输入法**默认英文，单按一次 `Shift` 才切中文**；直接键入 `nihao` 只出 ASCII 属正常，
不是"输入法不工作"。IME 用例必须按 `ime_shift.ps1` → `type_keys.ps1` 的顺序驱动。

## 约定（重要）

- **只按 tag 清理自己启动的实例**：每个用例用唯一 `--working-directory`（`<WORK>\i\<tag>`），
  `stop_instance <tag>` 匹配「exe 文件名 + tag」，绝不按进程名批量杀进程——开发机上可能正开着另一个 leantty 窗口。
- 剪贴板是全局资源：`set_clipboard_from_file` 会写入后**回读比对**，失败会显式报错
  （曾因为 Set-Clipboard 静默失败，把上一轮的旧剪贴板内容当成本轮载荷）。
- `LEANTTY_KDBG=1` 打开 `[win] ...` 诊断日志（焦点/首帧光标/剪贴板字节数/IME 提交/PTY 写入长度），
  日志落在 `<WORK>/<tag>.log`，粘贴与光标类断言直接读它。
- 1.1 用例使用**临时 APPDATA**（`<WORK>/cfg/appdata`），不会改动真实的 `%APPDATA%\leantty\leantty.toml`。

## 目录

```
scripts/e2e/win/
├── lib.sh                 # 公共函数（实例生命周期、dump 断言、剪贴板校验、采样）
├── run_all.sh             # 全量
├── run_config_matrix.sh   # 配置矩阵
├── run_cursor.sh          # 光标
├── run_paste.sh           # 粘贴/复制
├── run_mouse.sh           # 鼠标上报（含平台限制的 SKIP 判定）
├── run_ime.sh             # 输入法（Shift 切中文 + keybd_event）
├── run_ime_tui.sh         # TUI 里候选框锚点
├── run_select.sh          # 选区高亮（像素判据：单击后选区必须消失）
├── run_stability.sh       # 稳定性
└── tools/
    ├── ime_shift.ps1      # 单按一次 Shift（切中/英）
    ├── type_keys.ps1      # keybd_event 逐键打字（IME 组词必须用它）
    ├── send_keys.ps1      # 聚焦窗口并 SendKeys（不走组词通路，只适合非 IME 用例）
    ├── click.ps1          # 客户区坐标点击/拖拽
    ├── conread.c          # 读指定控制台进程的屏幕文本（IME 交叉对照）
    ├── altui.c            # 假 TUI：备用屏 + 指定光标格（锚点回归）
    ├── shot.ps1           # PrintWindow 截图（被遮挡也能截）
    ├── imgdiff.ps1        # 两张截图的像素差（MAD），run_select.sh 用
    ├── mouse_gesture.ps1  # 拖选/单击等手势脚本
    └── mousedump.c        # 鼠标上报探针（run_mouse.sh 用 zig cc 编译）
```
