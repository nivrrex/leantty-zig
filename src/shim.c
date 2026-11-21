#define _GNU_SOURCE
#include "shim.h"
#include "font_ft.h"

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/XKBlib.h>
#include <X11/Xatom.h>
#include <X11/extensions/XShm.h>
#include <sys/ipc.h>
#include <sys/shm.h>

#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_SYNTHESIS_H

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <string.h>
#include <locale.h>

/* ---- GPU 呈现（GLX + 纹理 + 全屏四边形）----
 * 自写管线：不依赖任何渲染框架，只做"把 CPU 帧缓冲当纹理贴到一个四边形上"。
 * 失败时返回 0，调用方继续用 SHM 路径。 */
#define GL_GLEXT_PROTOTYPES 1
#include <GL/gl.h>
#include <GL/glext.h>
#include <GL/glx.h>

struct tty_gl {
    GLXContext ctx;
    /* GPU 直画（字形图集 + quad）*/
    int gpu_ok;              /* shader/VBO/atlas 就绪 */
    GLuint prog_bg;          /* 纯色四边形 */
    GLuint prog_glyph;       /* 图集采样 × 顶点色 */
    GLuint atlas_tex;
    int atlas_size;
    int atlas_x, atlas_y, atlas_row_h; /* 简单行式装箱 */
    GLuint vbo_bg, vbo_glyph;

    GLuint tex;
    GLuint prog;
    GLint tex_uniform;
    int tex_w, tex_h;
    int ready;
};

struct tty_ctx {
    Display *dpy;
    Atom clipboard;
    Atom primary;
    Atom paste_prop;
    Atom utf8_string;
    char *clip_buf;
    int clip_len;
    char *primary_buf;
    int primary_len;
    struct tty_gl gl;
    int use_gl;
    /* 窗口实际使用的 visual/depth/colormap（GPU 时要与 GLX visual 一致） */
    Visual *visual;
    int depth;
    Colormap cmap;
    XVisualInfo *gl_vi;
    Atom wm_take_focus;
    XIM im;
    XIC xic;
    Window win;
    int w, h;
    Atom wm_delete;
    GC gc;
    XImage *img;
    XShmSegmentInfo shm;
    int shm_ok;
};

void tty_focus_window(void *ctx);
static int gl_init(struct tty_ctx *c, int width, int height);
static void gl_present(struct tty_ctx *c, const uint32_t *pixels, int width, int height);

static int shm_create(struct tty_ctx *c, int w, int h) {
    c->img = XShmCreateImage(c->dpy, c->visual, c->depth, ZPixmap, NULL, &c->shm, w, h);
    if (!c->img) return 0;
    c->shm.shmid = shmget(IPC_PRIVATE, (size_t)c->img->bytes_per_line * (size_t)h,
                          IPC_CREAT | 0600);
    if (c->shm.shmid < 0) {
        XDestroyImage(c->img);
        c->img = NULL;
        return 0;
    }
    c->shm.shmaddr = c->img->data = shmat(c->shm.shmid, NULL, 0);
    if (c->shm.shmaddr == (char *)-1) {
        shmctl(c->shm.shmid, IPC_RMID, NULL);
        XDestroyImage(c->img);
        c->img = NULL;
        return 0;
    }
    c->shm.readOnly = False;
    if (!XShmAttach(c->dpy, &c->shm)) {
        shmdt(c->shm.shmaddr);
        shmctl(c->shm.shmid, IPC_RMID, NULL);
        XDestroyImage(c->img);
        c->img = NULL;
        return 0;
    }
    XSync(c->dpy, False);
    /* 进程退出后由内核回收，避免残留段 */
    shmctl(c->shm.shmid, IPC_RMID, NULL);
    return 1;
}

static void shm_destroy(struct tty_ctx *c) {
    if (!c->img) return;
    if (c->shm_ok) XShmDetach(c->dpy, &c->shm);
    if (c->shm.shmaddr && c->shm.shmaddr != (char *)-1) shmdt(c->shm.shmaddr);
    XDestroyImage(c->img);
    c->img = NULL;
    c->shm_ok = 0;
}

