/* IBus 内联预编辑：libibus + GLib 主上下文，**运行时 dlopen 绑定**。
 *
 * 为什么 dlopen 而不是链接期依赖：
 *   libibus/glib/gobject 的包名与 ABI 在不同发行版/版本间反复变化
 *   （Debian bookworm: libglib2.0-0 / libgobject-2.0-0；
 *    trixie 及以后: libglib2.0-0t64 / libgobject-2.0-0t64），
 *   链接期硬依赖会让 .deb 的 Depends 在别的发行版上不可满足而装不上；
 *   而且没有 IBus 的机器上程序根本起不来（动态链接器直接报错）。
 *   = 终端核心功能不该被"输入法是否安装"绑架。
 *   改为运行时解析后：没有 libibus 时输入法降级关闭，终端正常工作。
 *
 * 为什么走 libibus 而不是裸 D-Bus：裸协议要先自己实现认证/编组/信号匹配，
 * 实测 CreateInputContext 能通但 FocusIn 因 capabilities 未生效被拒；
 * libibus 一次把建上下文、能力、焦点、按键、信号都处理干净（探针见 REPORT 6.7）。
 *
 * GLib 主上下文由宿主事件循环驱动：每次 tty_ibus_pump() 非阻塞迭代一次。
 * 线程约定：所有函数必须在同一个线程调用（与 X11/PTY 相同）。
 */
#include "ibus.h"
#include <dlfcn.h>
#include <stdlib.h>

#include <ibus.h>
#include <stdio.h>
#include <string.h>

/* ---- 运行时符号表 ---- */

struct ibus_api {
    void *h_ibus, *h_glib, *h_gobject;

    void (*p_ibus_init)(void);
    IBusBus *(*p_ibus_bus_new)(void);
    gboolean (*p_ibus_bus_is_connected)(IBusBus *);
    IBusInputContext *(*p_ibus_bus_create_input_context)(IBusBus *, const gchar *);
    void (*p_ibus_input_context_set_capabilities)(IBusInputContext *, guint32);
    void (*p_ibus_input_context_focus_in)(IBusInputContext *);
    void (*p_ibus_input_context_focus_out)(IBusInputContext *);
    gboolean (*p_ibus_input_context_process_key_event)(IBusInputContext *, guint32, guint32, guint32);
    void (*p_ibus_input_context_set_cursor_location)(IBusInputContext *, gint32, gint32, gint32, gint32);
    const gchar *(*p_ibus_text_get_text)(IBusText *);

    gboolean (*p_g_main_context_iteration)(GMainContext *, gboolean);
    void (*p_g_free)(gpointer);
    gulong (*p_g_signal_connect_data)(gpointer, const gchar *, GCallback, gpointer, GClosureNotify, GConnectFlags);
    void (*p_g_object_unref)(gpointer);
};

static struct ibus_api api;
static int api_tried;
static const char *api_reason = "未尝试加载 libibus";

#define BIND(h, field, name)                                                        \
    do {                                                                            \
        *(void **)(&api.field) = dlsym((h), (name));                                 \
        if (!api.field) { api_reason = "缺少符号 " name; return 0; }                  \
    } while (0)

static int load_api(void) {
    if (api_tried) return api.h_ibus != NULL;
    api_tried = 1;

    api.h_gobject = dlopen("libgobject-2.0.so.0", RTLD_NOW | RTLD_GLOBAL);
    if (!api.h_gobject) { api_reason = "未找到 libgobject-2.0.so.0（未安装 GLib）"; return 0; }
    /* glib 通常已由 gobject 带入，这里显式再取一次以防依赖顺序变化。 */
    api.h_glib = dlopen("libglib-2.0.so.0", RTLD_NOW | RTLD_GLOBAL);
    if (!api.h_glib) { api_reason = "未找到 libglib-2.0.so.0（未安装 GLib）"; return 0; }

    api.h_ibus = dlopen("libibus-1.0.so.5", RTLD_NOW | RTLD_GLOBAL);
    if (!api.h_ibus) api.h_ibus = dlopen("libibus-1.0.so.0", RTLD_NOW | RTLD_GLOBAL);
    if (!api.h_ibus) { api_reason = "未找到 libibus-1.0（未安装 IBus）"; return 0; }

    BIND(api.h_ibus, p_ibus_init, "ibus_init");
    BIND(api.h_ibus, p_ibus_bus_new, "ibus_bus_new");
    BIND(api.h_ibus, p_ibus_bus_is_connected, "ibus_bus_is_connected");
    BIND(api.h_ibus, p_ibus_bus_create_input_context, "ibus_bus_create_input_context");
    BIND(api.h_ibus, p_ibus_input_context_set_capabilities, "ibus_input_context_set_capabilities");
    BIND(api.h_ibus, p_ibus_input_context_focus_in, "ibus_input_context_focus_in");
    BIND(api.h_ibus, p_ibus_input_context_focus_out, "ibus_input_context_focus_out");
    BIND(api.h_ibus, p_ibus_input_context_process_key_event, "ibus_input_context_process_key_event");
    BIND(api.h_ibus, p_ibus_input_context_set_cursor_location, "ibus_input_context_set_cursor_location");
    BIND(api.h_ibus, p_ibus_text_get_text, "ibus_text_get_text");

    BIND(api.h_glib, p_g_main_context_iteration, "g_main_context_iteration");
    BIND(api.h_glib, p_g_free, "g_free");
    BIND(api.h_gobject, p_g_signal_connect_data, "g_signal_connect_data");
    BIND(api.h_gobject, p_g_object_unref, "g_object_unref");

    api_reason = NULL;
    return 1;
}

