#!/usr/bin/env python3
"""GTK3 拖放源（用于端到端验证 XDND）：窗口里一块可拖拽区域，拖出去产生 text/uri-list。

为什么不用自制 X11 探针：自制的只验证"我们自己的协议实现自洽"，
真正要验的是**真实 GTK 源**（PCManFM/Thunar/Nautilus 都是 GTK 的 gtkdnd）能否把
文件拖进来——目标窗口定位、XdndProxy/重父化、类型协商都在 GTK 那侧。
"""

import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, Gtk


def main() -> int:
    if len(sys.argv) < 2:
        print("用法: dndsrc.py <要拖出的文件路径> [窗口左上角 x y]", file=sys.stderr)
        return 1
    path = sys.argv[1]
    x = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    y = int(sys.argv[3]) if len(sys.argv) > 3 else 0

    win = Gtk.Window(title="DND-SOURCE")
    win.set_default_size(200, 120)
    win.move(x, y)
    label = Gtk.Label(label="DRAG\nME")
    box = Gtk.EventBox()
    box.add(label)
    win.add(box)

    def on_get(_widget, _ctx, sel, _info, _time):
        sel.set_uris(["file://" + path])

    def on_begin(_widget, _ctx):
        print("DRAG-BEGIN", flush=True)

    box.drag_source_set(
        Gdk.ModifierType.BUTTON1_MASK,
        [Gtk.TargetEntry.new("text/uri-list", 0, 0)],
        Gdk.DragAction.COPY,
    )
    box.connect("drag-data-get", on_get)
    box.connect("drag-begin", on_begin)
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    print("SOURCE-READY", flush=True)
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
