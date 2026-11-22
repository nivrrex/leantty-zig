# 变更记录

## 0.1.7

### 修复（Linux + Windows）

- **中文（及所有回退字体）字形顶部被裁掉 1px**：字形定位用的是主字体的 `ascent`，
  而 CJK 回退字体的字形更高（实测主字体 Consolas asc=12、回退 HYQiHei asc=15，
  字形 `top=13` → 第一行落在 `-1` 被丢弃）。度量改为**取所有可缩放字面的最大值**
  （`ascent`/`descent`/`height`，纯位图 emoji 字体排除），行高取 `max(height, ascent+descent)`。
  验证：同一份真实字体链下 14 个 CJK 码位裁切量从"顶 1px"变为 0。
  副作用：行高可能比主字体单独算出的高 1–2px（例如 16px 下 19px → 21px）。
- **SGR 2（faint/dim）灰阶与 Rust 版不一致**：原来按"向背景混合 60%"，而 ghostty 的语义是
  `faint-opacity = 0.5`、Rust 版 `dim()` 是 `fg/2 + bg/2`。改为 50%，两边灰阶一致
  （同一单元格实测 Rust `(145,145,144)`、旧实现 `(126,127,127)`）。

### 修复（仅 Windows）

- **选中文字后再单击，黑色选框不消失**：`MOUSE_RELEASE` 之前只在拖拽分支里清 `drag` 标志，
  单击路径没有结束拖拽状态；同时 `MOUSE_MOTION` 只要 `drag` 为真就重建选区，
  而 Windows 在按下/抬起之间会投递"没动"的 `WM_MOUSEMOVE`，于是留下 1 格选区。
  现在：motion 只在格子真的变化时建选区；release 时若无拖拽（或回到锚点格）显式清选区。

### 测试

- 单元测试 34 个（`faint` 用例改为断言 50% 混合）。

## 0.1.6

### 修复（Windows）

- **全屏 TUI 里看不见候选框**（能盲输、汉字能上屏）。根因：`position_ime()` 用
  `cursor_x/cursor_y` 定位，而该值表示"这一帧要不要画光标"——TUI 隐藏光标或处在闪烁灭相时
  它是 `-1`，被夹成 `(0,0)` 后正好等于缓存初值，函数**直接早退**，`ImmSetCandidateWindow`
  一次都没被调用，候选框停在 IME 默认位置。改为用 `cursor.viewport` 单独算 IME 锚点
  （与可见性/闪烁无关），只在拿到真实光标格时更新。
- **贴底时候选框被顶出屏幕**：光标下方不足 3 行时改用 `CFS_EXCLUDE`（排除光标所在行以下区域），
  由 IME 自行向上挑位置。
- **字形缓存越界**（`SIGSEGV` / 花屏）：`glyph_entry` 的 `cap` 同时描述 `alpha`(`w*h`) 与
  `color`(`w*h*4`) 两个缓冲，"先彩色后灰度"命中同一槽时跳过分配 → `memset` 到 NULL/偏小缓冲。
  拆成 `cap_alpha` / `cap_color`，加空指针守卫，彩色条目不再落进灰度读路径。
- `--working-directory` 之前对子进程无效（`w32_spawn` 的 cwd 恒为 null）。

### 测试

- Windows IME e2e 重写为真正可跑：先单按 `Shift` 切中文、用 `keybd_event` 逐键打字
  （`SendKeys` 不走组词通路），断言 `你好` / `wide=2` / 单次提交 / `ime pos`；
- 新增 `run_ime_tui.sh`（`tools/altui.c` 造"备用屏 + 光标在 (4,19)"的 TUI 现场），
  断言锚点不是 `(0,0)`；新增 `tools/ime_shift.ps1`、`tools/type_keys.ps1`；
- 单元测试 34 个。

### 文档

- 安装示例不再写死版本号（`leantty-zig_<版本号>_amd64.deb`），改为"以 Releases 页最新版为准"；
  `docs/BUILD.md` 的打包示例同理。
- 修正 0.1.3 之后就不再成立的描述：`backend = "gpu"` 是**字形图集直画**（不再"上传成品帧"），
  README 能力段与 `config/leantty.example.toml` 注释同步。
- 更新 Windows 能力状态：中文输入法（微软拼音）**已在真机验证**，含全屏 TUI 里的候选框定位
  （0.1.6 修复）；仍未验证的只剩鼠标上报（1000/1002/1006）。
- `docs/BUILD.md`：IBus/GLib 只需头文件（运行期 `dlopen`，不参与链接）。
- README 测试小节补 `run_gpu_parity.sh` 与 Windows e2e 入口并指向 `scripts/e2e/win/README.md`；
  环境变量表补 `APP_DUMP_COLORS`。
