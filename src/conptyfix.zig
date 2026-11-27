//! ConPTY 行重写补丁：修"Tab 补全后上一轮长名字的尾巴留在屏幕上"。
//!
//! 现象与根因（用 `LEANTTY_OUT_DUMP` 抓到的真实字节复现）：
//! cmd 的补全由 cmd 自己重画输入行，ConPTY 把这段重画转成 VT 发给宿主，形如
//!
//! ```text
//! ESC[25l ESC[2;24H ESC[?25h ESC[25l <新文本> <若干空格> ESC[2;66H ESC[?25h
//! ```
//!
//! 问题是那段"若干空格"**不够**：实测旧名 `…测试图片\图片6_ai_heatmap.png`（52 格）
//! 换成 `…测试图片\图片22.png`（42 格）时，需要补 10 个空格，ConPTY 只补了 5 个
//! （= 10/2，说明它把"格差"当成"字符数"又按每个宽字符 2 格折算了一次）。
//! 于是旧名字尾巴 `p.png` 永远留在屏幕上——终端本身按字节流渲染是对的，
//! 少的擦除上游没发。
//!
//! 补丁做法：识别上面这个"隐藏→定位→显示→隐藏 + 文本"的行重写惯用式，
//! 在文本后面补一个 `ESC[K`（擦到行尾）。光标此时正好在新文本末尾，
//! 擦到行尾正是 cmd 的本意，对更长的补全结果无副作用（无可擦）。

const std = @import("std");

const HIDE = "\x1b[25l";
const SHOW = "\x1b[?25h";

/// 在 `chunk` 里就地/搬运地插入补丁；返回写入 `out` 的长度。`out` 必须比 `chunk` 大。
pub fn apply(chunk: []const u8, out: []u8) []const u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < chunk.len) {
        // 识别 `ESC[25l ESC[2;<n>H ESC[?25h ESC[25l`
        if (matchIdiom(chunk[i..])) |hdr_len| {
            const text_start = i + hdr_len;
            if (text_start >= chunk.len) break;
            // 文本段：到下一个 ESC 或结尾
            var j = text_start;
            var printable = true;
            while (j < chunk.len and chunk[j] != 0x1b) : (j += 1) {
                if (chunk[j] < 0x20) printable = false; // 夹了控制字符：不当作行重写
            }
            if (j > text_start and printable and o + (j - i) + 3 <= out.len) {
                @memcpy(out[o..][0 .. j - i], chunk[i..j]);
                o += j - i;
                @memcpy(out[o..][0..3], "\x1b[K");
                o += 3;
                i = j;
                continue;
            }
        }
        if (o >= out.len) break;
        out[o] = chunk[i];
        o += 1;
        i += 1;
    }
    return out[0..o];
}

/// 匹配 `ESC[25l ESC[2;<n>H ESC[?25h ESC[25l`，返回其长度（不匹配返回 null）。
fn matchIdiom(s: []const u8) ?usize {
    if (!std.mem.startsWith(u8, s, HIDE)) return null;
    var i: usize = HIDE.len;
    if (!std.mem.startsWith(u8, s[i..], "\x1b[2;")) return null;
    i += 4;
    const num_start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i == num_start) return null;
    if (i >= s.len or s[i] != 'H') return null;
    i += 1;
    if (!std.mem.startsWith(u8, s[i..], SHOW)) return null;
    i += SHOW.len;
    if (!std.mem.startsWith(u8, s[i..], HIDE)) return null;
    return i + HIDE.len;
}

test "apply：行重写后补 ESC[K" {
    const testing = std.testing;
    var out: [256]u8 = undefined;
    const in = "\x1b[25l\x1b[2;24H\x1b[?25h\x1b[25lABC     \x1b[2;27H\x1b[?25h";
    const got = apply(in, &out);
    try testing.expectEqualStrings("\x1b[25l\x1b[2;24H\x1b[?25h\x1b[25lABC     \x1b[K\x1b[2;27H\x1b[?25h", got);
}

test "apply：普通文本不受影响" {
    const testing = std.testing;
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("hello", apply("hello", &out));
    // 只隐藏光标、没有定位+显示+再隐藏的，不算行重写
    try testing.expectEqualStrings("\x1b[25lxyz", apply("\x1b[25lxyz", &out));
}

test "apply：文本里含控制字符时不补（避免误擦）" {
    const testing = std.testing;
    var out: [128]u8 = undefined;
    const in = "\x1b[25l\x1b[2;1H\x1b[?25h\x1b[25lAB\rCD";
    try testing.expectEqualStrings(in, apply(in, &out));
}
