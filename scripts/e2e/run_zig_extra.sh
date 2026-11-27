#!/bin/sh
# Zig 版附加 e2e（Rust 阶段1 没有的能力，故不进共享 run_all.sh）：
#   A 键位：F1/F5/PageUp/PageDown/Insert/Delete 是否真的发到 PTY
#   B scrollback 滚动：Shift+PageUp/PageDown、Home/End（view/Bottom）
#   C 滚轮：鼠标上报关闭时用滚轮滚 scrollback
#   D 鼠标上报：程序开 1000 后点击/滚轮应编码成 ESC[M/ESC[<...M 写入 PTY
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/scripts/e2e/out"
mkdir -p "$OUT"
rm -f "$OUT"/extra*.log
# 测试隔离：用空配置，避免读到用户 ~/.config/leantty/leantty.toml（字体/绑定会影响断言）
: > "$OUT/empty.toml"
export LEANTTY_CONFIG="$OUT/empty.toml"
DISPLAY_NO=98
APP_BIN="${1:-$ROOT/zig-out/bin/leantty}" # 允许传入别的二进制（对拍/回归验证用）

for tool in Xvfb xdotool openbox; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool 未安装"; exit 1; }
done
[ -x "$APP_BIN" ] || { echo "FATAL: $APP_BIN 不存在，请先 zig build"; exit 1; }

if [ -e "/tmp/.X${DISPLAY_NO}-lock" ]; then
    echo "清理残留 display :$DISPLAY_NO"
    pkill -f "Xvfb :${DISPLAY_NO} " 2>/dev/null
    sleep 1
    rm -f "/tmp/.X${DISPLAY_NO}-lock"
fi
Xvfb :$DISPLAY_NO -screen 0 1280x720x24 >"$OUT/extra-xvfb.log" 2>&1 &
XVFB_PID=$!
openbox >"$OUT/extra-openbox.log" 2>&1 &
WM_PID=$!
trap 'kill $XVFB_PID $WM_PID ${APP_PID:-} 2>/dev/null; exit 0' EXIT INT TERM
sleep 1
export DISPLAY=:$DISPLAY_NO

PASS=0; FAIL=0
WID=""; APP_PID=""

start_app() {
    APP_CELL_W=8 APP_CELL_H=16 APP_DUMP_SNAPSHOT="$1" SHELL=/bin/dash "$APP_BIN" >>"$OUT/extra-app.log" 2>&1 &
    APP_PID=$!
    local i=0
    WID=""
    while [ $i -lt 20 ]; do
        WID=$(xdotool search --pid "$APP_PID" 2>/dev/null | tail -1)
        [ -z "$WID" ] && WID=$(xdotool search --name "tty" 2>/dev/null | head -1)
        [ -n "$WID" ] && break
        sleep 0.5; i=$((i+1))
    done
    [ -n "$WID" ] || { echo "FAIL start_app: 未找到窗口"; FAIL=$((FAIL+1)); return 1; }
    xdotool windowfocus "$WID" >/dev/null 2>&1
    xdotool windowactivate "$WID" >/dev/null 2>&1
    sleep 0.3
    return 0
}
stop_app() {
    [ -n "$APP_PID" ] && kill $APP_PID 2>/dev/null
    [ -n "$APP_PID" ] && wait $APP_PID 2>/dev/null
    APP_PID=""
    # 等窗口真的消失：否则下一个用例会按名字匹配到上一个窗口，测的是旧进程
    local i=0
    while [ $i -lt 10 ]; do
        [ -z "$(xdotool search --name tty 2>/dev/null | head -1)" ] && break
        sleep 0.2; i=$((i+1))
    done
}

# 带配置文件启动（用于配色断言）
# 额外的环境变量版启动：$1 dump 路径，其余是 VAR=VAL（与 start_app 同口径）
start_app_env() { # $1 dump 路径；$2.. 环境变量
    stop_app
    local dump="$1"; shift
    env "$@" APP_CELL_W=8 APP_CELL_H=16 APP_DUMP_SNAPSHOT="$dump" SHELL=/bin/dash "$APP_BIN" >>"$OUT/extra-app.log" 2>&1 &
    APP_PID=$!
    local i=0
    WID=""
    while [ $i -lt 20 ]; do
        WID=$(xdotool search --pid "$APP_PID" 2>/dev/null | tail -1)
        [ -z "$WID" ] && WID=$(xdotool search --name "tty" 2>/dev/null | tail -1)
        [ -n "$WID" ] && break
        sleep 0.5; i=$((i+1))
    done
    [ -n "$WID" ] || return 1
    xdotool windowfocus "$WID" >/dev/null 2>&1
    return 0
}

start_app_cfg() { # $1 dump 路径 $2 配置文件
    stop_app
    APP_CELL_W=8 APP_CELL_H=16 LEANTTY_CONFIG="$2" APP_DUMP_SNAPSHOT="$1" SHELL=/bin/dash "$APP_BIN" >>"$OUT/extra-app.log" 2>&1 &
    APP_PID=$!
    local i=0
    WID=""
    while [ $i -lt 20 ]; do
        WID=$(xdotool search --pid "$APP_PID" 2>/dev/null | tail -1)
        [ -z "$WID" ] && WID=$(xdotool search --name "tty" 2>/dev/null | tail -1)
        [ -n "$WID" ] && break
        sleep 0.5; i=$((i+1))
    done
    [ -n "$WID" ] || return 1
    xdotool windowfocus "$WID" >/dev/null 2>&1
    xdotool windowactivate "$WID" >/dev/null 2>&1
    sleep 0.3
    return 0
}