void *tty_open_at(int width, int height, const char *title, int x, int y) {
    /* XIM 需要 locale 已设置，否则 XOpenIM 直接失败。 */
    setlocale(LC_ALL, "");
    XSetLocaleModifiers("");
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "leantty: XOpenDisplay failed (DISPLAY=%s)\n",
                getenv("DISPLAY") ? getenv("DISPLAY") : "(unset)");
        return NULL;
    }
    int screen = DefaultScreen(dpy);

    struct tty_ctx *c = calloc(1, sizeof(*c));
    if (!c) {
        XCloseDisplay(dpy);
        return NULL;
    }
    c->dpy = dpy;
    c->w = width;
    c->h = height;
    /* 窗口一律用默认 visual：用 GLX visual 另建窗口时，部分 WM 不接管该窗口，
     * 表现为收不到键盘（实测 openbox）。GL 上下文改为"匹配默认 visual 的 FBConfig"。 */
    c->visual = DefaultVisual(dpy, screen);
    c->depth = DefaultDepth(dpy, screen);
    c->win = XCreateSimpleWindow(dpy, RootWindow(dpy, screen),
                                 x >= 0 ? (unsigned)x : 0, y >= 0 ? (unsigned)y : 0,
                                 (unsigned)width, (unsigned)height, 0,
                                 BlackPixel(dpy, screen), BlackPixel(dpy, screen));
    XStoreName(dpy, c->win, title ? title : "leantty");
    if (x >= 0 && y >= 0) {
        /* USPosition 让 WM（openbox 等）照用我们给的位置 */
        XSizeHints *size_hints = XAllocSizeHints();
        if (size_hints) {
            size_hints->flags = USPosition | PPosition;
            size_hints->x = x;
            size_hints->y = y;
            XSetWMNormalHints(dpy, c->win, size_hints);
            XFree(size_hints);
        }
    }
    XSelectInput(dpy, c->win,
                 KeyPressMask | KeyReleaseMask | StructureNotifyMask |
                     ExposureMask | FocusChangeMask | ButtonPressMask |
                     ButtonReleaseMask | Button1MotionMask);
    /* 声明本窗口接收键盘输入：否则部分 WM 不会把焦点给它，
     * xdotool 的 XTEST 路径就会把按键送给别的窗口，表现为「丢字」。 */
    /* 声明本窗口接收键盘输入：否则部分 WM 不会把焦点给它，
     * xdotool 的 XTEST 路径就会把按键送给别的窗口，表现为「丢字」。 */
    XWMHints hints;
    memset(&hints, 0, sizeof(hints));
    hints.flags = InputHint;
    hints.input = True;
    XSetWMHints(dpy, c->win, &hints);
    XClassHint class_hint = { .res_name = "leantty", .res_class = "Leantty" };
    XSetClassHint(dpy, c->win, &class_hint);
    /* _NET_WM_PID：让 xdotool/wmctrl/任务管理器能按进程找到窗口
     * （没有它 `xdotool search --pid` 找不到我们，性能基准与排障都受影响）。 */
    {
        Atom pid_atom = XInternAtom(dpy, "_NET_WM_PID", False);
        long lpid = (long)getpid();
        XChangeProperty(dpy, c->win, pid_atom, XA_CARDINAL, 32, PropModeReplace,
                        (unsigned char *)&lpid, 1);
    }

    c->clipboard = XInternAtom(dpy, "CLIPBOARD", False);
    c->primary = XA_PRIMARY;
    c->paste_prop = XInternAtom(dpy, "LEANTTY_PASTE", False);
    c->utf8_string = XInternAtom(dpy, "UTF8_STRING", False);
    c->wm_delete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    c->wm_take_focus = XInternAtom(dpy, "WM_TAKE_FOCUS", False);
    {
        Atom protocols[2] = { c->wm_delete, c->wm_take_focus };
        XSetWMProtocols(dpy, c->win, protocols, 2);
    }
    c->gc = XCreateGC(dpy, c->win, 0, NULL);
    /* 输入法：XIM。ibus/fcitx 都提供 XIM 前端，拿到 XIC 才能收到组词上屏。 */
    /* 不创建 XIM：实测 ibus-x11 的 XIM 会吞掉 Ctrl+Insert/Ctrl+Space 等带修饰键的
     * 事件（XFilterEvent 返回真），而它的回调式预编辑又不可用。输入法统一走 IBus 直连。 */
    c->im = NULL;
    c->xic = NULL;

    XMapWindow(dpy, c->win);
    XSync(dpy, False);

    int have_shm = XShmQueryExtension(dpy) && !getenv("LEANTTY_NO_SHM");
    if (have_shm && shm_create(c, width, height)) {
        c->shm_ok = 1;
    } else {
        /* 无 SHM：普通 XImage + XPutImage 回退 */
        c->img = XCreateImage(dpy, c->visual, c->depth, ZPixmap, 0, NULL,
                              (unsigned)width, (unsigned)height, 32, 0);
        if (!c->img) {
            tty_close(c);
            return NULL;
        }
        c->img->data = calloc(1, (size_t)c->img->bytes_per_line * (size_t)height);
        if (!c->img->data) {
            XDestroyImage(c->img);
            tty_close(c);
            return NULL;
        }
    }
    return c;
}

void *tty_open(int width, int height, const char *title) {
    return tty_open_at(width, height, title, -1, -1);
}

void tty_close(void *ctx) {
    struct tty_ctx *c = ctx;
    if (!c) return;
    free(c->clip_buf);
    free(c->primary_buf);
    if (c->gl.ready) {
        /* 顺序必须是：仍持有上下文 → 删 GL 对象 → 解绑 → 销毁上下文。
         * 先 makeCurrent(None) 再调 glDelete*，GL 分发表为空 → 段错误（真机复现过）。 */
        glDeleteTextures(1, &c->gl.tex);
        glDeleteProgram(c->gl.prog);
        glXMakeCurrent(c->dpy, None, NULL);
        glXDestroyContext(c->dpy, c->gl.ctx);
    }
    if (c->xic) XDestroyIC(c->xic);
    if (c->im) XCloseIM(c->im);
    shm_destroy(c);
    if (c->gl_vi) XFree(c->gl_vi);
    if (c->cmap) XFreeColormap(c->dpy, c->cmap);
    if (c->gc) XFreeGC(c->dpy, c->gc);
    if (c->win) XDestroyWindow(c->dpy, c->win);
    if (c->dpy) XCloseDisplay(c->dpy);
    free(c);
}

void tty_clipboard_set(void *ctx, const char *utf8, int len) {
    struct tty_ctx *c = ctx;
    if (!c || len < 0) return;
    free(c->clip_buf);
    c->clip_buf = malloc((size_t)len + 1);
    if (!c->clip_buf) {
        c->clip_len = 0;
        return;
    }
    memcpy(c->clip_buf, utf8, (size_t)len);
    c->clip_buf[len] = 0;
    c->clip_len = len;
    XSetSelectionOwner(c->dpy, c->clipboard, c->win, CurrentTime);
    XFlush(c->dpy);
}

void tty_clipboard_set_primary(void *ctx, const char *utf8, int len, int which) {
    struct tty_ctx *c = ctx;
    if (!c || len < 0) return;
    char **buf = which == 1 ? &c->primary_buf : &c->clip_buf;
    int *blen = which == 1 ? &c->primary_len : &c->clip_len;
    free(*buf);
    *buf = malloc((size_t)len + 1);
    if (!*buf) {
        *blen = 0;
        return;
    }
    memcpy(*buf, utf8, (size_t)len);
    (*buf)[len] = 0;
    *blen = len;
    XSetSelectionOwner(c->dpy, which == 1 ? c->primary : c->clipboard, c->win, CurrentTime);
    XFlush(c->dpy);
}

int tty_clipboard_request(void *ctx, int which) {
    struct tty_ctx *c = ctx;
    if (!c) return -1;
    Atom sel = which == 1 ? c->primary : c->clipboard;
    XConvertSelection(c->dpy, sel, c->utf8_string, c->paste_prop, c->win, CurrentTime);
    XFlush(c->dpy);
    return 0;
}

int tty_read_file(const char *path, char *buf, int cap) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    size_t n = fread(buf, 1, (size_t)(cap > 0 ? cap - 1 : 0), f);
    fclose(f);
    buf[n] = 0;
    return (int)n;
}

