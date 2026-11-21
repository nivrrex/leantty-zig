# Building leantty-zig

## Requirements

| Item | Version / note |
|---|---|
| Zig | 0.17.x (developed with 0.17.1) |
| libghostty source | pinned commit `0b8b9984e` (the same pin the Rust `leantty` uses) |
| FreeType | system package on Linux (`libfreetype-dev`); vendored copy is used for Windows builds |
| fontconfig | Linux only (`libfontconfig-dev`) |
| X11 / Xext / GL / GLX | Linux only (`libx11-dev`, `libxext-dev`, `libgl1-mesa-dev`) |
| IBus + GLib | Linux only (`libibus-1.0-dev`, `libglib2.0-dev`) |
| mingw windres | only for Windows icon resources (`binutils-mingw-w64-x86-64`) |

## Layout expected by `build.zig.zon`

`build.zig.zon` declares the VT core as a local path dependency:

```zig
.ghostty = .{ .path = ".deps/ghostty-src" },
```

One step to satisfy it:

```sh
./scripts/fetch-ghostty.sh      # 克隆 pin 0b8b9984e 到 .deps/ghostty-src（约 230 MB）
```

Already have a ghostty checkout? Symlink or move it to `.deps/ghostty-src`, or edit that `.path`
in `build.zig.zon`.

## Linux

```sh
zig build -Doptimize=ReleaseFast              # → zig-out/bin/leantty
zig build test                                # unit tests
sh scripts/e2e/run_all.sh                     # e2e under Xvfb
```

Optional flags: `-Drenderer-backend=cpu|gpu|auto` (default auto), `-Dfreetype-include=...`,
`-Dibus-include=...` if your headers live somewhere unusual.

## Windows (cross-compile from Linux)

```sh
zig build -Dtarget=x86_64-windows-gnu -Dcpu=baseline -Doptimize=ReleaseFast
```

The Windows target compiles the vendored FreeType from `vendor/freetype` and pre-compiles the icon
resource `assets/icon/leantty.rc` with `x86_64-w64-mingw32-windres` (must be on `PATH`).

## Packaging

```sh
sh scripts/package-deb.sh 0.1.0        # dist/leantty-zig_0.1.0_amd64.deb
sh scripts/package-windows.sh 0.1.0    # dist/leantty-zig-0.1.0-windows-x86_64.zip
```

Both scripts rebuild first, then stage files under `build/` and write the artifact to `dist/`.

Icons are generated from `assets/icon/leantty.svg`; the PNG set and `leantty.ico` are committed so
packaging does not need `rsvg-convert`, but regenerating is one command:

```sh
for s in 16 24 32 48 64 128 256 512; do
  rsvg-convert -w $s -h $s assets/icon/leantty.svg -o assets/icon/png/leantty-$s.png
done
convert assets/icon/png/leantty-{16,24,32,48,64,128,256}.png assets/icon/leantty.ico
```
