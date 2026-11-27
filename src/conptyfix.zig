//! ConPTY 行重写补丁：修"Tab 补全后上一轮长名字的尾巴留在屏幕上"。
//!
//! 现象与根因（用 `LEANTTY_OUT_DUMP` 抓到的两份真实字节复现，1317 / 11146 字节）：
//! cmd 的补全由 cmd 自己重画输入行，ConPTY 把这段重画转成 VT 发给宿主，实测有两种惯用式：
//!
//! A（带光标显隐）：
//! ```text
//! ESC[25l ESC[2;<n>H ESC[?25h ESC[25l <文本> [空格...] ESC[2;<m>H ESC[?25h
//! ```
//! B（存/恢复光标 + 空格擦除）：
//! ```text
//! ESC[2;<n>H ESC7 ESC[2;<n>H ESC[0m <空格...> ESC8 <文本>
//! ```
//!
//! 两种都**擦不干净**：擦除用的格数比需要的少（实测差 5 格；像是把"格差"又按宽字符
//! 2 格折算了一次）。终端按字节流渲染是对的——把抓包在 Linux 上 `-e /bin/cat` 重放，
//! 同一份字节就能复现残留。
//!
//! 补丁：识别这两种惯用式，在**文本之后**补一个 `ESC[K`（擦到行尾）。光标此刻正好在
//! 新文本末尾，擦到行尾正是 cmd 的本意；新结果更长时无可擦，无副作用。
//!
//! 实现是**有状态**的：ConPTY 的输出按块到达（每次 read 16 KiB），惯用式与文本都可能
//! 被切在块边界上，所以头部与文本各自可以跨块累积（见 `Fixer`）。

const std = @import("std");

const HIDE = "\x1b[25l";
const SHOW = "\x1b[?25h";
/// 挂起文本的上限：超过就直接发出（宁可少擦一次，也不无限吃内存）。
const MAX_PENDING = 4096;