void tty_x11_disable_xim(void *ctx) {
    struct tty_ctx *c = ctx;
    if (!c) return;
    if (c->xic) {
        XDestroyIC(c->xic);
        c->xic = NULL;
    }
}

int tty_window_origin(void *ctx, int *x, int *y) {
    struct tty_ctx *c = ctx;
    if (!c) return -1;
    Window child;
    int rx = 0, ry = 0;
    if (!XTranslateCoordinates(c->dpy, c->win, DefaultRootWindow(c->dpy), 0, 0, &rx, &ry, &child))
        return -1;
    if (x) *x = rx;
    if (y) *y = ry;
    return 0;
}

int tty_gl_enable(void *ctx) {
    struct tty_ctx *c = ctx;
    if (!c) return 0;
    if (!gl_init(c, c->w, c->h)) return 0;
    c->use_gl = 1;
    return 1;
}

/* 当前 GL 上下文用的渲染器（"NVIDIA GeForce GT 710/PCIe/SSE2" 或 "llvmpipe" 之类），
 * 用于启动时报告"到底用了 GPU 还是软件渲染"。 */
const char *tty_gl_renderer(void *ctx) {
    struct tty_ctx *c = ctx;
    if (!c || !c->use_gl) return NULL;
    const char *r = (const char *)glGetString(GL_RENDERER);
    return r;
}

/* SHM 图像传输是否可用（CPU 呈现路径的依赖）。 */
int tty_shm_ok(void *ctx) {
    struct tty_ctx *c = ctx;
    return c && c->shm_ok;
}

int tty_fd(void *ctx) {
    struct tty_ctx *c = ctx;
    if (!c || !c->dpy) return -1;
    return ConnectionNumber(c->dpy);
}

void tty_resize(void *ctx, int width, int height) {
    struct tty_ctx *c = ctx;
    if (!c || width <= 0 || height <= 0) return;
    if (width == c->w && height == c->h && c->img) return;
    shm_destroy(c);
    c->w = width;
    c->h = height;
    if (c->shm_ok && shm_create(c, width, height)) {
        c->shm_ok = 1;
    } else {
        c->shm_ok = 0;
        c->img = XCreateImage(c->dpy, c->visual, c->depth, ZPixmap, 0, NULL,
                              (unsigned)width, (unsigned)height, 32, 0);
        if (c->img)
            c->img->data = calloc(1, (size_t)c->img->bytes_per_line * (size_t)height);
    }
}

