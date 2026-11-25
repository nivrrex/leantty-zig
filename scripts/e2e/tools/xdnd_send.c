/* XDND 拖放"源"探针：把若干本地路径当成文件管理器拖进目标窗口（Linux/X11）。
 *
 * 为什么需要它：拖放只能由真实源端触发，xdotool/xclip 都做不了 XDND。
 * 没有源端就只能"读代码猜"，没法验证协议实现（接受位、类型表、uri-list 解码）。
 *
 * 用法：
 *   xdnd_send <目标窗口 id（十进制或 0x…）> <路径> [路径…]
 *
 * 流程（与 XDND 5 规范一致）：
 *   1) 自己开一个从不映射的小窗口当源，抢下 XdndSelection 的所有权；
 *   2) 在源窗口上写 XdndTypeList（text/uri-list 等）与 XdndAware；
 *   3) 依次发 XdndEnter / XdndPosition，等目标的 XdndStatus（看 bit0 接受位）；
 *   4) 发 XdndDrop，随后处理目标的 SelectionRequest，把 uri-list 写进它的属性；
 *   5) 等到 XdndFinished 或超时退出。
 * 退出码：0 = 完成（收到 XdndFinished 且接受位为 1）；2 = 目标不接受；3 = 超时。
 */
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_URI 4096

static char g_uri_list[MAX_URI * 8];
static size_t g_uri_len;
static Atom a_xdnd_aware, a_xdnd_enter, a_xdnd_position, a_xdnd_status, a_xdnd_drop,
    a_xdnd_finished, a_xdnd_selection, a_xdnd_type_list, a_xdnd_action_copy, a_text_uri_list,
    a_utf8, a_prop;

