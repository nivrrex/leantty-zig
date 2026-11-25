/* leantty-zig 的 C 绑定层。
 *
 * 为什么有这一层：Zig 0.17 移除了内建 @cImport，官方替代是 translate_c 包；
 * 本工程同时依赖 ghostty（其构建图里也有 translate_c），把同一个包再以 path
 * 依赖引入会造成模块身份冲突。因此 X11 / SHM / fontconfig / FreeType 这四个
 * 系统 C 库改为薄 shim：C 侧见到真实头文件（结构体布局由编译器保证），
 * Zig 侧只声明本文件导出的扁平接口。
 */
#ifndef LEANTTY_SHIM_H
#define LEANTTY_SHIM_H

#include <stdint.h>

/* 事件类型 */
enum {
    TTY_EV_KEY = 1,
    TTY_EV_RESIZE = 2,
    TTY_EV_EXPOSE = 3,
    TTY_EV_CLOSE = 4,
    TTY_EV_BUTTON = 5,
    TTY_EV_PASTE = 6,
    TTY_EV_MOTION = 7,
    TTY_EV_BUTTON_RELEASE = 8,
    TTY_EV_FOCUS_IN = 9,
    TTY_EV_FOCUS_OUT = 10,
    /* 修饰键释放（Shift/Control/Alt/Meta/Super）：rime 的 Shift 切换中英文
     * 依赖"按下+释放"这一对事件，普通按键释放不上报。 */
    TTY_EV_KEY_RELEASE = 11,
};

typedef struct {
    int type;
    int width;   /* resize: 新像素宽 */
    int height;  /* resize: 新像素高 */
    unsigned int keycode;
    unsigned int state;
    unsigned int keysym;
    /* XIM 提交的文本（UTF-8）。text_len>0 时表示这是输入法上屏，应直写 PTY。 */
    int text_len;
    char text[128];
    /* 鼠标按键：button 1..5（4/5 为滚轮），x/y 为窗口内像素坐标。 */
    int button;
    int x;
    int y;
} tty_event;

void *tty_open(int width, int height, const char *title);
/* x/y < 0 时交给 WM 决定位置。 */
void *tty_open_at(int width, int height, const char *title, int x, int y);
void tty_close(void *ctx);
/* 返回 1 表示写入一个事件到 out，0 表示当前没有待处理事件。 */
int tty_next_event(void *ctx, tty_event *out);
/* 把 ARGB(0x00RRGGBB, 小端字节序 B,G,R,X) 像素推到窗口。 */
void tty_present(void *ctx, const uint32_t *pixels, int width, int height);

/* GPU 直画：字形图集 + 顶点提交（见 shim.c 的 tty_gl_* 实现）。 */
int tty_gl_atlas_put(void *ctx, const unsigned char *bytes, int w, int h, int bgra,
                     float *uv4);
void tty_gl_atlas_reset(void *ctx);
void tty_gl_draw(void *ctx, int width, int height,
                 const void *bg_verts, int bg_bytes,
                 const void *glyph_verts, int glyph_bytes);
/* 剪贴板：设为 CLIPBOARD owner（供程序 OSC 52 写入用）。 */
void tty_clipboard_set(void *ctx, const char *utf8, int len);
/* which: 0=CLIPBOARD, 1=PRIMARY。 */
void tty_clipboard_set_primary(void *ctx, const char *utf8, int len, int which);
/* 剪贴板：异步请求 CLIPBOARD 内容，结果以 TTY_EV_PASTE 事件返回。
 *
 * 事件里只放"有粘贴"这个信号，真正的文本用 tty_paste_take() 取：
 * 事件结构里的 text[] 只有 128 字节，早前直接把内容截断复制进去，
 * 超过 127 字节的粘贴会被切在任意字节上（中文被切成半个字符 → 乱码）。
 * tty_paste_take 返回的指针在 tty_paste_done() 之前有效（所有者仍是 ctx）。 */
const unsigned char *tty_paste_take(void *c, int *len);
void tty_paste_done(void *c);
/* which: 0=CLIPBOARD, 1=PRIMARY。 */
int tty_clipboard_request(void *ctx, int which);
/* 读文件到 buf（用于配置文件）；返回字节数，失败返回 -1。 */
int tty_read_file(const char *path, char *buf, int cap);
/* 文件是否存在（1/0）；只做 stat，不打开。 */
int tty_file_exists(const char *path);
/* 登录 shell（/etc/passwd 的 pw_shell），没有返回 NULL。缓冲区归 shim 所有。 */
const char *tty_login_shell(void);
/* 文件 mtime（纳秒；失败 -1）与字节数（*size；失败 -1）。配置热加载用它检测变化。 */
int64_t tty_file_stamp(const char *path, int64_t *size);
/* 启用 GPU 呈现（GLX + 纹理四边形）；失败返回 0，调用方回落 SHM。 */
int tty_gl_enable(void *ctx);
/* 关掉 XIM（与 IBus 直连同时启用会互相抢键，二者只能留一个）。 */
void tty_x11_disable_xim(void *ctx);
void tty_resize(void *ctx, int width, int height);
int tty_fd(void *ctx); /* X11 连接 fd，供 poll 使用 */

/* 字体：family 为 NULL 时用 monospace。返回句柄，失败为 NULL。 */
void *tty_font_open(const char *family, int pixel_size, char *path_out, int path_cap);
/* 多字体：主字体 + 回退链（按顺序找第一个含有该码点的字体）。 */
void *tty_font_open_multi(const char *const *families, int count, int pixel_size,
                          char *path_out, int path_cap);

/* 分样式字体：styles 依次为 normal/bold/italic/bold_italic 的 {family, style}，
 * 允许 family/style 为 NULL 表示回落到 normal。 */
typedef struct {
    const char *family;
    const char *style;
} tty_font_style;

void *tty_font_open_styled(const tty_font_style *styles, int n_styles,
                           const char *const *fallbacks, int n_fallbacks,
                           int pixel_size, char *path_out, int path_cap);
/* style: 0=normal 1=bold 2=italic 3=bold_italic */
int tty_glyph_styled_ex(void *handle, uint32_t codepoint, int style,
                        unsigned char *out, int cap,
                        int *gw, int *gh, int *left, int *top, int *advance,
                        int *bpp, int *premul);

int tty_glyph_styled(void *handle, uint32_t codepoint, int style,
                     unsigned char *out, int cap,
                     int *gw, int *gh, int *left, int *top, int *advance);
/* 设置窗口标题（OSC 0/2 → dynamic_title）。 */
void tty_set_title(void *ctx, const char *title);
/* 显式取焦点（WM_TAKE_FOCUS / 点击聚焦用），内部带 map_state 检查与错误保护。 */
void tty_focus_window(void *ctx);
void tty_font_close(void *handle);
/* 字体度量：ascent/descent/line_height 为像素；advance 为 'M' 的步进。 */
/* 合成粗体：1 = 缺 Bold 面时用轮廓加粗模拟，0 = 退回常规字重。 */
void tty_font_set_synthetic_bold(void *handle, int on);
int tty_font_metrics(void *handle, int *ascent, int *descent, int *line_height, int *advance);
/* 光栅化一个码点。返回位图字节数（0 表示空字形），失败为 -1。 */
int tty_glyph(void *handle, uint32_t codepoint, unsigned char *out, int cap,
              int *gw, int *gh, int *left, int *top, int *advance);

#endif