int tty_next_event(void *ctx, tty_event *out) {
    struct tty_ctx *c = ctx;
    /* 返回 1=已写入事件，0=消费了一个事件但不需要上报，-1=当前无事件。
     * 0 与 -1 必须区分，否则调用方会在"消费掉一个 KeyRelease"后误以为队列已空。 */
    if (!c || !XPending(c->dpy)) return -1;
    XEvent ev;
    XNextEvent(c->dpy, &ev);
    /* 输入法可能整条吃掉事件（组词中的按键），此时不要再转给终端。 */
    if (c->xic && XFilterEvent(&ev, c->win)) return 0;
    memset(out, 0, sizeof(*out));
    switch (ev.type) {
    case KeyRelease: {
        /* 只上报修饰键释放：这是 rime "Shift 切换中英文" 的必要输入
         * （引擎在 Shift 释放时且其间无其他按键则翻转 ascii_mode）。
         * 其余按键释放一律丢弃，避免事件流膨胀。 */
        KeySym mks = XLookupKeysym(&ev.xkey, 0);
        unsigned int u = (unsigned int)mks;
        if (!((u >= 0xffe1 && u <= 0xffe4) || (u >= 0xffe7 && u <= 0xffee))) return 0;
        out->type = TTY_EV_KEY_RELEASE;
        out->keycode = ev.xkey.keycode;
        out->state = ev.xkey.state;
        out->keysym = u;
        return 1;
    }
    case FocusIn: {
        if (c->xic) XSetICFocus(c->xic);
        out->type = TTY_EV_FOCUS_IN;
        return 1;
    }
    case FocusOut: {
        if (c->xic) XUnsetICFocus(c->xic);
        out->type = TTY_EV_FOCUS_OUT;
        return 1;
    }
    case KeyPress: {
        out->type = TTY_EV_KEY;
        out->keycode = ev.xkey.keycode;
        out->state = ev.xkey.state;
        char buf[8];
        KeySym ks = NoSymbol;
        if (c->xic) {
            /* 有 XIC 时用 XmbLookupString：输入法上屏走 XLookupChars。 */
            Status st = 0;
            char mb[128];
            int n = XmbLookupString(c->xic, &ev.xkey, mb, (int)sizeof(mb) - 1, &ks, &st);
            if (st == XLookupChars) {
                if (n > 0) {
                    if (n > (int)sizeof(out->text) - 1) n = (int)sizeof(out->text) - 1;
                    memcpy(out->text, mb, (size_t)n);
                    out->text[n] = 0;
                    out->text_len = n;
                    out->keysym = (unsigned int)ks;
                    return 1;
                }
                return 0;
            }
            if (n > 0 && st == XLookupBoth) {
                memcpy(out->text, mb, (size_t)n < sizeof(out->text) ? (size_t)n : sizeof(out->text) - 1);
                out->text_len = (int)((size_t)n < sizeof(out->text) ? (size_t)n : sizeof(out->text) - 1);
            }
            out->keysym = (unsigned int)ks;
            return 1;
        }
        XLookupString(&ev.xkey, buf, sizeof(buf), &ks, NULL);
        if (ks == NoSymbol) {
            /* 合成事件在某些场景下映射不到 keysym，退化为 keycode 查表 */
            ks = XkbKeycodeToKeysym(c->dpy, (KeyCode)ev.xkey.keycode, 0,
                                    (ev.xkey.state & ShiftMask) ? 1 : 0);
        }
        out->keysym = (unsigned int)ks;
        return 1;
    }
    case ConfigureNotify: {
        if (ev.xconfigure.width != c->w || ev.xconfigure.height != c->h) {
            tty_resize(c, ev.xconfigure.width, ev.xconfigure.height);
            out->type = TTY_EV_RESIZE;
            out->width = ev.xconfigure.width;
            out->height = ev.xconfigure.height;
            return 1;
        }
        return 0;
    }
    case ButtonPress: {
        if (c->xic == NULL) tty_focus_window(c); /* 点击顺带取焦点，幂等 */
        out->type = TTY_EV_BUTTON;
        out->button = (int)ev.xbutton.button;
        out->x = ev.xbutton.x;
        out->y = ev.xbutton.y;
        out->state = ev.xbutton.state;
        return 1;
    }
    case SelectionRequest: {
        XSelectionRequestEvent *req = &ev.xselectionrequest;
        XSelectionEvent res;
        memset(&res, 0, sizeof(res));
        res.type = SelectionNotify;
        res.display = req->display;
        res.requestor = req->requestor;
        res.selection = req->selection;
        res.target = req->target;
        res.property = req->property;
        res.time = req->time;
        const char *buf = req->selection == c->primary ? c->primary_buf : c->clip_buf;
        const int buflen = req->selection == c->primary ? c->primary_len : c->clip_len;
        if (buf && buflen > 0 && req->target == c->utf8_string) {
            XChangeProperty(c->dpy, req->requestor, req->property ? req->property : req->target,
                            c->utf8_string, 8, PropModeReplace,
                            (unsigned char *)buf, buflen);
        } else if (buf && buflen > 0 && req->target == XA_STRING) {
            /* 老客户端（部分 xclip/xsel 组合）会要 STRING；UTF-8 内容原样给出 */
            XChangeProperty(c->dpy, req->requestor, req->property ? req->property : req->target,
                            XA_STRING, 8, PropModeReplace,
                            (unsigned char *)buf, buflen);
        } else if (req->target == XInternAtom(c->dpy, "TARGETS", False)) {
            Atom targets[3] = { c->utf8_string, XA_STRING,
                                XInternAtom(c->dpy, "TEXT", False) };
            XChangeProperty(c->dpy, req->requestor, req->property ? req->property : req->target,
                            XA_ATOM, 32, PropModeReplace,
                            (unsigned char *)targets, 3);
        } else {
            res.property = None; /* 其余 target 拒绝 */
        }
        XSendEvent(c->dpy, req->requestor, False, 0, (XEvent *)&res);
        XFlush(c->dpy);
        return 0;
    }
    case SelectionClear: {
        if (ev.xselectionclear.selection == c->clipboard) {
            free(c->clip_buf);
            c->clip_buf = NULL;
            c->clip_len = 0;
        } else if (ev.xselectionclear.selection == c->primary) {
            free(c->primary_buf);
            c->primary_buf = NULL;
            c->primary_len = 0;
        }
        return 0;
    }
    case SelectionNotify: {
        if (ev.xselection.property == None) return 0;
        Atom type = None;
        int fmt = 0;
        unsigned long n = 0, extra = 0;
        unsigned char *data = NULL;
        if (XGetWindowProperty(c->dpy, c->win, ev.xselection.property, 0, 65536, True,
                               c->utf8_string, &type, &fmt, &n, &extra, &data) != Success)
            return 0;
        if (!data || n == 0) {
            if (data) XFree(data);
            return 0;
        }
        out->type = TTY_EV_PASTE;
        int len = (int)n < (int)sizeof(out->text) - 1 ? (int)n : (int)sizeof(out->text) - 1;
        memcpy(out->text, data, (size_t)len);
        out->text[len] = 0;
        out->text_len = len;
        XFree(data);
        return 1;
    }
    case ButtonRelease: {
        out->type = TTY_EV_BUTTON_RELEASE;
        out->button = (int)ev.xbutton.button;
        out->x = ev.xbutton.x;
        out->y = ev.xbutton.y;
        out->state = ev.xbutton.state;
        return 1;
    }
    case MotionNotify: {
        out->type = TTY_EV_MOTION;
        out->button = 1;
        out->x = ev.xmotion.x;
        out->y = ev.xmotion.y;
        out->state = ev.xmotion.state;
        return 1;
    }
    case MappingNotify: {
        /* xdotool 等工具为输入非 ASCII 字符会临时改键盘映射再还原；
         * 不刷新 Xlib 的映射缓存就会把这类按键读成 NoSymbol（丢字）。 */
        XRefreshKeyboardMapping(&ev.xmapping);
        return 0;
    }
    case Expose: {
        if (ev.xexpose.count != 0) return 0;
        out->type = TTY_EV_EXPOSE;
        out->width = c->w;
        out->height = c->h;
        return 1;
    }
    case ClientMessage: {
        Atom kind = (Atom)ev.xclient.data.l[0];
        if (kind == c->wm_delete) {
            out->type = TTY_EV_CLOSE;
            return 1;
        }
        if (kind == c->wm_take_focus) {
            /* i3/awesome/dwm 这类 WM 不发 XSetInputFocus，而是让我们自己取焦点 */
            tty_focus_window(c);
            return 0;
        }
        return 0;
    }
    case DestroyNotify: {
        out->type = TTY_EV_CLOSE;
        return 1;
    }
    default:
        return 0;
    }
}

void tty_present(void *ctx, const uint32_t *pixels, int width, int height) {
    struct tty_ctx *c = ctx;
    if (c && c->use_gl) {
        gl_present(c, pixels, width, height);
        return;
    }
    if (!c || !c->img) return;
    if (width != c->img->width || height != c->img->height) return;
    int bpl = c->img->bytes_per_line;
    unsigned char *dst = (unsigned char *)c->img->data;
    for (int y = 0; y < height; y++) {
        memcpy(dst + (size_t)y * (size_t)bpl, pixels + (size_t)y * (size_t)width,
               (size_t)width * 4);
    }
    if (c->shm_ok)
        XShmPutImage(c->dpy, c->win, c->gc, c->img, 0, 0, 0, 0,
                     (unsigned)width, (unsigned)height, False);
    else
        XPutImage(c->dpy, c->win, c->gc, c->img, 0, 0, 0, 0,
                  (unsigned)width, (unsigned)height);
    XFlush(c->dpy);
}

static int gl_error_seen = 0;
static int gl_error_handler(Display *dpy, XErrorEvent *ev) {
    (void)dpy;
    (void)ev;
    gl_error_seen++;
    return 0; /* 吞掉，交给调用方降级 */
}

static GLuint compile_shader(GLenum type, const char *src) {
    GLuint sh = glCreateShader(type);
    glShaderSource(sh, 1, &src, NULL);
    glCompileShader(sh);
    GLint ok = 0;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetShaderInfoLog(sh, sizeof(log), NULL, log);
        fprintf(stderr, "leantty: shader compile failed: %s\n", log);
        glDeleteShader(sh);
        return 0;
    }
    return sh;
}

