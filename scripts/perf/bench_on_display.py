#!/usr/bin/env python3
"""三方性能基准：alacritty / Rust leantty / Zig leantty。

指标：
  1. 启动：spawn → 窗口出现（xdotool search --sync --pid），中位数
  2. 吞吐：cat 20MB 文本，spawn → 进程退出（含启动），并扣除启动中位数得到纯吞吐
  3. 空闲 CPU：空闲 5s 后采样 3s 的 utime+stime 占比
  4. 内存：空闲时 VmRSS / 吞吐后 VmHWM
  5. 按键回显：xdotool 输入 200 字符，dump/屏幕出现所需时间（仅 Zig 有 dump，故用窗口截图差异，略）

所有终端使用同一份「等效配置」：等宽 13pt、120x30、同一字体族。
"""

import contextlib
import json
import os
import pathlib
import signal
import statistics
import subprocess
import time

DISPLAY = os.environ.get("PERF_DISPLAY", ":71")
RES = "1920x1200x24"
CFG_LEANT = "/tmp/perf-leantty.toml"
CFG_ALA = "/tmp/perf-alacritty.toml"
CFG_LEANT_CPU = "/tmp/perf-leantty-cpu.toml"
DATA = "/tmp/perf-data.txt"
ROUNDS = int(os.environ.get("PERF_ROUNDS", "5"))

TERMS = {
    os.environ.get("ALA_EXE", "alacritty"): {
        "exe": os.environ.get("ALA_EXE", "alacritty"),
        "args": ["--config-file", CFG_ALA],
    },
    "rust": {
        "exe": os.environ.get("RUST_EXE", "leantty"),
        "args": ["--config-file", CFG_LEANT],
    },
    "zig": {
        "exe": os.environ.get("ZIG_EXE", "zig-out/bin/leantty"),
        "args": ["--config-file", CFG_LEANT],
    },
    "zig-cpu": {
        "exe": os.environ.get("ZIG_EXE", "zig-out/bin/leantty"),
        "args": ["--config-file", CFG_LEANT_CPU],
    },
}

TOML = """[window]
dimensions = { columns = 120, lines = 30 }

[font]
size = 13.0
family = "DejaVu Sans Mono"

[scrolling]
history = 10000

[colors.primary]
background = "#101010"
foreground = "#C0C0C0"
"""

ALA_TOML = """[window]
dimensions = { columns = 120, lines = 30 }

[font]
size = 13.0
normal = { family = "DejaVu Sans Mono", style = "Regular" }

[colors.primary]
background = "#101010"
foreground = "#C0C0C0"
"""


def setup():
    with open(CFG_LEANT, "w") as f:
        f.write(TOML)
    with open(CFG_ALA, "w") as f:
        f.write(ALA_TOML)
    with open(CFG_LEANT_CPU, "w") as f:
        f.write(TOML + '\n[renderer]\nbackend = "cpu"\n')
    if not os.path.exists(DATA) or os.path.getsize(DATA) < 20 * 1024 * 1024:
        line = (
            "The quick brown fox jumps over the lazy dog 0123456789 "
            "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ\n"
        )
        with open(DATA, "w") as f:
            n = 0
            while n < 20 * 1024 * 1024:
                f.write(line)
                n += len(line)


def kill_stale_xvfb():
    lock = pathlib.Path("/tmp/.X71-lock")
    try:
        pid = int(lock.read_text().strip())
        if pathlib.Path(f"/proc/{pid}/comm").read_text().strip() == "Xvfb":
            os.kill(pid, signal.SIGTERM)
    except (OSError, ValueError):
        pass