- README 两张性能表补测量口径（时间、硬件、"旧结果不代表当前版本"）。
- `scripts/e2e/win/README.md`：补 `run_ime_tui.sh` 与 `ime_shift.ps1`/`type_keys.ps1` 等工具、
  目录树，并写明"输入法默认英文态、需单按 Shift 切中文"和"`SendKeys` 不走组词通路"。

### 打包

- 两个发行包随附 FreeType 许可全文 `FTL.TXT`（FTL 要求二进制分发附带许可）；deb 装到
  `/usr/share/doc/leantty-zig/FTL.TXT`，zip 放根目录。
- 新增 `vendor/freetype/VENDOR.md` 说明裁剪范围与上游来源。

### 更正

- 撤回上一版内部记录里的"基本符号渲染成错误字形"：放大到 30px 逐块核对后箭头/方块/几何/
  数学/CJK 全部正确，早前是在 8×18 小格子里把密集符号误读成杂点。

## 0.1.5

### 修复（仅 Windows）

- **从 cmd 启动时诊断全丢（0.1.3 回归）**：`w32_init_console()` 用的 `freopen_s` 在本机
  mingw 运行库里只建文件、不接流（实测文件 0 字节），导致 `LEANTTY_KDBG` 抓不到任何输出。
  改用 `freopen`。
- **开了中文输入法就打不出字**：窗口激活时线程的 `hwndFocus` 是 0（`GetGUIThreadInfo` 实测），
  TSF 输入法没有可依附的焦点窗口，按键被吞且不产生 `WM_IME_*`。`WM_ACTIVATE`
  时显式 `SetFocus(hwnd)`。修完 `hwndFocus=hwnd`、按键流恢复。
- 新增 `LEANTTY_KDBG_FILE=<路径>`：把诊断写到文件，绕开 GUI 子系统下 stderr 被接管的问题。

### 变更

- Windows e2e 脚本适配 GUI 子系统（诊断走文件）与 MSYS 参数转换
  （`-e cmd.exe //k` 会被路径转换破坏，改传单参数 `-e 'cmd.exe /k'`）；
  新增 `tools/conread.c`（读控制台屏幕文本，用于 IME 交叉对照）。

### 已知限制

- IME 与鼠标上报仍是**环境未验证**：测试机的"微软拼音"在任何应用（含真实 cmd、
  Notepad3）都无法上屏，属系统层问题；`Windows Terminal` 装不上，而 inbox conhost
  不转发 `DECSET 1000/1002/1006`。两者均未改编码逻辑，`run_ime.sh` 已把
  "只有 cmd 能上屏而 leantty 不能才判 FAIL" 固化为自动判据。
- DPI 125%/150% 切换未取得真机证据（单显示器、`SET_DPI_SCALE` 返回 `ERROR_INVALID_PARAMETER`）。

## 0.1.4

### 修复

- **deb 依赖不可安装**：`Depends` 里写死的 `libglib2.0-0` / `libgobject-2.0-0` / `libibus-1.0-5`
  在部分机器上无法满足（glib 系列包名在 Debian 从 bookworm 到 trixie 改成了 `*-t64`），
  导致 `apt install ./leantty-zig_*.deb` 直接失败。根因是链接期硬依赖了 IBus/GLib。
- IBus/GLib/GObject 改为**运行期 `dlopen` 绑定**（`src/ibus.c`）：二进制不再 `NEEDED` 这三个库，
  没有 IBus 的机器上不再因动态链接失败而起不来，输入法按需降级关闭并打印原因。
- `Depends` 只剩直接链接的库；IBus 降为 `Recommends: libibus-1.0-5`。

### 变更

- **可执行文件改名为 `leantty`**（Linux `/usr/bin/leantty`、Windows `leantty.exe`），
  桌面条目与图标同名；包内声明 `Conflicts/Replaces: leantty`，与 Rust 版不同时装、不共存。
- 打包脚本 `scripts/package-deb.sh`、`scripts/package-windows.sh` 同步改名；
  `docs/IME-MANUAL-TEST.md` 去掉一处本机绝对路径（公开文档不带本机路径）。
## 0.1.3

- **新增 GPU 直画渲染后端**（`backend = "gpu"`）：字形进 2048² RGBA 图集，每帧一次 draw call 绘制
  背景四边形与字形四边形，不再上传整帧。与 CPU 光栅**逐像素一致**（`scripts/e2e/run_gpu_parity.sh`：
  0/672000 差异）；探针实测帧成本 26.44 ms → 4.23 ms（1920x1080、16k 格）。