static int gl_init(struct tty_ctx *c, int width, int height) {
    if (c->gl.ready) return 1;
    /* 上下文必须用与窗口相同的 visual，否则 glXMakeCurrent 会 BadMatch。
     * 窗口是默认 visual，因此在 FBConfig 里找 visualid 相同的那一个。 */
    if (!c->gl_vi) {
        int n = 0;
        int fb_attribs[] = { GLX_DOUBLEBUFFER, True, GLX_RED_SIZE, 8, GLX_GREEN_SIZE, 8,
                             GLX_BLUE_SIZE, 8, None };
        GLXFBConfig *cfgs = glXChooseFBConfig(c->dpy, DefaultScreen(c->dpy), fb_attribs, &n);
        if (!cfgs) return 0;
        unsigned long want = XVisualIDFromVisual(DefaultVisual(c->dpy, DefaultScreen(c->dpy)));
        for (int i = 0; i < n; i++) {
            XVisualInfo *vi = glXGetVisualFromFBConfig(c->dpy, cfgs[i]);
            if (!vi) continue;
            if (XVisualIDFromVisual(vi->visual) == want) {
                c->gl_vi = vi;
                break;
            }
            XFree(vi);
        }
        XFree(cfgs);
        if (!c->gl_vi) return 0; /* 没有匹配的 GLX visual → 回落 CPU */
    }
    gl_error_seen = 0;
    XErrorHandler old_handler = XSetErrorHandler(gl_error_handler);
    c->gl.ctx = glXCreateContext(c->dpy, c->gl_vi, NULL, GL_TRUE);
    if (c->gl.ctx) (void)glXMakeCurrent(c->dpy, c->win, c->gl.ctx);
    XSync(c->dpy, False);
    XSetErrorHandler(old_handler);
    if (!c->gl.ctx || gl_error_seen != 0 || glXGetCurrentContext() == NULL) {
        if (c->gl.ctx) glXDestroyContext(c->dpy, c->gl.ctx);
        c->gl.ctx = NULL;
        return 0;
    }

    const char *vs_src =
        "attribute vec2 a_pos;\n"
        "attribute vec2 a_uv;\n"
        "varying vec2 v_uv;\n"
        "void main() { v_uv = a_uv; gl_Position = vec4(a_pos, 0.0, 1.0); }\n";
    const char *fs_src =
        "uniform sampler2D u_tex;\n"
        "varying vec2 v_uv;\n"
        "void main() { gl_FragColor = texture2D(u_tex, v_uv); }\n";

    GLuint vs = compile_shader(GL_VERTEX_SHADER, vs_src);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, fs_src);
    if (!vs || !fs) return 0;
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glLinkProgram(prog);
    GLint linked = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &linked);
    glDeleteShader(vs);
    glDeleteShader(fs);
    if (!linked) {
        char log[512];
        glGetProgramInfoLog(prog, sizeof(log), NULL, log);
        fprintf(stderr, "leantty: program link failed: %s\n", log);
        glDeleteProgram(prog);
        return 0;
    }
    c->gl.prog = prog;
    c->gl.tex_uniform = glGetUniformLocation(prog, "u_tex");

    glGenTextures(1, &c->gl.tex);
    glBindTexture(GL_TEXTURE_2D, c->gl.tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_BGRA,
                 GL_UNSIGNED_BYTE, NULL);
    c->gl.tex_w = width;
    c->gl.tex_h = height;
    /* 关闭 vsync：我们的主循环自己做帧预算，若 swap 阻塞在 60Hz，
     * 每次循环只能消化一轮 PTY 数据（实测 5MB 输出要 39 秒）。 */
    {
        typedef void (*pfn_swap_interval_ext)(Display *, GLXDrawable, int);
        typedef int (*pfn_swap_interval_mesa)(unsigned int);
        pfn_swap_interval_ext set_ext =
            (pfn_swap_interval_ext)glXGetProcAddress((const GLubyte *)"glXSwapIntervalEXT");
        if (set_ext)
            set_ext(c->dpy, c->win, 0);
        else {
            pfn_swap_interval_mesa set_mesa =
                (pfn_swap_interval_mesa)glXGetProcAddress((const GLubyte *)"glXSwapIntervalMESA");
            if (set_mesa) set_mesa(0);
        }
        if (getenv("LEANTTY_KDBG")) {
            typedef int (*pfn_get_interval)(void);
            pfn_get_interval get_mesa =
                (pfn_get_interval)glXGetProcAddress((const GLubyte *)"glXGetSwapIntervalMESA");
            const char *rz = (const char *)glGetString(GL_RENDERER);
            fprintf(stderr, "gl: renderer=%s swap_interval=%d\n",
                    rz ? rz : "?", get_mesa ? get_mesa() : -1);
        }
    }
    c->gl.ready = 1;
    return 1;
}

/* ---------------- GPU 直画：字形图集 + quad ---------------- */
/* 顶点格式（与 Zig 侧 buildGpuFrame 一致）：
 *   bg:    float x, y;            u8 r,g,b,a   → 16 字节
 *   glyph: float x, y, u, v;      u8 r,g,b,a   → 24 字节
 */
#define BG_VERT_SIZE 16
#define GLYPH_VERT_SIZE 24

static const char *GPU_VS =
    "attribute vec2 a_pos;\n"
    "attribute vec4 a_color;\n"
    "uniform vec2 u_size;\n"
    "varying vec4 v_color;\n"
    "void main(){ vec2 p = a_pos / u_size * 2.0 - 1.0; gl_Position = vec4(p.x, -p.y, 0.0, 1.0); v_color = a_color; }\n";
static const char *GPU_FS_BG =
    "varying vec4 v_color;\n"
    "void main(){ gl_FragColor = v_color; }\n";
static const char *GPU_VS_G =
    "attribute vec2 a_pos;\n"
    "attribute vec2 a_uv;\n"
    "attribute vec4 a_color;\n"
    "uniform vec2 u_size;\n"
    "varying vec2 v_uv;\n"
    "varying vec4 v_color;\n"
    "void main(){ vec2 p = a_pos / u_size * 2.0 - 1.0; gl_Position = vec4(p.x, -p.y, 0.0, 1.0); v_uv = a_uv; v_color = a_color; }\n";