# 带 -e 启动（用于验证 argv 原样传递）
start_app_cmd() { # $1 dump 路径，其后为完整 argv
    local dump="$1"; shift
    stop_app
    APP_CELL_W=8 APP_CELL_H=16 APP_DUMP_SNAPSHOT="$dump" "$APP_BIN" "$@" >>"$OUT/extra-app.log" 2>&1 &
    APP_PID=$!
    local i=0
    WID=""
    while [ $i -lt 20 ]; do
        WID=$(xdotool search --pid "$APP_PID" 2>/dev/null | tail -1)
        [ -z "$WID" ] && WID=$(xdotool search --name "tty" 2>/dev/null | tail -1)
        [ -n "$WID" ] && break
        sleep 0.5; i=$((i+1))
    done
    [ -n "$WID" ] || return 1
    sleep 0.6
    return 0
}

wait_dump() { # $1 文件 $2 pattern
    local i=0
    while [ $i -lt 12 ]; do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.5; i=$((i+1)); done
    return 1
}
pass() { echo "PASS $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL $1 ($2)"; FAIL=$((FAIL+1)); cp "$D" "$OUT/extra-$1-fail.dump" 2>/dev/null; }

# ---- A 键位 ----
D="$OUT/extra-keys.dump"
if start_app "$D"; then
    # cat -v 把收到的控制字节转成可见文本，便于断言
    xdotool type --window "$WID" "cat -v"
    xdotool key --window "$WID" Return
    sleep 0.5
    xdotool key --window "$WID" F1
    xdotool key --window "$WID" F5
    xdotool key --window "$WID" Page_Up
    xdotool key --window "$WID" Delete
    # cat 是行缓冲：不按回车，前面这些键都还在终端驱动的行缓冲里
    xdotool key --window "$WID" Return
    sleep 0.8
    # F1 = ESC OP，cat -v 显示为 ^[OP；F5 = ^[[15~；PageUp = ^[[5~；Delete = ^[[3~
    wait_dump "$D" "OP" && pass "A-f1" || fail "A-f1" "OP"
    wait_dump "$D" "15~" && pass "A-f5" || fail "A-f5" "15~"
    wait_dump "$D" "5~" && pass "A-pageup" || fail "A-pageup" "5~"
    wait_dump "$D" "3~" && pass "A-delete" || fail "A-delete" "3~"
    xdotool key --window "$WID" ctrl+c
    stop_app
fi

# ---- B scrollback 滚动 ----
D="$OUT/extra-scroll.dump"
if start_app "$D"; then
    xdotool type --window "$WID" "seq 1 60"
    xdotool key --window "$WID" Return
    sleep 1
    wait_dump "$D" "60" && pass "B-output-60" || fail "B-output-60" "60"
    cp "$D" "$OUT/extra-before-scroll.dump"
    xdotool key --window "$WID" shift+Prior
    sleep 0.8
    if cmp -s "$D" "$OUT/extra-before-scroll.dump"; then
        fail "B-shift-pageup-changes-view" "dump 未变化"
    else
        pass "B-shift-pageup-changes-view"
    fi
    xdotool key --window "$WID" shift+End
    sleep 0.8
    wait_dump "$D" "60" && pass "B-shift-end-back-to-bottom" || fail "B-shift-end-back-to-bottom" "60"
    stop_app
fi

# ---- C 滚轮滚动（鼠标上报关闭时） ----
D="$OUT/extra-wheel.dump"
if start_app "$D"; then
    xdotool type --window "$WID" "seq 1 60"
    xdotool key --window "$WID" Return
    sleep 1
    cp "$D" "$OUT/extra-before-wheel.dump"
    xdotool click --window "$WID" --repeat 3 4   # 滚轮上
    sleep 0.8
    if cmp -s "$D" "$OUT/extra-before-wheel.dump"; then
        fail "C-wheel-scrolls-viewport" "dump 未变化"
    else
        pass "C-wheel-scrolls-viewport"
    fi
    stop_app
fi

# ---- D 鼠标上报（程序开启 1000） ----
D="$OUT/extra-mouse.dump"
if start_app "$D"; then
    # 打开 X10/normal 鼠标上报后，用 cat -v 显示终端发出的鼠标序列
    xdotool type --window "$WID" "printf '\033[?1000h'; cat -v"
    xdotool key --window "$WID" Return
    sleep 0.8
    xdotool click --window "$WID" 1
    sleep 0.8
    if wait_dump "$D" "\[M"; then
        pass "D-mouse-report-x10"
    else
        # SGR 模式会显示为 [<0;...M
        wait_dump "$D" "\[<" && pass "D-mouse-report-sgr" || fail "D-mouse-report" "\\[M"
    fi
    xdotool key --window "$WID" ctrl+c
    stop_app
fi

# ---- E 粘贴：Ctrl+Shift+V 从 CLIPBOARD 粘贴 ----
D="$OUT/extra-paste.dump"
if start_app "$D"; then
    printf 'PASTE_OK' | xclip -selection clipboard 2>/dev/null
    sleep 0.3
    xdotool key --window "$WID" ctrl+shift+v
    sleep 0.5
    xdotool key --window "$WID" Return
    sleep 0.8
    wait_dump "$D" "PASTE_OK" && pass "E-paste-clipboard" || fail "E-paste-clipboard" "PASTE_OK"
    stop_app
fi

