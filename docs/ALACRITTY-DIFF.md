# 与 alacritty 0.17.0 的差异清单

对比对象：本机安装的 **alacritty 0.17.0**（`/usr/local/bin/alacritty`，`alacritty --version`）与本项目 **0.1.21**。

证据分三类，每条后面标注：

- **实测**：在本机 Xvfb+openbox 里跑本项目的二进制、喂对应配置/操作，观察结果（配置告警、`APP_DUMP_SNAPSHOT`、`xclip` 内容等）；
- **源码核对**：读 alacritty 0.17.0 源码（`alacritty/src/config/*.rs`、`alacritty_terminal/`）与 alacritty(5) man page 得到；
- **未验证**：明确标注没验证过的猜测（本文档尽量不出现）。

> 说明：只比 alacritty，不涉及 Rust 版 leantty。Rust 版与 alacritty 也有差异（例如拖入路径加 shell 引号），不在本表范围。

## 一、配置键：alacritty 有、本项目无效

### 1.1 能识别但空转（会打"未实现，已忽略"告警）

| 键 | 现在的行为 | 实测现象 |
|---|---|---|
| `window.padding.x` / `.y` | 忽略 | 文本区紧贴窗口边缘 |
| `window.dynamic_padding` | 忽略 | 同上 |
| `window.opacity` | 忽略 | 无半透明（X11 需要合成器） |
| `window.blur` | 忽略 | 无模糊 |
| `window.decorations` | 忽略 | 无法去掉 WM 边框 |
| `window.startup_mode` | 忽略 | 不能默认全屏/最大化 |
| `window.resize_increments` | 忽略 | 缩窗按像素而不是按格 |
| `window.title` | 忽略 | 标题只受 OSC 0/2 控制 |
| `cursor.unfocused_hollow` | 忽略 | **失焦时光标仍是实心**（alacritty 默认 hollow） |
| `cursor.thickness` | 忽略 | 光标粗细固定 |
| `font.offset.x` / `.y` | 忽略 | 字形不能整体偏移 |
| `font.glyph_offset.x` / `.y` | 忽略 | 同上 |
| `font.builtin_box_drawing` | 忽略 | 制表符始终用字体画（相当于 alacritty 的 `false`） |
| `mouse.hide_when_typing` | 忽略 | 打字时鼠标指针不隐藏 |
| `terminal.osc52` | 忽略，行为固定 | 固定为"允许复制、不接受粘贴"（≈ alacritty 默认 `OnlyCopy`），`CopyPaste` 无法开启 |
| `terminal.shell_integration` | 忽略 | 无 OSC 133 语义提示 |
| `bell.animation` / `.duration` / `.color` / `.command` | 忽略 | **完全没有响铃**（BEL 静默丢弃） |
| `hints.enabled` | 忽略 | 无 URL 提示/键盘打开 |
| `colors.dim.*`（8 色） | 忽略 | 淡色改用本项目自有 `colors.faint` + `faint_opacity` |
| `colors.primary.bright_foreground` | 忽略 | 本项目用 `colors.bright.white_fg`（只作用于 palette 15 作前景） |

### 1.2 完全没解析（部分静默忽略，连告警都没有）

| 键 | 备注 |
|---|---|
| `general.working_directory` | 只有 CLI `--working-directory` 生效 |
| `general.live_config_reload` | ✅ 0.1.22 起已实现（Linux 与 Windows） |
| `general.import` | 无配置拆分/包含 |
| `general.ipc_socket` | 无 IPC（也没有 `alacritty msg` 那套） |
| `env` | 无法向子进程注入环境变量 |
| `window.level` / `window.embed` / `window.identity.*` | 无置顶、无嵌入、窗口 class 固定为 `leantty`/`Leantty` |
| `cursor.vi_mode_style` | 无 vi mode |
| `colors.vi_mode_cursor.*` / `colors.search.*` / `colors.line_indicator.*` / `colors.hints.*` / `colors.indexed_colors` / `colors.transparent_background_colors` | 对应特性不存在（除 `transparent_background_colors` 是需要合成器透明） |
| `font.use_thin_strokes` | macOS 专用 |
| `debug.*`（`log_level`/`print_events`/`persistent_logging`/`render_timer`/`highlight_damage`/`renderer`/`prefer_egl`） | 本项目用自己的 `LEANTTY_*` 环境变量与 `[renderer] backend` |
| `terminal.shell` | 只用 `-e` 指定命令 |

### 1.3 写法不同导致"配了但不生效"

