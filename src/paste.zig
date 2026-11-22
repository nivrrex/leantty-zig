//! 粘贴载荷归一（平台无关，便于单测）。
//!
//! 输入是剪贴板原文（原地压缩，写指针永不超过读指针），输出是准备写进 PTY 的字节数。
//!
//! 规则：
//!   - 丢掉 NUL（Windows 剪贴板里偶见）；
//!   - `CRLF` / 单独 `CR` / 单独 `LF` 统一成 `CR`（终端里的 Enter 就是 CR）；
//!   - `bracketed` 为真时，再把 `CR` 换成 `LF`。
//!
//! 最后一条是 Windows 侧的变通：ConPTY（inbox conhost）在输入侧会丢掉
//! `ESC[200~` / `ESC[201~`，并且会把每个 `CR` 变成两个 `CR`（实测：客户端写
//! 187 字节含标记，子进程 stdin 只收到正文 + 双 CR）。于是"对端要求 bracketed
//! paste"时改用 LF 分隔——子进程收到的是换行而不是回车，不会把每行当提交。
//! 没要求 bracketed 的对端（cmd / powershell 等）保持 CR，行为不变。

pub fn normalize(raw: []u8, bracketed: bool) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const b = raw[i];
        if (b == 0) continue;
        if (b == '\r') {
            if (i + 1 < raw.len and raw[i + 1] == '\n') i += 1;
            raw[len] = if (bracketed) '\n' else '\r';
            len += 1;
        } else if (b == '\n') {
            raw[len] = if (bracketed) '\n' else '\r';
            len += 1;
        } else {
            raw[len] = b;
            len += 1;
        }
    }
    return len;
}
