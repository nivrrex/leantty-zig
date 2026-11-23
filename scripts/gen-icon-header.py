#!/usr/bin/env python3
"""从 assets/icon/png/leantty-*.png 生成 src/icon_rgba.h（_NET_WM_ICON 用的 ARGB 数组）。

用法：python3 scripts/gen-icon-header.py
改了图标资源后重跑一次并提交生成结果（构建过程不依赖 Python/PIL）。
"""
from PIL import Image
import pathlib

SIZES = [16, 32, 64]
root = pathlib.Path(__file__).resolve().parent.parent
parts = []
for s in SIZES:
    im = Image.open(root / f"assets/icon/png/leantty-{s}.png").convert("RGBA")
    px = im.load()
    parts.append((s, [(px[x, y][3] << 24) | (px[x, y][0] << 16) | (px[x, y][1] << 8) | px[x, y][2]
                      for y in range(s) for x in range(s)]))

total = sum(len(v) for _, v in parts) + 2 * len(parts)
out = [
    "/* 自动生成：_NET_WM_ICON 数据（ARGB，多尺寸串接）。",
    " * 源：assets/icon/png/leantty-{16,32,64}.png；重新生成见 scripts/gen-icon-header.py。 */",
    "#ifndef LEANTTY_ICON_RGBA_H",
    "#define LEANTTY_ICON_RGBA_H",
    "#include <stdint.h>",
    f"#define TTY_ICON_CARDINALS {total}",
    "static const uint32_t tty_icon_data[] = {",
]
for s, vals in parts:
    out.append(f"    /* {s}x{s} */")
    out.append(f"    {s}, {s},")
    line = []
    for v in vals:
        line.append(f"0x{v:08x}")
        if len(line) == 8:
            out.append("    " + ", ".join(line) + ",")
            line = []
    if line:
        out.append("    " + ", ".join(line) + ",")
out += ["};", "#endif"]
(root / "src/icon_rgba.h").write_text("\n".join(out) + "\n")
print("wrote src/icon_rgba.h")
