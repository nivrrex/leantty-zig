# 变更记录

## 0.1.21

### 修复：选区高亮漏掉最后一格（双击选词/右键粘贴时的"多一个字符"）

双击选中一个词后，**最后一个字符不被反色**；复制（Ctrl+Insert / 右键粘贴）得到的却是完整的词，
于是粘贴时看起来"多出了一个未反色的字符"。两个现象是同一个 off-by-one。

根因是 ghostty `RenderState` 的 `row.selection` 语义：它是**闭区间** `[start, end]`
（ghostty 自己的单测里 x=0..2 的选区给出 `{0, 2}`）。渲染侧按半开区间 `x < end` 判断，
于是每行最后一格落在区间外：选区丢掉最后一格的高亮，而复制走 ghostty 自身逻辑、内容是完整的。

修法：判定收敛到 `cellcolor.inSelection()` 一处（闭区间 `x >= start and x <= end`），
`render.zig` 的 CPU/GPU 两条路径、`app.zig` 的 `APP_DUMP_COLORS`、`app_win.zig` 的 Windows 呈现
全部改为调用它，避免各处再写出不一致的比较。

### 测试：新增 U 用例（用配色 dump 直接看每格最终颜色）

`scripts/e2e/run_zig_extra.sh` 新增 `U-selection-covers-last-char`：把
`[colors.selection] background` 设成 `#FF00FF`，双击 `echo WORD1 WORD2` 输出行里的第一个词，
再读 `APP_DUMP_COLORS` 断言第 0–4 列都是 `ff00ff`（含最后一格）、第 5 列（空格）不是。
已确认这条用例在带缺陷的旧判定下会失败（选中列只有 `0,1,2,3`），修复后通过。
另加了单测 `inSelection：闭区间（含最后一格）`（用例总数 52）。

## 0.1.20

### 新功能：拖放文件到窗口，路径写进 PTY

把文件（或多个文件）从文件管理器拖进 leantty 窗口，路径会写进子进程 stdin。
口径与 alacritty 的 `paste(path + " ", true)` 一致：**每个路径后跟一个空格**、多文件用空格连接，
程序开了括号粘贴（DEC 2004）时整段被 `ESC[200~ … ESC[201~` 包裹；没开就写裸路径。

- **Linux（X11）**：实现 XDND 5——`XdndAware`=5、`XdndEnter`（类型表在 `XdndTypeList` 属性里）、
  `XdndPosition` 回 `XdndStatus`（整窗口作为接受矩形）、`XdndDrop` 用 `XConvertSelection` 取
  `text/uri-list`、处理完回 `XdndFinished`。`file://host/path` 只接受空 host 或 `localhost`，
  做 `%XX` 解码（中文/空格会被转义），`#` 注释行与空行跳过。
- **Windows**：`DragAcceptFiles` + `WM_DROPFILES`，用 `WideCharToMultiByte(CP_UTF8)` 转 UTF-8；
  一次 `WriteFile` 写完（含包裹序列）——与粘贴同一个坑，分批写会被 ConPTY 的 VT 解析器当散键。
- 两者的载荷都走**粘贴通道**：Linux 复用 `TTY_EV_PASTE`，Windows 新增 `W32_EV_DROP` + `w32_drop_take()`。

### 测试：新增拖放端到端用例（两个平台各一个源端探针）

拖放只能由真实源端触发，xdotool/xclip 都做不了 XDND，所以各写了一个探针：

- `scripts/e2e/tools/xdnd_send.c`（Linux）：真发一轮 XdndEnter/Position/Drop，并在
  `SelectionRequest` 里回 uri-list，等 `XdndFinished`；
- `scripts/e2e/win/tools/dropfiles.c`（Windows）：构造 `DROPFILES` + 双 NUL 路径表，
  `SendMessageW(hwnd, WM_DROPFILES, …)`。

用例 `scripts/e2e/dnd.sh`（3 条）与 `scripts/e2e/win/run_dnd.sh`（2 条）都断言**逐字节**：
路径含空格与非 ASCII 文件名、多文件连接、以及"探针不开 DEC 2004 时不包裹"。
`keydump.c` 新增 `KEYDUMP_NO_BRACKETED=1` 用来覆盖最后一条。


### Linux 实现细节：XdndStatus 的动作原子要同时放 l[4]（GTK 口径）与 l[6]（规范）

只管规范不够。第一版只按规范实现时，真实 GTK 源下**松开鼠标什么都不发生**：
日志里能看到 `XdndEnter` 与一串 `XdndPosition`，最后却是 `XdndLeave`——源主动取消了拖放。