| alacritty 写法 | 本项目 | 实测 |
|---|---|---|
| `cursor.style = { shape = "Beam", blinking = "On" }` | 要求字符串 `cursor.style = "bar"` + `cursor.blink = true` | 表写法**静默忽略**（不给告警），光标仍是 `block` |
| 取值名 `Block` / `Beam` / `Underline` / `HollowBlock` | `block` / `bar` / `underline` / `block_hollow` | `style = "Beam"` 打出 `cursor.style 取值无法识别，已忽略: Beam` |

## 二、非配置特性：alacritty 有、本项目没有

| 特性 | alacritty | 本项目 | 说明 |
|---|---|---|---|
| vi mode | `Ctrl+Shift+Space` 进入，vi 键位选择/复制 | ❌ | 无 |
| 搜索 | `Ctrl+Shift+F`，SearchForward/Backward | ❌ | 无 |
| hints（URL 检测/键盘打开/鼠标悬停） | 有 | ❌ | OSC 8 只画下划线，**不可点击**（ghostty 不导出 URI） |
| 响铃 | 视觉动画 / 执行命令 / 颜色可配 | ❌ | BEL 被忽略，静默 |
| 配置热载 | 默认开启 | ✅ 已实现（0.1.22，两平台） | |
| `[env]` 注入 | 有 | ❌ | |
| `[general] import` / `alacritty migrate` | 有 | ❌ | |
| IPC（`alacritty msg`：改配置、建窗口、清日志） | 有 | ❌ | |
| Wayland 后端 | 有 | ❌ | 只有 X11 |
| CLI：`--hold` / `--embed` / `--daemon` / `--socket` / `-o, --option` / `-t, --title` / `--class` / `--print-events` / `-q` / `-v` | 有 | ❌ | 本项目另有 alacritty 没有的 `--font` / `--font-size` / `--cols` / `--rows` |
| 字号热键（IncreaseFontSize/DecreaseFontSize/ResetFontSize） | 有（可绑定） | ❌ | 只能 `--font-size` 启动时指定 |
| 全屏切换键（ToggleFullscreen） | 有 | ❌ | 依赖 WM 快捷键 |
| IME 内联预编辑 | winit/IME 路径 | ⚠️ 部分 | 候选框定位已实现；**rime 把组词串发往自己的候选窗，终端内看不到草稿** |
| GPU 渲染 | 唯一路径（OpenGL） | ✅ CPU 默认 + 可选 GPU | 不是缺失，是默认不同（见三-6） |

## 三、已实现但与 alacritty 不一致

| # | 项目 | alacritty 0.17 | 本项目 0.1.21 | 影响 |
|---|---|---|---|---|
| 1 | `selection.save_to_clipboard` 默认值 | **false**（源码 `Default::default()`） | **true**（实测：不写该键时拖动选词，CLIPBOARD 与 PRIMARY 都变） | 默认就会写系统剪贴板；上一轮修的"右键 Paste 粘整词"链路依赖它 |
| 2 | 合成粗体 | 无（单字重字体时粗体=常规） | **默认开启**（`font.synthetic_bold`），1/24 em | 单字重字体下粗体可见；字形比 alacritty 略宽厚 |
| 3 | 滚动条 | 无 | 绘制 12px（轨道=fg/bg 各半、滑块=fg） | 同样列数下文本区比 alacritty 窄 12px |
| 4 | 光标闪烁 | 750ms 间隔、5s 超时，`cursor.style.blinking`、`cursor.blink_interval`/`blink_timeout` 可配 | 固定 530ms，只有 `cursor.blink` 布尔 | 节奏不同，且不能调间隔 |
| 5 | 默认鼠标绑定 | 右键 = `ExpandSelection`、中键 = `PasteSelection` | **无任何默认鼠标绑定** | 复制粘贴需自己配（或用 Ctrl+Shift+C/V、Shift+Insert） |
| 6 | 渲染后端 | 只有 GPU（OpenGL） | 默认 **CPU + XShm**，`[renderer] backend = "gpu"` 可选 | 空闲 CPU 都是 0%，但高负载滚动时 GPU 更快；GL 不可用时我们能降级 |
| 7 | 默认字号 | 11.25 点 | 11 点 | 同 dpi 下字形略小（约 2%） |
| 8 | 淡色文字实现 | `colors.dim.*` 独立调色板 | `colors.faint`（单色）+ `faint_opacity`（默认 0.5 混合） | 颜色可调范围不同 |
| 9 | 粗体提亮用的颜色 | `colors.primary.bright_foreground` | 不读该键；用 `colors.bright.white_fg` 处理"palette 15 作前景"的场景 | 浅色主题下 conhost 注入 bright white 的问题有解，但键名不同 |
| 10 | 字体回退 | 由 fontconfig 自动选择 | 显式 `font.fallback = [ ... ]` 链 + 内置兜底（Noto Color Emoji / Symbola） | 可控性更强，但**不写 fallback 时**与 alacritty 的回退顺序可能不同 |
| 11 | 默认键盘绑定 | 含 vi/搜索/`Ctrl+Shift+Space` 等；`Ctrl+Shift+C/V` 复制粘贴 | 无 vi/搜索；内置 `Ctrl+Insert`/`Shift+Insert`、`Ctrl+Shift+C/V` | 用惯 alacritty vi 键位的人会觉得缺功能 |
| 12 | `keyboard.bindings` 动作集合 | Copy/Paste/ClearSelection/SearchForward/SearchBackward/ToggleViMode/ToggleFullscreen/CreateNewWindow/SpawnNewInstance/ClearLogNotice/IncreaseFontSize/DecreaseFontSize/ResetFontSize/ReceiveChar 等 | Copy/Paste/ScrollPageUp/ScrollPageDown/ScrollToTop/ScrollToBottom/Quit | 配置里写其他动作会静默无效 |
| 13 | `mouse.bindings` 动作集合 | Copy/Paste/ExpandSelection/PasteSelection/HideCursor/Select/…（0.17 起按键也支持 WheelUp/WheelDown） | Copy/Paste（按键支持 Left/Right/Middle/WheelUp/WheelDown） | 同上 |
| 14 | 拖入文件 | 裸 `path + " "`（`DroppedFile` 分支） | 相同口径（Linux 已验；Windows 仅手工验证） | 与 Rust leantty 0.2.14（加 shell 引号）不同，属于三方差 |
| 15 | 配置告警的覆盖面 | 未知键一律报"Unrecognized config key" | 有些键报"未实现，已忽略"，另一些前缀（`window.`/`cursor.`/`debug.`/`terminal.`/`env.`/`hints.`/`bell.`）静默 | 静默会让人误以为生效 |