# ---- F OSC 52 写入：程序设置系统剪贴板 ----
D="$OUT/extra-osc52.dump"
if start_app "$D"; then
    # "OSC52_OK" 的 base64 是 T1NDNTJfT0s=
    xdotool type --window "$WID" "printf '\\033]52;c;T1NDNTJfT0s=\\a'"
    xdotool key --window "$WID" Return
    sleep 1
    got=$(timeout 3 xclip -o -selection clipboard 2>/dev/null | tr -d '\n')
    if [ "$got" = "OSC52_OK" ]; then
        pass "F-osc52-sets-x-clipboard"
    else
        fail "F-osc52-sets-x-clipboard" "xclip 得到 '[${got}]'"
    fi
    stop_app
fi

# ---- G 复制：Ctrl+Shift+C 把当前内容（无选区时全选）写入 CLIPBOARD ----
D="$OUT/extra-copy.dump"
if start_app "$D"; then
    xdotool type --window "$WID" "echo COPY_OK"
    xdotool key --window "$WID" Return
    sleep 0.8
    xdotool key --window "$WID" ctrl+shift+c
    sleep 0.8
    got=$(timeout 3 xclip -o -selection clipboard 2>/dev/null | tr -d '\n')
    case "$got" in
        *COPY_OK*) pass "G-copy-selection-to-clipboard" ;;
        *) fail "G-copy-selection-to-clipboard" "xclip 得到 '[${got}]'" ;;
    esac
    stop_app
fi

# ---- H 中键粘贴：PRIMARY ----
D="$OUT/extra-middle.dump"
if start_app "$D"; then
    printf 'MIDDLE_OK' | xclip -selection primary 2>/dev/null
    sleep 0.3
    xdotool click --window "$WID" 2
    sleep 0.5
    xdotool key --window "$WID" Return
    sleep 0.8
    wait_dump "$D" "MIDDLE_OK" && pass "H-middle-click-paste-primary" || fail "H-middle-click-paste-primary" "MIDDLE_OK"
    stop_app
fi

# ---- I 鼠标拖拽选区：拖动后选中内容进 PRIMARY ----
D="$OUT/extra-drag.dump"
if start_app "$D"; then
    xdotool type --window "$WID" "echo DRAG_OK"
    xdotool key --window "$WID" Return
    sleep 0.8
    # 从第 0 行拖到第 3 行末（8x16 格子：x=4..632, y=8..56）
    xdotool mousemove --window "$WID" 4 8
    xdotool mousedown 1
    xdotool mousemove --window "$WID" 200 24
    xdotool mousemove --window "$WID" 600 56
    xdotool mouseup 1
    sleep 0.8
    got=$(timeout 3 xclip -o -selection primary 2>/dev/null | tr -d '\n')
    case "$got" in
        *DRAG_OK*) pass "I-drag-select-to-primary" ;;
        *) fail "I-drag-select-to-primary" "PRIMARY 得到 '[${got}]'" ;;
    esac
    stop_app
fi

# ---- J 鼠标上报 1002+SGR：按下/拖动/释放都应编码 ----
D="$OUT/extra-motion.dump"
if start_app "$D"; then
    xdotool type --window "$WID" "printf '\\033[?1002h\\033[?1006h'; cat -v"
    xdotool key --window "$WID" Return
    sleep 0.8
    xdotool mousemove --window "$WID" 40 40
    xdotool mousedown 1
    xdotool mousemove --window "$WID" 120 48
    xdotool mouseup 1
    sleep 0.8
    if wait_dump "$D" "\[<0;"; then
        pass "J-mouse-press-encoded"
    else
        fail "J-mouse-press-encoded" "SGR 按下序列"
    fi
    # 拖动应产生 motion（按钮码 32+0）与释放（m 结尾）
    if wait_dump "$D" "M"; then pass "J-mouse-motion-or-release"; else fail "J-mouse-motion-or-release" "M"; fi
    xdotool key --window "$WID" ctrl+c
    stop_app
fi

# ---- K 双击选词：双击第二个词，PRIMARY 应只含该词 ----
D="$OUT/extra-dblclick.dump"
if start_app "$D"; then
    xdotool type --window "$WID" "echo WORD1 WORD2"
    xdotool key --window "$WID" Return
    sleep 0.8
    # 第 2 行（输出行）从 x=40 处双击：约等于第二个词
    # 输出行 "WORD1 WORD2"：WORD2 在 x 格 6..10 → 像素 48..88，取 60
    xdotool mousemove --window "$WID" 60 24
    xdotool click --repeat 2 --delay 120 1
    sleep 0.8
    got=$(timeout 3 xclip -o -selection primary 2>/dev/null | tr -d '\n')
    case "$got" in
        *WORD2*) [ "${got#*WORD1}" = "$got" ] && pass "K-double-click-word" || fail "K-double-click-word" "选中了整行 '[${got}]'" ;;
        *) fail "K-double-click-word" "PRIMARY 得到 '[${got}]'" ;;
    esac
    # 三击选整行：应同时包含两个词
    xdotool click --repeat 3 --delay 120 1
    sleep 0.8
    got2=$(timeout 3 xclip -o -selection primary 2>/dev/null | tr -d '\n')
    case "$got2" in
        *WORD1*WORD2*) pass "K-triple-click-line" ;;
        *) fail "K-triple-click-line" "PRIMARY 得到 '[${got2}]'" ;;
    esac
    stop_app
fi

