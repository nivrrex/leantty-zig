# leantty-zig

一个用 Zig 编写的小型终端模拟器，VT 核心直接使用 **libghostty**。

本仓库是 Rust 项目 [**leantty**](https://github.com/nivrrex/leantty) 的**独立 Zig 实现**：两套代码
互不共享，各自开发；共同点是同一个设计思路、同一个 VT 核心，以及（部分）兼容的配置文件格式。
想要成熟、有正式发布节奏的实现，请用 [leantty](https://github.com/nivrrex/leantty)（Rust）。
本仓库存在的意义是提供第二套实现：依赖更少、单一二进制、窗口层自己写。

```
Rust leantty（github.com/nivrrex/leantty）   ←→   leantty-zig（本仓库）
  winit + wgpu + crossfont                        自写 X11 / Win32 窗口层 + FreeType
  仓库：/srv/git/tty.git（自建）                   仓库：本 GitHub 仓库
```

两者读取同一种 TOML 配置（`~/.config/leantty/leantty.toml`）。leantty-zig 只实现其中一个子集，
遇到未实现的键会在启动时打印 `未实现，已忽略: <键名>`，不会静默吞掉。

## 已实现的功能

Linux（X11，主要目标，完整测试过）：

- **VT 核心**：由 libghostty 提供网格语义 —— 宽字符、组合字符、字素簇、回流（reflow）、回滚、
  备用屏、括号粘贴、OSC 0/2 标题、OSC 4/10/11 配色、OSC 52 剪贴板。
- **渲染**：CPU 软件光栅到共享帧缓冲，可选 OpenGL（GLX）呈现
  （`[renderer] backend = "auto" | "cpu" | "gpu"`）。字形始终由 CPU 侧 FreeType 光栅化，
  GPU 只负责把成品帧上传与缩放。
- **字体**：FreeType + fontconfig。四个样式槽（normal / bold / italic / bold-italic）按家族分别解析；
  不做合成粗体/斜体（与 alacritty 一致——只有单一字重的家族就保持常规）。回退链来自配置，
  另有内置兜底 `Noto Color Emoji` / `Symbola`。彩色 emoji（CBDT）按彩色渲染；
  `font.size` 的单位是**点**（`px = 点 × Xft.dpi / 72`）。
- **文本属性**：粗体、淡色、斜体、下划线（单/双/波浪/点线/虚线，可单独指定下划线颜色）、
  删除线、上划线、反显、隐藏、256 色与真彩色、`draw_bold_text_with_bright_colors`。
- **输入**：按键编码在测试矩阵（49 条：可打印字符、Ctrl/Alt 组合、方向键、F1–F12、小键盘、
  Insert 家族、AltGr、应用光标/键区模式）上与 alacritty 逐字节一致。输入法直连 IBus（不走 XIM），
  支持 rime 里配置的 Shift 轻按切换中英文。鼠标上报、选区（单击/双击/三击/拖选）、
  经由 PRIMARY/CLIPBOARD 的复制粘贴、带滚动条的滚轮回滚。
- **窗口行为**：`WM_TAKE_FOCUS` 处理、OSC 0/2 动态标题、DECSCUSR 光标形状（可用 `[cursor] style`
  设默认形状，程序仍可覆盖）、可选光标闪烁。

Windows（`x86_64-windows-gnu`，可编译可运行，限制见下文）：

- 基于 ConPTY 的 PTY（没有匿名管道退化路径）、DIB 双缓冲渲染、与 Linux 共用同一份 FreeType 字体层、
  Imm32 输入法接线、剪贴板、鼠标选区、Per-Monitor DPI、内嵌窗口图标。

## 已知限制

- **没有 Wayland 后端**，Linux 侧只支持 X11。
- **Windows**：已在真实 Windows 上验证配置、粘贴、光标（含 DECSCUSR 四态）、键位、ConPTY、
  窗口行为；**输入法（微软拼音）与鼠标上报（1002/1006）仍未在具备条件的机器上验证**——
  测试机的 conhost 不转发这两个鼠标模式，也缺少输入法引擎。
- **OSC 8 超链接**只画下划线，不可点击（VT 核心 API 不暴露 URI）。
- **输入法内联预编辑不显示**：引擎把预编辑串发给自己的候选窗时（rime over IBus 就是如此），
  终端内看不到草稿，已提交文本正常。
- 未实现、启动时会提示：`window.padding.*`、`window.opacity`、`window.decorations`、
  `cursor.unfocused_hollow`、`font.glyph_offset.*`、`selection.semantic_escape_chars`、`env.*`、
  `hints.*`、`bell.*`。
- `Ctrl+Shift+<符号>` 按 ghostty/xterm 口径发送（例如 `Ctrl+?` 发 `0x7f`），与 alacritty 的 `0x3f` 不同。
- Windows 的 ConPTY 会把 VT 属性重新映射到 Win32 控制台模型，少数属性无法与 Linux 完全一致：
  `SGR 2`（dim）被丢弃、`SGR 1` 无颜色时落地为亮白前景、`SGR 7`（反显）由颜色互换实现、
  与默认属性相同的颜色（如默认配色下的 `SGR 37` / `SGR 40`）会被省略。Rust 版同样受此限制。

## 安装

### Debian / Devuan 包

```sh
sudo dpkg -i leantty-zig_0.1.0_amd64.deb
sudo apt -f install          # 首次安装时补齐依赖
leantty-zig
```

包内安装 `/usr/bin/leantty-zig`、一个桌面条目和 16–512 px 的 hicolor 图标；
命令名与 Rust 版不同，不会覆盖 `leantty`。

### Windows

下载 `leantty-zig-0.1.0-windows-x86_64.zip`，解压到任意目录，运行 `leantty-zig.exe`
（或 `run.cmd`）。压缩包里的 `leantty.toml` 是示例配置，删掉即用默认值。

### 从源码构建

见 [`docs/BUILD.md`](docs/BUILD.md)。简述：Zig 0.17.x、一份 pin 住版本的 libghostty 源码，然后

```sh
zig build -Doptimize=ReleaseFast        # 产物 zig-out/bin/leantty
zig build -Dtarget=x86_64-windows-gnu -Dcpu=baseline -Doptimize=ReleaseFast
```

## 配置

配置文件是 TOML，读取顺序：`--config-file` → `LEANTTY_CONFIG` → `~/.config/leantty/leantty.toml`。
所有支持的键见 [`config/leantty.example.toml`](config/leantty.example.toml)。几点说明：

- `font.size` 单位是**点**，换算 `px = 点 × Xft.dpi / 72`（与 alacritty 同一口径）。
- `[colors.*]` 沿用 alacritty 的结构（`primary`、`cursor`、`normal`、`bright`、`selection`）。
- `[[keyboard.bindings]]` / `[[mouse.bindings]]` 支持的动作：`Copy`、`Paste`、`ScrollPageUp`、
  `ScrollPageDown`、`ScrollToTop`、`ScrollToBottom`、`Quit`。

## 环境变量（主要用于测试）

| 变量 | 含义 |
|---|---|
| `LEANTTY_CONFIG` | 配置文件路径 |
| `LEANTTY_KDBG=1` | 把按键/绑定/输入法判定打印到 stderr |
| `LEANTTY_FONTDBG=1` | 打印解析到的字体面与度量 |
| `APP_COLS` / `APP_ROWS` / `APP_CELL_W` / `APP_CELL_H` / `APP_FONT_SIZE` | 覆盖网格/格子几何 |
| `APP_DUMP_SNAPSHOT=<路径>` | 每帧把屏幕内容导出为文本 |

## 测试

```sh
zig build test                     # VT/终端单元测试
sh scripts/e2e/run_all.sh          # 共享端到端用例（Xvfb）
sh scripts/e2e/run_zig_extra.sh    # Zig 特有端到端用例
sh scripts/e2e/run_keys_matrix.sh  # 逐字节按键编码矩阵
sh scripts/golden-check.sh         # 跨平台字体黄金文件（Linux 对比 Windows/wine）
```

端到端脚本需要 `Xvfb`、`openbox`、`xdotool`、`xwininfo`、`import`（ImageMagick）。

## 性能

### 呈现后端

- `backend = "auto"`（默认）：**CPU 光栅 + XShm 呈现**。真机实测最稳，不受驱动/窗口遮挡影响。
- `backend = "gpu"`：**GPU 直画**——字形进图集，每帧一次 draw call 画背景与字形（不搬整帧）。
  与 CPU 路径逐像素一致（`scripts/e2e/run_gpu_parity.sh` 断言 0 差异），适合全屏/大窗口或 XShm 不可用的环境。
- `backend = "cpu"`：强制 CPU 呈现。

启动时打印实际后端，便于自查：

```
renderer: cpu (XShm)
renderer: gpu (NVIDIA GeForce GT 710/PCIe/SSE2)
```

### 帧成本（探针 `scripts/perf/glbench.c`，1920x1080、16k 格、vsync 关）

| 路径 | ms/帧 |
|---|---|
| 整帧上传 + 四边形 | 26.44 |
| PBO 异步上传 | 24.86 |
| texture-from-pixmap | 28.19 |
| **GPU 直画（字形图集）** | **4.23** |

### 与 alacritty / Rust leantty 对比（5 MB `cat`，三轮中位）

| 环境 | leantty-zig(cpu) | alacritty | Rust leantty |
|---|---|---|---|
| Xvfb + llvmpipe | 215 ms | 1235 ms | 8469 ms* |
| 真机（NVIDIA GT 710） | 265–415 ms | 1235 ms | 453–27488 ms* |

\* Rust 版与 alacritty 走 wgpu/GL 并受 vsync 节流，波动大；`scripts/perf/cpu_per_mb.py` 提供与帧率无关的 CPU/MB 指标。

**注意**：真机上 GPU 路径的端到端时间波动很大（0.26 s ~ 43 s），原因是窗口可见性/焦点切换会触发 NVIDIA 驱动的
present 阻塞，与渲染几何无关；因此默认后端是 CPU + XShm。基准复现方式见 `scripts/perf/`。

## 许可

MIT，见 [LICENSE](LICENSE)。`vendor/freetype` 是 FreeType 的 vendored 副本，按其自身 FTL/GPLv2
双许可分发（见 `vendor/freetype/docs/FTL.TXT`）；libghostty 为 MIT。

## 与 `leantty`（Rust）的关系

- [leantty](https://github.com/nivrrex/leantty)：Rust 实现，winit + wgpu + crossfont，有正式发布；
  本项目的设计参照。
- `leantty-zig`（本仓库）：Zig 实现，自写 X11/Win32 窗口层、FreeType 渲染、IBus 输入、
  同一个 VT 核心（libghostty）、兼容的配置子集。

终端行为类问题欢迎提到本仓库；两套实现共有的问题一般先在 Rust 项目里修。