def xvfb_start():
    if os.environ.get("PERF_DISPLAY"):
        return  # 用现成的显示（例如真机 :0 有真显卡）
    kill_stale_xvfb()
    time.sleep(0.5)
    subprocess.Popen(
        ["Xvfb", DISPLAY, "-screen", "0", RES],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    time.sleep(1.5)
    subprocess.Popen(
        ["openbox"],
        env=dict(os.environ, DISPLAY=DISPLAY),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    time.sleep(1.0)


def env():
    e = dict(os.environ, DISPLAY=DISPLAY)
    e.pop("DBUS_SESSION_BUS_ADDRESS", None)
    return e


def spawn(name, child_cmd):
    spec = TERMS[name]
    cmd = [spec["exe"]] + spec["args"] + ["-e"] + child_cmd
    return subprocess.Popen(
        cmd,
        env=env(),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def wait_window(pid, timeout=10.0):
    """轮询窗口出现（不用 --sync：某些终端窗口的 _NET_WM_PID 与进程 pid 不一致会卡死）。"""
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < timeout:
        try:
            r = subprocess.run(
                ["xdotool", "search", "--pid", str(pid)],
                env=env(),
                capture_output=True,
                text=True,
                timeout=1.5,
                check=False,
            )
            if r.stdout.strip():
                return (time.perf_counter() - t0) * 1000
        except subprocess.TimeoutExpired:
            pass
        time.sleep(0.02)
    return None


def proc_stat(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            parts = f.read().split()
        return int(parts[13]) + int(parts[14])  # utime + stime (ticks)
    except OSError:
        return None


def rss_kb(pid, key="VmRSS"):
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith(key + ":"):
                    return int(line.split()[1])
    except OSError:
        pass
    return None


def measure_startup(name):
    out = []
    for _ in range(ROUNDS):
        p = spawn(name, ["/bin/sh", "-c", "sleep 5"])
        dt = wait_window(p.pid)
        if dt:
            out.append(dt)
            with contextlib.suppress(OSError, subprocess.SubprocessError, IndexError):
                subprocess.run(
                    [
                        "xdotool",
                        "windowactivate",
                        "--sync",
                        subprocess.run(
                            ["xdotool", "search", "--pid", str(p.pid)],
                            env=env(),
                            capture_output=True,
                            text=True,
                            check=False,
                        ).stdout.split()[-1],
                    ],
                    env=env(),
                    timeout=3,
                    check=False,
                )
        p.kill()
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        time.sleep(0.4)
    return out


def measure_throughput(name):
    out = []
    global DATA
    if os.environ.get("PERF_DISPLAY") and os.path.exists("/tmp/perf-data-small.txt"):
        DATA = "/tmp/perf-data-small.txt"
    for _ in range(ROUNDS):
        t0 = time.perf_counter()
        p = spawn(name, ["/bin/cat", DATA])
        with contextlib.suppress(OSError, subprocess.SubprocessError, IndexError):
            w = wait_window(p.pid, timeout=5)
            if w is not None:
                wid = subprocess.run(
                    ["xdotool", "search", "--pid", str(p.pid)],
                    env=env(),
                    capture_output=True,
                    text=True,
                    check=False,
                ).stdout.split()
                if wid:
                    subprocess.run(
                        ["xdotool", "windowactivate", "--sync", wid[-1]],
                        env=env(),
                        timeout=3,
                        capture_output=True,
                        check=False,
                    )
        try:
            p.wait(timeout=120)
        except subprocess.TimeoutExpired:
            p.kill()
        out.append((time.perf_counter() - t0) * 1000)
        time.sleep(0.4)
    return out


def measure_idle(name):
    cpu, rss = [], []
    for _ in range(max(2, ROUNDS // 2)):
        p = spawn(name, ["/bin/sh", "-c", "sleep 12"])
        if wait_window(p.pid) is None:
            p.kill()
            continue
        time.sleep(4)
        s0 = proc_stat(p.pid)
        time.sleep(3)
        s1 = proc_stat(p.pid)
        if s0 is not None and s1 is not None:
            cpu.append((s1 - s0) / (3.0 * os.sysconf("SC_CLK_TCK")) * 100)
        rss.append(rss_kb(p.pid))
        p.kill()
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        time.sleep(0.4)
    return cpu, rss


def main():
    setup()
    xvfb_start()
    results = {}
    for name in TERMS:
        print(f"== {name} ==", flush=True)
        st = measure_startup(name)
        th = measure_throughput(name)
        cpu, rss = measure_idle(name)
        results[name] = {
            "startup_ms": st,
            "throughput_ms": th,
            "idle_cpu_pct": cpu,
            "rss_kb": rss,
        }
        print(
            f"   启动 {statistics.median(st):.0f} ms   吞吐 {statistics.median(th):.0f} ms"
            f"   空闲CPU {statistics.median(cpu) if cpu else -1:.1f}%"
            f"   RSS {statistics.median(rss) if rss else -1:.0f} KB",
            flush=True,
        )

    print("\n=== 汇总（中位数）===")
    hdr = f"{'终端':12s} {'启动':>8s} {'吞吐(20MB)':>12s} {'净吞吐':>9s} {'空闲CPU':>8s} {'RSS':>9s} {'MB/s':>8s}"
    print(hdr)
    base = {}
    for name, r in results.items():
        st = statistics.median(r["startup_ms"])
        th = statistics.median(r["throughput_ms"])
        net = th - st
        cpu = (
            statistics.median(r["idle_cpu_pct"]) if r["idle_cpu_pct"] else float("nan")
        )
        rss = statistics.median(r["rss_kb"]) if r["rss_kb"] else float("nan")
        mbs = 20 / (net / 1000) if net > 0 else float("nan")
        base[name] = (st, net, mbs)
        print(
            f"{name:12s} {st:7.0f}ms {th:11.0f}ms {net:8.0f}ms {cpu:7.1f}% {rss:8.0f}KB {mbs:7.1f}"
        )
    with open("/tmp/perf-results.json", "w") as f:
        json.dump(results, f, indent=2)
    print("\n原始数据：/tmp/perf-results.json")


if __name__ == "__main__":
    main()