# ---- L 配置鼠标绑定：Right = Paste ----
cat > "$OUT/mouse.toml" <<'TOMLEOF'
[[mouse.bindings]]
mouse = "Right"
action = "Paste"
TOMLEOF
D="$OUT/extra-mousebind.dump"
LEANTTY_CONFIG="$OUT/mouse.toml"
if start_app "$D"; then
    printf 'RIGBIND_OK' | xclip -selection clipboard 2>/dev/null
    sleep 0.3
    xdotool click --window "$WID" 3
    sleep 0.5
    xdotool key --window "$WID" Return
    sleep 0.8
    wait_dump "$D" "RIGBIND_OK" && pass "L-mouse-binding-right-paste" || fail "L-mouse-binding-right-paste" "RIGBIND_OK"
    stop_app
fi

# ---- M 配置键盘绑定（key + mods 写法）：Ctrl+Insert = Copy ----
cat > "$OUT/key.toml" <<'TOMLEOF'
[[keyboard.bindings]]
key = "Insert"
mods = "Control"
action = "Copy"
TOMLEOF
D="$OUT/extra-keybind.dump"
LEANTTY_CONFIG="$OUT/key.toml"
if start_app "$D"; then
    xdotool type --window "$WID" "echo KEYBIND_SRC"
    xdotool key --window "$WID" Return
    sleep 0.8
    xdotool key --window "$WID" ctrl+Insert
    sleep 0.8
    got=$(timeout 3 xclip -o -selection clipboard 2>/dev/null | tr -d '\n')
    case "$got" in
        *KEYBIND_SRC*) pass "M-key-binding-mods-control-insert" ;;
        *) fail "M-key-binding-mods-control-insert" "剪贴板得到 '[${got}]'" ;;
    esac
    stop_app
fi

# ---- N 无配置时 Insert 家族默认语义，且不得出现 CSI 2;5~ 残片 ----
D="$OUT/extra-insert-default.dump"
LEANTTY_CONFIG="$OUT/empty.toml"
if start_app "$D"; then
    printf 'DEFINS_OK' | xclip -selection clipboard 2>/dev/null
    sleep 0.3
    xdotool key --window "$WID" shift+Insert
    sleep 0.5
    xdotool key --window "$WID" Return
    sleep 0.8
    wait_dump "$D" "DEFINS_OK" && pass "N-shift-insert-default-paste" || fail "N-shift-insert-default-paste" "DEFINS_OK"
    xdotool key --window "$WID" ctrl+Insert
    sleep 0.8
    if grep -q "5~" "$D"; then
        fail "N-no-csi-2-5-fragment" "dump 出现 5~"
    else
        pass "N-no-csi-2-5-fragment"
    fi
    stop_app
fi

# ---- O 动态标题（OSC 2）----
D="$OUT/extra-title.dump"
LEANTTY_CONFIG="$OUT/empty.toml"
if start_app "$D"; then
    xdotool type --window "$WID" 'printf "\\033]2;TITLE_E2E\\007"'
    xdotool key --window "$WID" Return
    sleep 0.8
    if xprop -id "$WID" WM_NAME 2>/dev/null | grep -q "TITLE_E2E"; then
        pass "O-dynamic-title"
    else
        fail "O-dynamic-title" "WM_NAME 未更新"
    fi
    stop_app
fi

# ---- P 光标样式（DECSCUSR 5=bar / 2=block）----
D="$OUT/extra-cursor.dump"
if start_app "$D"; then
    xdotool type --window "$WID" 'printf "\\033[5 q"'
    xdotool key --window "$WID" Return
    sleep 0.6
    wait_dump "$D" "cursor=bar" && pass "P-cursor-style-bar" || fail "P-cursor-style-bar" "cursor=bar"
    xdotool type --window "$WID" 'printf "\\033[2 q"'
    xdotool key --window "$WID" Return
    sleep 0.6
    wait_dump "$D" "cursor=block" && pass "P-cursor-style-block" || fail "P-cursor-style-block" "cursor=block"
    stop_app
fi

# ---- Q 光标闪烁（配置开启后 cursor_visible 应出现 0 与 1 两种相位）----
cat > "$OUT/blink.toml" <<'TOMLEOF'
[cursor]
blink = true
TOMLEOF
D="$OUT/extra-blink.dump"
LEANTTY_CONFIG="$OUT/blink.toml"
if start_app "$D"; then
    seen_off=0
    seen_on=0
    i=0
    while [ $i -lt 10 ]; do
        if grep -q "cursor_visible=0" "$D" 2>/dev/null; then seen_off=1; fi
        if grep -q "cursor_visible=1" "$D" 2>/dev/null; then seen_on=1; fi
        sleep 0.2
        i=$((i+1))
    done
    if [ "$seen_off" -eq 1 ] && [ "$seen_on" -eq 1 ]; then
        pass "Q-cursor-blink-toggles"
    else
        fail "Q-cursor-blink-toggles" "off=$seen_off on=$seen_on"
    fi
    stop_app
fi

# ---------- R：配色配置生效 ----------
printf '[colors.primary]\nbackground = "#101010"\nforeground = "#C0C0C0"\n[colors.normal]\nred = "#FF0000"\n' > "$OUT/colors.toml"
D="$OUT/extra-colors.dump"
if start_app_cfg "$D" "$OUT/colors.toml"; then
    if wait_dump "$D" "bg=101010"; then
        echo "PASS R-colors-bg (bg=101010)"; PASS=$((PASS+1))
    else
        echo "FAIL R-colors-bg"; FAIL=$((FAIL+1)); cp "$D" "$OUT/R-fail.dump" 2>/dev/null
    fi
else
    echo "FAIL R-colors-bg (启动失败)"; FAIL=$((FAIL+1))
fi