## 四、本项目比 alacritty 多出来的东西

| 项 | 说明 |
|---|---|
| `font.fallback` | 显式回退链（alacritty 靠 fontconfig） |
| `font.synthetic_bold` | 合成粗体开关（默认开） |
| `colors.faint` / `colors.faint_opacity` | 淡色单色 + 混合比例（替代 `colors.dim.*`） |
| `colors.bright.white_fg` | palette 15 作前景时的替代色（浅色主题专用） |
| `[renderer] backend = "auto"/"cpu"/"gpu"` | alacritty 没有 CPU 后端 |
| 12px 滚动条 | alacritty 完全没有滚动条 |
| CLI `--font` / `--font-size` / `--cols` / `--rows` | 便于无配置启动与测试 |
| `LEANTTY_KDBG` / `LEANTTY_CONFIG` / `APP_DUMP_SNAPSHOT` / `APP_DUMP_COLORS` / `APP_CELL_W/H` / `LEANTTY_PASTE_DUMP` 等 | 诊断与 e2e 钩子（默认不产生输出） |

## 五、下一步优先级建议（按"影响观感/日常使用"排序）

1. **`cursor.style` 表写法 + 取值名兼容**（小改动、纯解析层）：alacritty 用户的配置现在被静默忽略，属"配了不生效"的信任问题；
2. **`window.padding`**（小改动）：本机 TUI 与 alacritty 并排时边距差别最直观；
3. **`bell`**（中等）：至少支持"视觉闪烁"与 `command`，很多脚本依赖 BEL 提示；
4. **`selection.save_to_clipboard` 默认值改成 false**（一行）：与 alacritty 对齐，但会改变现有用户行为（建议同时保留"右键粘贴读 PRIMARY 兜底"）；
5. **`colors.dim.*` 支持**（中等）：现在的 `faint` 只做混合，浅色主题下 8 个 dim 色差不出层次；
6. ~~**配置热载**~~：0.1.22 已实现（Linux）；
7. **搜索 / vi mode / hints**（较大）：三项互相依赖（vi mode 与搜索共用 bindings 与选区模型），建议一起做；
8. **IPC / `[env]` / `[general] import`**（中等，偏工程便利）；
9. **Wayland 后端**（大，独立议题）。

## 六、复核方式

本清单可复跑：`docs/ALACRITTY-DIFF.md` 里每条"实测"都能用下面两条命令复现：

```sh
# 看某个配置键是否被识别/生效（把键写进 /tmp/x.toml 再启动）
LEANTTY_CONFIG=/tmp/x.toml DISPLAY=:71 ./zig-out/bin/leantty -e /bin/true

# 看默认值与拖选行为（拖动后对比两个剪贴板）
# 见 scripts/e2e/run_zig_extra.sh 的 U/V 用例
```

alacritty 侧默认值来自 `alacritty-0.17.0/alacritty/src/config/*.rs` 的 `impl Default`；
键清单来自 `extra/man/alacritty.5.scd` 与配置结构体字段。
