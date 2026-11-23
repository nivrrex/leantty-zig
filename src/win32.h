#ifndef LEANTTY_WIN32_H
#define LEANTTY_WIN32_H

#include <stdint.h>

/* Windows 平台层：ConPTY + GDI/DIB 双缓冲呈现 + IME + 剪贴板 + 鼠标上报。
 *
 * 线程约定：全部函数只在 UI 线程（运行事件循环的那个线程）调用；
 * 内部不使用工作线程，ConPTY 输出用 PeekNamedPipe 轮询。
 * 唯一例外：静态剪贴板函数由同一线程调用，无共享状态之外的可变全局量。 */

enum {
    W32_EV_KEY = 1,    /* vk + state；Zig 侧映射成终端按键序列 */
    W32_EV_CHAR = 2,   /* codepoint（UTF-32，已合并代理对） */
    W32_EV_RESIZE = 3, /* cols/rows + 客户区像素尺寸 */
    W32_EV_CLOSE = 4,
    W32_EV_WHEEL = 5,  /* delta：正 = 上滚 */
    W32_EV_EXPOSE = 6,
    W32_EV_MOUSE = 7,  /* action/button/x/y（客户区像素） */
    W32_EV_FOCUS = 8,  /* x = 1 获得焦点，0 失去焦点 */
    W32_EV_COPY = 9,   /* Ctrl+Shift+C：本机复制（同时吞掉 0x03 回声） */
    W32_EV_PASTE = 10, /* Ctrl+Shift+V：本机粘贴（同时吞掉 0x16 回声） */
};

/* 鼠标动作 */
enum { W32_MOUSE_PRESS = 0, W32_MOUSE_RELEASE = 1, W32_MOUSE_MOTION = 2 };
/* 鼠标按键 */
enum { W32_BTN_LEFT = 1, W32_BTN_RIGHT = 2, W32_BTN_MIDDLE = 3 };

typedef struct {
    int type;
    unsigned int vk;        /* KEY：Win32 虚拟键码 */
    unsigned int codepoint; /* CHAR：Unicode 码点 */
    unsigned int state;     /* bit0 shift, bit1 ctrl, bit2 alt */
    unsigned int action;    /* MOUSE：见 W32_MOUSE_* */
    unsigned int button;    /* MOUSE：见 W32_BTN_* */
    int x, y;               /* MOUSE：客户区像素坐标 */
    int width, height;      /* RESIZE：客户区像素尺寸 */
    int cols, rows;         /* RESIZE：换算后的网格尺寸 */
    int delta;              /* WHEEL：+1/-1 的倍数 */
} w32_event;

/* 单元格（每帧由 Zig 侧填好交给平台层绘制） */
typedef struct {
    uint32_t cp;
    uint32_t fg;
    uint32_t bg;
    /* 0 = 窄，1 = 宽（占两格），2 = 宽字符的续格（不绘制） */
    uint8_t wide;
    /* bit0 粗体，bit1 斜体，bit2 下划线，bit3 删除线 */
    uint8_t attrs;
} w32_cell;

void *w32_open(int cols, int rows, int cell_w, int cell_h, const char *title,
               const char *font_family, int font_px);
void w32_close(void *ctx);

/* 取下一个待处理事件；返回 1 表示 out 有效，0 表示没有更多事件。 */
int w32_next_event(void *ctx, w32_event *out);

enum {
    /* 光标形状（与 app_win.zig 的 cursorShape 对齐） */
    W32_CURSOR_BAR = 0,
    W32_CURSOR_BLOCK = 1,
    W32_CURSOR_UNDERLINE = 2,
    W32_CURSOR_HOLLOW = 3,
};

void w32_present(void *ctx, const w32_cell *cells, int cols, int rows,
                 int cursor_x, int cursor_y, int anchor_x, int anchor_y, int focused,
                 uint32_t default_fg, uint32_t default_bg,
                 int cursor_style, uint32_t cursor_color, uint32_t cursor_text_color);

/* 用 ConPTY 启动子进程；cwd 可为 NULL。返回 0 成功。 */
int w32_spawn(void *ctx, const char *command_line, const char *cwd);
/* 读子进程输出；返回字节数，0 = 暂无数据，-1 = EOF/错误。 */
int w32_read(void *ctx, char *buf, int cap);
/* 写子进程输入（全量写入或放弃剩余）。 */
void w32_write(void *ctx, const char *buf, int len);
/* 子进程是否还在跑。 */
int w32_alive(void *ctx);
/* 通知 ConPTY 新的网格尺寸（跟随窗口）。 */
void w32_resize_pty(void *ctx, int cols, int rows);
/* 当前客户区对应的网格尺寸。 */
void w32_grid(void *ctx, int *cols, int *rows);
/* 当前 DPI 下的格子像素尺寸（字体度量 × DPI 缩放）。 */
void w32_cell_size(void *ctx, int *cell_w, int *cell_h);

void w32_set_title(void *ctx, const char *title);

/* 剪贴板：均为 UTF-8。read 返回字节数，-1 表示无文本或失败。 */
/* 剪贴板读取（UTF-8）。返回写入字节数；cap 不足时返回 -(需要字节数 + 1)，
 * 调用方扩容后可重读；-1 表示无文本或打开剪贴板失败。 */
int w32_clipboard_read(char *buf, int cap);
void w32_clipboard_write(const char *utf8, int len);

/* 读整个文件；返回字节数（-1 失败）。 */
int w32_read_file(const char *path, char *buf, int cap);
/* 文件是否存在（1/0，UTF-8 路径）。 */
int w32_file_exists(const char *path);

#endif