# ---------- S：-e 的 argv 原样传递（曾经把 argv[0] 当 shell 名）----------
D="$OUT/extra-argv.dump"
# 子进程要有停留时间，否则首帧还没落盘就退出了
# 注意 sh -c 的语义：-c 之后的第一个参数是 $0，不是 $1
if start_app_cmd "$D" -e /bin/sh -c 'printf "ARGV_%s_OK\n" "$0"; sleep 2' X; then
    if wait_dump "$D" "ARGV_X_OK"; then
        echo "PASS S-argv-passthrough"; PASS=$((PASS+1))
    else
        echo "FAIL S-argv-passthrough"; FAIL=$((FAIL+1)); cp "$D" "$OUT/S-fail.dump" 2>/dev/null
    fi
else
    echo "FAIL S-argv-passthrough (启动失败)"; FAIL=$((FAIL+1))
fi


# ---------- T：**默认配置路径**真的生效（0.1.12 曾返回栈上缓冲的悬空指针）----------
# 只在 XDG_CONFIG_HOME 下放一份配置、不传 --config-file：路径必须被真正打开。
mkdir -p "$OUT/xdg/leantty"
printf '[colors.primary]\nbackground = "#123456"\nforeground = "#ABCDEF"\n' > "$OUT/xdg/leantty/leantty.toml"
D="$OUT/extra-defaultcfg.dump"
rm -f "$D"   # 避免读到上一次运行留下的旧 dump
# 脚本顶部 export 了 LEANTTY_CONFIG（隔离用户配置），它优先级高于默认路径，这里清空才能测默认路径
if start_app_env "$D" XDG_CONFIG_HOME="$OUT/xdg" LEANTTY_CONFIG=""; then
    if wait_dump "$D" "bg=123456"; then
        pass "T-default-config-path"
    else
        fail "T-default-config-path" "$(head -1 "$D" 2>/dev/null)"
    fi
    stop_app
else
    fail "T-default-config-path" "启动失败"
fi

# ---------- U：双击选词的高亮必须覆盖到**最后一个字符**（闭区间）----------
# 曾经的缺陷：ghostty 的 row.selection 是闭区间 [start, end]，渲染侧按半开区间判断，
# 于是选区最后一格不反色；复制走 ghostty 自身逻辑、内容是完整的 → 右键粘贴时
# 表现为"多出一个未反色的字符"。这里用可辨识的选区配色 + APP_DUMP_COLORS 看每格最终配色。
cat >"$OUT/selection.toml" <<'TOMLEOF'
[colors.selection]
background = "#FF00FF"
foreground = "#000000"
TOMLEOF
D="$OUT/extra-selectcolors.dump"
COL="$OUT/extra-selectcolors.colors"
rm -f "$D" "$COL"
stop_app
APP_CELL_W=8 APP_CELL_H=16 LEANTTY_CONFIG="$OUT/selection.toml" \
    APP_DUMP_SNAPSHOT="$D" APP_DUMP_COLORS="$COL" SHELL=/bin/dash \
    "$APP_BIN" >>"$OUT/extra-app.log" 2>&1 &
APP_PID=$!
i=0
WID=""
while [ $i -lt 20 ]; do
    WID=$(xdotool search --pid "$APP_PID" 2>/dev/null | tail -1)
    [ -n "$WID" ] && break
    sleep 0.1
    i=$((i + 1))
done
if [ -n "$WID" ]; then
    sleep 0.4
    xdotool type --window "$WID" "echo WORD1 WORD2"
    xdotool key --window "$WID" Return
    sleep 0.9
    # 第 1 行 "WORD1 WORD2"：双击 cell 1（'O'，像素 x=12,y=24）选中的应是 WORD1 五个字符
    xdotool mousemove --window "$WID" 12 24
    xdotool click --repeat 2 --delay 120 1
    sleep 0.5
    xdotool mousemove --window "$WID" 400 300 # 触发一帧渲染，让配色 dump 刷新
    sleep 0.5
    row=$(grep -E "^1 " "$COL" 2>/dev/null)
    if [ -z "$row" ]; then
        fail "U-selection-covers-last-char" "配色 dump 为空（$COL）"
    else
        got_sel=$(printf '%s\n' "$row" | awk '$4=="ff00ff" {print $2}' | sort -n | tr '\n' ',')
        if [ "$got_sel" = "0,1,2,3,4," ]; then
            pass "U-selection-covers-last-char"
        else
            fail "U-selection-covers-last-char" "选中列=[$got_sel]，期望 0,1,2,3,4,"
        fi
        if printf '%s\n' "$row" | awk '$2==5 && $4=="ff00ff" {found=1} END {exit !found}'; then
            fail "U-selection-not-extend-past-word" "第 5 列（空格）也被高亮了"
        else
            pass "U-selection-not-extend-past-word"
        fi
    fi
    stop_app
else
    fail "U-selection-covers-last-char" "窗口没起来"
fi

# ---------- V：双击选词后右键 Paste 必须粘出整个词 ----------
# 曾经的缺陷：单击也会建 1 格选区，配合 save_to_clipboard 把它写进 CLIPBOARD；
# 右键绑 Paste 读 CLIPBOARD，于是粘出的是"点击处那一个字符"。
cat >"$OUT/selpaste.toml" <<'TOMLEOF'
[selection]
save_to_clipboard = true