static const char *GPU_FS_G =
    "uniform sampler2D u_atlas;\n"
    "varying vec2 v_uv;\n"
    "varying vec4 v_color;\n"
    "void main(){ vec4 t = texture2D(u_atlas, v_uv); gl_FragColor = vec4(v_color.rgb, v_color.a * t.a); }\n";

static GLuint gpu_prog(const char *vs, const char *fs) {
    GLuint v = compile_shader(GL_VERTEX_SHADER, vs);
    GLuint f = compile_shader(GL_FRAGMENT_SHADER, fs);
    if (!v || !f) return 0;
    GLuint p = glCreateProgram();
    glAttachShader(p, v);
    glAttachShader(p, f);
    glBindAttribLocation(p, 0, "a_pos");
    glBindAttribLocation(p, 1, "a_color");
    glBindAttribLocation(p, 2, "a_uv");
    glLinkProgram(p);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    glDeleteShader(v);
    glDeleteShader(f);
    if (!ok) {
        char log[512];
        glGetProgramInfoLog(p, sizeof(log), NULL, log);
        fprintf(stderr, "leantty: gpu program link failed: %s\n", log);
        return 0;
    }
    return p;
}

static int gpu_init(struct tty_ctx *c) {
    if (c->gl.gpu_ok) return 1;
    if (!c->gl.ready) return 0;
    c->gl.prog_bg = gpu_prog(GPU_VS, GPU_FS_BG);
    c->gl.prog_glyph = gpu_prog(GPU_VS_G, GPU_FS_G);
    if (!c->gl.prog_bg || !c->gl.prog_glyph) return 0;

    c->gl.atlas_size = 2048;
    c->gl.atlas_x = 1;
    c->gl.atlas_y = 1;
    c->gl.atlas_row_h = 0;
    glGenTextures(1, &c->gl.atlas_tex);
    glBindTexture(GL_TEXTURE_2D, c->gl.atlas_tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, c->gl.atlas_size, c->gl.atlas_size, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, NULL);

    glGenBuffers(1, &c->gl.vbo_bg);
    glGenBuffers(1, &c->gl.vbo_glyph);
    glDisable(GL_DEPTH_TEST);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    c->gl.gpu_ok = 1;
    return 1;
}

/* 把一个字形（灰度 mask 或 BGRA）放进图集，返回 UV（0..1）。
 * mask_bgra=0 时 bytes 是 w*h 的灰度；=1 时是 w*h*4 的 BGRA（彩色 emoji）。 */
int tty_gl_atlas_put(void *ctx, const unsigned char *bytes, int w, int h, int bgra,
                    float *uv4) {
    struct tty_ctx *c = (struct tty_ctx *)ctx;
    if (!c || !gpu_init(c) || w <= 0 || h <= 0) return 0;
    int pad = 1;
    if (c->gl.atlas_x + w + pad >= c->gl.atlas_size) {
        c->gl.atlas_x = 1;
        c->gl.atlas_y += c->gl.atlas_row_h + pad;
        c->gl.atlas_row_h = 0;
    }
    if (c->gl.atlas_y + h + pad >= c->gl.atlas_size) return 0; /* 图集满：调用方清空重试 */

    unsigned char *tmp = malloc((size_t)w * h * 4);
    if (!tmp) return 0;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            unsigned char *d = tmp + ((size_t)y * w + x) * 4;
            if (bgra) {
                const unsigned char *p = bytes + ((size_t)y * w + x) * 4;
                d[0] = p[2]; d[1] = p[1]; d[2] = p[0]; d[3] = p[3];
            } else {
                unsigned char a = bytes[(size_t)y * w + x];
                d[0] = 255; d[1] = 255; d[2] = 255; d[3] = a;
            }
        }
    }
    glBindTexture(GL_TEXTURE_2D, c->gl.atlas_tex);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glTexSubImage2D(GL_TEXTURE_2D, 0, c->gl.atlas_x, c->gl.atlas_y, w, h,
                    GL_RGBA, GL_UNSIGNED_BYTE, tmp);
    free(tmp);

    float sx = 1.0f / (float)c->gl.atlas_size;
    uv4[0] = (float)c->gl.atlas_x * sx;
    uv4[1] = (float)c->gl.atlas_y * sx;
    uv4[2] = (float)(c->gl.atlas_x + w) * sx;
    uv4[3] = (float)(c->gl.atlas_y + h) * sx;
    c->gl.atlas_x += w + pad;
    if (h > c->gl.atlas_row_h) c->gl.atlas_row_h = h;
    return 1;
}

void tty_gl_atlas_reset(void *ctx) {
    struct tty_ctx *c = (struct tty_ctx *)ctx;
    if (!c || !c->gl.gpu_ok) return;
    c->gl.atlas_x = 1;
    c->gl.atlas_y = 1;
    c->gl.atlas_row_h = 0;
}

