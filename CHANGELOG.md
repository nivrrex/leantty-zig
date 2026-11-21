# 变更记录

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