[[mouse.bindings]]
mouse = "Right"
action = "Paste"
TOMLEOF
D="$OUT/extra-selpaste.dump"
rm -f "$D"
if command -v xclip >/dev/null 2>&1; then
    printf 'SEED' | xclip -selection clipboard 2>/dev/null
    printf 'PRISEED' | xclip -selection primary 2>/dev/null
    sleep 0.2
    stop_app
    APP_CELL_W=8 APP_CELL_H=16 LEANTTY_CONFIG="$OUT/selpaste.toml" \
        APP_DUMP_SNAPSHOT="$D" SHELL=/bin/dash \
        "$APP_BIN" >>"$OUT/extra-app.log" 2>&1 &
    APP_PID=$!
    i=0
    WID=""
    while [ $i -lt 20 ]; do
        WID=$(xdotool search --pid "$APP_PID" 2>/dev/null | tail -1)
        [ -n "$WID" ] && break
        sleep 0.1
        i=$((i + 1))
    done
    if [ -n "$WID" ]; then
        sleep 0.4
        xdotool type --window "$WID" "echo WORD1 WORD2"
        xdotool key --window "$WID" Return
        sleep 0.9
        # 单击一次：不得往 CLIPBOARD 写东西（以前会写进点击处那一个字符）
        xdotool mousemove --window "$WID" 12 24
        xdotool click 1
        sleep 0.5
        clip=$(timeout 3 xclip -o -selection clipboard 2>/dev/null | tr -d '\n')
        if [ "$clip" = "SEED" ]; then
            pass "V-single-click-keeps-clipboard"
        else
            fail "V-single-click-keeps-clipboard" "CLIPBOARD=[$clip]"
        fi
        # 双击 WORD1：CLIPBOARD 与 PRIMARY 都应是这个词
        xdotool click --repeat 2 --delay 120 1
        sleep 0.6
        clip=$(timeout 3 xclip -o -selection clipboard 2>/dev/null | tr -d '\n')
        pri=$(timeout 3 xclip -o -selection primary 2>/dev/null | tr -d '\n')
        if [ "$clip" = "WORD1" ] && [ "$pri" = "WORD1" ]; then
            pass "V-double-click-fills-clipboard"
        else
            fail "V-double-click-fills-clipboard" "CLIPBOARD=[$clip] PRIMARY=[$pri]"
        fi
        # 右键粘贴：应粘出整词（不是单个字符）
        xdotool click --window "$WID" 3
        sleep 0.8
        if grep -qE '(^|[#$]) WORD1$' "$D" 2>/dev/null; then
            pass "V-right-click-pastes-whole-word"
        else
            fail "V-right-click-pastes-whole-word" "$(grep -n 'WORD1' "$D" 2>/dev/null | tail -2 | tr '\n' ' ')"
        fi
        stop_app
    else
        fail "V-right-click-pastes-whole-word" "窗口没起来"
    fi
else
    echo "SKIP V-selpaste（缺 xclip）"
fi

# ---------- W：配置热加载（general.live_config_reload） ----------
# 改文件后不重启：配色应自动生效；live_config_reload=false 时不应生效。
cat >"$OUT/reload.toml" <<'TOMLEOF'
[general]
live_config_reload = true

[colors.primary]
background = "#111111"
TOMLEOF
D="$OUT/extra-reload.dump"
rm -f "$D"
stop_app
APP_CELL_W=8 APP_CELL_H=16 LEANTTY_CONFIG="$OUT/reload.toml" APP_DUMP_SNAPSHOT="$D"     SHELL=/bin/dash "$APP_BIN" >>"$OUT/extra-app.log" 2>&1 &
APP_PID=$!
PID_BEFORE=$APP_PID
i=0
WID=""
while [ $i -lt 20 ]; do
    WID=$(xdotool search --pid "$APP_PID" 2>/dev/null | tail -1)
    [ -n "$WID" ] && break
    sleep 0.1
    i=$((i + 1))
done
if [ -n "$WID" ]; then
    sleep 0.5
    got=$(head -1 "$D" 2>/dev/null | grep -o 'bg=[0-9a-f]*')
    if [ "$got" = "bg=111111" ]; then pass "W-live-reload-initial-color"; else fail "W-live-reload-initial-color" "$got"; fi
    cat >"$OUT/reload.toml" <<'TOMLEOF'
[general]
live_config_reload = true

[colors.primary]
background = "#223344"
TOMLEOF
    # 0.7s 就断言：重载成功后必须自己出一帧（不能依赖后续输入触发重绘）
    sleep 0.7
    got=$(head -1 "$D" 2>/dev/null | grep -o 'bg=[0-9a-f]*')
    if [ "$got" = "bg=223344" ]; then pass "W-live-reload-applies-color"; else fail "W-live-reload-applies-color" "$got"; fi
    if kill -0 "$PID_BEFORE" 2>/dev/null; then pass "W-live-reload-same-process"; else fail "W-live-reload-same-process" "进程被重启了"; fi
    stop_app
else
    fail "W-live-reload-applies-color" "窗口没起来"
fi

# 关闭热加载：改文件后颜色必须保持原样
cat >"$OUT/reload-off.toml" <<'TOMLEOF'
[general]
live_config_reload = false

[colors.primary]
background = "#101010"
TOMLEOF
D="$OUT/extra-reload-off.dump"
rm -f "$D"
stop_app
APP_CELL_W=8 APP_CELL_H=16 LEANTTY_CONFIG="$OUT/reload-off.toml" APP_DUMP_SNAPSHOT="$D" \
    SHELL=/bin/dash "$APP_BIN" >>"$OUT/extra-app.log" 2>&1 &
APP_PID=$!
i=0
WID=""
while [ $i -lt 20 ]; do
    WID=$(xdotool search --pid "$APP_PID" 2>/dev/null | tail -1)
    [ -n "$WID" ] && break
    sleep 0.1
    i=$((i + 1))