差异在 `XdndStatus` 里**动作原子的位置**：

| 读取方 | 读的位置 |
|---|---|
| XDND 规范 | `data.l[6]` |
| **GTK（gdkdnd-x11.c，GTK2 与 GTK3 都是）** | `data.l[4]` |

GTK 的 `xdnd_status_filter` 里 `Atom action = xevent->xclient.data.l[4];`，并且要求
"action 非 0" 与 "flags bit0 置位"一致，否则判定为非法状态、把 action 归零 →
`context->action == 0` → 松开鼠标时取消拖放并发 `XdndLeave`。我们只按规范放在 `l[6]`，
`l[4]` 给的是接受矩形宽度，于是 GTK 读到的 action 为 0。

最终实现：`l[4]` 与 `l[6]` **都放** `XdndActionCopy`（两套口径都能读），`l[1]` 置 `3`
（同意接受 + 请继续发 `XdndPosition`，与 GTK 自己的目标端一致），`l[5]` 置 0 不再给矩形。

### 测试：真实 GTK 源端拖放用例

`scripts/e2e/dnd_gtk.sh` 用 `scripts/e2e/tools/dndsrc.py`（GTK3 拖放源，与 PCManFM 同一套
gtkdnd 代码）＋ `xdotool` 真按下/移动/松开，断言子进程收到 `ESC[200~ + 路径 + 空格 + ESC[201~`。
自制 X11 探针（`tools/xdnd_send.c`）直接给客户窗口发 ClientMessage，绕过了"源如何定位目标
窗口"与"源如何解读 XdndStatus"，所以它能过而真实拖放不能——这条用例补上的正是这个缺口。
缺 `python3-gi` 时自动 SKIP。

另在**真实 PCManFM（GTK2，LXDE 默认文件管理器）**里做过一次人工验证：从 `/tmp/dnd-fm`
把 `拖我.txt` 拖进窗口，子进程收到
`ESC[200~ /tmp/dnd-fm/拖我.txt SPACE ESC[201~`（与 alacritty 同字节）。

## 0.1.19

### 修复（仅 Windows）：Ctrl+字母 在 kitty 协议下与 Rust 一致

`win32.c::handle_keydown` 里 `if (!seq && !(st & 4)) return 0;` 把 **Ctrl+字母**
直接交回 `DefWindowProc`，最终由 `WM_CHAR` 产出 `0x01`——编码器全程没参与，
于是 kitty 协议下也发不出 `ESC[97;5u`（Rust 会发）。

修法两步：

1. `handle_keydown`：Ctrl（不带 Alt、非 AltGr）的普通键也 push `W32_EV_KEY`，
   并置 `swallow_ctrl` 吞掉随后 `WM_CHAR` 的 C0；legacy 下仍由编码器给出 `0x01`，
   行为不变。
2. `handleKey`：可打印键**总是**填 `utf8` 与 `unshifted_codepoint`（原来只在 Alt 时填），
   并补 `consumed_mods`（Shift 已由字符体现时算 consumed），与 Linux 侧同口径。

实测（Linux 侧同一 ghostty 编码器）：Ctrl+a → `ESC[97;5u`、Ctrl+Shift+a → `ESC[97;6u`、
Alt+x → `ESC[120;3u`，与 Rust 0.2.10 一致；legacy 下仍是 `0x01`。

### 修复（仅 Windows）：回退 inbox conhost 时不传 `WIN32_INPUT_MODE`

`0x4` 只有 OpenConsole（`conpty.dll`）认；inbox conhost 收到它**连子进程都起不来**
（实测：flags=0x7 走 kernel32 → 探针文件一个都不创建，窗口只剩首帧）。
所以 flags 改为按实际实现选择：OpenConsole → `0x1|0x2|0x4`，回退 kernel32 → `0`；
回退时打一行警告（括号粘贴标记与 CSI-u 会丢，把两个文件放到 exe 同目录即可恢复）。

### 修复（仅 Windows）：回退 inbox conhost 时强制 legacy 编码

上一版只让 `CreatePseudoConsole` 的 flags 按实现选择，但**kitty 键盘协议的标志没管**：
子进程（pi/vim）照旧 push kitty 协议，我们照旧发 `ESC[97;5u`，而 inbox conhost 会丢弃 →
**Ctrl+C 变成"什么都不发"**，比 legacy 的 `0x03` 更糟。