/* 提交一帧：bg 顶点（纯色）+ glyph 顶点（图集），然后交换缓冲。 */
void tty_gl_draw(void *ctx, int width, int height,
                 const void *bg_verts, int bg_bytes,
                 const void *glyph_verts, int glyph_bytes) {
    struct tty_ctx *c = (struct tty_ctx *)ctx;
    if (!c || !c->use_gl || !c->gl.ready) return;
    /* 必须先 makeCurrent 再初始化 GL 对象：没有当前上下文时 glGenTextures / glTexImage2D
     * 等调用不会生效，后续绘制就是全黑。 */
    glXMakeCurrent(c->dpy, c->win, c->gl.ctx);
    if (!gpu_init(c)) return;
    glViewport(0, 0, width, height);
    glClearColor(0.f, 0.f, 0.f, 1.f);
    glClear(GL_COLOR_BUFFER_BIT);

    if (bg_bytes > 0) {
        glUseProgram(c->gl.prog_bg);
        GLint uloc = glGetUniformLocation(c->gl.prog_bg, "u_size");
        glUniform2f(uloc, (float)width, (float)height);
        glBindBuffer(GL_ARRAY_BUFFER, c->gl.vbo_bg);
        glBufferData(GL_ARRAY_BUFFER, bg_bytes, bg_verts, GL_STREAM_DRAW);
        glEnableVertexAttribArray(0);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, BG_VERT_SIZE, 0);
        glVertexAttribPointer(1, 4, GL_UNSIGNED_BYTE, GL_TRUE, BG_VERT_SIZE,
                              (void *)(2 * sizeof(GLfloat)));
        glDrawArrays(GL_TRIANGLES, 0, bg_bytes / BG_VERT_SIZE);
    }
    if (glyph_bytes > 0) {
        glUseProgram(c->gl.prog_glyph);
        GLint uloc = glGetUniformLocation(c->gl.prog_glyph, "u_size");
        glUniform2f(uloc, (float)width, (float)height);
        glUniform1i(glGetUniformLocation(c->gl.prog_glyph, "u_atlas"), 0);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, c->gl.atlas_tex);
        glBindBuffer(GL_ARRAY_BUFFER, c->gl.vbo_glyph);
        glBufferData(GL_ARRAY_BUFFER, glyph_bytes, glyph_verts, GL_STREAM_DRAW);
        glEnableVertexAttribArray(0);
        glEnableVertexAttribArray(1);
        glEnableVertexAttribArray(2);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, GLYPH_VERT_SIZE, 0);
        glVertexAttribPointer(1, 4, GL_UNSIGNED_BYTE, GL_TRUE, GLYPH_VERT_SIZE,
                              (void *)(4 * sizeof(GLfloat)));
        glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, GLYPH_VERT_SIZE,
                              (void *)(2 * sizeof(GLfloat)));
        glDrawArrays(GL_TRIANGLES, 0, glyph_bytes / GLYPH_VERT_SIZE);
    }
    glXSwapBuffers(c->dpy, c->win);
}

static void gl_present(struct tty_ctx *c, const uint32_t *pixels, int width, int height) {
    if (!c->gl.ready) return;
    glXMakeCurrent(c->dpy, c->win, c->gl.ctx);

    glViewport(0, 0, width, height);
    glBindTexture(GL_TEXTURE_2D, c->gl.tex);
    if (width != c->gl.tex_w || height != c->gl.tex_h) {
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_BGRA,
                     GL_UNSIGNED_BYTE, pixels);
        c->gl.tex_w = width;
        c->gl.tex_h = height;
    } else {
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_BGRA,
                        GL_UNSIGNED_BYTE, pixels);
    }

    glUseProgram(c->gl.prog);
    glUniform1i(c->gl.tex_uniform, 0);
    /* 两个三角形覆盖整个 NDC；uv 上下翻转（帧缓冲是自上而下） */
    static const GLfloat verts[] = {
        -1.f, -1.f, 0.f, 1.f,  1.f, -1.f, 1.f, 1.f,  1.f, 1.f, 1.f, 0.f,
        -1.f, -1.f, 0.f, 1.f,  1.f,  1.f, 1.f, 0.f, -1.f, 1.f, 0.f, 0.f,
    };
    GLint pos_loc = glGetAttribLocation(c->gl.prog, "a_pos");
    GLint uv_loc = glGetAttribLocation(c->gl.prog, "a_uv");
    glEnableVertexAttribArray((GLuint)pos_loc);
    glEnableVertexAttribArray((GLuint)uv_loc);
    glVertexAttribPointer((GLuint)pos_loc, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), verts);
    glVertexAttribPointer((GLuint)uv_loc, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), verts + 2);
    glDrawArrays(GL_TRIANGLES, 0, 6);
    glXSwapBuffers(c->dpy, c->win);
}

/* ---------------- 字体：fontconfig 查文件 + FreeType 光栅化 ---------------- */

#define LEANTTY_MAX_FACES 8

/* ---- 字体：fontconfig 选文件（支持 style）+ FreeType 光栅化（分样式）---- */

#define LEANTTY_MAX_FACES 8
#define LEANTTY_STYLE_COUNT 4 /* normal / bold / italic / bold-italic */

/* 字体层已抽到平台无关的 font_ft.c（Linux/Windows 共用）。
 * 这里只保留 fontconfig 的"家族名 → 字体文件路径"解析，然后把路径表交给 ft_font。 */

/* 用 fontconfig 把 (family, style) 解析成字体文件路径；style 里含 Bold/Italic 时
 * 通过 FC_WEIGHT / FC_SLANT 参与匹配。 */
static int resolve_font_file_styled(const char *family, const char *style, char *path, size_t cap) {
    FcPattern *pat = FcPatternCreate();
    if (!pat) return 0;
    const char *want = (family && family[0]) ? family : "monospace";
    FcPatternAddString(pat, FC_FAMILY, (const FcChar8 *)want);
    if (style && style[0]) {
        int bold = strstr(style, "Bold") != NULL;
        int italic = (strstr(style, "Italic") != NULL) || (strstr(style, "Oblique") != NULL);
        FcPatternAddInteger(pat, FC_WEIGHT, bold ? FC_WEIGHT_BOLD : FC_WEIGHT_REGULAR);
        FcPatternAddInteger(pat, FC_SLANT, italic ? FC_SLANT_ITALIC : FC_SLANT_ROMAN);
    }
    FcConfigSubstitute(NULL, pat, FcMatchPattern);
    FcDefaultSubstitute(pat);
    FcResult res = FcResultNoMatch;
    FcPattern *match = FcFontMatch(NULL, pat, &res);
    FcPatternDestroy(pat);
    if (!match) return 0;
    FcChar8 *file = NULL;
    int ok = 0;
    if (FcPatternGetString(match, FC_FILE, 0, &file) == FcResultMatch && file) {
        snprintf(path, cap, "%s", (const char *)file);
        ok = 1;
    }
    FcPatternDestroy(match);
    return ok;
}

/* styles[i] = {family, style}，i 顺序为 normal/bold/italic/bold_italic；
 * family 为 NULL 时回落到 styles[0] 的 family，style 为 NULL 时按 i 推断。 */