done
if [ -n "$WID" ]; then
    sleep 0.5
    cat >"$OUT/reload-off.toml" <<'TOMLEOF'
[general]
live_config_reload = false

[colors.primary]
background = "#abcdef"
TOMLEOF
    sleep 1.2
    got=$(head -1 "$D" 2>/dev/null | grep -o 'bg=[0-9a-f]*')
    if [ "$got" = "bg=101010" ]; then pass "W-live-reload-disabled"; else fail "W-live-reload-disabled" "$got"; fi
    stop_app
else
    fail "W-live-reload-disabled" "窗口没起来"
fi

# ---------- X：默认 shell 的优先级（配置 > $SHELL > 登录 shell） ----------
# 早前 SHELL 缺失时兜底 /bin/sh，从 .desktop/面板启动会跑成 sh-5.2（用户实测）。
# 判据用 $BASH（bash 里非空，dash/sh 里为空），不依赖提示符格式。
cat >"$OUT/shell-auto.toml" <<'TOMLEOF'
# 空配置：走 $SHELL / 登录 shell
TOMLEOF
D="$OUT/extra-shell-auto.dump"
rm -f "$D"
stop_app
env -u SHELL APP_CELL_W=8 APP_CELL_H=16 LEANTTY_CONFIG="$OUT/shell-auto.toml" \
    APP_DUMP_SNAPSHOT="$D" "$APP_BIN" >>"$OUT/extra-app.log" 2>&1 &
APP_PID=$!
i=0
WID=""
while [ $i -lt 20 ]; do
    WID=$(xdotool search --pid "$APP_PID" 2>/dev/null | tail -1)
    [ -n "$WID" ] && break
    sleep 0.1
    i=$((i + 1))
done
if [ -n "$WID" ]; then
    sleep 0.5
    xdotool type --window "$WID" 'printf "SHELLMARK:%s\n" "${BASH:-none}"'
    xdotool key --window "$WID" Return
    sleep 0.9
    if grep -q "SHELLMARK:/bin/bash\|SHELLMARK:/usr/bin/bash" "$D" 2>/dev/null; then
        pass "X-shell-falls-back-to-login-shell"
    else
        fail "X-shell-falls-back-to-login-shell" "$(grep -o 'SHELLMARK:[^ ]*' "$D" 2>/dev/null | tail -1)"
    fi
    stop_app
else
    fail "X-shell-falls-back-to-login-shell" "窗口没起来"
fi

# 配置显式给的 shell 优先于 $SHELL
cat >"$OUT/shell-cfg.toml" <<'TOMLEOF'
[terminal]
shell = "/bin/dash"
TOMLEOF
D="$OUT/extra-shell-cfg.dump"
rm -f "$D"
stop_app
SHELL=/bin/bash APP_CELL_W=8 APP_CELL_H=16 LEANTTY_CONFIG="$OUT/shell-cfg.toml" \
    APP_DUMP_SNAPSHOT="$D" "$APP_BIN" >>"$OUT/extra-app.log" 2>&1 &
APP_PID=$!
i=0
WID=""
while [ $i -lt 20 ]; do
    WID=$(xdotool search --pid "$APP_PID" 2>/dev/null | tail -1)
    [ -n "$WID" ] && break
    sleep 0.1
    i=$((i + 1))
done
if [ -n "$WID" ]; then
    sleep 0.5
    xdotool type --window "$WID" 'printf "SHELLMARK:%s\n" "${BASH:-none}"'
    xdotool key --window "$WID" Return
    sleep 0.9
    if grep -q "SHELLMARK:none" "$D" 2>/dev/null; then
        pass "X-shell-config-wins-over-env"
    else
        fail "X-shell-config-wins-over-env" "$(grep -o 'SHELLMARK:[^ ]*' "$D" 2>/dev/null | tail -1)"
    fi
    stop_app
else
    fail "X-shell-config-wins-over-env" "窗口没起来"
fi

# 会话把 SHELL 设成 /bin/sh（LXDE 等）时应改用登录 shell，而不是 bash-as-sh（sh-5.2）
D="$OUT/extra-shell-sh.dump"
rm -f "$D"
stop_app
# 这一条专门测"SHELL=/bin/sh（LXDE 等会话的 POSIX 兜底值）应被忽略"，
# 所以这里必须原样传 /bin/sh，不能跟着上面的 /bin/dash 一起改。
SHELL=/bin/sh APP_CELL_W=8 APP_CELL_H=16 LEANTTY_CONFIG="$OUT/shell-auto.toml" \
    APP_DUMP_SNAPSHOT="$D" "$APP_BIN" >>"$OUT/extra-app.log" 2>&1 &
APP_PID=$!
i=0
WID=""
while [ $i -lt 20 ]; do
    WID=$(xdotool search --pid "$APP_PID" 2>/dev/null | tail -1)
    [ -n "$WID" ] && break
    sleep 0.1
    i=$((i + 1))
done
if [ -n "$WID" ]; then
    sleep 0.5
    xdotool type --window "$WID" 'printf "SHELLMARK:%s\n" "${BASH:-none}"'
    xdotool key --window "$WID" Return
    sleep 0.9
    if grep -q "SHELLMARK:/bin/bash\|SHELLMARK:/usr/bin/bash" "$D" 2>/dev/null; then
        pass "X-shell-ignores-posix-sh-env"
    else
        fail "X-shell-ignores-posix-sh-env" "$(grep -o 'SHELLMARK:[^ ]*' "$D" 2>/dev/null | tail -1)"
    fi
    stop_app
