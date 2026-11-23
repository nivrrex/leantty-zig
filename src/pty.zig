//! PTY：openpty（libutil）+ fork/exec（raw Linux 系统调用），非阻塞读。
//!
//! Zig 0.17 的 std.posix 不再提供 fork/execvpeZ/waitpid，这里直接用
//! std.os.linux 的原始封装（返回值编码 errno），错误路径逐个处理。

const std = @import("std");
const linux = std.os.linux;
const E = linux.E;

/// Linux x86_64 的 ioctl 请求号（Zig 0.17 的 std 里不再导出这两个常量）。
const TIOCSCTTY: u32 = 0x540E;
const TIOCSWINSZ: u32 = 0x5414;

pub const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

extern fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*]u8,
    termp: ?*anyopaque,
    winp: ?*Winsize,
) c_int;

pub const Pty = struct {
    master: linux.fd_t,
    child: linux.pid_t,
    closed: bool = false,
    /// 未写完的数据：master 是 O_NONBLOCK，粘贴大段文本时 PTY 缓冲会写满，
    /// 一次 write 只写进一部分。早前遇到 EAGAIN 直接 return，剩下的静默丢弃
    /// （用户实测：长粘贴被截断、结尾半个汉字）。现在挂起，等可写时再续写。
    pending: std.ArrayList(u8) = .empty,

    /// argv 为空时用 shell；cwd 非空时在子进程里先 chdir。
    /// argv 的字符串在 fork 之前拷贝到堆上（带 NUL），父子进程都可见。
    pub fn spawn(
        shell: []const u8,
        argv_in: []const []const u8,
        cwd: ?[]const u8,
        cols: u16,
        rows: u16,
    ) !Pty {
        var shell_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (shell.len >= shell_buf.len) return error.ShellPathTooLong;
        @memcpy(shell_buf[0..shell.len], shell);
        shell_buf[shell.len] = 0;
        const shell_z: [*:0]const u8 = @ptrCast(&shell_buf);

        // 参数拷贝（fork 前完成；子进程 exec 后由内核回收）
        var args = std.ArrayList([:0]u8).empty;
        defer args.deinit(std.heap.page_allocator);
        for (argv_in) |a| {
            const z = try std.heap.page_allocator.allocSentinel(u8, a.len, 0);
            @memcpy(z[0..a.len], a);
            try args.append(std.heap.page_allocator, z);
        }

        var master: c_int = -1;
        var slave: c_int = -1;
        var ws: Winsize = .{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
        if (openpty(&master, &slave, null, null, &ws) != 0) return error.OpenPtyFailed;
        const m: linux.fd_t = master;
        const s: linux.fd_t = slave;

        const rc = linux.fork();
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            else => return error.ForkFailed,
        }
        const pid: linux.pid_t = @intCast(rc);
        if (pid == 0) {
            _ = linux.setsid();
            _ = linux.ioctl(s, TIOCSCTTY, 0);
            _ = linux.dup2(s, 0);
            _ = linux.dup2(s, 1);
            _ = linux.dup2(s, 2);
            if (s > 2) _ = linux.close(s);
            _ = linux.close(m);
            _ = setenv("TERM", "xterm-256color", 1);
            _ = setenv("SHELL", shell_z, 1);

            if (cwd) |dir| {
                var cbuf: [std.fs.max_path_bytes]u8 = undefined;
                if (dir.len + 1 <= cbuf.len) {
                    @memcpy(cbuf[0..dir.len], dir);
                    cbuf[dir.len] = 0;
                    _ = linux.chdir(@ptrCast(&cbuf));
                }
            }

            var argv_buf: [64]?[*:0]const u8 = undefined;
            var argc: usize = 0;
            for (args.items) |a| {
                if (argc + 1 >= argv_buf.len) break;
                argv_buf[argc] = a.ptr;
                argc += 1;
            }
            // -e/--command 给的是完整 argv：argv[0] 就是要 exec 的程序。
            // 之前一律 execve(shell, argv) 会把 argv[0] 当成 shell 的名字，
            // 于是 `-e python3 -c 'x'` 实际在跑 bash（bash 把 -c 当成自己的参数）。
            var exec_z: [*:0]const u8 = shell_z;
            if (argc == 0) {
                argv_buf[0] = shell_z;
                argc = 1;
            } else {
                exec_z = args.items[0].ptr;
            }
            argv_buf[argc] = null;

            const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
            const argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(&argv_buf);
            _ = linux.execve(exec_z, argv_z, envp);
            linux.exit(127);
        }

        // 父进程：释放从端，主端改非阻塞
        _ = linux.close(s);
        const fl = linux.fcntl(m, linux.F.GETFL, 0);
        switch (linux.errno(fl)) {
            .SUCCESS => {},
            else => return error.FcntlFailed,
        }
        const set = linux.fcntl(m, linux.F.SETFL, @as(usize, @intCast(fl)) | 0o4000);
        switch (linux.errno(set)) {
            .SUCCESS => {},
            else => return error.FcntlFailed,
        }
        return .{ .master = m, .child = pid };
    }

    /// 非阻塞读：error.WouldBlock 表示暂无数据；返回 0 表示对端 EOF。
    pub fn read(self: *Pty, buf: []u8) !usize {
        const rc = linux.read(self.master, buf.ptr, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .AGAIN => return error.WouldBlock,
            .INTR => return error.WouldBlock,
            else => return error.ReadFailed,
        }
    }

    /// 写 PTY：先排队再尽力冲刷，写不完的留在 pending 里（由 flush() 续写）。
    /// alloc 由调用方在 init 时传入的分配器负责（见 Pty.alloc）。
    pub fn write(self: *Pty, alloc: std.mem.Allocator, bytes: []const u8) void {
        if (self.pending.items.len > 0) {
            // 保持顺序：先补上旧数据；旧数据太大时直接追加到后面
            self.pending.appendSlice(alloc, bytes) catch return;
            _ = self.flush();
            return;
        }
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = linux.write(self.master, bytes[off..].ptr, bytes.len - off);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) break;
                    off += rc;
                },
                .INTR => continue,
                .AGAIN => {
                    // 缓冲满：余下的挂起，等主循环 poll 到可写时再续写
                    self.pending.appendSlice(alloc, bytes[off..]) catch return;
                    return;
                },
                else => return,
            }
        }
    }

    /// 尽力把 pending 里的数据写出去；返回 true 表示已清空。
    pub fn flush(self: *Pty) bool {
        var off: usize = 0;
        const items = self.pending.items;
        while (off < items.len) {
            const rc = linux.write(self.master, items[off..].ptr, items.len - off);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) break;
                    off += rc;
                },
                .INTR => continue,
                .AGAIN => break,
                else => break,
            }
        }
        if (off > 0) {
            const rest = items.len - off;
            std.mem.copyForwards(u8, self.pending.items[0..rest], items[off..]);
            self.pending.shrinkRetainingCapacity(rest);
        }
        return self.pending.items.len == 0;
    }

    pub fn hasPending(self: *const Pty) bool {
        return self.pending.items.len > 0;
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) void {
        var ws: Winsize = .{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = linux.ioctl(self.master, TIOCSWINSZ, @intFromPtr(&ws));
    }

    /// 子进程已退出则返回状态码。
    pub fn tryWait(self: *Pty) ?u32 {
        var status: i32 = 0;
        const rc = linux.waitpid(self.child, &status, linux.W.NOHANG);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            else => return null,
        }
        if (rc == 0) return null;
        return @bitCast(status);
    }

    /// close 契约：先释放主端，再回收子进程；两次调用幂等。
    pub fn close(self: *Pty) void {
        if (self.closed) return;
        self.closed = true;
        _ = linux.close(self.master);
        _ = linux.kill(self.child, .HUP);
        var status: i32 = 0;
        _ = linux.waitpid(self.child, &status, 0);
    }
};