pub const Fixer = struct {
    /// 是否纠正 ConPTY 给的"输入行光标列"（`LEANTTY_CONPTY_CURSOR_FIX=1` 开启）。
    /// 见下面 `textMetrics()` 的说明：ConPTY 在某些路径里按**字符数**算光标列，
    /// 含中文时每行差"宽字符个数"格，表现为"删几个字后光标和文字之间出现空隙"。
    cursor_fix: bool = false,
    state: enum { idle, hdr, text } = .idle,
    /// 正在累积的候选头部（idle 时遇到 ESC 开始攒，攒够/攒废即判定）。
    scan: [96]u8 = undefined,
    scan_len: usize = 0,
    /// 已确认的头部（A 或 B），等文本到齐后与文本一起发出。
    hdr: [96]u8 = undefined,
    hdr_len: usize = 0,
    /// 惯用式后面的文本（行重写的新内容）。
    pend: [MAX_PENDING]u8 = undefined,
    pend_len: usize = 0,
    /// 文本开始前，先攒几个字节判断是不是可选的尾部 `ESC[25l`（可能跨块）。
    hold: [HIDE.len]u8 = undefined,
    hold_len: usize = 0,
    /// 行首列（惯用式里的 CUP 列号），用于纠正 ConPTY 的光标列。
    start_col: usize = 0,
    /// 刚发完一次行重写：接下来若出现 `ESC[2;<m>H`，按"真实格数"纠正 m。
    await_cursor: bool = false,
    /// 该次重写文本的（格数, 字符数）。
    text_cells: usize = 0,
    text_chars: usize = 0,

    /// 喂一块数据，返回要立刻交给终端解析的字节（写进 `out`）。
    pub fn feed(self: *Fixer, in: []const u8, out: []u8) []const u8 {
        var o: usize = 0;
        var i: usize = 0;
        while (i < in.len) {
            const b = in[i];
            switch (self.state) {
                .idle => {
                    if (b == 0x1b) {
                        self.scan[0] = b;
                        self.scan_len = 1;
                        self.state = .hdr;
                        i += 1;
                        continue;
                    }
                    if (o >= out.len) break;
                    out[o] = b;
                    o += 1;
                    i += 1;
                },
                .hdr => {
                    if (self.scan_len < self.scan.len) {
                        self.scan[self.scan_len] = b;
                        self.scan_len += 1;
                    }
                    const cand = self.scan[0..self.scan_len];
                    if (self.cursor_fix and self.await_cursor) {
                        if (cupColumn(cand)) |col| {
                            const want = self.start_col + self.text_cells;
                            const naive = self.start_col + self.text_chars;
                            const use = if (col == naive and self.text_cells > self.text_chars) want else col;
                            const txt = std.fmt.bufPrint(out[o..], "\x1b[2;{d}H", .{use}) catch "";
                            o += txt.len;
                            self.await_cursor = false;
                            self.scan_len = 0;
                            self.state = .idle;
                            i += 1;
                            continue;
                        }
                    }
                    if (matchA(cand) orelse matchB(cand)) |hdr_len| {
                        @memcpy(self.hdr[0..hdr_len], cand[0..hdr_len]);
                        self.hdr_len = hdr_len;
                        self.start_col = headerCol(cand[0..hdr_len]);
                        self.pend_len = 0;
                        self.scan_len = 0;
                        self.state = .text;
                        i += 1;
                        continue;
                    }
                    if (!isHeaderPrefix(cand)) {
                        // 不是惯用式：把这几个字节原样发出
                        if (o + cand.len <= out.len) {
                            @memcpy(out[o..][0..cand.len], cand);
                            o += cand.len;
                        }
                        self.scan_len = 0;
                        self.state = .idle;
                        self.await_cursor = false;
                    }
                    i += 1;
                },
                .text => {
                    // 头部匹配时末尾的 `ESC[25l` 可能还没到（它是可选的）：
                    // 文本尚未开始、接下来正好是它 → 并进头部，继续等文本。
                    // 逐字节喂时它也会被切开，所以用 hold 攒够再判断。
                    if (self.pend_len == 0) {
                        if (self.hold_len < HIDE.len and
                            std.mem.startsWith(u8, HIDE[self.hold_len..], in[i .. i + 1]))
                        {
                            self.hold[self.hold_len] = b;
                            self.hold_len += 1;
                            i += 1;
                            if (self.hold_len == HIDE.len) {
                                @memcpy(self.hdr[self.hdr_len..][0..HIDE.len], self.hold[0..HIDE.len]);
                                self.hdr_len += HIDE.len;
                                self.hold_len = 0;
                            }
                            continue;
                        }
                        if (self.hold_len > 0) {
                            @memcpy(self.pend[self.pend_len..][0..self.hold_len], self.hold[0..self.hold_len]);
                            self.pend_len += self.hold_len;
                            self.hold_len = 0;
                            continue;
                        }
                    }
                    const is_text = b != 0x1b and b >= 0x20;
                    if (is_text) {
                        self.pend[self.pend_len] = b;
                        self.pend_len += 1;
                        i += 1;
                        if (self.pend_len >= self.pend.len) {
                            o = self.emitPending(out, o, false);
                        }
                        continue;
                    }
                    // 文本结束：只有下一个是 ESC（序列边界）时才补擦除
                    self.textMetrics();
                    o = self.emitPending(out, o, b == 0x1b);
                    self.state = .idle;
                    // 当前字节回到 idle 重新处理
                },
            }
        }
        return out[0..o];
    }

    /// 统计刚画出的文本有多少**格**与多少**字符**（宽字符按 2 格）。
    fn textMetrics(self: *Fixer) void {
        var chars: usize = 0;
        var cells: usize = 0;
        var i: usize = 0;
        const t = self.pend[0..self.pend_len];
        while (i < t.len) {
            const len = std.unicode.utf8ByteSequenceLength(t[i]) catch 1;
            const cp: u21 = if (i + len <= t.len)
                std.unicode.utf8Decode(t[i..][0..len]) catch 0
            else
                0;
            chars += 1;
            // 粗判：CJK/Hangul/emoji 都在 >= U+1100 的区域，按 2 格；ASCII 与拉丁扩展按 1 格。
            cells += if (cp >= 0x1100) 2 else 1;
            i += if (len == 0) 1 else len;
        }
        self.text_chars = chars;
        self.text_cells = cells;
        self.await_cursor = true;
    }

    fn emitPending(self: *Fixer, out: []u8, o_in: usize, add_erase: bool) usize {
        var o = o_in;
        if (self.hold_len > 0) {
            if (o + self.hold_len <= out.len) {
                @memcpy(out[o..][0..self.hold_len], self.hold[0..self.hold_len]);
                o += self.hold_len;
            }
            self.hold_len = 0;
        }
        if (o + self.hdr_len <= out.len) {
            @memcpy(out[o..][0..self.hdr_len], self.hdr[0..self.hdr_len]);
            o += self.hdr_len;
        }
        if (o + self.pend_len <= out.len) {
            @memcpy(out[o..][0..self.pend_len], self.pend[0..self.pend_len]);
            o += self.pend_len;
        }
        if (add_erase and self.pend_len > 0 and o + 3 <= out.len) {
            @memcpy(out[o..][0..3], "\x1b[K");
            o += 3;
        }
        self.hdr_len = 0;
        self.pend_len = 0;
        self.scan_len = 0;
        return o;
    }

    /// 进程结束时把还挂着的字节发出去（不补 ESC[K]）。
    pub fn flush(self: *Fixer, out: []u8) []const u8 {
        var o: usize = 0;
        if (self.state == .text) o = self.emitPending(out, o, false) else if (self.scan_len > 0) {
            // 半截头部：原样吐出，别丢字节
            if (self.scan_len <= out.len) {
                @memcpy(out[0..self.scan_len], self.scan[0..self.scan_len]);
                o = self.scan_len;
            }
            self.scan_len = 0;
        }
        self.state = .idle;
        return out[0..o];
    }
};

