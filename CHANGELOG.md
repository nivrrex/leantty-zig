# 变更记录

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