修法：`w32_conpty_openconsole()` 暴露实际实现，`handleKey` 里用
`winkey.gateKittyFlags(openconsole, opts.kitty_flags)` 清零。回退路径因此完全回到 0.1.18
的表现：粘贴无标记、Ctrl+C = `0x03`、Ctrl+A = `0x01`；带 `conpty.dll` 时不受影响。

### 测试（仅 Windows）：新增 `run_fallback.sh`，回退路径纳入全量

`scripts/e2e/win/run_fallback.sh` 把 exe 单独拷到一个**没有 dll** 的目录再启动，断言：
日志出现 `kernel32 (inbox conhost)` 与降级警告、子进程能起来、kitty 模式下 `Ctrl+C=03`、
`Ctrl+A=01`、粘贴无 `ESC[200~` 但正文仍在。已接进 `run_all.sh` 全量序列。

顺带修了两处采样抖动（只影响测试可信度，不动产品代码）：`run_cursor` 的闪烁采样从
"固定 8×0.25s" 改成"最多 24 次、看到 `0` 与 `1` 即通过"（原窗口约 2 秒，机器忙时会全程
落在同一相位，8 次跑 2 次假失败）；`run_mouse` 的探针就绪改成轮询；`run_fallback` 的粘贴
从 Shift+Insert 改 Ctrl+Shift+V（本机输入法会抢单靠 Shift 的组合）。

### 构建（仅 Windows）：`zig build` 产物自带 `conpty.dll` + `OpenConsole.exe`

`build.zig` 把 `vendor/conpty/` 的一对文件一起装到 `zig-out/bin`（打包脚本本来也带），
于是**开发构建不再需要手工拷 dll**，也不会出现"裸构建的子进程起不来"。两文件必须成对：
conpty.dll 只是转发层，实现在 OpenConsole.exe 里。

### 变更：Windows 包内置 `conpty.dll` + `OpenConsole.exe`

zip 里直接带这两个文件（Windows Terminal 的 OpenConsole，MIT），
用户不需要再去别处拷；程序启动时按 `exe 同目录 → 系统 → kernel32` 顺序装载
（`src/win32.c::load_conpty`，`LEANTTY_KDBG=1` 会打印实际实现）。
随包附 `CONPTY-NOTICE.md` 说明来源与许可；源码仓库对应 `vendor/conpty/`。

### 修复（仅 Windows）：CreatePseudoConsole 缺少 `WIN32_INPUT_MODE`（输入序列被解析丢弃）

这是"Ctrl+字母 编码正确却送不到子进程"的真正原因。`CreatePseudoConsole()` 的 `flags`
我们一直传 **0**，于是 ConPTY 把主机写入的输入当作 **VT 序列**解析：认识的方向键/SS3 变成
键记录，不认识的（`ESC[200~`、kitty 的 `ESC[97;5u`）**直接丢**。

同机 Rust 版走 portable-pty，它传的是 `PSEUDOCONSOLE_INHERIT_CURSOR | RESIZE_QUIRK |
WIN32_INPUT_MODE`（`0x1|0x2|0x4`）；打开 `WIN32_INPUT_MODE` 后输入按"win32 输入记录"解释，
非记录的字节按字面透传——所以 Rust 的 `ESC[200~ … ESC[201~` 与 `ESC[97;5u` 能完整到达子进程。

本版改为同样传 `0x7`。这解释了此前两个看似无关的现象（粘贴标记丢失、CSI-u 丢失）是**同一个开关**。

### 修复（仅 Windows）：优先使用随包的 `conpty.dll`（OpenConsole）

第七轮实机对照发现了决定性差异（同一份剪贴板、同一个探针）：

| 终端 | 子进程收到的粘贴字节 |
|---|---|
| Rust 0.2.10（随包带 `conpty.dll`） | `ESC[200~` + 正文 + `ESC[201~`（**标记完整**） |
| Zig 0.1.18（inbox conhost） | 只有正文，两个标记都被吃掉 |

同一个 ConPTY 下两个终端行为不同 → 不是"conhost 一律丢标记"，而是**实现不同**：
inbox conhost 在输入侧把 VT 序列翻译成键记录（`ESC[200~` 不是键 → 丢弃；`CR` 变成两个
键记录），并把子进程输出重新渲染后回放（kitty 键盘协议的 `CSI > 1 u` 之类容易丢）；
OpenConsole（Windows Terminal 的实现，即 `conpty.dll`）基本按字节流直通。