static void *open_impl(const tty_font_style *styles, int n_styles,
                       const char *const *fallbacks, int n_fallbacks,
                       int pixel_size, char *path_out, int path_cap) {
    if (!FcInit()) return NULL;
    static const char *default_styles[LEANTTY_STYLE_COUNT] = {
        "Regular", "Bold", "Italic", "Bold Italic"
    };
    /* 路径缓冲：样式槽 4 个 + 回退链。字符串必须在 ft_font_open 期间保持有效，
     * ft_font 会保留指针用于去重比较，故用静态/长效缓冲。 */
    static char path_bufs[FT_FONT_MAX_FACES][1024];
    const char *paths[FT_FONT_MAX_FACES];
    int n_paths = 0;
    for (int i = 0; i < FT_FONT_MAX_FACES; i++) paths[i] = NULL;

    const char *base_family = (n_styles > 0 && styles[0].family) ? styles[0].family : "monospace";
    for (int i = 0; i < LEANTTY_STYLE_COUNT; i++) {
        const char *fam = base_family;
        const char *sty = default_styles[i];
        if (i < n_styles) {
            if (styles[i].family && styles[i].family[0]) fam = styles[i].family;
            if (styles[i].style && styles[i].style[0]) sty = styles[i].style;
        }
        if (resolve_font_file_styled(fam, sty, path_bufs[n_paths], sizeof(path_bufs[0]))) {
            if (i == 0 && path_out && path_cap > 0)
                snprintf(path_out, (size_t)path_cap, "%s", path_bufs[n_paths]);
            paths[n_paths] = path_bufs[n_paths];
            n_paths++;
        }
    }
    if (n_paths == 0) return NULL;
    for (int i = 0; i < n_fallbacks && n_paths < FT_FONT_MAX_FACES; i++) {
        if (!fallbacks[i]) continue;
        if (!resolve_font_file_styled(fallbacks[i], "Regular", path_bufs[n_paths], sizeof(path_bufs[0])))
            continue;
        paths[n_paths] = path_bufs[n_paths];
        n_paths++;
    }
    return ft_font_open(paths, n_paths, LEANTTY_STYLE_COUNT, pixel_size);
}

void *tty_font_open_styled(const tty_font_style *styles, int n_styles,
                           const char *const *fallbacks, int n_fallbacks,
                           int pixel_size, char *path_out, int path_cap) {
    return open_impl(styles, n_styles, fallbacks, n_fallbacks, pixel_size, path_out, path_cap);
}

void *tty_font_open_multi(const char *const *families, int count, int pixel_size,
                          char *path_out, int path_cap) {
    tty_font_style styles[LEANTTY_STYLE_COUNT];
    for (int i = 0; i < LEANTTY_STYLE_COUNT; i++) {
        styles[i].family = (count > 0) ? families[0] : NULL;
        styles[i].style = NULL;
    }
    return open_impl(styles, LEANTTY_STYLE_COUNT, families, count > 0 ? count - 1 : 0,
                     pixel_size, path_out, path_cap);
}

void *tty_font_open(const char *family, int pixel_size, char *path_out, int path_cap) {
    tty_font_style styles[LEANTTY_STYLE_COUNT];
    for (int i = 0; i < LEANTTY_STYLE_COUNT; i++) {
        styles[i].family = family;
        styles[i].style = NULL;
    }
    return open_impl(styles, LEANTTY_STYLE_COUNT, NULL, 0, pixel_size, path_out, path_cap);
}

void tty_font_close(void *handle) { ft_font_close((ft_font *)handle); }

int tty_font_metrics(void *handle, int *ascent, int *descent, int *line_height, int *advance) {
    return ft_font_metrics((ft_font *)handle, ascent, descent, line_height, advance);
}

int tty_glyph_styled_ex(void *handle, uint32_t codepoint, int style,
                        unsigned char *out, int cap,
                        int *gw, int *gh, int *left, int *top, int *advance,
                        int *bpp, int *premul) {
    return ft_font_glyph((ft_font *)handle, codepoint, style, out, cap,
                         gw, gh, left, top, advance, bpp, premul);
}

int tty_glyph_styled(void *handle, uint32_t codepoint, int style,
                     unsigned char *out, int cap,
                     int *gw, int *gh, int *left, int *top, int *advance) {
    return ft_font_glyph((ft_font *)handle, codepoint, style, out, cap,
                         gw, gh, left, top, advance, NULL, NULL);
}

int tty_glyph(void *handle, uint32_t codepoint, unsigned char *out, int cap,
              int *gw, int *gh, int *left, int *top, int *advance) {
    return ft_font_glyph((ft_font *)handle, codepoint, 0, out, cap,
                         gw, gh, left, top, advance, NULL, NULL);
}

static int focus_error_seen = 0;
static int focus_error_handler(Display *dpy, XErrorEvent *ev) {
    (void)dpy;
    (void)ev;
    focus_error_seen++;
    return 0;
}

/* 读取 X 资源里的 Xft.dpi（没有则返回 0）。
 * 终端字号按"点"给出时，像素大小 = 点 * dpi / 72；
 * alacritty 就是这个口径（16pt @144dpi = 32px），我们此前当像素用，字只有一半大。 */
int tty_x_dpi(void) {
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) return 0;
    int dpi = 0;
    char *res = XResourceManagerString(dpy);
    if (res) {
        const char *key = "Xft.dpi:";
        for (const char *p = res; p && *p; p = strchr(p, '\n')) {
            if (*p == '\n') p++;
            if (strncmp(p, key, strlen(key)) != 0) continue;
            const char *v = p + strlen(key);
            while (*v == ' ' || *v == '\t') v++;
            int n = atoi(v);
            if (n > 0) dpi = n;
            break;
        }
    }
    XCloseDisplay(dpy);
    return dpi;
}

void tty_set_title(void *ctx, const char *title) {
    struct tty_ctx *c = ctx;
    if (!c || !c->win) return;
    XStoreName(c->dpy, c->win, title ? title : "tty");
    XFlush(c->dpy);
}

void tty_focus_window(void *ctx) {
    struct tty_ctx *c = ctx;
    if (!c || !c->win) return;
    XWindowAttributes attr;
    if (!XGetWindowAttributes(c->dpy, c->win, &attr)) return;
    /* 只有已映射（IsViewable）才取焦点，否则 XSetInputFocus 会 BadMatch（致命） */
    if (attr.map_state != IsViewable) return;
    focus_error_seen = 0;
    XErrorHandler old = XSetErrorHandler(focus_error_handler);
    XSetInputFocus(c->dpy, c->win, RevertToParent, CurrentTime);
    XSync(c->dpy, False);
    XSetErrorHandler(old);
}
