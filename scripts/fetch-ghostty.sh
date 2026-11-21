#!/bin/sh
# 取 libghostty 源码到 build.zig.zon 期望的位置（pin 0b8b9984e，与 Rust 版一致）。
set -eu
PIN=0b8b9984e
DEST="${1:-.deps/ghostty-src}"
if [ -d "$DEST/.git" ]; then
    git -C "$DEST" fetch --all --tags >/dev/null 2>&1 || true
else
    mkdir -p "$(dirname "$DEST")"
    git clone https://github.com/ghostty-org/ghostty "$DEST"
fi
git -C "$DEST" checkout "$PIN"
echo "ghostty source ready at $DEST (pin $PIN)"