本版改为：**exe 同目录的 `conpty.dll` → 系统 `conpty.dll` → kernel32 自带实现**，
任一步失败自动退回下一步。`LEANTTY_KDBG=1` 时会打印实际用的是哪一个。

由此**同时**改善两类问题：

- 多行粘贴重新带上括号粘贴标记（`pi` 里应恢复 `[paste #1 +N lines]`）；
- 子进程启用 kitty 键盘协议（`pi`/`vim`）后，`Esc`/`Ctrl+a`/`Alt+x`/`Shift+Enter`
  能按协议编码，而不是一直停在 legacy。

**实机复测（0.1.19）**：启动日志出现 `[win] conpty: conpty.dll (OpenConsole)`；
多行粘贴的子进程字节与 Rust **逐字节一致**（`ESC[200~` + 正文 + `ESC[201~`），
`pi` 里重新出现 `[paste #1 +N lines]`；kitty 模式下 `Esc` → `ESC[27u`、`Alt+x` → `ESC[120;3u`
与 Rust 相同。用户手按 `Shift+Enter` 也已能软回车。

### 测试

`zig build test` **51**（含 Windows 键映射、kitty 协议编码、Ctrl+字母 legacy/kitty、回退路径的 `gateKittyFlags` 断言，`--summary all` 实测 51/51）；
`smoke.sh` 7/7；Windows 侧 `run_keys_bytes.sh` 的 28 键矩阵已并入 `win` 分支。

## 0.1.18

### 新增：滚动条（Linux + Windows，12px，与 Rust 版一致）

- 宽度从 4px 提到 **12px**（Rust 侧就是从 4 → 8 → 12：用户反馈"太窄、点不中"），
  几何抽到 `src/scrollbar.zig`（纯函数 + 单测），CPU 绘制、GPU 绘制、Windows DIB 绘制与
  鼠标命中测试共用同一份口径。
- 配色与 Rust 对齐：轨道 = 前景/背景各半，滑块 = 前景色（原来轨道 20%、滑块 55%，
  在浅色主题下几乎看不见——这也是"好像没有滚动条"的观感来源）。
- **Windows 侧此前完全没有滚动条**，本轮补上（`w32_present()` 增加 thumb 参数，
  在 DIB 上画轨道与滑块）。
- 命中：点在右缘 12px 条带内不再触发选区（与 Rust 的 `hit_scrollbar` 同口径），两平台都做。

### 测试

- `src/scrollbar.zig` 新增 3 条单测：无滚动区不画、滑块顶部/底部贴住轨道两端、命中判定边界。
- `smoke.sh` 增加像素断言：右缘 12px 条带内恰好出现两种颜色（轨道 `#919190`、滑块 `#303238`），
  左邻 12px 无条带。

## 0.1.17

### 修复（仅 Windows）：启动后在当前目录生成一个名为 `nu` 的文件

现象：在 Windows 上运行后，cwd 里多出一个文件 `nu`，内容是 `Active code page: 65001`。

根因：默认命令行是 `cmd.exe /K chcp 65001>nul`，而拼装函数末尾统一执行
`cmd_buf[cmd_len - 1] = 0` 去"尾随空格"——这行只对带尾随空格的 `-e` 参数拼接成立，
对**默认命令**（没有尾随空格）就把最后的 `l` 覆盖成了 NUL，命令变成
`cmd.exe /K chcp 65001>nu`：cmd 于是把 `chcp` 的输出重定向到 cwd 下一个名为 `nu` 的文件。

修法：拼装逻辑抽到 `src/cmdline.zig`（纯函数），只去掉**自己追加**的尾随空格；
补了 3 条单测（默认命令必须完整保留 `>nul`、`-e` 多参数单空格、`-e` 单参数不追加空格），
并在 Linux 上引用执行（该模块平时只在 Windows 编译）。

**清理**：升级后可以把之前误生成的 `nu` 文件删掉（它只是 chcp 的输出）。

### 测试体系：补上"能抓到按键/粘贴问题"的快速用例

用户反馈"测试跑半小时、却没测出方向键/粘贴之类的问题"。逐项补齐：

- **新增 `scripts/e2e/smoke.sh`（本机 6.5 秒）**：方向键/Home/End/PgUp/PgDn/Insert/Delete
  的**逐字节**转义序列、Ctrl+A/Ctrl+E 的 C0 字节、UTF-8 + 宽字符显示、粘贴包裹
  （`ESC[200~ … ESC[201~`）、配色 dump 头，共 6 条断言。日常改动跑这个即可。
