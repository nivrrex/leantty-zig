#!/bin/bash
# 光标验收：
#   * 四种形状（block / bar / underline / block_hollow）用 [cursor] style 指定，
#     dump 断言 cursor=<形状>，同时各截一张图（$WORK/shots）。
#   * 闪烁：[cursor] blink = true 时 cursor_visible 应在 0/1 之间翻转。
#   * 可见性：dump 的 cursor_visible=1（= rs.cursor.visible 且处于亮态）。
. "$(dirname "$0")/lib.sh"

C="$WORK/cursor"
mkdir -p "$(unixpath "$C")/shots"
CU="$(unixpath "$C")"

for st in block bar underline block_hollow; do
    printf '[cursor]\nstyle = "%s"\n' "$st" >"$CU/$st.toml"
    echo "== 形状 $st =="
    export LEANTTY_CONFIG="$C\\$st.toml"
    start_instance "cur$st" -e 'cmd.exe /k'
    assert_grep "cursor=$st" "cursor=$st cursor_visible=1" "$(dump_file "cur$st")"
    powershell -NoProfile -ExecutionPolicy Bypass -File "$SHOT" -cmdLike "i\\cur$st" \
        -out "$(winpath "$CU/shots/cursor_$st.png")" 2>&1 | tail -1
    stop_instance "cur$st"
done
unset LEANTTY_CONFIG

echo "== 闪烁（cursor.blink = true） =="
printf '[cursor]\nblink = true\nstyle = "block"\n' >"$CU/blink.toml"
export LEANTTY_CONFIG="$C\\blink.toml"
start_instance curblink -e 'cmd.exe /k'
seen=""
for i in 1 2 3 4 5 6 7 8; do
    seen="$seen$(grep -o 'cursor_visible=[01]' "$(dump_file curblink)" 2>/dev/null | head -1 | tail -c 2)"
    sleep 0.25
done
echo "cursor_visible 采样: $seen"
if printf '%s' "$seen" | grep -q "1" && printf '%s' "$seen" | grep -q "0"; then
    echo "PASS 闪烁翻转"; PASS=$((PASS + 1))
else
    echo "FAIL 闪烁未翻转: $seen"; FAIL=$((FAIL + 1))
fi
stop_instance curblink
unset LEANTTY_CONFIG

echo "== 无焦点时仍可见（失焦画空心框） =="
start_instance curnofocus -e 'cmd.exe /k'
powershell -NoProfile -ExecutionPolicy Bypass -File "$SEND" -cmdLike "i\\curnofocus" -keys 'focus-me' >/dev/null 2>&1
sleep 1
assert_grep "失焦仍上报可见" "cursor_visible=1" "$(dump_file curnofocus)"
powershell -NoProfile -ExecutionPolicy Bypass -File "$SHOT" -cmdLike "i\\curnofocus" \
    -out "$(winpath "$CU/shots/cursor_unfocused.png")" 2>&1 | tail -1
stop_instance curnofocus

echo "截图目录: $(unixpath "$C")/shots"
summary
