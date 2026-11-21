# Changelog

## 0.1.0

First published snapshot of the Zig implementation. Current state, no history:

- VT core: libghostty (pin `0b8b9984e`) — wide chars, grapheme clusters, reflow, scrollback,
  alternate screen, bracketed paste, OSC 0/2/4/10/11/52.
- Linux X11 backend: CPU framebuffer rendering, optional GLX presentation (`backend = auto|cpu|gpu`),
  SHM image transport, WM_TAKE_FOCUS handling, per-window icon via desktop entry.
- Windows backend: ConPTY, DIB double buffer, FreeType fonts, Imm32 IME, clipboard, mouse selection,
  per-monitor DPI, embedded window icon.
- Fonts (both platforms): FreeType, four style slots, no synthetic bold/italic, configurable fallback
  chain + built-in emoji/symbol fallback, color emoji on Linux (CBDT), `font.size` in points with
  Xft.dpi scaling.
- Text: underline styles (single/double/curly/dotted/dashed), strikethrough, overline, inverse,
  invisible, faint, 256-color/truecolor, `draw_bold_text_with_bright_colors`.
- Input: byte-compatible key encoding with alacritty across a 49-case matrix; IBus IME with
  Shift-tap toggle; mouse reporting; selection and clipboard; wheel scrolling with scrollbar.
- Config: TOML subset compatible with the Rust `leantty`; unsupported keys are reported at startup.
- Tooling: e2e suites (shared + Zig-specific + key matrix), cross-platform font golden file.

Known limitations are listed in the README.
