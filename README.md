# leantty-zig

A small terminal emulator written in Zig, built directly on **libghostty**'s VT core.

This is an **independent, from-scratch Zig implementation** of the same terminal that the Rust
project [**leantty**](https://github.com/nivrrex/leantty) implements. The two projects share no code
and are developed separately; what they share is the design idea and (partially) the configuration
file format. If you want the mature, published implementation, use
[leantty](https://github.com/nivrrex/leantty) (Rust). This repository exists as a second
implementation with a much smaller dependency footprint and a single static-ish binary.

```
Rust leantty (github.com/nivrrex/leantty)   ←→   leantty-zig (this repository)
  winit + wgpu + crossfont                       own X11/Win32 code + FreeType
  repository: /srv/git/tty.git (self-hosted)     repository: this GitHub repo
```

Both read the same style of TOML config (`~/.config/leantty/leantty.toml`); leantty-zig implements a
subset and prints `未实现，已忽略: <key>` at startup for keys it does not support, so nothing is
silently dropped.

## What works

Linux (X11, primary target — fully tested):

- **VT core**: libghostty handles grid semantics — wide characters, combining marks, grapheme
  clusters, reflow, scrollback, alternate screen, bracketed paste, OSC 0/2 titles, OSC 4/10/11
  colors, OSC 52 clipboard.
- **Rendering**: CPU rasterizer over a shared framebuffer, plus optional OpenGL (GLX) presentation
  (`[renderer] backend = "auto" | "cpu" | "gpu"`). Glyph rasterization is FreeType on the CPU; the
  GPU path only uploads and scales the finished frame.
- **Fonts**: FreeType + fontconfig. Four style slots (normal/bold/italic/bold-italic) resolved per
  family; no synthetic bold/italic (same as alacritty — a single-weight family simply stays regular).
  Fallback chain from config plus built-in `Noto Color Emoji` / `Symbola`. Color emoji (CBDT) render
  in color; `font.size` is in points (`px = pt × Xft.dpi / 72`).
- **Text attributes**: bold, faint, italic, underline (single/double/curly/dotted/dashed with
  optional color), strikethrough, overline, inverse, invisible, 256-color and truecolor,
  `draw_bold_text_with_bright_colors`.
- **Input**: key encoding byte-for-byte compatible with alacritty for the tested matrix (49 cases:
  printable, Ctrl/Alt combinations, arrows, F1–F12, keypad, Insert family, AltGr, application
  cursor/keypad modes). IME through IBus directly (no XIM), including Shift-tap to toggle
  Chinese/English as configured in rime. Mouse reporting, selection (single/double/triple click,
  drag), copy/paste over PRIMARY/CLIPBOARD, wheel scrolling with a scrollbar.
- **Window behaviour**: `WM_TAKE_FOCUS` handling, dynamic title from OSC 0/2, cursor shapes via
  DECSCUSR, optional cursor blink.

Windows (`x86_64-windows-gnu`, builds and runs; see limitations):

- ConPTY-based PTY (no anonymous-pipe fallback), DIB double-buffered rendering, FreeType font
  backend shared with the Linux build, Imm32 IME wiring, clipboard, mouse selection, per-monitor
  DPI, window icon.

## Known limitations

- **Wayland is not implemented**; the Linux backend is X11-only.
- **Windows**: the binary is cross-compiled and smoke-tested under Wine; IME, mouse reporting and
  the window integration are not verified on real Windows hardware.
- **OSC 8 hyperlinks** are underlined but not clickable (the URI is not exposed by the VT core API).
- **Inline IME preedit is not shown** when the engine sends preedit text to its own candidate panel
  (as rime does over IBus); committed text works normally.
- Not implemented, reported at startup: `window.padding.*`, `window.opacity`, `window.decorations`,
  `cursor.style`, `font.glyph_offset.*`, `selection.semantic_escape_chars`, `env.*`, `hints.*`,
  `bell.*`.
- `Ctrl+Shift+<punctuation>` follows ghostty/xterm (`0x7f` for `Ctrl+?`), not alacritty (`0x3f`).

## Install

### Debian / Devuan package

```sh
sudo dpkg -i leantty-zig_0.1.0_amd64.deb
sudo apt -f install          # 补齐依赖（首次安装时）
leantty-zig
```

The package installs `/usr/bin/leantty-zig`, a desktop entry and hicolor icons (16…512 px).
It does not replace the Rust `leantty` package — the command name differs.

### Windows

Download `leantty-zig-0.1.0-windows-x86_64.zip`, unpack anywhere and run `leantty-zig.exe`
(or `run.cmd`). The bundled `leantty.toml` is an example configuration; delete it to use defaults.

### Build from source

See [`docs/BUILD.md`](docs/BUILD.md). In short: Zig 0.17.x, a libghostty source checkout at the
pinned commit, then

```sh
zig build -Doptimize=ReleaseFast        # zig-out/bin/leantty
zig build -Dtarget=x86_64-windows-gnu -Dcpu=baseline -Doptimize=ReleaseFast
```

## Configure

The configuration file is TOML, read from (in order) `--config-file`, `LEANTTY_CONFIG`,
`~/.config/leantty/leantty.toml`. See [`config/leantty.example.toml`](config/leantty.example.toml)
for every supported key. A few notes:

- `font.size` is in **points**; `px = pt × Xft.dpi / 72` (same rule as alacritty).
- `[colors.*]` follows alacritty's layout (`primary`, `cursor`, `normal`, `bright`, `selection`).
- `[[keyboard.bindings]]` / `[[mouse.bindings]]` accept `Copy`, `Paste`, `ScrollPageUp`,
  `ScrollPageDown`, `ScrollToTop`, `ScrollToBottom`, `Quit`.

## Environment variables (mainly for testing)

| Variable | Meaning |
|---|---|
| `LEANTTY_CONFIG` | configuration file path |
| `LEANTTY_KDBG=1` | print key/binding/IME decisions to stderr |
| `LEANTTY_FONTDBG=1` | print resolved font faces and metrics |
| `APP_COLS` / `APP_ROWS` / `APP_CELL_W` / `APP_CELL_H` / `APP_FONT_SIZE` | override grid/cell geometry |
| `APP_DUMP_SNAPSHOT=<path>` | dump the screen as text after each frame |

## Tests

```sh
zig build test                  # VT/terminal unit tests
sh scripts/e2e/run_all.sh       # shared end-to-end suite (Xvfb)
sh scripts/e2e/run_zig_extra.sh # Zig-specific end-to-end cases
sh scripts/e2e/run_keys_matrix.sh  # byte-exact key encoding matrix
sh scripts/golden-check.sh      # cross-platform font golden file (Linux vs Windows/wine)
```

The e2e scripts need `Xvfb`, `openbox`, `xdotool`, `xwininfo`, `import` (ImageMagick).

## License

MIT — see [LICENSE](LICENSE). The vendored FreeType copy under `vendor/freetype` is distributed
under its own FTL/GPLv2 dual license (see `vendor/freetype/docs/FTL.TXT`); libghostty is MIT.

## Relationship to `leantty` (Rust)

- [leantty](https://github.com/nivrrex/leantty) — the Rust implementation: winit + wgpu +
  crossfont, published releases, the project this one was modelled after.
- `leantty-zig` (this repository) — the Zig implementation: own X11/Win32 window layer, FreeType
  rendering, IBus input, same VT core (libghostty), compatible config subset.

Bug reports about terminal behaviour are welcome here; bugs that exist in both implementations are
usually fixed in the Rust project first.
