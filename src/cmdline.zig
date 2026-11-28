//! Windows 子进程命令行拼装（纯函数，便于在 Linux 上单测）。
//!
//! 历史 bug：`-e` 分支给每个参数追加一个空格，之后统一 `cmd_buf[cmd_len - 1] = 0`
//! 去尾随空格；但**默认命令**（`cmd.exe /K chcp 65001>nul`）本身没有尾随空格，
//! 这行就把最后的 `l` 覆盖成了 NUL —— 命令变成 `chcp 65001>nu`，
//! cmd 于是把 chcp 的输出重定向到当前目录下一个名为 `nu` 的文件（内容 `Active code page: 65001`）。

/// 把 `parts` 用空格拼进 `buf`（不带尾随空格）；`parts` 为空时用 `default`。
/// 返回写入的字节（已去尾随空格），不写 NUL —— 调用方自己按需终止。
pub fn joinParts(buf: []u8, parts: []const []const u8, default: []const u8) []const u8 {
    var n: usize = 0;
    if (parts.len == 0) {
        if (default.len > buf.len) return buf[0..0];
        @memcpy(buf[0..default.len], default);
        return buf[0..default.len];
    }
    for (parts) |part| {
        if (part.len == 0) continue;
        if (n + part.len + 1 > buf.len) break; // 与旧行为一致：超长就截断在参数边界
        @memcpy(buf[n..][0..part.len], part);
        n += part.len;
        buf[n] = ' ';
        n += 1;
    }
    // 只去掉**我们追加的**那个尾随空格
    if (n > 0 and buf[n - 1] == ' ') n -= 1;
    return buf[0..n];
}

fn needsQuote(arg: []const u8) bool {
    if (arg.len == 0) return true;
    for (arg) |c| {
        if (c == ' ' or c == '\t' or c == '"') return true;
    }
    return false;
}

fn appendQuoted(out: *std.ArrayList(u8), alloc: std.mem.Allocator, arg: []const u8) !void {
    if (!needsQuote(arg)) return out.appendSlice(alloc, arg);
    try out.append(alloc, '"');
    var i: usize = 0;
    while (i < arg.len) {
        var slashes: usize = 0;
        while (i + slashes < arg.len and arg[i + slashes] == '\\') slashes += 1;
        if (i + slashes == arg.len) {
            try out.appendNTimes(alloc, '\\', slashes * 2);
            break;
        }
        if (arg[i + slashes] == '"') {
            try out.appendNTimes(alloc, '\\', slashes * 2 + 1);
            try out.append(alloc, '"');
            i += slashes + 1;
            continue;
        }
        try out.appendNTimes(alloc, '\\', slashes);
        try out.append(alloc, arg[i + slashes]);
        i += slashes + 1;
    }
    try out.append(alloc, '"');
}

/// 按 Windows CreateProcess 命令行规则拼接 argv，保留空格、空参数与反斜杠。
/// 返回分配器所有的字节切片，调用方负责释放。
pub fn joinWindows(alloc: std.mem.Allocator, parts: []const []const u8, default: []const u8) ![]u8 {
    if (parts.len == 0) return alloc.dupe(u8, default);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (parts, 0..) |part, i| {
        if (i > 0) try out.append(alloc, ' ');
        try appendQuoted(&out, alloc, part);
    }
    return out.toOwnedSlice(alloc);
}

const std = @import("std");
const testing = std.testing;

test "默认命令不能被截掉最后一个字符" {
    var buf: [64]u8 = undefined;
    const got = joinParts(&buf, &.{}, "cmd.exe /K chcp 65001>nul");
    try testing.expectEqualStrings("cmd.exe /K chcp 65001>nul", got);
    // 回归点：以前这里会变成 "...>nu"
    try testing.expect(got[got.len - 1] == 'l');
}

test "-e 拼接：参数之间单空格，末尾不留空格" {
    var buf: [64]u8 = undefined;
    const got = joinParts(&buf, &.{ "/bin/sh", "-c", "echo hi" }, "");
    try testing.expectEqualStrings("/bin/sh -c echo hi", got);
}

test "-e 单参数：原样，不追加空格" {
    var buf: [64]u8 = undefined;
    const got = joinParts(&buf, &.{"leantty.exe"}, "");
    try testing.expectEqualStrings("leantty.exe", got);
}

test "Windows 命令行：路径和参数含空格时加引号" {
    const got = try joinWindows(testing.allocator, &.{ "C:\\Program Files\\app.exe", "hello world" }, "");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\"C:\\Program Files\\app.exe\" \"hello world\"", got);
}

test "Windows 命令行：空参数、引号与尾部反斜杠按规则转义" {
    const got = try joinWindows(testing.allocator, &.{ "app.exe", "", "a\"b", "C:\\Program Files\\dir\\" }, "");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("app.exe \"\" \"a\\\"b\" \"C:\\Program Files\\dir\\\\\"", got);
}
