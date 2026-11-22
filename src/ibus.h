#ifndef LEANTTY_IBUS_H
#define LEANTTY_IBUS_H

/* IBus 输入法（内联预编辑）。所有函数需在同一线程调用，手柄为 NULL 时全部降级为无操作。 */

void *tty_ibus_open(void);
/* 不可用原因（静态字符串，可为 NULL）；仅在 open 失败后有意义。 */
const char *tty_ibus_unavailable_reason(void);
void tty_ibus_close(void *handle);
void tty_ibus_focus(void *handle, int focused);
/* 返回 1 表示输入法已消费该按键（不要再写给 PTY）。 */
int tty_ibus_process_key(void *handle, unsigned int keyval, unsigned int keycode, unsigned int state);
/* 报告光标位置（屏幕坐标），让候选窗跟随光标。 */
void tty_ibus_set_cursor(void *handle, int x, int y, int w, int h);
/* 非阻塞驱动 GLib 主上下文（信号分发）。 */
void tty_ibus_pump(void *handle);
/* 取走已提交文本，返回字节数；取走后清空。 */
int tty_ibus_take_commit(void *handle, char *buf, int cap);
/* 取当前预编辑串（不消费），返回字节数。 */
int tty_ibus_take_preedit(void *handle, char *buf, int cap, int *cursor, int *visible);

#endif
