//! 自适应帧间隔：帧间隔 = clamp(K × EMA(渲染耗时), MIN, MAX)。
//! 参数与 Rust v0.2.3 的 `framepace.rs` 对齐（K=3、EMA α=0.3、8–100ms）。

const std = @import("std");

pub const ema_alpha: f64 = 0.3;
pub const k: f64 = 3.0;
pub const min_ms: f64 = 8.0;
pub const max_ms: f64 = 100.0;

/// 纯函数：由渲染耗时 EMA 计算目标帧间隔（毫秒）。
pub fn targetIntervalMs(ema_ms: ?f64) f64 {
    const e = ema_ms orelse return min_ms;
    if (!std.math.isFinite(e) or e <= 0) return min_ms;
    return @min(@max(k * e, min_ms), max_ms);
}

/// 纯函数：更新 EMA（首次样本作为初值）。
pub fn nextEma(prev: ?f64, sample_ms: f64) f64 {
    const p = prev orelse return sample_ms;
    return ema_alpha * sample_ms + (1.0 - ema_alpha) * p;
}

pub const Pacer = struct {
    ema_ms: ?f64 = null,
    last_frame_ms: i64 = 0,
    /// 强制下一帧（resize/expose/首次绘制）。
    force: bool = true,

    pub fn intervalMs(self: *const Pacer) f64 {
        return targetIntervalMs(self.ema_ms);
    }

    /// 是否该画这一帧。
    pub fn due(self: *const Pacer, now_ms: i64) bool {
        if (self.force) return true;
        return @as(f64, @floatFromInt(now_ms - self.last_frame_ms)) >= self.intervalMs();
    }

    /// 记录一帧：render_ms 为本帧渲染耗时（毫秒）。
    pub fn record(self: *Pacer, now_ms: i64, render_ms: f64) void {
        self.ema_ms = nextEma(self.ema_ms, render_ms);
        self.last_frame_ms = now_ms;
        self.force = false;
    }
};