/// `s` 是否是惯用式 A/B 头部的前缀（用于跨块攒头部）。
fn isHeaderPrefix(s: []const u8) bool {
    // 还在 HIDE 内部：算前缀
    if (std.mem.startsWith(u8, HIDE, s)) return true;
    // 短输入还要考虑"直接以 CUP 开头"（惯用式 B）：此时 s 已经和 HIDE 分岔了
    if (s.len <= HIDE.len) return cupPrefix(s);
    if (std.mem.startsWith(u8, s, HIDE)) return isCupPrefixOrAfter(s[HIDE.len..]);
    return isCupPrefixOrAfter(s);
}

fn isCupPrefixOrAfter(s: []const u8) bool {
    // CUP(2;n) 前缀（攒到一半）
    if (cupPrefix(s)) return true;
    const n1 = cup(s) orelse return false;
    if (n1 == 0) return false;
    const rest = s[n1..];
    // 惯用式 B：CUP 之后是 `ESC7` …
    if (std.mem.startsWith(u8, rest, "\x1b7") or std.mem.startsWith(u8, "\x1b7", rest)) {
        if (rest.len <= 2) return true;
        const r3 = rest[2..];
        if (cupPrefix(r3)) return true;
        const n2 = cup(r3) orelse return false;
        if (n2 == 0) return false;
        return isBAfterSgr(r3[n2..]);
    }
    // 惯用式 A：CUP 之后是 `ESC[?25h` …
    if (std.mem.startsWith(u8, rest, SHOW) or std.mem.startsWith(u8, SHOW, rest)) {
        if (rest.len <= SHOW.len) return true;
        const r2 = rest[SHOW.len..];
        return r2.len <= HIDE.len and std.mem.startsWith(u8, HIDE, r2);
    }
    return false;
}

/// 惯用式 B 里 `ESC[0m` 之后的部分：空格串 + `ESC8`（可只到一半）。
fn isBAfterSgr(s: []const u8) bool {
    const sgr = "\x1b[0m";
    if (s.len <= sgr.len) return std.mem.startsWith(u8, sgr, s);
    if (!std.mem.startsWith(u8, s, sgr)) return false;
    var i: usize = sgr.len;
    while (i < s.len and s[i] == ' ') i += 1;
    const rest = s[i..];
    if (rest.len <= 2) return std.mem.startsWith(u8, "\x1b8", rest);
    return false;
}

fn cupPrefix(s: []const u8) bool {
    const pat = "\x1b[2;";
    if (s.len <= pat.len) return std.mem.startsWith(u8, pat, s);
    if (!std.mem.startsWith(u8, s, pat)) return false;
    var i: usize = pat.len;
    const digits_start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i >= s.len) return i > digits_start;
    if (s[i] != 'H') return false;
    return i + 1 == s.len;
}

