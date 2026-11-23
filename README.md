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
- **渲染**：CPU 软件光栅到共享帧缓冲（XShm），可选 OpenGL（GLX）**字形图集直画**
  （`[renderer] backend = "auto" | "cpu" | "gpu"`）。字形由 FreeType 光栅化进 2048² 图集，
  每帧只画背景与字形四边形，不上传整帧。
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
  窗口行为，以及**中文输入法（微软拼音）**——含全屏 TUI 里的候选框定位（0.1.6 修复）。
  **鼠标上报（1000/1002/1006）仍未验证**：测试机的 conhost 不转发这两个模式，
  需要 Windows Terminal 一类自带伪控制台服务端的终端才能覆盖。
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
sudo apt install ./leantty-zig_<版本号>_amd64.deb   # 版本号以 Releases 页最新版为准
leantty
```

包内安装 `/usr/bin/leantty`、一个桌面条目和 16–512 px 的 hicolor 图标。
**命令名就是 `leantty`**，与 Rust 版同名：两者不要同时装（包内已声明
`Conflicts/Replaces: leantty`，装这个会顶掉同名的包）。
硬依赖只有直接链接的那几个库（`libc6`、`libx11-6`、`libxext6`、`libfontconfig1`、
`libfreetype6`、`libgl1`、`libglx0`）。IBus/GLib 是运行期 `dlopen` 的可选依赖
（`Recommends: libibus-1.0-5`）：没装 IBus 时输入法功能关闭，终端照常工作。

### Windows

下载 `leantty-zig-<版本号>-windows-x86_64.zip`（版本号以 Releases 页最新版为准），
解压到任意目录，运行 `leantty.exe`
（或 `run.cmd`）。压缩包里的 `leantty.toml` 是示例配置，删掉即用默认值。

### 从源码构建

见 [`docs/BUILD.md`](docs/BUILD.md)。简述：Zig 0.17.x、一份 pin 住版本的 libghostty 源码，然后

```sh
zig build -Doptimize=ReleaseFast        # 产物 zig-out/bin/leantty（Windows 为 leantty.exe）
zig build -Dtarget=x86_64-windows-gnu -Dcpu=baseline -Doptimize=ReleaseFast
```

## 配置

配置文件是 TOML，读取顺序（先命中先赢）：

1. `--config-file <路径>`
2. `LEANTTY_CONFIG` 环境变量
3. 平台默认：Windows `%APPDATA%\leantty\leantty.toml`（退化 `%USERPROFILE%\.config\leantty\leantty.toml`）、
   Linux `$XDG_CONFIG_HOME/leantty/leantty.toml` 或 `~/.config/leantty/leantty.toml`
4. **可执行文件同目录的 `leantty.toml`**（便携包用它；只有用户没有自己的配置时才生效）

启动时会打印实际使用的路径（`config: <路径>`），改配置没生效时先看这一行。
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
| `LEANTTY_KDBG_FILE=<路径>` | 把上面这些诊断写到文件（Windows GUI 子系统下 stderr 被接管时用） |
| `LEANTTY_FONTDBG=1` | 打印解析到的字体面与度量 |
| `APP_COLS` / `APP_ROWS` / `APP_CELL_W` / `APP_CELL_H` / `APP_FONT_SIZE` | 覆盖网格/格子几何 |
| `APP_DUMP_SNAPSHOT=<路径>` | 每帧把屏幕内容导出为文本 |
| `APP_DUMP_COLORS=<路径>` | 导出每格 `row col fg bg`（配色对拍用） |

## 测试

```sh
zig build test                     # VT/终端单元测试
sh scripts/e2e/run_all.sh          # 共享端到端用例（Xvfb）
sh scripts/e2e/run_zig_extra.sh    # Zig 特有端到端用例
sh scripts/e2e/run_keys_matrix.sh  # 逐字节按键编码矩阵
sh scripts/e2e/run_gpu_parity.sh    # GPU 直画与 CPU 逐像素对拍（0 差异断言）
sh scripts/golden-check.sh         # 跨平台字体黄金文件（Linux 对比 Windows/wine）
```

Windows 侧的端到端用例在 `scripts/e2e/win/run_all.sh`（Git Bash + PowerShell，断言读
`APP_DUMP_SNAPSHOT`，不依赖截图），说明见 `scripts/e2e/win/README.md`。

Linux 端到端脚本需要 `Xvfb`、`openbox`、`xdotool`、`xwininfo`、`import`（ImageMagick）。

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

> 测量时间：0.1.3 前后，本机 NVIDIA GT 710。属于该环境下的单次探针结果，换卡/换驱动会变。

| 路径 | ms/帧 |
|---|---|
| 整帧上传 + 四边形 | 26.44 |
| PBO 异步上传 | 24.86 |
| texture-from-pixmap | 28.19 |
| **GPU 直画（字形图集）** | **4.23** |

### 与 alacritty / Rust leantty 对比（5 MB `cat`，三轮中位）

> 测量时间：0.1.2 发布前后（本机 NVIDIA GT 710 / Xft.dpi=144）。这些数字受驱动、
> 窗口遮挡、vsync 设置影响很大，**旧结果不代表当前版本**；复现脚本在 `scripts/perf/`。

| 环境 | leantty-zig(cpu) | alacritty | Rust leantty |
|---|---|---|---|
| Xvfb + llvmpipe | 215 ms | 1235 ms | 8469 ms* |
| 真机（NVIDIA GT 710） | 265–415 ms | 1235 ms | 453–27488 ms* |

\* Rust 版与 alacritty 走 wgpu/GL 并受 vsync 节流，波动大；`scripts/perf/cpu_per_mb.py` 提供与帧率无关的 CPU/MB 指标。

**注意**：真机上 GPU 路径的端到端时间波动很大（0.26 s ~ 43 s），原因是窗口可见性/焦点切换会触发 NVIDIA 驱动的
present 阻塞，与渲染几何无关；因此默认后端是 CPU + XShm。基准复现方式见 `scripts/perf/`。

## 许可

MIT，见 [LICENSE](LICENSE)。

`vendor/freetype` 是 FreeType 的**裁剪副本**（只留构建所需的头文件与源文件），按其自身
FTL / GPLv2 双许可分发，全文见 `vendor/freetype/docs/FTL.TXT`；Linux 版链接系统 FreeType，
Windows 版静态编译该副本，两种发行包都随附这份 FTL 全文。libghostty 为 MIT。

## 与 `leantty`（Rust）的关系

- [leantty](https://github.com/nivrrex/leantty)：Rust 实现，winit + wgpu + crossfont，有正式发布；
  本项目的设计参照。
- `leantty-zig`（本仓库）：Zig 实现，自写 X11/Win32 窗口层、FreeType 渲染、IBus 输入、
  同一个 VT 核心（libghostty）、兼容的配置子集。

终端行为类问题欢迎提到本仓库；两套实现共有的问题一般先在 Rust 项目里修。