const char *tty_ibus_unavailable_reason(void) {
    if (!api_tried) load_api();
    return api_reason;
}

/* ---- 会话 ---- */

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
    if (dbg_on()) fprintf(stderr, "ibuscb commit text=%s\n", text ? api.p_ibus_text_get_text(text) : "(null)");
    (void)ic;
    struct tty_ibus *s = user;
    if (!s || !text) return;
    const char *t = api.p_ibus_text_get_text(text);
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
    const char *t = text ? api.p_ibus_text_get_text(text) : NULL;
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
    if (!load_api()) {
        if (dbg_on()) fprintf(stderr, "ibus: 加载失败：%s\n", api_reason ? api_reason : "未知原因");
        return NULL;
    }
    api.p_ibus_init();
    struct tty_ibus *s = calloc(1, sizeof *s);
    if (!s) return NULL;

    /* 没有可用的 IBus 会话（例如 Xvfb 测试环境）时 ibus_bus_new 返回未连接的 bus，下面静默降级。 */
    s->bus = api.p_ibus_bus_new();
    if (!s->bus || !api.p_ibus_bus_is_connected(s->bus)) {
        api_reason = "IBus 守护进程未运行";
        api.p_g_free(s);
        return NULL;
    }
    s->ic = api.p_ibus_bus_create_input_context(s->bus, "leantty");
    if (!s->ic) {
        api_reason = "创建输入上下文失败";
        api.p_g_object_unref(s->bus);
        api.p_g_free(s);
        return NULL;
    }

    /* 必须声明能力：只有声明 IBUS_CAP_FOCUS 的输入上下文才会被守护进程当作活动
     * IC，否则引擎照旧"处理"按键（process_key_event 返回 1）但 commit/预编辑
     * 信号无处投递——本机实测正是这个症状（引擎 handled=1，零信号）。 */
    api.p_ibus_input_context_set_capabilities(s->ic, IBUS_CAP_PREEDIT_TEXT | IBUS_CAP_FOCUS);

    api.p_g_signal_connect_data(s->ic, "commit-text", G_CALLBACK(on_commit), s, NULL, 0);
    api.p_g_signal_connect_data(s->ic, "update-preedit-text", G_CALLBACK(on_preedit), s, NULL, 0);
    api.p_g_signal_connect_data(s->ic, "show-preedit-text", G_CALLBACK(on_show), s, NULL, 0);
    api.p_g_signal_connect_data(s->ic, "hide-preedit-text", G_CALLBACK(on_hide), s, NULL, 0);

    api.p_ibus_input_context_set_capabilities(s->ic, IBUS_CAP_PREEDIT_TEXT | IBUS_CAP_FOCUS);
    return s;
}

void tty_ibus_close(void *handle) {
    struct tty_ibus *s = handle;
    if (!s) return;
    if (s->ic) {
        api.p_ibus_input_context_focus_out(s->ic);
        api.p_g_object_unref(s->ic);
    }
    if (s->bus) api.p_g_object_unref(s->bus);
    api.p_g_free(s);
}

void tty_ibus_focus(void *handle, int focused) {
    struct tty_ibus *s = handle;
    if (!s || !s->ic) return;
    if (focused)
        api.p_ibus_input_context_focus_in(s->ic);
    else
        api.p_ibus_input_context_focus_out(s->ic);
}

int tty_ibus_process_key(void *handle, unsigned int keyval, unsigned int keycode, unsigned int state) {
    struct tty_ibus *s = handle;
    if (!s || !s->ic) return 0;
    return api.p_ibus_input_context_process_key_event(s->ic, keyval, keycode, state) ? 1 : 0;
}

void tty_ibus_set_cursor(void *handle, int x, int y, int w, int h) {
    struct tty_ibus *s = handle;
    if (!s || !s->ic) return;
    api.p_ibus_input_context_set_cursor_location(s->ic, x, y, w, h);
}

void tty_ibus_pump(void *handle) {
    (void)handle;
    if (!api.p_g_main_context_iteration) return;
    /* 非阻塞迭代，直到没有更多待处理事件 */
    while (api.p_g_main_context_iteration(NULL, FALSE)) {
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