/// 惯用式 A：`ESC[25l ESC[2;<n>H ESC[?25h [ESC[25l]`，返回头部长度。
fn matchA(s: []const u8) ?usize {
    if (!std.mem.startsWith(u8, s, HIDE)) return null;
    var i: usize = HIDE.len;
    const n = cup(s[i..]) orelse return null;
    if (n == 0) return null; // 必须是第 2 行
    i += n;
    if (!std.mem.startsWith(u8, s[i..], SHOW)) return null;
    i += SHOW.len;
    if (std.mem.startsWith(u8, s[i..], HIDE)) i += HIDE.len; // 末尾可省略
    return i;
}

/// 惯用式 B：`ESC[2;<n>H ESC7 ESC[2;<n>H ESC[0m <空格...> ESC8`，返回头部长度（含 ESC8）。
fn matchB(s: []const u8) ?usize {
    const n1 = cup(s) orelse return null;
    if (n1 == 0) return null;
    var i = n1;
    if (!std.mem.startsWith(u8, s[i..], "\x1b7")) return null;
    i += 2;
    const n2 = cup(s[i..]) orelse return null;
    if (n2 == 0) return null;
    i += n2;
    if (!std.mem.startsWith(u8, s[i..], "\x1b[0m")) return null;
    i += 4;
    while (i < s.len and s[i] == ' ') i += 1; // 擦除用的空格
    if (!std.mem.startsWith(u8, s[i..], "\x1b8")) return null;
    return i + 2;
}

/// 匹配 `ESC[2;<n>H`：返回长度；0 表示"是 CUP 但不是第 2 行"（ConPTY 重画输入行的固定行号）。
fn cup(s: []const u8) ?usize {
    if (!std.mem.startsWith(u8, s, "\x1b[")) return null;
    var i: usize = 2;
    const row_start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i == row_start) return null;
    const row = s[row_start..i];
    if (i >= s.len or s[i] != ';') return null;
    i += 1;
    const col_start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i == col_start) return null;
    if (i >= s.len or s[i] != 'H') return null;
    i += 1;
    if (!std.mem.eql(u8, row, "2")) return 0;
    return i;
}

// ---------------------------------------------------------------------------
// 单测
// ---------------------------------------------------------------------------

fn applyAll(stream: []const u8, out: []u8) []const u8 {
    var f: Fixer = .{};
    const a = f.feed(stream, out);
    const b = f.flush(out[a.len..]);
    return out[0 .. a.len + b.len];
}

/// 逐字节喂（最坏的块边界），结果必须和整块喂一致。
fn applyBytewise(stream: []const u8, out: []u8) []const u8 {
    var f: Fixer = .{};
    var tmp: [512]u8 = undefined;
    var total: usize = 0;
    var i: usize = 0;
    while (i < stream.len) : (i += 1) {
        const part = f.feed(stream[i .. i + 1], tmp[0..]);
        @memcpy(out[total..][0..part.len], part);
        total += part.len;
    }
    const tail = f.flush(tmp[0..]);
    @memcpy(out[total..][0..tail.len], tail);
    total += tail.len;
    return out[0..total];
}

test "惯用式 A：文本后补 ESC[K" {
    const testing = std.testing;
    var out: [256]u8 = undefined;
    const in = "\x1b[25l\x1b[2;24H\x1b[?25h\x1b[25lABC     \x1b[2;27H\x1b[?25h";
    try testing.expectEqualStrings(
        "\x1b[25l\x1b[2;24H\x1b[?25h\x1b[25lABC     \x1b[K\x1b[2;27H\x1b[?25h",
        applyAll(in, &out),
    );
}

test "惯用式 B：空格擦除 + 存/恢复光标，文本后补 ESC[K" {
    const testing = std.testing;
    var in_buf: [128]u8 = undefined;
    var want_buf: [128]u8 = undefined;
    const head = "\x1b[2;21H\x1b7\x1b[2;21H\x1b[0m";
    const mid = "\x1b8C:\\path\\x.png";
    const tail = "\x1b[2;21H";
    var n: usize = 0;
    @memcpy(in_buf[n..][0..head.len], head);
    n += head.len;
    @memset(in_buf[n..][0..37], ' ');
    n += 37;
    @memcpy(in_buf[n..][0..mid.len], mid);
    n += mid.len;
    @memcpy(in_buf[n..][0..tail.len], tail);
    n += tail.len;

    var m: usize = 0;
    @memcpy(want_buf[m..][0..head.len], head);
    m += head.len;
    @memset(want_buf[m..][0..37], ' ');
    m += 37;
    @memcpy(want_buf[m..][0..mid.len], mid);
    m += mid.len;
    @memcpy(want_buf[m..][0..3], "\x1b[K");
    m += 3;
    @memcpy(want_buf[m..][0..tail.len], tail);
    m += tail.len;

    var out: [256]u8 = undefined;
    try testing.expectEqualStrings(want_buf[0..m], applyAll(in_buf[0..n], &out));
}