/* 把路径拼成 file://<uri>，按 RFC 3986 对非 unreserved 字节做 %XX */
static void append_uri(const char *path) {
    static const char hex[] = "0123456789ABCDEF";
    g_uri_len += (size_t)snprintf(g_uri_list + g_uri_len, sizeof(g_uri_list) - g_uri_len,
                                  "file://");
    for (const unsigned char *p = (const unsigned char *)path; *p; p++) {
        const unsigned char c = *p;
        const int keep = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                         (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' ||
                         c == '~' || c == '/';
        if (keep) {
            g_uri_list[g_uri_len++] = (char)c;
        } else {
            g_uri_list[g_uri_len++] = '%';
            g_uri_list[g_uri_len++] = hex[c >> 4];
            g_uri_list[g_uri_len++] = hex[c & 15];
        }
    }
    g_uri_list[g_uri_len++] = '\r';
    g_uri_list[g_uri_len++] = '\n';
    g_uri_list[g_uri_len] = 0;
}

static void send_msg(Display *dpy, Window dst, Atom type, long l0, long l1, long l2, long l3,
                     long l4, long l5) {
    XEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.xclient.type = ClientMessage;
    ev.xclient.display = dpy;
    ev.xclient.window = dst;
    ev.xclient.message_type = type;
    ev.xclient.format = 32;
    ev.xclient.data.l[0] = l0;
    ev.xclient.data.l[1] = l1;
    ev.xclient.data.l[2] = l2;
    ev.xclient.data.l[3] = l3;
    ev.xclient.data.l[4] = l4;
    ev.xclient.data.l[5] = l5;
    XSendEvent(dpy, dst, False, 0, &ev);
    XFlush(dpy);
}

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "用法: %s <窗口 id> <路径> [路径…]\n", argv[0]);
        return 1;
    }
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "xdnd_send: XOpenDisplay 失败\n");
        return 1;
    }
    const Window target = (Window)strtoul(argv[1], NULL, 0);
    if (!target) {
        fprintf(stderr, "xdnd_send: 目标窗口 id 非法\n");
        return 1;
    }
    g_uri_len = 0;
    for (int i = 2; i < argc; i++) append_uri(argv[i]);

    a_xdnd_aware = XInternAtom(dpy, "XdndAware", False);
    a_xdnd_enter = XInternAtom(dpy, "XdndEnter", False);
    a_xdnd_position = XInternAtom(dpy, "XdndPosition", False);
    a_xdnd_status = XInternAtom(dpy, "XdndStatus", False);
    a_xdnd_drop = XInternAtom(dpy, "XdndDrop", False);
    a_xdnd_finished = XInternAtom(dpy, "XdndFinished", False);
    a_xdnd_selection = XInternAtom(dpy, "XdndSelection", False);
    a_xdnd_type_list = XInternAtom(dpy, "XdndTypeList", False);
    a_xdnd_action_copy = XInternAtom(dpy, "XdndActionCopy", False);
    a_text_uri_list = XInternAtom(dpy, "text/uri-list", False);
    a_utf8 = XInternAtom(dpy, "UTF8_STRING", False);
    a_prop = XInternAtom(dpy, "XDND_PROBE", False);

    /* 源端窗口：不映射，只用来挂类型表并当 selection 属主 */
    Window src = XCreateSimpleWindow(dpy, DefaultRootWindow(dpy), -10, -10, 1, 1, 0, 0, 0);
    long ver = 5;
    XChangeProperty(dpy, src, a_xdnd_aware, XA_ATOM, 32, PropModeReplace,
                    (const unsigned char *)&ver, 1);
    Atom types[4] = { a_text_uri_list, a_utf8, XA_STRING, a_xdnd_type_list };
    XChangeProperty(dpy, src, a_xdnd_type_list, XA_ATOM, 32, PropModeReplace,
                    (const unsigned char *)types, 4);
    XSetSelectionOwner(dpy, a_xdnd_selection, src, CurrentTime);
    XFlush(dpy);
    if (XGetSelectionOwner(dpy, a_xdnd_selection) != src) {
        fprintf(stderr, "xdnd_send: 抢不到 XdndSelection（另一个拖放进行中？）\n");
        return 1;
    }

    /* 1) XdndEnter：l[1] 高字节=版本，低字节 bit0=有类型表 */
    send_msg(dpy, target, a_xdnd_enter, (long)src, (5L << 24) | 1L, (long)a_text_uri_list,
             (long)a_text_uri_list, (long)a_text_uri_list, 0);
    /* 2) XdndPosition：l[2] = (x<<16)|y，l[3] = 时间戳，l[4] = 动作 */
    const Time ts = CurrentTime;
    send_msg(dpy, target, a_xdnd_position, (long)src, 0, (10L << 16) | 10L, (long)ts,
             (long)a_xdnd_action_copy, 0);

    int accepted = -1, finished = -1;
    const double deadline = now_s() + 6.0;
    int dropped = 0;
    while (now_s() < deadline) {
        while (XPending(dpy)) {
            XEvent ev;
            XNextEvent(dpy, &ev);
            if (getenv("XDND_DEBUG"))
                fprintf(stderr, "src 收到事件 type=%d mt=%lu%s\n", ev.type,
                        ev.type == ClientMessage ? (unsigned long)ev.xclient.message_type : 0UL,
                        ev.type == ClientMessage
                            ? XGetAtomName(dpy, ev.xclient.message_type)
                            : "");
            if (ev.type == ClientMessage && ev.xclient.message_type == a_xdnd_status) {
                /* 规范：XdndStatus/XdndFinished 的 data.l[0] 是**目标**窗口
                 * （接收方自己），用它可以确认回复没串到别的拖放上。 */
                if ((Window)ev.xclient.data.l[0] != target) continue;
                accepted = (int)(ev.xclient.data.l[1] & 1);
                if (!dropped) {
                    if (!accepted) {
                        fprintf(stderr, "xdnd_send: 目标不接受 text/uri-list\n");
                        return 2;
                    }
                    /* 3) 接受后再发 XdndDrop（时间戳用 CurrentTime 亦可） */
                    send_msg(dpy, target, a_xdnd_drop, (long)src, 0, (long)CurrentTime, 0, 0, 0);
                    dropped = 1;
                }
            } else if (ev.type == ClientMessage && ev.xclient.message_type == a_xdnd_finished) {
                if ((Window)ev.xclient.data.l[0] != target) continue;
                finished = (int)(ev.xclient.data.l[1] & 1);
            } else if (ev.type == SelectionRequest) {
                XSelectionRequestEvent *req = &ev.xselectionrequest;
                XSelectionEvent res;
                memset(&res, 0, sizeof(res));
                res.type = SelectionNotify;
                res.display = req->display;
                res.requestor = req->requestor;
                res.selection = req->selection;
                res.target = req->target;
                res.time = req->time;
                res.property = req->property;
                if (req->target == a_text_uri_list || req->target == a_utf8 ||
                    req->target == XA_STRING) {
                    XChangeProperty(dpy, req->requestor,
                                    req->property ? req->property : req->target,
                                    req->target == a_text_uri_list ? a_text_uri_list : req->target,
                                    8, PropModeReplace, (const unsigned char *)g_uri_list,
                                    (int)g_uri_len);
                } else {
                    res.property = None;
                }
                XSendEvent(dpy, req->requestor, False, 0, (XEvent *)&res);
                XFlush(dpy);
            }
        }
        if (!dropped && accepted == -1 && now_s() > deadline - 5.0) {
            /* 目标一直不回 XdndStatus：规范上不该发生，直接判定失败 */
            fprintf(stderr, "xdnd_send: 目标没有回 XdndStatus\n");
            return 3;
        }
        if (finished >= 0) break;
        struct timespec nap = { 0, 20 * 1000 * 1000 };
        nanosleep(&nap, NULL);
    }
    if (finished < 0) {
        fprintf(stderr, "xdnd_send: 超时（没收到 XdndFinished）\n");
        return 3;
    }
    printf("xdnd_send: accepted=%d finished=%d uris=%zu bytes\n", accepted, finished, g_uri_len);
    XCloseDisplay(dpy);
    return finished == 1 ? 0 : 4;
}
