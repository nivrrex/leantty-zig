#!/usr/bin/env python3
"""向窗口发送标准 WM_DELETE_WINDOW client message（e2e 关窗用例）。

实测结论（DECISIONS 登记）：run_all 序列环境下 wmctrl -c 发的 WM_DELETE 丢失，
本脚本直发有效；app 对标准 WM_DELETE 响应正常（无缺陷）。
用法: wm_send.py <window-id（十进制或 0x 十六进制）>
"""
import sys

from Xlib import X, display
from Xlib.protocol import event as xevent

WID = int(sys.argv[1], 0)
d = display.Display()
w = d.create_resource_object('window', WID)
wm_protocols = d.intern_atom('WM_PROTOCOLS')
wm_delete = d.intern_atom('WM_DELETE_WINDOW')
ev = xevent.ClientMessage(
    window=w,
    client_type=wm_protocols,
    data=(32, [wm_delete, X.CurrentTime, 0, 0, 0]),
)
w.send_event(ev)
d.sync()
print(f"sent WM_DELETE to {WID:#x}")