test "普通文本与无关键不受影响" {
    const testing = std.testing;
    var out: [128]u8 = undefined;
    try testing.expectEqualStrings("hello", applyAll("hello", &out));
    try testing.expectEqualStrings("\x1b[25lxyz", applyAll("\x1b[25lxyz", &out));
    // 第 5 行的 CUP 不算（只针对第 2 行 = cmd 输入行）
    const other = "\x1b[5;1H\x1b7\x1b[5;1H\x1b[0m \x1b8ABC";
    try testing.expectEqualStrings(other, applyAll(other, &out));
}

test "文本里含控制字符时不补（避免误擦）" {
    const testing = std.testing;
    var out: [128]u8 = undefined;
    const in = "\x1b[25l\x1b[2;1H\x1b[?25h\x1b[25lAB\rCD";
    try testing.expectEqualStrings(in, applyAll(in, &out));
}

test "逐字节喂 == 整块喂（块边界不影响结果）" {
    const testing = std.testing;
    const stream = "\x1b[25l\x1b[2;5H\x1b[?25h\x1b[25lAB\x1b[2;7H" ++
        "\x1b[2;5H\x1b7\x1b[2;5H\x1b[0m   \x1b8CD\x1b[2;7H";
    var whole: [512]u8 = undefined;
    var bybyte: [512]u8 = undefined;
    try testing.expectEqualStrings(applyAll(stream, &whole), applyBytewise(stream, &bybyte));
}

/// 从惯用式头部里取出**第一个** `ESC[2;<col>H` 的列号（允许后面还有别的序列）。
fn headerCol(hdr: []const u8) usize {
    var i: usize = 0;
    while (i + 4 < hdr.len) : (i += 1) {
        if (!std.mem.startsWith(u8, hdr[i..], "\x1b[2;")) continue;
        var j = i + 4;
        var col: usize = 0;
        const start = j;
        while (j < hdr.len and hdr[j] >= '0' and hdr[j] <= '9') : (j += 1) {
            col = col * 10 + (hdr[j] - '0');
        }
        if (j > start and j < hdr.len and hdr[j] == 'H') return col;
    }
    return 0;
}

/// `s` 是否正好是 `ESC[2;<digits>H`；是则返回列号。
fn cupColumn(s: []const u8) ?usize {
    if (!std.mem.startsWith(u8, s, "\x1b[2;")) return null;
    var i: usize = 4;
    const start = i;
    var col: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        col = col * 10 + (s[i] - '0');
    }
    if (i == start) return null;
    if (i >= s.len or s[i] != 'H') return null;
    if (i + 1 != s.len) return null;
    return col;
}

test "cupColumn / headerCol" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, 24), cupColumn("\x1b[2;24H"));
    try testing.expectEqual(@as(?usize, null), cupColumn("\x1b[2;24Hx"));
    try testing.expectEqual(@as(?usize, null), cupColumn("\x1b[3;24H"));
    try testing.expectEqual(@as(usize, 21), headerCol("\x1b[2;21H\x1b7\x1b[2;21H\x1b[0m"));
}

test "光标列纠正：ConPTY 按字符数算列时改成按格数" {
    const testing = std.testing;
    var f: Fixer = .{ .cursor_fix = true };
    // 惯用式 B 画 "图片"（2 字符 4 格）后，ConPTY 把光标指到 21+2=23（按字符数），应为 21+4=25
    var stream_buf: [128]u8 = undefined;
    var n: usize = 0;
    const head = "\x1b[2;21H\x1b7\x1b[2;21H\x1b[0m";
    @memcpy(stream_buf[n..][0..head.len], head);
    n += head.len;
    @memset(stream_buf[n..][0..2], ' ');
    n += 2;
    const rest = "\x1b8图片\x1b[2;23H";
    @memcpy(stream_buf[n..][0..rest.len], rest);
    n += rest.len;

    var out: [256]u8 = undefined;
    const got = f.feed(stream_buf[0..n], &out);
    try testing.expect(std.mem.indexOf(u8, got, "\x1b[2;25H") != null);
}