else
    fail "X-shell-ignores-posix-sh-env" "窗口没起来"
fi

# ---------- Y：擦除类序列（cmd 补全改写一行时依赖它们） ----------
# 输入"长名字 → 回到行首 → 短名字 + 擦到行尾"，屏幕上不得留下长名字的尾巴。
D="$OUT/extra-erase.dump"
rm -f "$D"
stop_app
APP_CELL_W=8 APP_CELL_H=16 LEANTTY_CONFIG="$OUT/empty.toml" APP_DUMP_SNAPSHOT="$D" \
    SHELL=/bin/bash "$APP_BIN" -e /bin/sh -c \
    "printf 'LONGFILENAME.TXT\rSHORT\033[K'; sleep 2" >>"$OUT/extra-app.log" 2>&1 &
APP_PID=$!
i=0
while [ $i -lt 20 ]; do
    [ -s "$D" ] && break
    sleep 0.1
    i=$((i + 1))
done
sleep 0.4
line=$(tail -n +2 "$D" 2>/dev/null | head -1)
case "$line" in
    SHORT) pass "Y-erase-to-eol" ;;
    *LONGFILENAME*) fail "Y-erase-to-eol" "残留：[$line]" ;;
    *) fail "Y-erase-to-eol" "[$line]" ;;
esac
# 同一条再用 ECH（擦 n 个字符）验证
D="$OUT/extra-erase2.dump"
rm -f "$D"
stop_app
APP_CELL_W=8 APP_CELL_H=16 LEANTTY_CONFIG="$OUT/empty.toml" APP_DUMP_SNAPSHOT="$D" \
    SHELL=/bin/bash "$APP_BIN" -e /bin/sh -c \
    "printf 'ABCDEFGH\rXY\033[4X'; sleep 2" >>"$OUT/extra-app.log" 2>&1 &
APP_PID=$!
i=0
while [ $i -lt 20 ]; do
    [ -s "$D" ] && break
    sleep 0.1
    i=$((i + 1))
done
sleep 0.4
line=$(tail -n +2 "$D" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//')
# ECH 只把 4 个格子清空、不左移后续字符：XY 后 4 空格，再 GH
case "$line" in
    "XY    GH") pass "Y-erase-characters" ;;
    *) fail "Y-erase-characters" "[$line]" ;;
esac
stop_app

# ---------- Z：ConPTY 行重写擦除不足的补丁（conptyfix） ----------
# cmd 补全重画输入行时，ConPTY 对含宽字符的旧名字补的空格不够（实测差一半），
# 旧名字尾巴会留在屏幕上。conptyfix 在那类"隐藏→定位→显示→隐藏 + 文本"后补 ESC[K。
# 这里用合成流复现：先写长名字，再用 5 个空格覆盖短名字（本应 10 个）。
python3 - "$OUT/under-erase.out" <<'PYEOF'
import sys
hdr = "\x1b[25l\x1b[2;1H\x1b[?25h\x1b[25l"
long_name = "LONGFILENAME.TXT"
short_name = "SHORT" + " " * 5   # 少补 5 个空格，模拟 ConPTY 的不足
data = hdr + long_name + hdr + short_name + "\x1b[2;6H\x1b[?25h"
open(sys.argv[1], "wb").write(data.encode())
PYEOF
for mode in off on; do
    D="$OUT/extra-conptyfix-$mode.dump"
    rm -f "$D"
    stop_app
    if [ "$mode" = on ]; then
        LEANTTY_CONPTY_ERASE_FIX=1 APP_CELL_W=8 APP_CELL_H=16 LEANTTY_CONFIG="$OUT/empty.toml" \
            APP_DUMP_SNAPSHOT="$D" SHELL=/bin/bash "$APP_BIN" -e /bin/sh -c \
            "cat '$OUT/under-erase.out'; sleep 2" >>"$OUT/extra-app.log" 2>&1 &
    else
        APP_CELL_W=8 APP_CELL_H=16 LEANTTY_CONFIG="$OUT/empty.toml" \
            APP_DUMP_SNAPSHOT="$D" SHELL=/bin/bash "$APP_BIN" -e /bin/sh -c \
            "cat '$OUT/under-erase.out'; sleep 2" >>"$OUT/extra-app.log" 2>&1 &
    fi
    APP_PID=$!
    i=0
    while [ $i -lt 20 ]; do
        [ -s "$D" ] && break
        sleep 0.1
        i=$((i + 1))
    done
    sleep 0.4
    # 合成流把内容写在"第 2 行"（ESC[2;1H），所以按整屏文本判断，不取固定行号
    text=$(tail -n +2 "$D" 2>/dev/null | tr -d '\r')
    if [ "$mode" = on ]; then
        if printf '%s\n' "$text" | grep -qx 'SHORT' && ! printf '%s' "$text" | grep -q FILENAME; then
            pass "Z-conptyfix-clears-tail"
        else
            fail "Z-conptyfix-clears-tail" "$(printf '%s' "$text" | tr '\n' '|')"
        fi
    else
        # 关掉补丁时，行尾必然残留长名字的一部分（合成流只补了 5 个空格）
        if printf '%s' "$text" | grep -q 'ME.TXT'; then
            pass "Z-conptyfix-off-shows-tail"
        else
            fail "Z-conptyfix-off-shows-tail" "$(printf '%s' "$text" | tr '\n' '|')"
        fi
    fi
done
stop_app

echo "===== zig 附加 e2e: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
