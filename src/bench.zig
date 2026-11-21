//! 渲染基准 + 正确性对拍：同一终端状态分别用 full / dirty 两种模式画帧，
//! 逐字节比较帧缓冲，并给出每帧耗时与脏行命中率。
//!
//! 两组负载：
//!   A 稀疏更新：每帧把光标移到第 10 行写一个字符（应只重画 1~2 行）
//!   B 滚动：每帧换行输出（视口滚动，幽灵态通常报 full）
//!
//! 用法：zig build bench；任何一帧两块帧缓冲不一致即视为失败。

const std = @import("std");
const vt = @import("vt.zig");
const render = @import("render.zig");
const timer = @import("timer.zig");

const COLS = 80;
const ROWS = 24;
const CELL_W = 8;
const CELL_H = 16;
const FRAMES = 2000;
const PX_W = COLS * CELL_W;
const PX_H = ROWS * CELL_H;

const Result = struct {
    full_us: f64,
    dirty_us: f64,
    dirty_rows: f64,
    mismatches: usize,
};

fn run(alloc: std.mem.Allocator, setup: []const u8, chunk: []const u8) !Result {
    const t_full = try vt.Wrapper.create(alloc, COLS, ROWS);
    defer t_full.destroy();
    const t_dirty = try vt.Wrapper.create(alloc, COLS, ROWS);
    defer t_dirty.destroy();

    var r_full = try render.Renderer.init(alloc, &.{}, 11);
    defer r_full.deinit();
    r_full.mode = .full;
    var r_dirty = try render.Renderer.init(alloc, &.{}, 11);
    defer r_dirty.deinit();
    r_dirty.mode = .dirty;

    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(alloc);
    try script.appendSlice(alloc, "hello\x1b[31mred\x1b[0m \xe4\xbd\xa0\xe5\xa5\xbdabc\r\n");
    var i: usize = 1;
    while (i <= 60) : (i += 1) {
        const line = try std.fmt.allocPrint(alloc, "line {d}\r\n", .{i});
        defer alloc.free(line);
        try script.appendSlice(alloc, line);
    }
    if (setup.len > 0) {
        try script.appendSlice(alloc, setup);
    }
    t_full.feed(script.items);
    t_dirty.feed(script.items);
    try t_full.update();
    try t_dirty.update();

    // 首帧两边都走全量，保证 dirty 侧底图正确
    r_full.mode = .full;
    const first_full = try r_full.render(&t_full.rs, PX_W, PX_H);
    const first_copy = try alloc.dupe(u32, first_full);
    defer alloc.free(first_copy);
    r_dirty.mode = .dirty;
    const first_dirty = try r_dirty.render(&t_dirty.rs, PX_W, PX_H);
    if (!std.mem.eql(u32, first_copy, first_dirty)) {
        std.debug.print("首帧不一致：dirty 模式底图错误\n", .{});
        std.process.exit(1);
    }

    var mismatches: usize = 0;
    var full_ns: u64 = 0;
    var dirty_ns: u64 = 0;
    var painted: usize = 0;
    var f: usize = 0;
    while (f < FRAMES) : (f += 1) {
        t_full.feed(chunk);
        t_dirty.feed(chunk);

        const a0 = timer.nowNs();
        try t_full.update();
        const fb_full = try r_full.render(&t_full.rs, PX_W, PX_H);
        const a1 = timer.nowNs();

        const b0 = timer.nowNs();
        try t_dirty.update();
        const fb_dirty = try r_dirty.render(&t_dirty.rs, PX_W, PX_H);
        const b1 = timer.nowNs();

        full_ns += a1 - a0;
        dirty_ns += b1 - b0;
        painted += r_dirty.last_painted_rows;

        if (!std.mem.eql(u32, fb_full, fb_dirty)) {
            mismatches += 1;
            if (mismatches == 1) {
                for (fb_full, fb_dirty, 0..) |a, b, idx| {
                    if (a != b) {
                        std.debug.print(
                            "首个差异 帧={d} idx={d} (x={d},y={d}) full={x} dirty={x}\n",
                            .{ f, idx, idx % PX_W, idx / PX_W, a, b },
                        );
                        break;
                    }
                }
            }
        }
    }

    return .{
        .full_us = @as(f64, @floatFromInt(full_ns)) / FRAMES / 1000.0,
        .dirty_us = @as(f64, @floatFromInt(dirty_ns)) / FRAMES / 1000.0,
        .dirty_rows = @as(f64, @floatFromInt(painted)) / FRAMES,
        .mismatches = mismatches,
    };
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const cases = [_]struct { name: []const u8, setup: []const u8, chunk: []const u8 }{
        .{ .name = "A 稀疏更新(单格)", .setup = "", .chunk = "\x1b[10;10Hx" },
        .{ .name = "B 滚动输出", .setup = "", .chunk = "x\r\n" },
        .{ .name = "C 交替屏内稀疏更新", .setup = "\x1b[?1049h", .chunk = "\x1b[5;5Hx" },
    };

    var failed = false;
    for (cases) |c| {
        const r = try run(alloc, c.setup, c.chunk);
        std.debug.print(
            "{s}: full={d:.1}us dirty={d:.1}us 加速={d:.1}x 脏行={d:.1}/{d} 帧不一致={d}\n",
            .{ c.name, r.full_us, r.dirty_us, r.full_us / r.dirty_us, r.dirty_rows, ROWS, r.mismatches },
        );
        if (r.mismatches != 0) failed = true;
    }
    if (failed) std.process.exit(1);
}
