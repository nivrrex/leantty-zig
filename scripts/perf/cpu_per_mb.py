import os
import statistics
import subprocess
import time

DISPLAY = ":71"
DATA = "/tmp/perf-data.txt"
CFG_L = "/tmp/perf-leantty.toml"
CFG_A = "/tmp/perf-alacritty.toml"
TERMS = {
    os.environ.get("ALA_EXE", "alacritty"): (
        [os.environ.get("ALA_EXE", "alacritty"), "--config-file", CFG_A]
    ),
    "rust": ([os.environ.get("RUST_EXE", "leantty"), "--config-file", CFG_L]),
    "zig": ([os.environ.get("ZIG_EXE", "zig-out/bin/leantty"), "--config-file", CFG_L]),
}
env = dict(os.environ, DISPLAY=DISPLAY)
env.pop("DBUS_SESSION_BUS_ADDRESS", None)
res = {}
for name, cmd in TERMS.items():
    cpus = []
    for _ in range(3):
        p = subprocess.Popen(
            cmd + ["-e", "/bin/cat", DATA],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        pid, status, ru = os.wait4(p.pid, 0)
        cpus.append(ru.ru_utime + ru.ru_stime)
        time.sleep(0.3)
    mb = os.path.getsize(DATA) / 1024 / 1024
    med = statistics.median(cpus)
    res[name] = (med, med / mb)
    print(f"{name:10s} CPU {med:.2f}s  每 MB {med / mb * 1000:.1f} ms")
