/* IBus 内联预编辑：libibus + GLib 主上下文。
 *
 * 为什么走 libibus 而不是裸 D-Bus：裸协议要先自己实现认证/编组/信号匹配，
 * 实测 CreateInputContext 能通但 FocusIn 因 capabilities 未生效被拒；
 * libibus 一次把建上下文、能力、焦点、按键、信号都处理干净（探针见 REPORT 6.7）。
 *
 * GLib 主上下文由宿主事件循环驱动：每次 tty_ibus_pump() 非阻塞迭代一次。
 * 线程约定：所有函数必须在同一个线程调用（与 X11/PTY 相同）。
 */
#include "ibus.h"
#include <stdlib.h>

#include <ibus.h>
#include <stdio.h>
#include <string.h>

struct tty_ibus {
    IBusBus *bus;
    IBusInputContext *ic;
    /* 待取走的提交/预编辑文本（信号回调写入，宿主取走） */
    char commit[512];
    int commit_len;
    char preedit[512];
    int preedit_len;
    int preedit_cursor;
    int preedit_visible;
};

static int dbg_on(void) { return getenv("LEANTTY_KDBG") != NULL; }

static void on_commit(IBusInputContext *ic, IBusText *text, gpointer user) {
    if (dbg_on()) fprintf(stderr, "ibuscb commit text=%s\n", text ? ibus_text_get_text(text) : "(null)");
    (void)ic;
    struct tty_ibus *s = user;
    if (!s || !text) return;
    const char *t = ibus_text_get_text(text);
    if (!t) return;
    int n = (int)strlen(t);
    if (n >= (int)sizeof(s->commit)) n = (int)sizeof(s->commit) - 1;
    memcpy(s->commit, t, (size_t)n);
    s->commit[n] = 0;
    s->commit_len = n;
}

static void on_preedit(IBusInputContext *ic, IBusText *text, guint cursor, gboolean visible, gpointer user) {
    (void)ic;
    struct tty_ibus *s = user;
    if (!s) return;
    const char *t = text ? ibus_text_get_text(text) : NULL;
    int n = t ? (int)strlen(t) : 0;
    if (n >= (int)sizeof(s->preedit)) n = (int)sizeof(s->preedit) - 1;
    if (n > 0) memcpy(s->preedit, t, (size_t)n);
    s->preedit[n] = 0;
    s->preedit_len = n;
    s->preedit_cursor = (int)cursor;
    s->preedit_visible = visible ? 1 : 0;
}

static void on_show(IBusInputContext *ic, gpointer user) {
    (void)ic;
    struct tty_ibus *s = user;
    if (s) s->preedit_visible = 1;
}

static void on_hide(IBusInputContext *ic, gpointer user) {
    (void)ic;
    struct tty_ibus *s = user;
    if (s) {
        s->preedit_visible = 0;
        s->preedit_len = 0;
        s->preedit[0] = 0;
    }
}

void *tty_ibus_open(void) {
    ibus_init();
    struct tty_ibus *s = g_new0(struct tty_ibus, 1);
    if (!s) return NULL;

    /* 没有可用的 IBus 会话（例如 Xvfb 测试环境）时 ibus_bus_new 返回未连接的 bus，下面静默降级。 */
    s->bus = ibus_bus_new();
    if (!s->bus || !ibus_bus_is_connected(s->bus)) {
        g_free(s);
        return NULL;
    }
    s->ic = ibus_bus_create_input_context(s->bus, "leantty");
    if (!s->ic) {
        g_object_unref(s->bus);
        g_free(s);
        return NULL;
    }

    /* 必须声明能力：只有声明 IBUS_CAP_FOCUS 的输入上下文才会被守护进程当作活动
     * IC，否则引擎照旧"处理"按键（process_key_event 返回 1）但 commit/预编辑
     * 信号无处投递——本机实测正是这个症状（引擎 handled=1，零信号）。 */
    ibus_input_context_set_capabilities(s->ic, IBUS_CAP_PREEDIT_TEXT | IBUS_CAP_FOCUS);

    g_signal_connect(s->ic, "commit-text", G_CALLBACK(on_commit), s);
    g_signal_connect(s->ic, "update-preedit-text", G_CALLBACK(on_preedit), s);
    g_signal_connect(s->ic, "show-preedit-text", G_CALLBACK(on_show), s);
    g_signal_connect(s->ic, "hide-preedit-text", G_CALLBACK(on_hide), s);

    ibus_input_context_set_capabilities(s->ic, IBUS_CAP_PREEDIT_TEXT | IBUS_CAP_FOCUS);
    return s;
}

void tty_ibus_close(void *handle) {
    struct tty_ibus *s = handle;
    if (!s) return;
    if (s->ic) {
        ibus_input_context_focus_out(s->ic);
        g_object_unref(s->ic);
    }
    if (s->bus) g_object_unref(s->bus);
    g_free(s);
}

void tty_ibus_focus(void *handle, int focused) {
    struct tty_ibus *s = handle;
    if (!s || !s->ic) return;
    if (focused)
        ibus_input_context_focus_in(s->ic);
    else
        ibus_input_context_focus_out(s->ic);
}

int tty_ibus_process_key(void *handle, unsigned int keyval, unsigned int keycode, unsigned int state) {
    struct tty_ibus *s = handle;
    if (!s || !s->ic) return 0;
    return ibus_input_context_process_key_event(s->ic, keyval, keycode, state) ? 1 : 0;
}

void tty_ibus_set_cursor(void *handle, int x, int y, int w, int h) {
    struct tty_ibus *s = handle;
    if (!s || !s->ic) return;
    ibus_input_context_set_cursor_location(s->ic, x, y, w, h);
}

void tty_ibus_pump(void *handle) {
    (void)handle;
    /* 非阻塞迭代，直到没有更多待处理事件 */
    while (g_main_context_iteration(NULL, FALSE)) {
    }
}

int tty_ibus_take_commit(void *handle, char *buf, int cap) {
    struct tty_ibus *s = handle;
    if (!s || s->commit_len <= 0) return 0;
    int n = s->commit_len < cap - 1 ? s->commit_len : cap - 1;
    memcpy(buf, s->commit, (size_t)n);
    buf[n] = 0;
    s->commit_len = 0;
    s->commit[0] = 0;
    return n;
}

int tty_ibus_take_preedit(void *handle, char *buf, int cap, int *cursor, int *visible) {
    struct tty_ibus *s = handle;
    if (!s) return 0;
    int n = s->preedit_len < cap - 1 ? s->preedit_len : cap - 1;
    if (n > 0) memcpy(buf, s->preedit, (size_t)n);
    buf[n] = 0;
    if (cursor) *cursor = s->preedit_cursor;
    if (visible) *visible = s->preedit_visible;
    return n;
}
