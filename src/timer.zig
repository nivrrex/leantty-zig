//! 计时用单调时钟（Zig 0.17 移除了 std.time.Timer，且 TinyIo 的 now 不可用）。
//! 非 Linux 目标（交叉编译探针）不做计时，直接返回 0。

const std = @import("std");
const builtin = @import("builtin");

pub fn nowNs() u64 {
    if (builtin.os.tag != .linux) return 0;
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