- **新增 `scripts/e2e/tools/keydump.c`**：把子进程 stdin 收到的字节按十六进制落盘
  （raw 模式 + 裸 `read`），按键/粘贴断言不再依赖截图。Windows 也能交叉编译，用于 ConPTY 侧取证。
- **Windows 虚拟键映射抽成 `src/winkey.zig`**，并加单测：把 `VK_LEFT/UP/RIGHT/DOWN/HOME/END/
  PRIOR/NEXT/INSERT/DELETE/ENTER/ESCAPE` 经 ghostty 编码器编出来的字节与
  `ESC[A`…`ESC[3~` 逐一比对。该模块平时只在 Windows 编译，现在通过 `vt_test.zig`
  在 Linux 上也会执行——这类"映射错/编不出字节"的问题不必等实机。
- `app_win.zig` 里按键编码路径加了 `kdbg encode len=`，便于实机确认"按键到了、但编码为空"还是"根本没到"。
- 新增 `scripts/e2e/tools/keydump.c` 后，粘贴/按键的断言同时覆盖大段粘贴与 bracketed 包裹。


### 新增：拖选到底部自动滚动（Linux + Windows）

之前把鼠标拖到视口下边缘后，选区只能停在当前屏幕，看不到的滚回内容选不中。现在：

- 拖选时指针贴住**首行/末行**（X11 的坐标很难真的越出窗口，所以贴在最后一行即算贴边），
  主循环每 30ms 滚 2 行并继续扩展选区；鼠标不动也持续滚动。
- 选区起点改为记录**页面坐标锚点**（`vt.Wrapper.Anchor`），滚动后起点不会跟着视口漂移；
  之前是按 viewport 坐标存 `drag_start`，一滚动起点就错位。
- 两个平台共用同一逻辑（`selectAnchor` / `selectFromAnchor`），Windows 侧同样生效。

`scripts/e2e/smoke.sh` 增加一条端到端断言：先 Shift+PageUp 翻上去，再拖到底部按住 1.2 秒，
断言首行索引确实变大（实测 106 → 123）。

### 顺带

- `docs/BUILD.md` 补 `src/icon_rgba.h` 的生成说明（改图标要重跑 `scripts/gen-icon-header.py`）。
- README 的测试小节按耗时分层（smoke 7–10 秒 / 全量 2–3 分钟），并给出各套件实测耗时。

## 0.1.16

### 修复（Linux）：窗口标题里的 UTF-8 变成乱码

现象：标题栏在图标后面显示成一个"带音标的怪字符"（例如 `Ï€ - Leantty`），而 Windows 正常。

根因：设置标题只调了 `XStoreName()`，它写的是 ICCCM 的 `WM_NAME`，属性类型 `STRING` 按
**Latin-1** 解释。标题里一旦有 UTF-8（`pi` 会把标题设成 `π - Leantty`、shell 也可能把路径塞进标题），
每个字节就被当成一个 Latin-1 字符显示。EWMH 的现代做法是另写 `_NET_WM_NAME`（`UTF8_STRING`），
现代窗口管理器优先读它。

修法：新增 `set_title()`，一次写三处——`WM_NAME`（兼容只认它的老程序）、
`_NET_WM_NAME`、`_NET_WM_ICON_NAME`（均 `UTF8_STRING`）。窗口创建与 OSC 0/2 动态标题共用它。
验证：`xprop` 里 `_NET_WM_NAME(UTF8_STRING) = "π - Leantty"`，标题栏实际显示 `π - Leantty`。

## 0.1.15

### 新增：合成粗体（缺 Bold 面时仍然有粗体）

实测：单字重字体（如汉仪旗黑 55S）下，我们与 alacritty 都**没有**粗体——`SGR 1` 与常规完全一致
（覆盖 7.26% vs 7.26%、墨段 2.91px vs 2.91px）。用户要求"粗体不能缺失"，因此新增：

- `[font] synthetic_bold`（默认 **true**）：家族没有 Bold 面时，用 FreeType 的
  `FT_Outline_Embolden` 轮增加粗（强度 1/24 em，至少 1px），再自行渲染。
  判断口径是"这个字形本来会拿到常规面"，所以主字体有 Bold、CJK 回退字体没有时，
  CJK 字形同样会被加粗。
- 实测效果（16px、HYQiHei 单字重）：墨覆盖率 9.98% → 13.84%；
  同口径下 Consolas **真 Bold** 是 9.90% → 14.44%，强度相当。
  设 `synthetic_bold = false` 即回到 alacritty 行为（粗体=常规）。

