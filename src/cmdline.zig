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