- 修复：GPU 初始化顺序（未 makeCurrent 时创建 GL 对象无效 → 全黑）、字形图集标记写在缓存副本上
  （每帧重传全部字形 → 真机 30–40 s）。
- 输出突发合并：连续两轮都有 PTY 数据时跳过呈现，避免被呈现/交换限速。
- 默认后端仍为 CPU + XShm（真机最稳）；启动时打印 `renderer: cpu (XShm)` 或 `renderer: gpu (GL_RENDERER)`。
- README 增加性能小节：呈现后端选择、四条 GPU 路径的帧成本、与 alacritty / Rust 版的对比与口径说明。
- 基准脚本：`scripts/perf/glbench.c`、`bench_three_terms.py`、`bench_on_display.py`、`cpu_per_mb.py`。

## 0.1.2

- **空闲 CPU 修复**：此前主循环在帧预算到期时无条件重绘并 `XShmPutImage`，即使屏幕无任何变化，
  实测空闲占用约 12.7% CPU。现在只有 VT 脏、光标移动/可见性变化、滚动条变化或显式强制时才渲染，
  空闲回到 0.0–0.3%（与 alacritty / Rust 版一致）。
- 窗口设置 `_NET_WM_PID`，`xdotool search --pid`、wmctrl 等工具可以按进程定位窗口。
- 新增三方基准脚本 `scripts/perf/bench_three_terms.py` 与 `scripts/perf/cpu_per_mb.py`；
  本机实测（Xvfb、DejaVu Sans Mono 13pt、120x30）：启动 78 ms、20MB 输出净耗时 437 ms（45.8 MB/s）、
  每 MB CPU 36.6 ms。

## 0.1.1

Windows 后端修复（Linux 侧不受影响）：

- 配置生效：Windows 下补 `%APPDATA%\leantty\leantty.toml` 默认路径；配置文本支持 UTF-8 BOM 与
  UTF-16LE/BE；只配置 `background` 或 `foreground` 之一时不再整体失效；`app_win` 现在把配色真正交给
  VT 核心（此前 Windows 走的是 `createWithScrollback`，配色被丢弃）。
- 粘贴：剪贴板读取改为"容量不足返回所需大小"由调用方扩容重读（>64 KiB / 中文多行不再静默失败）；
  长度以 `GlobalSize` 为上限并按首个 NUL 截断；`CF_TEXT` 回退；`OpenClipboard` 失败重试；
  新增 `Ctrl+Insert` 复制 / `Shift+Insert` 粘贴与 `[[mouse.bindings]]`（右键/中键到 Copy/Paste）。
- 光标：修正 `WM_SETFOCUS` 事件恒为 0 导致窗口被判失焦（光标整体不画）；支持 DECSCUSR 四态
  （block / bar / underline / block_hollow）、光标颜色与闪烁；`[cursor] style` 配置项生效。
- 新增 `scripts/e2e/win/`（配置矩阵、粘贴、光标、鼠标、IME、稳定性），Windows 侧 30 PASS / 2 SKIP。
- 版本号 0.1.1。

## 0.1.0

Zig 实现的第一个发布快照。以下为当前状态，不含历史：

- VT 核心：libghostty（pin `0b8b9984e`）——宽字符、字素簇、回流、回滚、备用屏、括号粘贴、
  OSC 0/2/4/10/11/52。
- Linux X11 后端：CPU 帧缓冲渲染，可选 GLX 呈现（`backend = auto|cpu|gpu`），SHM 图像传输，
  `WM_TAKE_FOCUS` 处理，桌面条目带图标。
- Windows 后端：ConPTY、DIB 双缓冲、FreeType 字体、Imm32 输入法、剪贴板、鼠标选区、
  Per-Monitor DPI、内嵌窗口图标。
- 字体（两平台）：FreeType、四个样式槽、不做合成粗体/斜体、可配置回退链 + 内置 emoji/符号兜底、
  Linux 彩色 emoji（CBDT）、`font.size` 按点并乘 Xft.dpi。
- 文本：下划线样式（单/双/波浪/点/虚线）、删除线、上划线、反显、隐藏、淡色、
  256 色/真彩色、`draw_bold_text_with_bright_colors`。
- 输入：49 条按键矩阵上与 alacritty 逐字节一致的编码；IBus 输入法含 Shift 轻按切换；
  鼠标上报；选区与剪贴板；带滚动条的滚轮回滚。
- 配置：与 Rust 版 `leantty` 兼容的 TOML 子集；未实现的键在启动时提示。
- 工具：端到端用例（共享 + Zig 特有 + 按键矩阵）、跨平台字体黄金文件。

已知限制见 README。