### 新增：`[selection] semantic_escape_chars`

双击选词的边界字符改为可配置（与 alacritty 同义），默认仍是 NUL/空格/Tab；
配置后按该字符集切词，因此 `代码任务：` 这类带全角标点的串会按预期在标点处断开。

### 配置核对（对照用户提供的 alacritty.toml）

同一份配置在本实现下逐项验证：`config:` 路径、`cols=120 rows=30`、窗口位置
（配置 x=50,y=40 → 实际 51,64，差值是 openbox 的边框与标题栏）、`bg=f3f1e9 fg=303238`、
16 色板、光标/选区颜色、`scrolling.history=10000`、`Ctrl+Insert`/`Shift+Insert` 绑定均生效。
**仍不支持**（启动告警，且这两项在参考配置里都是空操作）：`window.padding.x/y`（=0）、
`window.opacity`（=1.0）。

## 0.1.14

### 修复：默认配置路径整份失效（0.1.12 回归，Linux + Windows）

`configPath()` 把默认路径拼进**函数栈上的缓冲**后 `return` 该切片；函数返回后栈失效，
`fopen` 打开的是被覆盖的内容。表现：日志里 `config:` 打印的路径是对的，紧接着
`config: 读不到该文件，使用默认值`，`%APPDATA%` / `XDG_CONFIG_HOME` / `HOME` 三种默认配置全部不生效
（`--config-file` 与 `LEANTTY_CONFIG` 走调用方缓冲，不受影响）。
修法：返回前用调用方的 `out` 缓冲重建一次切片。
已补 e2e 用例 `T-default-config-path`（只设 `XDG_CONFIG_HOME`，断言 dump 头 `bg=123456`），
修复前 FAIL、修复后 PASS。

### 修复：`--version` / `-h` 输出丢失（0.1.13 回归，仅 Windows）

0.1.13 为了打印 `config:` 把 `w32_init_console()` 提到 `main()` 第一行，
它会无条件把 stdout/stderr `freopen` 到 `CONOUT$`/`NUL`，于是在
MSYS bash、管道、`--version > f` 这类场景下把已经有效的重定向流覆盖掉：
`--version` 无输出、重定向文件 0 字节。
现在**只接管无效的流**（`fileno`/`_get_osfhandle`/`GetFileType` 判定），
`LEANTTY_KDBG_FILE` 仍优先用于 stderr；`--version` / `-h` 恢复正常。

### 测试

- 单元测试 39；e2e 14/14；附加 e2e **29**（新增 T 用例）；按键矩阵 49/49；golden 逐字节一致；
- e2e 的窗口查找改为按 `_NET_WM_PID` 精确定位，`stop_app` 会等窗口真正消失
  （之前按窗口名匹配会命中上一个用例的窗口，测的是旧进程）。

## 0.1.13

### 修复：浅色主题下"白字白底"（pi 那四行标签）

第五轮实机取证定位到根因：`pi` 那四行只发 **bold、不带颜色**，而 inbox conhost
（10.0.19041）会把"SGR 1 无颜色"归一化成 **bright white（palette 15）**。
dump 原始行：`fg=p15 bold=1 faint=0`，背景 `#F3F1E9`，对比度只有 **1.15:1**。
所以此前无论改 `[colors.bright] black`（那是 p8）还是 `faint_opacity`（这些格 `faint=0`，
SGR 2 已被 conhost 丢弃）都不会有变化。

修法：

- 新增 **`[colors.bright] white_fg`**：palette 15 作为**前景**时使用的颜色
  （背景仍用 `white`）。浅色主题里 `bright white` 既要当"接近背景"的底色、
  又要当 conhost 注入的前景色，这个键把两种用途分开。
  示例主题设成 `white_fg = "#303238"`，四行标签的对比度回到 **11.33:1**。
- **示例主题按 WCAG ≥4.6:1 重算**（保色相、只压亮度）：normal 组 8 个 +
  bright 组 7 个全部达标（原值最低 1.15、多数 2.5–4.2）。`bright.white` 保留为浅色
  `#DCD8CB` 供底色使用。

### 修复：Windows GUI 子系统下 `config:` 路径打印丢失

`main.zig` 在读配置时打印 `config: <路径>`，但那时 `w32_init_console()` 还没跑，
stderr 是无效句柄 → 日志里看不到这一行（"改错文件"排查不出来）。
现在 `w32_init_console()` 幂等化，`main()` 最开头就调用一次。

## 0.1.12

### 新增：可调 dim（faint）与配置来源可见

