#!/usr/bin/env python3
"""比对两份配色导出（row col fg bg）：
   - 以「每行第一个格子」为代表给出 48 个样本的颜色表（便于人看）
   - 逐格 diff，报告缺失行/颜色不同的格子
用法：python3 scripts/e2e/win/compare_colors.py tests/golden/colors-linux.txt zig-colors.txt
"""

import sys
from collections import defaultdict


def load(path):
    rows = defaultdict(list)
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            p = line.split()
            if len(p) < 4:
                continue
            try:
                r, c, fg, bg = int(p[0]), int(p[1]), int(p[2], 16), int(p[3], 16)
            except ValueError:
                continue
            rows[r].append((c, fg, bg))
    for r in rows:
        rows[r].sort()
    return rows


a, b = load(sys.argv[1]), load(sys.argv[2])
# 样本文件的行序：0-7 fg30-37，8-15 fg90-97，16-23 bg40-47，24-31 bg100-107，
# 32-39 256 色，40-43 truecolor，44 bold+red，45 bold+默认前景，46 dim，47 reverse
CASES = (
    [(i, f"fg{30 + i}") for i in range(8)]
    + [(8 + i, f"fg{90 + i}") for i in range(8)]
    + [(16 + i, f"bg{40 + i}") for i in range(8)]
    + [(24 + i, f"bg{100 + i}") for i in range(8)]
    + [
        (32 + i, f"c256:{c}")
        for i, c in enumerate((16, 21, 196, 226, 46, 201, 244, 255))
    ]
    + [
        (40 + i, f"rgb{r},{g},{b}")
        for i, (r, g, b) in enumerate(
            ((255, 0, 0), (0, 255, 0), (0, 0, 255), (18, 52, 86))
        )
    ]
    + [(44, "bold+red"), (45, "bold+default"), (46, "dim+red"), (47, "reverse")]
)
diff = 0
print(f"{'样本':14s} {'Linux(golden)':22s} {'Windows':22s} 结果")
for row, lab in CASES:
    la = a.get(row, [])
    lb = b.get(row, [])
    ca = la[0] if la else None
    cb = lb[0] if lb else None
    fa = f"#{ca[1]:06X}/#{ca[2]:06X}" if ca else "(缺)"
    fb = f"#{cb[1]:06X}/#{cb[2]:06X}" if cb else "(缺)"
    ok = ca is not None and cb is not None and ca[1:] == cb[1:]
    if not ok:
        diff += 1
    print(f"{lab:14s} {fa:22s} {fb:22s} {'一致' if ok else '不同'}")

# 逐格
cells_a = sum(len(v) for v in a.values())
cells_b = sum(len(v) for v in b.values())
mismatch = 0
for r in sorted(set(a) | set(b)):
    da = {c: (fg, bg) for c, fg, bg in a.get(r, [])}
    db = {c: (fg, bg) for c, fg, bg in b.get(r, [])}
    for c in sorted(set(da) | set(db)):
        if da.get(c) != db.get(c):
            mismatch += 1
            if mismatch <= 10:
                print(
                    f"  格差异 row={r} col={c}: linux={da.get(c)} windows={db.get(c)}"
                )
print(
    f"\n样本行差异 {diff}/{len(CASES)}；格子差异 {mismatch} 处（linux {cells_a} 格 / windows {cells_b} 格）"
)
sys.exit(0 if diff == 0 and mismatch == 0 else 1)