- `[colors] faint = true|false`：SGR 2（dim）是否压暗。设 `false` 时按原色绘制
  （与 Rust 版 Windows 行为一致）。
- `[colors] faint_opacity = 0..1`（默认 0.5）：压暗强度，`显示色 = 背景×(1-p) + 前景×p`。
  实测同一份配置：`0.5` → `#9E9D97`、`0.25` → `#C8C7C0`、`0` → 背景色。
- 启动时打印**实际加载的配置路径**（`config: <路径>`），找不到时打印
  `config: 读不到该文件，使用默认值`。Windows 上 `%APPDATA%`、便携配置、`LEANTTY_CONFIG`
  哪个生效一目了然——此前"改了配置没生效"就是因为看不见这一点。

### 新增：Windows 便携配置真正生效

zip 包里的 `leantty.toml` 与 `run.cmd` 一直声称"同目录配置会被读取"，但代码**从未实现**。
现在按下面的顺序查找（先命中先赢）：`--config-file` → `LEANTTY_CONFIG` →
平台默认（`%APPDATA%\leantty\leantty.toml` / `$XDG_CONFIG_HOME` 或 `~/.config`）→
可执行文件同目录的 `leantty.toml`。便携配置**只在用户没有自己的配置时**生效，
避免分发示例配置盖掉用户配置。

### 修复：窗口标题与图标

- X11：默认标题改为 `leantty`；新增 `_NET_WM_ICON`（内嵌 16/32/64 三档 RGBA，
  由 `scripts/gen-icon-header.py` 从 `assets/icon/png/` 生成 `src/icon_rgba.h`）；
  `WM_CLASS` 为 `leantty`/`Leantty`，与 `.desktop` 的 `StartupWMClass=leantty` 对齐。
  修了一个 Xlib 细节：format=32 的 `XChangeProperty` 要求数据按 `long` 排布，
  直接传 `uint32_t` 数组会写出长度减半、内容错位的属性（xprop 里表现为一个不存在的 48×48）。
- Windows：默认标题 `leantty`；窗口类与 `WM_SETICON` 都使用 exe 内嵌图标资源，
  任务栏与 Alt-Tab 不再显示空白窗口图标。

## 0.1.11

### 修复（Linux 粘贴，三个叠加的缺陷）

用户实测：粘贴一段配置文本被截断，末尾出现半个汉字（`微暖灰�`）。

1. **事件缓冲只有 128 字节**：`TTY_EV_PASTE` 把剪贴板内容直接复制进 `event.text[128]`，
   超过 127 字节就按字节截断（中文被切在半个 UTF-8 字符上 → 乱码）。
   改为事件只带"有粘贴"信号，正文由 `tty_paste_take()/tty_paste_done()` 从 shim 整块取走；
   `app.zig` 侧再加一层 UTF-8 边界兜底（宁可少一个字符也不送半字符进 PTY）。
2. **不支持 X11 INCR 增量传输**：大选区（>约 20 KB）X 只回一个 `INCR` 标记，内容按块用
   `PropertyNotify` 送。之前完全不处理 → 只拿到第一块。现已实现：识别 `INCR`、
   逐块 `XGetWindowProperty(Delete=True)` 追加、收到 0 长度块结束。
3. **PTY 非阻塞写遇到 `EAGAIN` 直接丢弃**：master 是 `O_NONBLOCK`，大段粘贴写满缓冲后
   `write()` 返回 `EAGAIN`，旧代码 `return` 把余下数据静默丢掉。改为**挂起队列**：
   写不完的进 `pending`，主循环在 `poll` 里带 `POLLOUT` 续写。

**验证**（Linux，探针把子进程 stdin 原样落盘，逐字节比对）：

| 用例 | 修复前 | 修复后 |
|---|---|---|
| 633 B 中文配置 | 截断在 127 B、乱码 | 字节一致 |
| 183,000 B 中文（3000 行） | 只到 17,420 B | **183,000 B 字节一致** |
| 201,000 B 纯 ASCII | 截断 | **201,000 B 字节一致** |

同时确认 **Rust 版在 Linux 上没有这个问题**（同样 183 KB 粘贴收到完整 183,000 B，
只是它把换行归一成 `\r`）。

## 0.1.10

### 修复（Linux + Windows）

- **行高比 alacritty 高（"字体过长"）**：0.1.7 为解决 CJK 顶部被裁，把格子度量改成"取所有字面的最大值"，
  行高因此高 1–2px。现在改回**只按主字体**算（`ascent + descent + line_gap` = FT 的 `height`，
  与 alacritty 同一口径，实测 26px 下双方都是 30px），裁切改由渲染侧解决。
- **允许字形纵向溢出格子**：CJK 回退字体字形比主字体高时，按 alacritty 的口径画到相邻行，
  而不是裁掉或抬高行高。Linux（`render.zig`）去掉纵向格子裁剪；Windows（`win32.c`）
  字形位图按需上下补行（`pad_top`/`pad_bottom`），再把整块上移贴图。
  实测：26px 下"你"字渲染 24 行（= FreeType 位图行数，修复前会少 1 行）。

### 更正（历史发布说明）

- 0.1.7 里"单击不清选区"的根因写的是 `MOUSE_RELEASE` 未结束拖拽——**不成立**；
  真因是 ghostty 的 `RenderState.update` 在选区清空后不重写 `row.selection`（0.1.9 修复）。
- 0.1.8 里"多行粘贴逐行提交"的根因写的是"三次 `WriteFile` 切开转义序列"——**不成立**；
  真因是 inbox conhost 丢弃 `ESC[200~`/`ESC[201~` 并把 `CR` 翻倍（0.1.9 修复，
  一次写入仍然必要但不是充分原因）。

### 测试

- 单元测试 38、e2e 14/14、附加 28/28、golden 逐字节一致；两平台构建通过。

## 0.1.9

### 修复（Windows 为主，Linux 同步加固）

- **选中文字后单击，黑色选框不消失**：ghostty 的 `RenderState.update` 在
  `selection == null` 时**不会**重写各行的 `row.selection`（只有被重建的行才置 null），
  而渲染侧无条件信任行缓存 → 清掉选区后旧区间继续反色（全屏 TUI 里最明显）。
  Windows 侧改为按 `term.hasSelection()` 决定是否采用行缓存；Linux 侧同一条代码路径
  也加了同样的门（`Renderer.selection_active`），本次手势在 Linux 上未复现，
  属预防性一致化，实测行为不变。
- **多行粘贴被逐行提交**（Windows）：inbox conhost（10.0.19041）的输入解析器会**丢弃**
  `ESC[200~`/`ESC[201~`，并把每个 `CR` 变成两个 `CR`（客户端日志确认发的是 187 字节、
  含标记、一次写入；子进程实收正文 + 双 CR）。Rust 版 0.2.10 在同机表现一致，属平台行为。
  现在对端要求 bracketed paste 时把正文换行用 **LF** 代替 CR（`src/paste.zig`），
  子进程不再把每行当提交；不要求 bracketed 的程序（cmd / powershell）行为不变。

### 已知限制（Windows）

- ConPTY 丢弃括号粘贴标记，因此 `pi` 里看到的是**多行文本**而不是 `[paste #1 +N lines]`；
  要拿到原生聚合提示需要 WSLC/OpenConsole 一类自带伪控制台服务端的环境。
- `SGR 2`（dim）在 ConPTY 输入侧被丢弃、`SGR 1` 无颜色被改写成亮白，因此 faint 类
  配色无法在 Windows 实机上对照；VT 解析层的单测证明我们自己认这两个属性。

### 测试

- 单元测试 38 个（新增粘贴归一 3 条、SGR 2/1/7 风格位 1 条）；
- Windows e2e 新增 `run_select.sh`（像素判据）+ `tools/mouse_gesture.ps1`、`tools/imgdiff.ps1`。

## 0.1.8

### 修复（仅 Windows）

- **多行粘贴被逐行提交**：粘贴时把 `ESC[200~`（bracketed paste 前缀）、正文、`ESC[201~` 分**三次**
  `WriteFile` 写入 ConPTY。ConPTY 的输入侧是 VT 解析器，每次写入是一个独立批次，
  批尾不完整的转义序列会被当成散键（ESC → Escape，`[200~` 变成字面字符），
  程序收不到包裹，于是把每个换行当 Enter 提交——表现就是"只粘了一行就提交，其余逐行排队"。
  改为**一次性写入**整段（前缀 + 归一化正文 + 后缀），与 Rust 版的 `normalize_paste()` 同口径。
  Linux 侧直写 PTY 主端、无 VT 解析，不存在该问题（探针验证：包裹序列完整到达）。

### 验证

- Linux 探针对照：Zig 0.1.7 收到 `ESC[200~…ESC[201~`（正文保留 LF）；Rust 版收到同样包裹（正文为 CR）。
- Windows 侧需实机确认（第四轮任务书 §5）。

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
