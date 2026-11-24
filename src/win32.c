/* Windows 平台层实现。
 *
 * 结构：
 *   1. UTF-8/UTF-16 转换
 *   2. 字形缓存 + DIB 双缓冲呈现
 *   3. 窗口过程（键盘 / 鼠标 / 尺寸 / DPI / IME）
 *   4. ConPTY 会话（动态解析 kernel32 导出，Win10 1809 之前会明确失败）
 *   5. 剪贴板
 *
 * 线程安全：所有可变状态都在 struct w32_ctx 里，只在 UI 线程访问；
 * 文件级只有一个静态剪贴板指针（单实例程序），同样只在 UI 线程读写。 */

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00 /* 构建命令里也传了，这里兜底 */
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <imm.h>
#include <stdio.h>
#include <io.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "win32.h"
#include "font_ft.h"

#include <ft2build.h>
#include FT_FREETYPE_H

#ifndef PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
/* 老 SDK 头文件里没有；数值来自 winbase.h 的 ProcThreadAttributeValue 定义。 */
#define PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE \
    ProcThreadAttributeValue(22, FALSE, TRUE, FALSE)
#endif

#define GLYPH_CACHE_SLOTS 2048
#define EVENT_QUEUE_LEN 512
#define MAX_FONTS 9

typedef struct {
    uint32_t key; /* 0 = 空槽 */
    int w, h;
    uint8_t *alpha;   /* 灰度覆盖度（bpp=1） */
    uint8_t *color;   /* BGRA 预乘（bpp=4，彩色 emoji） */
    int bpp;
    int pad_top;      /* 位图上方额外补的行数（字形高于格子时用于溢出绘制） */
    int pad_bottom;   /* 位图下方额外补的行数 */
    /* 两个缓冲区的容量必须分开记：灰度按 w*h 字节、彩色按 w*h*4 字节。
     * 共用一个 cap 时，"先彩色后灰度"会以彩色的容量判定灰度缓冲够用而跳过分配，
     * 随后 memset 到 NULL/偏小的 alpha 上 —— 表现为花屏与 SIGSEGV（见 REPORT 6.47）。 */
    int cap_alpha;
    int cap_color;
} glyph_entry;

struct w32_ctx {
    HWND hwnd;
    HDC mem_dc;
    HBITMAP dib;
    uint32_t *pixels;
    int buf_w, buf_h;
    int drawn_w, drawn_h;
    int have_frame;

    int cols, rows;
    int cell_w, cell_h;   /* 当前 DPI 下的格子尺寸 */
    int base_cw, base_ch; /* 96 DPI 基准（0 = 按字体度量） */
    int font_px;          /* 配置字号（96 DPI 下的像素高度） */
    int dpi;
    wchar_t face[LF_FACESIZE];
    ft_font *ft;            /* 与 Linux 共用的 FreeType 字体句柄 */

    glyph_entry glyphs[GLYPH_CACHE_SLOTS];

    int closed;
    int layout_ready;   /* 初始布局完成前不推送 RESIZE（避免启动时多次无效 resize） */
    int alive;
    int focused;
    /* 自己跟踪的修饰键状态（bit0 shift / bit1 ctrl / bit2 alt）。
     * 为什么不能只靠 GetKeyState：keybd_event / IME 场景下按 Shift 之后
     * 线程键盘状态可能不保留（实测 Shift+Up 时 GetKeyState(VK_SHIFT)==0，
     * 于是 Shift+方向键被编成普通方向键，见 WINDOWS-FINDINGS-7）。 */
    unsigned int mod_track;
    int pty_cols, pty_rows;   /* ConPTY 当前尺寸（用于跳过同尺寸 resize） */
    int dbg_frame_done;   /* LEANTTY_KDBG：只打印首帧光标状态 */
    int cursor_x, cursor_y;
    int anchor_x, anchor_y;   /* IME 锚点：最近一次"真实"光标格（不受闪烁/隐藏影响） */

    w32_event queue[EVENT_QUEUE_LEN];
    int q_head, q_tail;

    /* 输入状态 */
    int high_surrogate;   /* 待配对的 UTF-16 高位代理 */
    int ime_composing;
    int ime_in_position;      /* position_ime 重入保护（MSCTF 会回调 IME 消息） */
    int ime_px, ime_py;       /* 上次设置的候选窗位置（相同则不重复调用） */
    int swallow_ctrl;         /* 已被快捷键吃掉、需要丢弃的那个控制字符 */
    int ime_mute_echo;      /* IME 结果串已自行提交：丢弃随后的 WM_(IME_)CHAR 回声 */
    int mouse_down;       /* 当前按下的按钮（0 = 没有） */
    int tracking_leave;

    /* ConPTY */
    HANDLE hpc;
    HANDLE in_w;
    HANDLE out_r;
    PROCESS_INFORMATION pi;
    HANDLE job;
    int spawned;

    FILE *trace;
};

typedef HRESULT(WINAPI *pfn_create_pc)(COORD, HANDLE, HANDLE, DWORD, HANDLE *);
typedef HRESULT(WINAPI *pfn_resize_pc)(HANDLE, COORD);
typedef void(WINAPI *pfn_close_pc)(HANDLE);

static pfn_create_pc p_create_pc;
static pfn_resize_pc p_resize_pc;
static pfn_close_pc p_close_pc;

static struct w32_ctx *g_clip_ctx;

/* LEANTTY_KDBG=1 时把窗口/剪贴板/IME 的关键事件打到 stderr。
 * 与 Zig 侧同名开关一致，用于“配置/粘贴/光标”三类问题的现场取证。 */
static int dbg_on(void) {
    static int cached = -1;
    if (cached < 0) cached = getenv("LEANTTY_KDBG") != NULL ? 1 : 0;
    return cached;
}
#define DBG(...)                            do {                                        if (dbg_on()) {                             fprintf(stderr, __VA_ARGS__);             fflush(stderr);                     }                                   } while (0)

/* ------------------------------------------------------------------ */
/* UTF 转换                                                            */
/* ------------------------------------------------------------------ */

static wchar_t *utf8_to_wide(const char *s) {
    if (!s) return NULL;
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (!w) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n) <= 0) {
        free(w);
        return NULL;
    }
    return w;
}

/* UTF-16（含代理对）→ UTF-8。返回写入字节数；空间不足时截断在合法边界。 */
static int wide_to_utf8(const wchar_t *w, int wlen, char *out, int cap) {
    if (!w || wlen <= 0 || cap <= 0) return 0;
    int n = WideCharToMultiByte(CP_UTF8, 0, w, wlen, out, cap, NULL, NULL);
    return n > 0 ? n : 0;
}

/* GUI 子系统下没有控制台：从 cmd/PowerShell 启动时挂到父控制台，
 * 双击启动时把 stdout/stderr 指向 NUL（否则 std.debug.print 会写失败）。
 * 在任何诊断输出之前调用（main 里 Windows 分支第一件事）。 */
/* 流是否还接在有效句柄上（文件 / 管道 / 控制台都算有效）。
 * GUI 子系统启动时 CRT 的 stdout/stderr 可能是无效句柄（fileno<0 或 -1/-2 的 osfhandle）。 */
static int stream_usable(FILE *f) {
    int fd = _fileno(f);
    if (fd < 0) return 0;
    intptr_t h = _get_osfhandle(fd);
    if (h == -1 || h == -2) return 0;
    if (GetFileType((HANDLE)h) == FILE_TYPE_UNKNOWN) return 0;
    return 1;
}

/* GUI 子系统下没有控制台：从 cmd/PowerShell 启动时挂到父控制台，
 * 双击启动时把 stdout/stderr 指向 NUL（否则 std.debug.print 会写失败）。
 * 在任何诊断输出之前调用（main 里 Windows 分支第一件事）。
 *
 * 关键：**只接管无效的流**。0.1.13 曾无条件 freopen，把 `--version > f`、
 * 管道、MSYS bash 这类已经重定向好的 stdout 换成 NUL/CONOUT$，
 * 结果 `--version` / `-h` 没有任何输出（rc 还可能因为写失败变 1）。 */
void w32_init_console(void) {
    /* 幂等：main 在建窗口前就会调用一次（让启动期的 std.debug.print 有输出），
     * app_win 里还会再调一次。第二次直接返回，避免重复 freopen 把流再切一遍。 */
    static int inited = 0;
    if (inited) return;
    inited = 1;
    /* 注意：这里必须用 freopen，不能用 freopen_s —— 本机 mingw 运行库里的
     * freopen_s 只把文件建出来、并不真正把流接上去（实测：文件 0 字节、
     * fprintf 全部丢失），导致 0.1.3 的“从 cmd 启动时诊断出现在该 cmd”失效。 */
    const char *dbgfile = getenv("LEANTTY_KDBG_FILE");
    int out_ok = stream_usable(stdout);
    int err_ok = stream_usable(stderr);

    /* 诊断文件是用户显式要求的，stderr 一律写进去（e2e 依赖这一点）。 */
    if (dbgfile && dbgfile[0]) {
        if (freopen(dbgfile, "a", stderr) != NULL) err_ok = 1;
    }
    if (out_ok && err_ok) return; /* 都已经接在有效句柄上：不要动 */

    int attached = AttachConsole(ATTACH_PARENT_PROCESS) ? 1 : 0;
    if (!out_ok) {
        if (freopen(attached ? "CONOUT$" : "NUL", "w", stdout) != NULL) { /* stdout → 控制台/NUL */ }
    }
    if (!err_ok) {
        if (freopen(attached ? "CONOUT$" : "NUL", "w", stderr) != NULL) { }
    }
}

/* ------------------------------------------------------------------ */
/* 动态入口                                                            */
/* ------------------------------------------------------------------ */

/* 装载 ConPTY 实现。优先用随包的 `conpty.dll`（OpenConsole，Windows Terminal 的实现）：
 *
 * inbox conhost（10.0.19041）在输入侧会把 VT 序列**翻译成键记录**，导致
 * `ESC[200~ / ESC[201~`（括号粘贴）被丢掉、CR 变双 CR；OpenConsole 则把输入当字节流
 * 直通，括号粘贴、kitty 键盘协议的按键都能原样到达子进程。
 * 同机 Rust 版随包带 `conpty.dll`，表现正是"标记能到达"，这解释了同一 ConPTY 下
 * 两个终端行为不同（见 WINDOWS-FINDINGS-7.md §8）。
 *
 * 顺序：exe 同目录 conpty.dll → 系统 conpty.dll → kernel32 自带实现。
 * 任何一步失败都退回下一步，不影响启动。 */
static void load_conpty(void) {
    HMODULE pc = NULL;
    /* 1) 可执行文件同目录 */
    wchar_t exe[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, exe, (DWORD)(sizeof(exe) / sizeof(exe[0])));
    if (n > 0 && n < (DWORD)(sizeof(exe) / sizeof(exe[0]))) {
        wchar_t *slash = wcsrchr(exe, L'\\');
        if (slash) {
            *(slash + 1) = 0;
            wchar_t path[MAX_PATH];
            if (swprintf(path, MAX_PATH, L"%sconpty.dll", exe) > 0) pc = LoadLibraryW(path);
        }
    }
    /* 2) 系统搜索路径（若用户装过 Windows Terminal 并放进 System32/PATH） */
    if (!pc) pc = LoadLibraryW(L"conpty.dll");
    if (pc) {
        p_create_pc = (pfn_create_pc)(void *)GetProcAddress(pc, "CreatePseudoConsole");
        p_resize_pc = (pfn_resize_pc)(void *)GetProcAddress(pc, "ResizePseudoConsole");
        p_close_pc = (pfn_close_pc)(void *)GetProcAddress(pc, "ClosePseudoConsole");
        if (p_create_pc && p_resize_pc && p_close_pc) {
            if (getenv("LEANTTY_KDBG")) fprintf(stderr, "[win] conpty: conpty.dll (OpenConsole)\n");
            return;
        }
        p_create_pc = NULL;
        p_resize_pc = NULL;
        p_close_pc = NULL;
    }
    /* 3) kernel32 自带（inbox conhost） */
    HMODULE k32 = GetModuleHandleW(L"kernel32.dll");
    if (!k32) return;
    p_create_pc = (pfn_create_pc)(void *)GetProcAddress(k32, "CreatePseudoConsole");
    p_resize_pc = (pfn_resize_pc)(void *)GetProcAddress(k32, "ResizePseudoConsole");
    p_close_pc = (pfn_close_pc)(void *)GetProcAddress(k32, "ClosePseudoConsole");
    if (getenv("LEANTTY_KDBG")) fprintf(stderr, "[win] conpty: kernel32 (inbox conhost)\n");
}

/* ------------------------------------------------------------------ */
/* 事件队列                                                            */
/* ------------------------------------------------------------------ */

static void push_event(struct w32_ctx *c, const w32_event *e) {
    int next = (c->q_tail + 1) % EVENT_QUEUE_LEN;
    if (next == c->q_head) return; /* 队列满：丢弃，避免阻塞消息循环 */
    c->queue[c->q_tail] = *e;
    c->q_tail = next;
}

static void push_simple(struct w32_ctx *c, int type) {
    w32_event e;
    memset(&e, 0, sizeof(e));
    e.type = type;
    push_event(c, &e);
}

/* 焦点事件必须带上“是否获得焦点”：之前用 push_simple 投递，x 恒为 0，
 * app_win 的 EV_FOCUS 分支（focused = ev.x != 0）因此把窗口判成失焦，
 * 而旧的光标绘制又要求 focused —— 这就是“看不到光标”的直接原因。 */
static void push_focus(struct w32_ctx *c, int on) {
    w32_event e;
    memset(&e, 0, sizeof(e));
    e.type = W32_EV_FOCUS;
    e.x = on ? 1 : 0;
    push_event(c, &e);
}

static void push_char(struct w32_ctx *c, uint32_t cp) {
    w32_event e;
    memset(&e, 0, sizeof(e));
    e.type = W32_EV_CHAR;
    e.codepoint = cp;
    push_event(c, &e);
}

/* 把一次 UTF-16 码元并入输出；高位代理先缓存，低位到达时合成一个码点。 */
static void feed_surrogate(struct w32_ctx *c, unsigned int unit) {
    if (unit >= 0xD800 && unit <= 0xDBFF) {
        c->high_surrogate = (int)unit;
        return;
    }
    if (unit >= 0xDC00 && unit <= 0xDFFF) {
        if (c->high_surrogate) {
            uint32_t hi = (uint32_t)c->high_surrogate;
            c->high_surrogate = 0;
            push_char(c, 0x10000 + ((hi - 0xD800) << 10) + (unit - 0xDC00));
            return;
        }
        return; /* 孤立低位：丢弃 */
    }
    c->high_surrogate = 0;
    push_char(c, unit);
}

/* ------------------------------------------------------------------ */
/* 字体与字形缓存                                                      */
/* ------------------------------------------------------------------ */

static int is_cjk_cp(uint32_t cp) {
    return (cp >= 0x2E80 && cp <= 0x9FFF) ||   /* 部首扩展/CJK 统一表意 */
           (cp >= 0xA960 && cp <= 0xA97F) ||   /* 谚文字母扩展 */
           (cp >= 0xAC00 && cp <= 0xD7AF) ||   /* 谚文音节 */
           (cp >= 0xF900 && cp <= 0xFAFF) ||   /* 兼容表意 */
           (cp >= 0xFE30 && cp <= 0xFE4F) ||   /* 兼容形式 */
           (cp >= 0xFF00 && cp <= 0xFF60) ||   /* 全角 */
           (cp >= 0xFFE0 && cp <= 0xFFE6) ||
           (cp >= 0x20000 && cp <= 0x3FFFF);
}

/* ---- 字体：扫描系统字体目录 → 用 FreeType 建索引 → 交给共享的 font_ft 层 ----
 * 与 Linux 走同一份光栅器（"FreeType everywhere"），从而得到：
 *   - 彩色字形（FT_LOAD_COLOR，CBDT/COLR 位图）
 *   - 扩展平面（>U+FFFF）的真实 cmap 覆盖判断（GDI 的 GetGlyphIndicesW 只支持 BMP）
 *   - 与 Linux 一致的字形度量（FT size->metrics，而不是 TEXTMETRICW）
 */
typedef struct {
    char path[512];
    char family[96];   /* UTF-8 */
    int bold;
    int italic;
} font_file_entry;

typedef struct {
    font_file_entry e[1024];
    int n;
    int scanned;
} font_index;

static void index_add(font_index *ix, const char *path, FT_Face face) {
    if (!ix || !face || ix->n >= (int)(sizeof(ix->e) / sizeof(ix->e[0]))) return;
    if (!face->family_name) return;
    font_file_entry *e = &ix->e[ix->n++];
    snprintf(e->path, sizeof(e->path), "%s", path);
    snprintf(e->family, sizeof(e->family), "%s", face->family_name);
    e->bold = (face->style_flags & FT_STYLE_FLAG_BOLD) != 0;
    e->italic = (face->style_flags & FT_STYLE_FLAG_ITALIC) != 0;
    const char *st = face->style_name;
    if (st) {
        if (strstr(st, "Bold") || strstr(st, "bold")) e->bold = 1;
        if (strstr(st, "Italic") || strstr(st, "Oblique")) e->italic = 1;
    }
}

/* 扫描一个目录下的字体文件（.ttf/.otf/.ttc，TTC 逐个 face 读）。 */
static void scan_font_dir(font_index *ix, FT_Library lib, const wchar_t *dir) {
    wchar_t pattern[MAX_PATH];
    _snwprintf(pattern, MAX_PATH, L"%ls\\*", dir);
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        const wchar_t *name = fd.cFileName;
        size_t len = wcslen(name);
        if (len < 4) continue;
        const wchar_t *ext = name + len - 4;
        if (_wcsicmp(ext, L".ttf") != 0 && _wcsicmp(ext, L".otf") != 0 &&
            _wcsicmp(ext, L".ttc") != 0)
            continue;
        wchar_t full[MAX_PATH];
        _snwprintf(full, MAX_PATH, L"%ls\\%ls", dir, name);
        char utf8[MAX_PATH * 3];
        if (WideCharToMultiByte(CP_UTF8, 0, full, -1, utf8, sizeof(utf8), NULL, NULL) <= 0)
            continue;
        /* TTC 里多个 face 都要索引 */
        for (int idx = 0;; idx++) {
            FT_Face face = NULL;
            if (FT_New_Face(lib, utf8, idx, &face) != 0) break;
            index_add(ix, utf8, face);
            FT_Done_Face(face);
            if (idx > 32) break;
        }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
}

static void build_font_index(font_index *ix) {
    if (ix->scanned) return;
    ix->scanned = 1;
    ix->n = 0;
    FT_Library lib = NULL;
    if (FT_Init_FreeType(&lib) != 0) return;
    wchar_t dir[MAX_PATH];
    UINT n = GetWindowsDirectoryW(dir, MAX_PATH);
    if (n > 0 && n < MAX_PATH) {
        wcscat(dir, L"\\Fonts");
        scan_font_dir(ix, lib, dir);
    }
    wchar_t adir[MAX_PATH];
    DWORD m = GetEnvironmentVariableW(L"LOCALAPPDATA", adir, MAX_PATH);
    if (m > 0 && m < MAX_PATH) {
        wcscat(adir, L"\\Microsoft\\Windows\\Fonts");
        scan_font_dir(ix, lib, adir);
    }
    FT_Done_FreeType(lib);
}

/* 在索引里找 (family, bold, italic) 最佳匹配；找不到返回 NULL。 */
static const font_file_entry *index_find(font_index *ix, const char *family, int bold, int italic) {
    const font_file_entry *best = NULL;
    int best_score = -1000;
    for (int i = 0; i < ix->n; i++) {
        const font_file_entry *e = &ix->e[i];
        if (_stricmp(e->family, family) != 0) continue;
        int score = 0;
        if (e->bold == (bold != 0)) score += 2; else score -= 2;
        if (e->italic == (italic != 0)) score += 1; else score -= 1;
        if (score > best_score) {
            best_score = score;
            best = e;
        }
    }
    return best;
}

static void destroy_ft(struct w32_ctx *c) {
    if (c->ft) {
        ft_font_close(c->ft);
        c->ft = NULL;
    }
}

/* 建字体：4 个样式槽 + 回退链（CJK/emoji/符号），像素大小按当前 DPI 缩放。 */
static void build_ft(struct w32_ctx *c) {
    destroy_ft(c);
    int px = c->font_px * c->dpi / 96;
    if (px < 6) px = 6;
    static font_index ix;
    build_font_index(&ix);
    char fam[128];
    const wchar_t *srcfam = c->face[0] ? c->face : L"Consolas";
    int famlen = wide_to_utf8(srcfam, (int)wcslen(srcfam), fam, (int)sizeof(fam) - 1);
    fam[famlen > 0 ? famlen : 0] = 0;
    if (!fam[0]) snprintf(fam, sizeof(fam), "Consolas");

    char paths[FT_FONT_MAX_FACES][512];
    const char *ptrs[FT_FONT_MAX_FACES];
    int n = 0;
    static const struct { int bold, italic; } slots[4] = {
        {0, 0}, {1, 0}, {0, 1}, {1, 1}
    };
    for (int i = 0; i < 4; i++) {
        const font_file_entry *e = index_find(&ix, fam, slots[i].bold, slots[i].italic);
        if (!e) { ptrs[n] = NULL; n++; continue; }
        snprintf(paths[n], sizeof(paths[n]), "%s", e->path);
        ptrs[n] = paths[n];
        n++;
    }
    /* 回退链：CJK → emoji → 符号。找不到的会被 font_ft 静默跳过。 */
    static const char *fb[] = {
        "Microsoft YaHei", "SimSun", "Noto Sans CJK SC",
        "Segoe UI Emoji", "Noto Color Emoji", "Segoe UI Symbol", "Symbola"
    };
    for (size_t i = 0; i < sizeof(fb) / sizeof(fb[0]) && n < FT_FONT_MAX_FACES; i++) {
        const font_file_entry *e = index_find(&ix, fb[i], 0, 0);
        if (!e) continue;
        snprintf(paths[n], sizeof(paths[n]), "%s", e->path);
        ptrs[n] = paths[n];
        n++;
    }
    c->ft = ft_font_open(ptrs, n, 4, px);
    if (!c->ft) {
        /* 兜底：任取一个系统字体，避免完全没有输出 */
        for (int i = 0; i < ix.n && !c->ft; i++) {
            ptrs[0] = ix.e[i].path;
            c->ft = ft_font_open(ptrs, 1, 1, px);
        }
    }
    if (getenv("LEANTTY_FONTDBG") && c->ft) {
        fprintf(stderr, "win fontdbg: px=%d family=%s ps0=%s asc/desc/h=",
                px, fam, ft_font_postscript(c->ft, 0) ? ft_font_postscript(c->ft, 0) : "?");
        int a = 0, d = 0, hh = 0, adv = 0;
        ft_font_metrics(c->ft, &a, &d, &hh, &adv);
        fprintf(stderr, "%d/%d/%d adv=%d\n", a, d, hh, adv);
    }
}

/* 渲染一个码点的字形到"单元格大小"的缓冲：
 *   bpp=1 → alpha 覆盖度（按 FT 的 baseline/left 摆进格子，越界裁剪）
 *   bpp=4 → BGRA 彩色（按格子尺寸面积平均缩放，铺满整格） */
static int render_glyph_ft(struct w32_ctx *c, uint32_t cp, int bold, int italic,
                           int two_cell, glyph_entry *e) {
    if (!c->ft) return -1;
    int w = two_cell ? c->cell_w * 2 : c->cell_w;
    int h = c->cell_h;
    if (w < 1 || h < 1) return -1;
    int style = (bold ? 1 : 0) | (italic ? 2 : 0);
    static unsigned char raw[144 * 144 * 4];
    int gw = 0, gh = 0, left = 0, top = 0, adv = 0, bpp = 1, premul = 1;
    int n = ft_font_glyph(c->ft, cp, style, raw, (int)sizeof(raw),
                          &gw, &gh, &left, &top, &adv, &bpp, &premul);
    if (n <= 0) return -1;

    /* 与 alacritty 同口径：格子高度只按主字体算，回退字体（CJK）字形更高时
     * 允许它画到相邻行，不裁切、也不抬高行高。彩色字形按格子缩放、不溢出。 */
    int asc_ = 0, desc_ = 0, lh_ = 0, madv_ = 0;
    ft_font_metrics(c->ft, &asc_, &desc_, &lh_, &madv_);
    int pad_top = 0, pad_bottom = 0;
    if (bpp != 4) {
        if (top > asc_) pad_top = top - asc_;
        int bottom_row = asc_ + (gh - top);
        if (bottom_row > h) pad_bottom = bottom_row - h;
    }
    int buf_h = h + pad_top + pad_bottom;
    e->pad_top = pad_top;
    e->pad_bottom = pad_bottom;
    int need = w * buf_h * (bpp == 4 ? 4 : 1);
    uint8_t **slot = bpp == 4 ? &e->color : &e->alpha;
    int *cap = bpp == 4 ? &e->cap_color : &e->cap_alpha;
    if (*cap < need || !*slot) {
        uint8_t *nb = (uint8_t *)realloc(*slot, (size_t)need);
        if (!nb) return -1;
        *slot = nb;
        *cap = need;
    }
    if (!*slot) return -1;
    e->bpp = bpp;
    e->w = w;
    e->h = h;

    if (bpp == 4) {
        memset(e->color, 0, (size_t)need);
        for (int ty = 0; ty < h; ty++) {
            int sy0 = ty * gh / h;
            int sy1 = (ty + 1) * gh / h;
            if (sy1 <= sy0) sy1 = sy0 + 1;
            for (int tx = 0; tx < w; tx++) {
                int sx0 = tx * gw / w;
                int sx1 = (tx + 1) * gw / w;
                if (sx1 <= sx0) sx1 = sx0 + 1;
                unsigned sr = 0, sg = 0, sb = 0, sa = 0, cnt = 0;
                for (int sy = sy0; sy < sy1 && sy < gh; sy++) {
                    for (int sx = sx0; sx < sx1 && sx < gw; sx++) {
                        const unsigned char *p = raw + ((size_t)sy * (size_t)gw + (size_t)sx) * 4;
                        sb += p[0]; sg += p[1]; sr += p[2]; sa += p[3];
                        cnt++;
                    }
                }
                if (!cnt) continue;
                sr /= cnt; sg /= cnt; sb /= cnt; sa /= cnt;
                if (!premul && sa) {
                    sr = sr * sa / 255; sg = sg * sa / 255; sb = sb * sa / 255;
                }
                unsigned char *d = e->color + ((size_t)ty * (size_t)w + (size_t)tx) * 4;
                d[0] = (unsigned char)sb; d[1] = (unsigned char)sg;
                d[2] = (unsigned char)sr; d[3] = (unsigned char)sa;
            }
        }
        return 0;
    }

    /* 灰度：清空后按基线摆放（与 Linux 渲染器同口径，允许纵向溢出格子） */
    memset(e->alpha, 0, (size_t)need);
    for (int gy = 0; gy < gh; gy++) {
        int py = pad_top + asc_ - top + gy;
        if (py < 0 || py >= buf_h) continue;
        for (int gx = 0; gx < gw; gx++) {
            int px = left + gx;
            if (px < 0 || px >= w) continue;
            e->alpha[(size_t)py * (size_t)w + (size_t)px] = raw[(size_t)gy * (size_t)gw + (size_t)gx];
        }
    }
    return 0;
}

static void free_glyphs(struct w32_ctx *c) {
    for (int i = 0; i < GLYPH_CACHE_SLOTS; i++) {
        free(c->glyphs[i].alpha);
        free(c->glyphs[i].color);
        c->glyphs[i].alpha = NULL;
        c->glyphs[i].color = NULL;
        c->glyphs[i].cap_alpha = 0;
        c->glyphs[i].cap_color = 0;
        c->glyphs[i].bpp = 1;
        c->glyphs[i].pad_top = 0;
        c->glyphs[i].pad_bottom = 0;
        c->glyphs[i].key = 0;
    }
}

static const glyph_entry *glyph_get(struct w32_ctx *c, uint32_t cp, int bold,
                                    int italic, int two_cell) {
    uint32_t key = cp | ((uint32_t)(bold & 1) << 21) |
                   ((uint32_t)(italic & 1) << 22) | ((uint32_t)(two_cell & 1) << 23);
    if (key == 0) return NULL;
    glyph_entry *e = &c->glyphs[key % GLYPH_CACHE_SLOTS];
    int want_w = two_cell ? c->cell_w * 2 : c->cell_w;
    if (e->key == key && e->w == want_w && e->h == c->cell_h &&
        (e->alpha || e->color))
        return e;
    e->key = 0;
    if (render_glyph_ft(c, cp, bold, italic, two_cell, e) != 0) return NULL;
    e->key = key;
    return e;
}

/* ------------------------------------------------------------------ */
/* 呈现：DIB 双缓冲 + 软件 alpha 混合                                   */
/* ------------------------------------------------------------------ */

static void destroy_buffer(struct w32_ctx *c) {
    if (c->mem_dc) {
        SelectObject(c->mem_dc, GetStockObject(SYSTEM_FONT));
        DeleteDC(c->mem_dc);
        c->mem_dc = NULL;
    }
    if (c->dib) {
        DeleteObject(c->dib);
        c->dib = NULL;
    }
    c->pixels = NULL;
    c->buf_w = c->buf_h = 0;
    c->have_frame = 0;
}

static int ensure_buffer(struct w32_ctx *c, int w, int h) {
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    if (c->mem_dc && c->pixels && c->buf_w >= w && c->buf_h >= h) return 0;
    destroy_buffer(c);

    c->mem_dc = CreateCompatibleDC(NULL);
    if (!c->mem_dc) return -1;

    BITMAPINFO bi;
    memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;

    void *bits = NULL;
    c->dib = CreateDIBSection(c->mem_dc, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    if (!c->dib || !bits) {
        destroy_buffer(c);
        return -1;
    }
    SelectObject(c->mem_dc, c->dib);
    c->pixels = (uint32_t *)bits;
    c->buf_w = w;
    c->buf_h = h;
    return 0;
}

static inline void fill_rect(struct w32_ctx *c, int x, int y, int w, int h,
                             uint32_t color) {
    if (x < 0) {
        w += x;
        x = 0;
    }
    if (y < 0) {
        h += y;
        y = 0;
    }
    if (x + w > c->buf_w) w = c->buf_w - x;
    if (y + h > c->buf_h) h = c->buf_h - y;
    if (w <= 0 || h <= 0) return;
    uint32_t px = color & 0xFFFFFF;
    for (int row = 0; row < h; row++) {
        uint32_t *dst = c->pixels + (size_t)(y + row) * (size_t)c->buf_w + x;
        for (int col = 0; col < w; col++) dst[col] = px;
    }
}

static inline uint32_t blend_px(uint32_t dst, uint32_t fg, uint32_t a) {
    uint32_t ia = 255 - a;
    uint32_t r = (((fg >> 16) & 0xFF) * a + ((dst >> 16) & 0xFF) * ia) / 255;
    uint32_t g = (((fg >> 8) & 0xFF) * a + ((dst >> 8) & 0xFF) * ia) / 255;
    uint32_t b = ((fg & 0xFF) * a + (dst & 0xFF) * ia) / 255;
    return (r << 16) | (g << 8) | b;
}

/* 把字形混合到 (x,y)：灰度用 fg 着色；彩色按预乘 BGRA 直接叠加。 */
static void blit_glyph(struct w32_ctx *c, const glyph_entry *g, int x, int y,
                       uint32_t fg) {
    if (!g) return;
    if (g->bpp == 4) {
        /* 彩色条目只走 color 缓冲：不能落到灰度路径 —— alpha 可能是更早、更小的
         * 旧缓冲，用 color 的 w/h 去读会越界。 */
        if (!g->color) return;
        for (int gy = 0; gy < g->h; gy++) {
            int py = y + gy;
            if (py < 0 || py >= c->buf_h) continue;
            const uint8_t *src = g->color + (size_t)gy * (size_t)g->w * 4;
            uint32_t *dst = c->pixels + (size_t)py * (size_t)c->buf_w;
            for (int gx = 0; gx < g->w; gx++) {
                int px = x + gx;
                if (px < 0 || px >= c->buf_w) continue;
                const uint8_t *p = src + (size_t)gx * 4;
                uint32_t a = p[3];
                if (a == 0) continue;
                uint32_t ia = 255 - a;
                uint32_t r = (uint32_t)p[2] + (((dst[px] >> 16) & 0xFF) * ia) / 255;
                uint32_t gg = (uint32_t)p[1] + (((dst[px] >> 8) & 0xFF) * ia) / 255;
                uint32_t b = (uint32_t)p[0] + ((dst[px] & 0xFF) * ia) / 255;
                if (r > 255) r = 255;
                if (gg > 255) gg = 255;
                if (b > 255) b = 255;
                dst[px] = (r << 16) | (gg << 8) | b;
            }
        }
        return;
    }
    if (!g->alpha) return;
    /* 灰度位图可能比格子高（CJK 溢出）：整体上移 pad_top，画到相邻行去，不裁切。 */
    int rows_ = g->h + g->pad_top + g->pad_bottom;
    for (int gy = 0; gy < rows_; gy++) {
        int py = y + gy - g->pad_top;
        if (py < 0 || py >= c->buf_h) continue;
        const uint8_t *src = g->alpha + (size_t)gy * (size_t)g->w;
        uint32_t *dst = c->pixels + (size_t)py * (size_t)c->buf_w;
        for (int gx = 0; gx < g->w; gx++) {
            int px = x + gx;
            if (px < 0 || px >= c->buf_w) continue;
            uint32_t a = src[gx];
            if (a == 0) continue;
            if (a == 255) {
                dst[px] = fg & 0xFFFFFF;
            } else {
                dst[px] = blend_px(dst[px], fg, a);
            }
        }
    }
}

#define SCROLLBAR_WIDTH_PX 12

void w32_present(void *ctx, const w32_cell *cells, int cols, int rows,
                 int cursor_x, int cursor_y, int anchor_x, int anchor_y, int focused,
                 uint32_t default_fg,
                 uint32_t default_bg, int cursor_style, uint32_t cursor_color,
                 uint32_t cursor_text_color, int sb_thumb_y, int sb_thumb_h) {
    struct w32_ctx *c = (struct w32_ctx *)ctx;
    if (!c || !cells) return;
    if (cols <= 0 || rows <= 0) return;

    int need_w = cols * c->cell_w;
    int need_h = rows * c->cell_h;
    if (ensure_buffer(c, need_w, need_h) != 0) return;

    /* 先整屏铺默认背景（比逐格填更省：绝大多数格子是默认色）。 */
    fill_rect(c, 0, 0, need_w, need_h, default_bg);

    int show_cursor = cursor_x >= 0 && cursor_x < cols &&
                      cursor_y >= 0 && cursor_y < rows;
    /* IME 锚点只在拿到真实光标格时更新：TUI 常隐藏光标或走闪烁灭相，
     * 若这时把锚点退化成 (0,0)，候选框会被钉到窗口左上角（用户看到的就是"没有候选框"）。 */
    if (anchor_x >= 0 && anchor_x < cols && anchor_y >= 0 && anchor_y < rows) {
        c->anchor_x = anchor_x;
        c->anchor_y = anchor_y;
    }
    if (!c->dbg_frame_done) {
        DBG("[win] first-frame grid=%dx%d cell=%dx%d cursor=(%d,%d) style=%d focused=%d\n", cols, rows, c->cell_w, c->cell_h, cursor_x, cursor_y,
            cursor_style, focused);
        c->dbg_frame_done = 1;
    }

    for (int y = 0; y < rows; y++) {
        for (int x = 0; x < cols; x++) {
            const w32_cell *cell = &cells[(size_t)y * (size_t)cols + x];
            if (cell->wide == 2) continue; /* 宽字符续格由前一格铺满 */
            int px = x * c->cell_w;
            int py = y * c->cell_h;
            int two = cell->wide == 1;
            int draw_w = two ? c->cell_w * 2 : c->cell_w;

            uint32_t bg = cell->bg & 0xFFFFFF;
            uint32_t fg = cell->fg & 0xFFFFFF;
            if (bg != (default_bg & 0xFFFFFF)) fill_rect(c, px, py, draw_w, c->cell_h, bg);
            if (cell->cp != 0) {
                int bold = cell->attrs & 1;
                int italic = (cell->attrs >> 1) & 1;
                const glyph_entry *g = glyph_get(c, cell->cp, bold, italic, two);
                blit_glyph(c, g, px, py, fg);
            }
            if (cell->attrs & 4) { /* 下划线 */
                fill_rect(c, px, py + c->cell_h - 2, draw_w, 1, fg);
            }
            if (cell->attrs & 8) { /* 删除线 */
                fill_rect(c, px, py + (c->cell_h * 2) / 3, draw_w, 1, fg);
            }
            if (cell->attrs & 16) { /* 上划线（SGR 53） */
                fill_rect(c, px, py, draw_w, 1, fg);
            }
        }
    }

    /* 光标：形状取自 DECSCUSR（block/bar/underline/hollow）；闪烁与可见性
     * 由 app_win.zig 决定（不可见时 cursor_x/y = -1）。失焦时画空心框，
     * 这样即使 WM_SETFOCUS 没到，也不会“完全看不到光标”。 */
    if (show_cursor) {
        int px = cursor_x * c->cell_w;
        int py = cursor_y * c->cell_h;
        const w32_cell *cc = &cells[(size_t)cursor_y * (size_t)cols + cursor_x];
        int draw_w = (cc->wide == 1) ? c->cell_w * 2 : c->cell_w;
        int style = focused ? cursor_style : W32_CURSOR_HOLLOW;
        uint32_t stroke = cursor_color & 0xFFFFFF;
        switch (style) {
        case W32_CURSOR_BAR:
            fill_rect(c, px, py, c->cell_w / 4 > 1 ? c->cell_w / 4 : 1, c->cell_h, stroke);
            break;
        case W32_CURSOR_UNDERLINE: {
            int h = c->cell_h / 8 > 2 ? c->cell_h / 8 : 2;
            fill_rect(c, px, py + c->cell_h - h, draw_w, h, stroke);
            break;
        }
        case W32_CURSOR_HOLLOW:
            fill_rect(c, px, py, draw_w, 1, stroke);
            fill_rect(c, px, py + c->cell_h - 1, draw_w, 1, stroke);
            fill_rect(c, px, py, 1, c->cell_h, stroke);
            fill_rect(c, px + draw_w - 1, py, 1, c->cell_h, stroke);
            break;
        default: /* W32_CURSOR_BLOCK：实心填充 + 用文字色重画字符（反色） */
            fill_rect(c, px, py, draw_w, c->cell_h, stroke);
            if (cc->cp != 0) {
                int bold = cc->attrs & 1;
                int italic = (cc->attrs >> 1) & 1;
                const glyph_entry *g = glyph_get(c, cc->cp, bold, italic, cc->wide == 1);
                blit_glyph(c, g, px, py, cursor_text_color & 0xFFFFFF);
            }
            break;
        }
    }

    c->drawn_w = need_w;
    c->drawn_h = need_h;
    c->have_frame = 1;
    c->cursor_x = cursor_x;
    c->cursor_y = cursor_y;

    /* 滚动条：右缘 12px（与 Rust / Linux 同宽）。轨道 = 前景背景各半，滑块 = 前景色。
     * sb_thumb_h <= 0 表示没有滚动区（内容不超一屏）。 */
    if (sb_thumb_h > 0) {
        int bar_w = SCROLLBAR_WIDTH_PX;
        if (bar_w > need_w) bar_w = need_w;
        uint32_t tr = ((((default_fg >> 16) & 0xFF) + ((default_bg >> 16) & 0xFF)) / 2) << 16 |
                      (((((default_fg >> 8) & 0xFF) + ((default_bg >> 8) & 0xFF)) / 2) << 8) |
                      ((((default_fg & 0xFF) + (default_bg & 0xFF)) / 2));
        fill_rect(c, need_w - bar_w, 0, bar_w, need_h, tr);
        int ty = sb_thumb_y;
        int th = sb_thumb_h;
        if (ty < 0) ty = 0;
        if (ty + th > need_h) th = need_h - ty;
        fill_rect(c, need_w - bar_w, ty, bar_w, th, default_fg & 0xFFFFFF);
    }

    HDC dc = GetDC(c->hwnd);
    if (dc) {
        BitBlt(dc, 0, 0, need_w, need_h, c->mem_dc, 0, 0, SRCCOPY);
        ReleaseDC(c->hwnd, dc);
    }
}

/* ------------------------------------------------------------------ */
/* 网格 / 尺寸                                                         */
/* ------------------------------------------------------------------ */

static void push_resize(struct w32_ctx *c) {
    /* 初始布局未完成时只更新尺寸、不产生事件：启动过程中窗口会经历几次临时尺寸，
     * 每次都推 ResizePseudoConsole 会让子进程的初始控制台尺寸停在中间值
     * （实测：子进程看到 104x26 而终端网格是 80x24）。 */
    if (!c->layout_ready) return;
    w32_event e;
    memset(&e, 0, sizeof(e));
    e.type = W32_EV_RESIZE;
    e.cols = c->cols;
    e.rows = c->rows;
    e.width = c->cols * c->cell_w;
    e.height = c->rows * c->cell_h;
    push_event(c, &e);
}

static void recompute_grid(struct w32_ctx *c, int *out_cols, int *out_rows) {
    RECT rc;
    GetClientRect(c->hwnd, &rc);
    int w = rc.right - rc.left;
    int h = rc.bottom - rc.top;
    int cols = c->cell_w > 0 ? w / c->cell_w : 1;
    int rows = c->cell_h > 0 ? h / c->cell_h : 1;
    if (cols < 1) cols = 1;
    if (rows < 1) rows = 1;
    c->cols = cols;
    c->rows = rows;
    if (out_cols) *out_cols = cols;
    if (out_rows) *out_rows = rows;
}

void w32_cell_size(void *ctx, int *cell_w, int *cell_h) {
    struct w32_ctx *c = (struct w32_ctx *)ctx;
    if (!c) return;
    if (cell_w) *cell_w = c->cell_w;
    if (cell_h) *cell_h = c->cell_h;
}

void w32_grid(void *ctx, int *cols, int *rows) {
    struct w32_ctx *c = (struct w32_ctx *)ctx;
    if (!c) return;
    if (cols) *cols = c->cols;
    if (rows) *rows = c->rows;
}

static void apply_dpi(struct w32_ctx *c, int dpi, const RECT *suggest) {
    if (dpi <= 0) dpi = 96;
    c->dpi = dpi;

    /* 格子尺寸来自 FreeType 度量（与 Linux 完全同口径：宽 = 'M' 的 advance，
     * 高 = FT 的 height（含 line gap）），不再用 TEXTMETRICW —— 那是另一套定义，
     * 会造成两平台格子高度/基线系统性差一截。 */
    build_ft(c);
    int cw = c->base_cw, chh = c->base_ch;
    if (cw <= 0 || chh <= 0) {
        int asc = 0, desc = 0, lh = 0, adv = 0;
        if (c->ft) ft_font_metrics(c->ft, &asc, &desc, &lh, &adv);
        if (cw <= 0) cw = adv > 0 ? adv : 8;
        if (chh <= 0) chh = lh > 0 ? lh : (asc + desc > 0 ? asc + desc : 16);
        c->cell_w = cw;
        c->cell_h = chh;
    } else {
        c->cell_w = cw * dpi / 96;
        c->cell_h = chh * dpi / 96;
    }
    if (c->cell_w < 1) c->cell_w = 1;
    if (c->cell_h < 1) c->cell_h = 1;

    free_glyphs(c);
    destroy_buffer(c);

    if (suggest) {
        SetWindowPos(c->hwnd, NULL, suggest->left, suggest->top,
                     suggest->right - suggest->left, suggest->bottom - suggest->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
    }
    recompute_grid(c, NULL, NULL);
    push_resize(c);
}

/* ------------------------------------------------------------------ */
/* ConPTY                                                              */
/* ------------------------------------------------------------------ */

static void close_conpty(struct w32_ctx *c) {
    if (c->hpc) {
        if (p_close_pc) p_close_pc(c->hpc);
        c->hpc = NULL;
    }
    if (c->in_w) {
        CloseHandle(c->in_w);
        c->in_w = NULL;
    }
    if (c->out_r) {
        CloseHandle(c->out_r);
        c->out_r = NULL;
    }
    if (c->pi.hThread) {
        CloseHandle(c->pi.hThread);
        c->pi.hThread = NULL;
    }
    if (c->pi.hProcess) {
        CloseHandle(c->pi.hProcess);
        c->pi.hProcess = NULL;
    }
    if (c->job) {
        CloseHandle(c->job);
        c->job = NULL;
    }
    c->alive = 0;
}

int w32_spawn(void *ctx, const char *command_line, const char *cwd) {
    struct w32_ctx *c = (struct w32_ctx *)ctx;
    if (!c || c->spawned) return -1;
    if (!p_create_pc || !p_resize_pc || !p_close_pc) return -2; /* 需要 Win10 1809+ */

    wchar_t *wcmd = utf8_to_wide(command_line);
    if (!wcmd) return -1;
    wchar_t *wcwd = cwd ? utf8_to_wide(cwd) : NULL;

    SECURITY_ATTRIBUTES sa;
    memset(&sa, 0, sizeof(sa));
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;

    HANDLE in_r = NULL, in_w = NULL, out_r = NULL, out_w = NULL;
    int rc = -1;
    if (!CreatePipe(&in_r, &in_w, &sa, 0)) goto done;
    SetHandleInformation(in_w, HANDLE_FLAG_INHERIT, 0);
    if (!CreatePipe(&out_r, &out_w, &sa, 0)) goto done;
    SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0);

    COORD size;
    size.X = (SHORT)c->cols;
    size.Y = (SHORT)c->rows;
    /* CreatePseudoConsole 的 flags：
     *   PSEUDOCONSOLE_INHERIT_CURSOR (0x1)
     *   PSEUDOCONSOLE_RESIZE_QUIRK   (0x2)
     *   PSEUDOCONSOLE_WIN32_INPUT_MODE (0x4)  ← 关键
     * 之前传 0，ConPTY 会把主机写入的输入当成 **VT 序列**去解析：认识的（方向键、SS3）
     * 变成键记录，不认识的（`ESC[200~`、kitty 的 `ESC[97;5u`）**直接丢掉**。
     * 打开 WIN32_INPUT_MODE 后，输入侧按"win32 输入记录"解释，非记录的字节按字面文本
     * 透传——括号粘贴标记与 CSI-u 于是能原样到达子进程。同机 Rust 版（portable-pty）
     * 传的正是 0x1|0x2|0x4（见 portable-pty 0.9 的 psuedocon.rs），这是两边行为差异的根源。 */
    HRESULT hr = p_create_pc(size, in_r, out_w, 0x1 | 0x2 | 0x4, &c->hpc);
    if (SUCCEEDED(hr)) {
        c->pty_cols = c->cols;
        c->pty_rows = c->rows;
    }
    if (FAILED(hr)) {
        rc = -3;
        goto done;
    }
    /* ConPTY 自己持有管道端引用，本地副本可以关掉。 */
    CloseHandle(in_r);
    in_r = NULL;
    CloseHandle(out_w);
    out_w = NULL;

    STARTUPINFOEXW si;
    memset(&si, 0, sizeof(si));
    si.StartupInfo.cb = sizeof(si);
    /* STARTF_USESTDHANDLES + 三个 NULL 句柄：否则子进程会照抄父进程的
     * stdout/stderr（重定向到文件时表现为cmd 输出不进 ConPTY），实测有效。 */
    si.StartupInfo.dwFlags = EXTENDED_STARTUPINFO_PRESENT | STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = NULL;
    si.StartupInfo.hStdOutput = NULL;
    si.StartupInfo.hStdError = NULL;
    SIZE_T attr_size = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
    si.lpAttributeList =
        (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attr_size);
    if (!si.lpAttributeList) {
        rc = -1;
        goto done;
    }
    if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_size)) {
        rc = -1;
        goto done;
    }
    if (!UpdateProcThreadAttribute(si.lpAttributeList, 0,
                                   PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, c->hpc,
                                   sizeof(c->hpc), NULL, NULL)) {
        rc = -1;
        goto done;
    }

    /* 子进程的 stdin/stdout 由 ConPTY 接管，不需要 STARTF_USESTDHANDLES；
     * 同时设了两者反而会让子进程拿到管道原始句柄（见报告「工程判断」）。 */
    BOOL ok = CreateProcessW(NULL, wcmd, NULL, NULL, FALSE,
                             EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT |
                                 CREATE_NEW_PROCESS_GROUP,
                             NULL, wcwd, &si.StartupInfo, &c->pi);
    DWORD child_err = ok ? 0 : GetLastError();
    DeleteProcThreadAttributeList(si.lpAttributeList);
    HeapFree(GetProcessHeap(), 0, si.lpAttributeList);
    if (!ok) {
        (void)child_err;
        rc = -4;
        goto done;
    }

    /* job：进程退出时连同子进程树一起回收，避免残留 cmd。 */
    c->job = CreateJobObjectW(NULL, NULL);
    if (c->job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION jli;
        memset(&jli, 0, sizeof(jli));
        jli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(c->job, JobObjectExtendedLimitInformation, &jli,
                                sizeof(jli));
        AssignProcessToJobObject(c->job, c->pi.hProcess);
    }

    c->in_w = in_w;
    in_w = NULL;
    c->out_r = out_r;
    out_r = NULL;
    c->alive = 1;
    c->spawned = 1;
    rc = 0;

done:
    if (in_r) CloseHandle(in_r);
    if (in_w) CloseHandle(in_w);
    if (out_r) CloseHandle(out_r);
    if (out_w) CloseHandle(out_w);
    free(wcmd);
    free(wcwd);
    return rc;
}

int w32_read(void *ctx, char *buf, int cap) {
    struct w32_ctx *c = (struct w32_ctx *)ctx;
    if (!c || !c->out_r || cap <= 0) return 0;
    DWORD avail = 0;
    if (!PeekNamedPipe(c->out_r, NULL, 0, NULL, &avail, NULL)) {
        c->alive = 0;
        return -1;
    }
    if (avail == 0) {
        if (!c->alive) return -1;
        return 0;
    }
    DWORD want = (DWORD)cap;
    if (avail < want) want = avail;
    DWORD got = 0;
    if (!ReadFile(c->out_r, buf, want, &got, NULL)) {
        c->alive = 0;
        return -1;
    }
    return (int)got;
}

void w32_write(void *ctx, const char *buf, int len) {
    struct w32_ctx *c = (struct w32_ctx *)ctx;
    if (!c || !c->in_w || len <= 0) return;
    // 大块写入（粘贴）记录长度：用于核对“整段都进了 PTY，没有被截断”。
    if (len > 4096) DBG("[win] pty-write %d bytes\n", len);
    int off = 0;
    while (off < len) {
        DWORD n = 0;
        if (!WriteFile(c->in_w, buf + off, (DWORD)(len - off), &n, NULL) || n == 0) break;
        off += (int)n;
    }
}

void w32_set_synthetic_bold(void *ctx, int on) {
    struct w32_ctx *c = (struct w32_ctx *)ctx;
    if (c && c->ft) ft_font_set_synthetic_bold(c->ft, on);
}

int w32_alive(void *ctx) {
    struct w32_ctx *c = (struct w32_ctx *)ctx;
    if (!c) return 0;
    if (c->pi.hProcess &&
        WaitForSingleObject(c->pi.hProcess, 0) == WAIT_OBJECT_0)
        c->alive = 0;
    return c->alive;
}

void w32_resize_pty(void *ctx, int cols, int rows) {
    struct w32_ctx *c = (struct w32_ctx *)ctx;
    if (!c || !c->hpc || cols <= 0 || rows <= 0) return;
    /* 尺寸没变就不要调 ResizePseudoConsole：ConPTY 每次 resize 都会让 conhost
     * 重排屏幕、子进程重画提示符，实测表现为"首行为空、内容整体下移一行"。 */
    if (cols == c->pty_cols && rows == c->pty_rows) {
        if (c->trace) fprintf(c->trace, "RESIZE-PTY %dx%d skipped (unchanged)\n", cols, rows);
        return;
    }
    COORD size;
    size.X = (SHORT)cols;
    size.Y = (SHORT)rows;
    HRESULT hr = p_resize_pc(c->hpc, size);
    if (SUCCEEDED(hr)) {
        c->pty_cols = cols;
        c->pty_rows = rows;
    }
    if (c->trace)
        fprintf(c->trace, "RESIZE-PTY %dx%d hr=%ld\n", cols, rows, (long)hr);
}

/* ------------------------------------------------------------------ */
/* 输入：键盘 / 鼠标 / IME                                             */
/* ------------------------------------------------------------------ */

static unsigned int mod_state(const struct w32_ctx *c) {
    unsigned int s = c ? c->mod_track : 0;
    /* GetKeyState 反映"本线程已处理过的消息"里的状态；输入法把 Shift 当切换键时
     * 会把它提前清掉（实测：Shift 的 keyup 早于方向键的 keydown 到达）。
     * GetAsyncKeyState 读的是系统级实时状态，注入与真实按键都能反映 —— 两者取并集。 */
    if ((GetKeyState(VK_SHIFT) & 0x8000) || (GetAsyncKeyState(VK_SHIFT) & 0x8000)) s |= 1;
    if ((GetKeyState(VK_CONTROL) & 0x8000) || (GetAsyncKeyState(VK_CONTROL) & 0x8000)) s |= 2;
    if ((GetKeyState(VK_MENU) & 0x8000) || (GetAsyncKeyState(VK_MENU) & 0x8000)) s |= 4;
    return s;
}

/* 修饰键自身的 keydown/keyup：只更新跟踪位，不产生终端序列。 */
static unsigned int mod_bit_for_vk(WPARAM vk) {
    switch (vk) {
    case VK_SHIFT: case VK_LSHIFT: case VK_RSHIFT: return 1;
    case VK_CONTROL: case VK_LCONTROL: case VK_RCONTROL: return 2;
    case VK_MENU: case VK_LMENU: case VK_RMENU: return 4;
    default: return 0;
    }
}

/* 由窗口过程直接处理（发终端序列）的键：其余键走 WM_CHAR。 */
static int is_sequence_key(WPARAM vk) {
    switch (vk) {
    case VK_RETURN:
    case VK_BACK:
    case VK_TAB:
    case VK_ESCAPE:
    case VK_LEFT:
    case VK_UP:
    case VK_RIGHT:
    case VK_DOWN:
    case VK_HOME:
    case VK_END:
    case VK_PRIOR:
    case VK_NEXT:
    case VK_INSERT:
    case VK_DELETE:
    case VK_F1:
    case VK_F2:
    case VK_F3:
    case VK_F4:
    case VK_F5:
    case VK_F6:
    case VK_F7:
    case VK_F8:
    case VK_F9:
    case VK_F10:
    case VK_F11:
    case VK_F12:
    case VK_NUMPAD0:
    case VK_NUMPAD1:
    case VK_NUMPAD2:
    case VK_NUMPAD3:
    case VK_NUMPAD4:
    case VK_NUMPAD5:
    case VK_NUMPAD6:
    case VK_NUMPAD7:
    case VK_NUMPAD8:
    case VK_NUMPAD9:
    case VK_MULTIPLY:
    case VK_ADD:
    case VK_SUBTRACT:
    case VK_DECIMAL:
    case VK_DIVIDE:
        return 1;
    default:
        return 0;
    }
}

static int altgr_down(void) {
    /* AltGr = 右 Alt + 左 Ctrl：这种组合是输入字符，不是 Alt 组合键。 */
    return (GetKeyState(VK_RMENU) & 0x8000) && (GetKeyState(VK_LCONTROL) & 0x8000);
}

/* 返回 1 表示该按键已被本程序消费（不再走默认处理）。 */
static int handle_keydown(struct w32_ctx *c, WPARAM vk) {
    unsigned int st = mod_state(c);
    int seq = is_sequence_key(vk);
    DBG("[win] kd vk=%02X mods=%u seq=%d\n", (unsigned)vk, st, seq);

    /* Ctrl+Shift+C/V：本机剪贴板。必须在这里拦，否则 WM_CHAR 会把 0x03/0x16
     * 送给子进程（实测：Ctrl+Shift+V 会变成 cmd 里的 ^V）。 */
    if ((st & 2) && (st & 1)) {
        if (vk == 'C' || vk == 'V') {
            w32_event e;
            memset(&e, 0, sizeof(e));
            e.type = vk == 'C' ? W32_EV_COPY : W32_EV_PASTE;
            DBG("[win] hotkey %s\n", vk == 'C' ? "Ctrl+Shift+C(copy)" : "Ctrl+Shift+V(paste)");
            e.vk = (unsigned int)vk;
            push_event(c, &e);
            c->swallow_ctrl = 1;
            return 1;
        }
    }
    c->ime_mute_echo = 0; /* 新的一次按键：IME 提交回声期结束 */

    /* Ctrl+字母/符号 也走编码器：kitty 键盘协议下它们要编码成 CSI u（`ESC[97;5u`），
     * 而 legacy 下是 C0（`0x01`）——这两者都只能由 encodeKey 产生。
     * 之前这里直接 return 0 交给 DefWindowProc，结果是 WM_CHAR 给了 0x01，
     * 编码器根本没参与（第七轮实机：kitty 模式下 Ctrl+a 与 Rust 不一致）。
     * 交给编码器后要吞掉随后 WM_CHAR 产生的那一个 C0（用现有的 swallow_ctrl）。 */
    if (!seq && (st & 2) && !(st & 4) && !altgr_down()) {
        w32_event ce;
        memset(&ce, 0, sizeof(ce));
        ce.type = W32_EV_KEY;
        ce.vk = (unsigned int)vk;
        ce.state = st;
        push_event(c, &ce);
        c->swallow_ctrl = 1;
        return 1;
    }
    if (!seq && !(st & 4)) return 0;
    if (!seq && altgr_down()) return 0;

    w32_event e;
    memset(&e, 0, sizeof(e));
    e.type = W32_EV_KEY;
    e.vk = (unsigned int)vk;
    e.state = st;
    push_event(c, &e);
    if (c->trace) fprintf(c->trace, "KEY vk=%02X mods=%u\n", (unsigned)vk, st);
    return seq || (st & 4) != 0;
}

static void handle_char(struct w32_ctx *c, unsigned int cp) {
    /* IME 结果串已由 WM_IME_COMPOSITION 直接提交：随后系统回放的同批
     * WM_IME_CHAR/WM_CHAR 全部丢弃，直到下一次按键（见 handle_keydown）。 */
    if (c->ime_mute_echo) {
        if (c->trace) fprintf(c->trace, "CHAR absorbed ime cp=%X\n", cp);
        return;
    }
    if (cp == 0) return;
    if (c->swallow_ctrl) {
        c->swallow_ctrl = 0;
        if (cp < 0x20) return;
    }
    /* 回车/退格/制表/ESC 已由 KEY 路径编码，避免重复写入。 */
    if (cp == 8 || cp == 9 || cp == 13 || cp == 27) return;
    feed_surrogate(c, cp);
    if (c->trace) fprintf(c->trace, "CHAR cp=%X\n", cp);
}

/* 预编辑/候选窗跟随光标 */
static void position_ime(struct w32_ctx *c) {
    /* ImmSetCompositionWindow 会经 MSCTF 再投递 IME 消息；不加这条保护会
     * 形成 WM_IME_* -> ImmSetCompositionWindow -> MSCTF -> WM_IME_* 的无限
     * 递归，表现为栈溢出（实测崩溃点就在 ImmSetCompositionWindow 内部）。 */
    if (c->ime_in_position) return;
    HIMC hImc = ImmGetContext(c->hwnd);
    if (!hImc) {
        DBG("[win] ime pos himc=0 cell=(%d,%d)\n", c->cursor_x, c->cursor_y);
        return;
    }
    int x = c->anchor_x < 0 ? 0 : c->anchor_x;
    int y = c->anchor_y < 0 ? 0 : c->anchor_y;
    POINT pt;
    pt.x = x * c->cell_w;
    pt.y = y * c->cell_h;
    if (pt.x == c->ime_px && pt.y == c->ime_py) {
        ImmReleaseContext(c->hwnd, hImc);
        return;
    }
    c->ime_px = pt.x;
    c->ime_py = pt.y;
    c->ime_in_position = 1;
    COMPOSITIONFORM cf;
    memset(&cf, 0, sizeof(cf));
    cf.dwStyle = CFS_POINT;
    cf.ptCurrentPos = pt;
    ImmSetCompositionWindow(hImc, &cf);
    CANDIDATEFORM cand;
    memset(&cand, 0, sizeof(cand));
    cand.dwIndex = 0;
    /* 候选窗位置：光标下方要留得下一行候选列表框，否则不要钉死位置——
     * 贴底（全屏 TUI 的输入框通常就在最后一行）时贴光标下方会把候选框顶到
     * 窗口/屏幕之外，表现就是「盲输能出字、但看不见候选框」。
     * 这种情形改成 CFS_EXCLUDE + 排除光标所在行，让 IME 自己往上挑可见位置。 */
    int client_w = c->cols * c->cell_w;
    int client_h = c->rows * c->cell_h;
    int below = client_h - pt.y - c->cell_h;
    if (below >= 3 * c->cell_h) {
        cand.dwStyle = CFS_CANDIDATEPOS;
        cand.ptCurrentPos = pt;
    } else {
        cand.dwStyle = CFS_EXCLUDE;
        cand.ptCurrentPos = pt;
        cand.rcArea.left = 0;
        cand.rcArea.top = pt.y;
        cand.rcArea.right = client_w;
        cand.rcArea.bottom = client_h;
    }
    ImmSetCandidateWindow(hImc, &cand);
    /* 回读候选窗：TSF 输入法可能不接受 CFS_CANDIDATEPOS。 */
    CANDIDATEFORM rb;
    memset(&rb, 0, sizeof(rb));
    rb.dwIndex = 0;
    if (ImmGetCandidateWindow(hImc, 0, &rb)) {
        DBG("[win] ime pos anchor=(%d,%d) px=(%ld,%ld) req=%lx below=%d rb style=%lx at=(%ld,%ld) client=%ldx%ld\n",
            c->anchor_x, c->anchor_y, (long)pt.x, (long)pt.y, (unsigned long)cand.dwStyle, below,
            (unsigned long)rb.dwStyle, (long)rb.ptCurrentPos.x, (long)rb.ptCurrentPos.y,
            (long)client_w, (long)client_h);
    } else {
        DBG("[win] ime pos anchor=(%d,%d) px=(%ld,%ld) req=%lx below=%d rb=unreadable\n",
            c->anchor_x, c->anchor_y, (long)pt.x, (long)pt.y, (unsigned long)cand.dwStyle, below);
    }
    ImmReleaseContext(c->hwnd, hImc);
    c->ime_in_position = 0;
}

/* GCS_RESULTSTR 提交：返回读取到的 UTF-16 码元数（0 = 没有结果串）。 */
static int ime_take_result(struct w32_ctx *c, HIMC hImc) {
    LONG bytes = ImmGetCompositionStringW(hImc, GCS_RESULTSTR, NULL, 0);
    if (bytes <= 0) return 0;
    wchar_t stackbuf[256];
    wchar_t *buf = stackbuf;
    int units = (int)(bytes / (LONG)sizeof(wchar_t));
    if (units + 1 > (int)(sizeof(stackbuf) / sizeof(stackbuf[0]))) {
        buf = (wchar_t *)malloc((size_t)(units + 1) * sizeof(wchar_t));
        if (!buf) return 0;
    }
    LONG got = ImmGetCompositionStringW(hImc, GCS_RESULTSTR, buf, bytes);
    int n = got > 0 ? (int)(got / (LONG)sizeof(wchar_t)) : 0;
    for (int i = 0; i < n; i++) feed_surrogate(c, (unsigned int)buf[i]);
    if (buf != stackbuf) free(buf);
    if (c->trace) fprintf(c->trace, "IME result units=%d\n", n);
    return n;
}

/* ------------------------------------------------------------------ */
/* 窗口过程                                                            */
/* ------------------------------------------------------------------ */

static void track_leave(struct w32_ctx *c) {
    if (c->tracking_leave) return;
    TRACKMOUSEEVENT tme;
    memset(&tme, 0, sizeof(tme));
    tme.cbSize = sizeof(tme);
    tme.dwFlags = TME_LEAVE;
    tme.hwndTrack = c->hwnd;
    TrackMouseEvent(&tme);
    c->tracking_leave = 1;
}

static void push_mouse(struct w32_ctx *c, int action, int button) {
    POINT pt;
    GetCursorPos(&pt);
    ScreenToClient(c->hwnd, &pt);
    w32_event e;
    memset(&e, 0, sizeof(e));
    e.type = W32_EV_MOUSE;
    e.action = (unsigned int)action;
    e.button = (unsigned int)button;
    e.x = pt.x;
    e.y = pt.y;
    e.state = mod_state(c);
    if (c->trace)
        fprintf(c->trace, "MOUSE action=%d button=%d x=%ld y=%ld\n", action, button,
                (long)pt.x, (long)pt.y);
    push_event(c, &e);
}

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    struct w32_ctx *c = (struct w32_ctx *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (!c) return DefWindowProcW(hwnd, msg, wp, lp);

    switch (msg) {
    case WM_CLOSE:
        push_simple(c, W32_EV_CLOSE);
        return 0;

    case WM_DESTROY:
        c->closed = 1;
        PostQuitMessage(0);
        return 0;

    case WM_ERASEBKGND:
        return 1;

    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        if (c->have_frame && c->mem_dc) {
            BitBlt(dc, 0, 0, c->drawn_w, c->drawn_h, c->mem_dc, 0, 0, SRCCOPY);
        }
        EndPaint(hwnd, &ps);
        return 0;
    }

    case WM_SIZE: {
        if (wp == SIZE_MINIMIZED) return 0;
        int cols = 0, rows = 0;
        recompute_grid(c, &cols, &rows);
        destroy_buffer(c);
        push_resize(c);
        return 0;
    }

    case WM_DPICHANGED: {
        int dpi = HIWORD(wp);
        apply_dpi(c, dpi, (const RECT *)lp);
        return 0;
    }

    /* 激活时显式把键盘焦点给窗口本身。
     * 不这样做时线程的 hwndFocus 会是 0（GetGUIThreadInfo 实测），
     * 中文输入法（TSF/微软拼音）没有可依附的焦点窗口 → 按键被吞、
     * 收不到任何 WM_IME_*，表现为"开了输入法就打不出字"。 */
    case WM_ACTIVATE:
        if (LOWORD(wp) != WA_INACTIVE) SetFocus(hwnd);
        break;

    case WM_SETFOCUS:
        DBG("[win] focus=1 hwnd=%p\n", (void *)c->hwnd);
        c->focused = 1;
        push_focus(c, 1);
        break;

    case WM_KILLFOCUS:
        DBG("[win] focus=0\n");
        c->focused = 0;
        c->mod_track = 0; /* 失焦后可能收不到 keyup，清掉避免"卡住 Shift" */
        push_focus(c, 0);
        break;

    case WM_KEYDOWN:
    case WM_SYSKEYDOWN: {
        /* 自己记修饰键的按下：GetKeyState 在某些注入/IME 场景下拿不到（见 ctx.mod_track）。 */
        unsigned int mb = mod_bit_for_vk(wp);
        if (mb) {
            c->mod_track |= mb;
            DBG("[win] mod down vk=%02X track=%u\n", (unsigned)wp, c->mod_track);
            return 0;
        }
        /* 按下的键已交给终端：不再走系统菜单/默认处理，避免提示音。 */
        if (handle_keydown(c, wp)) return 0;
        return DefWindowProcW(hwnd, msg, wp, lp);
    }

    case WM_KEYUP:
    case WM_SYSKEYUP: {
        unsigned int mb = mod_bit_for_vk(wp);
        if (mb) {
            c->mod_track &= ~mb;
            DBG("[win] mod up vk=%02X track=%u\n", (unsigned)wp, c->mod_track);
            return 0;
        }
        break;
    }

    case WM_SYSCHAR:
        return 0; /* Alt+键 产生的系统字符：吞掉，防提示音 */

    case WM_CHAR:
        handle_char(c, (unsigned int)wp);
        return 0;

    case WM_UNICHAR:
        if (wp == UNICODE_NOCHAR) return TRUE; /* 声明支持 */
        handle_char(c, (unsigned int)wp);
        return 0;

    case WM_INPUTLANGCHANGE:
        DBG("[win] inputlang hkl=%p\n", (void *)(uintptr_t)lp);
        break;

    case WM_IME_SETCONTEXT:
        DBG("[win] ime setcontext active=%d lp=%lx showui=%d\n", (int)wp, (unsigned long)lp,
            (int)((lp & ISC_SHOWUICOMPOSITIONWINDOW) != 0));
        break;

    case WM_IME_STARTCOMPOSITION:
        DBG("[win] ime start\n");
        c->ime_composing = 1;
        position_ime(c);
        return 0;

    case WM_IME_COMPOSITION:
        DBG("[win] ime comp flags=%lx\n", (unsigned long)lp);
        if (lp & GCS_RESULTSTR) {
            HIMC hImc = ImmGetContext(hwnd);
            if (hImc) {
                int units = ime_take_result(c, hImc);
                DBG("[win] ime result units=%d\n", units);
                if (units > 0) c->ime_mute_echo = 1;
                ImmReleaseContext(hwnd, hImc);
            }
        }
        position_ime(c);
        return 0;

    case WM_IME_ENDCOMPOSITION:
        DBG("[win] ime end\n");
        c->ime_composing = 0;
        position_ime(c);
        return 0;

    case WM_IME_CHAR:
        DBG("[win] ime char %04X\n", (unsigned)wp);
        /* 走 WM_IME_CHAR 的输入法：同样并入字符流（结果串路径已计数时被吞掉）。 */
        handle_char(c, (unsigned int)wp);
        return 0;

    case WM_IME_NOTIFY:
        /* 通知类消息直接交默认处理：这里再调 Imm* 会触发 MSCTF 递归。 */
        break;

    case WM_MOUSEMOVE:
        track_leave(c);
        if (c->mouse_down) push_mouse(c, W32_MOUSE_MOTION, c->mouse_down);
        return 0;

    case WM_MOUSELEAVE:
        c->tracking_leave = 0;
        return 0;

    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
    case WM_MBUTTONDOWN: {
        int btn = msg == WM_LBUTTONDOWN ? W32_BTN_LEFT
                  : msg == WM_RBUTTONDOWN ? W32_BTN_RIGHT : W32_BTN_MIDDLE;
        c->mouse_down = btn;
        SetCapture(hwnd);
        SetFocus(hwnd);
        push_mouse(c, W32_MOUSE_PRESS, btn);
        return 0;
    }

    case WM_LBUTTONUP:
    case WM_RBUTTONUP:
    case WM_MBUTTONUP: {
        int btn = msg == WM_LBUTTONUP ? W32_BTN_LEFT
                  : msg == WM_RBUTTONUP ? W32_BTN_RIGHT : W32_BTN_MIDDLE;
        if (c->mouse_down == btn) c->mouse_down = 0;
        ReleaseCapture();
        push_mouse(c, W32_MOUSE_RELEASE, btn);
        return 0;
    }

    case WM_MOUSEWHEEL: {
        short delta = (short)HIWORD(wp);
        POINT pt;
        pt.x = (short)LOWORD(lp);
        pt.y = (short)HIWORD(lp);
        ScreenToClient(hwnd, &pt);
        w32_event e;
        memset(&e, 0, sizeof(e));
        e.type = W32_EV_WHEEL;
        e.delta = delta > 0 ? 1 : -1;
        e.x = pt.x;
        e.y = pt.y;
        e.state = mod_state(c);
        push_event(c, &e);
        return 0;
    }

    case WM_MOUSEHWHEEL:
        return 0;

    case WM_GETMINMAXINFO: {
        MINMAXINFO *mmi = (MINMAXINFO *)lp;
        mmi->ptMinTrackSize.x = c->cell_w * 8;
        mmi->ptMinTrackSize.y = c->cell_h * 2;
        return 0;
    }

    default:
        break;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

/* ------------------------------------------------------------------ */
/* 打开/关闭                                                           */
/* ------------------------------------------------------------------ */

void *w32_open(int cols, int rows, int cell_w, int cell_h, const char *title,
               const char *font_family, int font_px) {
    load_conpty();

    /* Per-Monitor V2 DPI 感知：按监视器 DPI 缩放整数字号，避免系统位图拉伸。 */
    typedef BOOL(WINAPI * pfn_set_dpi_ctx)(HANDLE);
    HMODULE u32 = GetModuleHandleW(L"user32.dll");
    if (u32) {
        pfn_set_dpi_ctx f =
            (pfn_set_dpi_ctx)(void *)GetProcAddress(u32, "SetProcessDpiAwarenessContext");
        if (f) f((HANDLE)(LONG_PTR)-4); /* DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 */
    }

    struct w32_ctx *c = (struct w32_ctx *)calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->dpi = 96;
    c->cursor_x = -1;
    c->cursor_y = -1;
    c->cell_w = cell_w > 0 ? cell_w : 8;
    c->cell_h = cell_h > 0 ? cell_h : 16;
    c->base_cw = cell_w;
    c->base_ch = cell_h;
    c->font_px = font_px > 0 ? font_px : 14;
    c->cols = cols > 0 ? cols : 80;
    c->rows = rows > 0 ? rows : 24;

    if (font_family && font_family[0]) {
        MultiByteToWideChar(CP_UTF8, 0, font_family, -1, c->face,
                            (int)(sizeof(c->face) / sizeof(c->face[0])));
    } else {
        wcscpy(c->face, L"Consolas");
    }

    const char *tr = getenv("LEANTTY_WIN_TRACE");
    if (tr && tr[0]) {
        c->trace = fopen(tr, "a");
        if (c->trace) setvbuf(c->trace, NULL, _IONBF, 0); /* 无缓冲，便于崩溃/退出后取证 */
    }

    HINSTANCE inst = GetModuleHandleW(NULL);
    WNDCLASSEXW wc;
    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS;
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_IBEAM);
    /* 图标来自 exe 内嵌资源（assets/icon/leantty.rc 的 `1 ICON`）：
     * 类图标 + 窗口图标都设上，任务栏与 Alt-Tab 才显示自己的图标，
     * 否则是 Windows 默认的空白窗口图标（用户反馈"左上角没有图标"）。 */
    wc.hIcon = (HICON)LoadImageW(inst, MAKEINTRESOURCEW(1), IMAGE_ICON, 0, 0, LR_DEFAULTSIZE);
    wc.hIconSm = (HICON)LoadImageW(inst, MAKEINTRESOURCEW(1), IMAGE_ICON,
                                   GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0);
    wc.hbrBackground = NULL;
    wc.lpszClassName = L"leantty-w32";
    RegisterClassExW(&wc); /* 重复注册会失败，忽略 */

    c->hwnd = CreateWindowExW(0, L"leantty-w32", L"leantty", WS_OVERLAPPEDWINDOW,
                              CW_USEDEFAULT, CW_USEDEFAULT,
                              cols * c->cell_w, rows * c->cell_h, NULL, NULL, inst, c);
    if (!c->hwnd) {
        free(c);
        return NULL;
    }
    SetWindowLongPtrW(c->hwnd, GWLP_USERDATA, (LONG_PTR)c);

    /* 大/小图标都显式设置：类图标在多显示器 DPI 变化时不一定跟着换。 */
    {
        HICON big = (HICON)LoadImageW(inst, MAKEINTRESOURCEW(1), IMAGE_ICON,
                                      GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), 0);
        HICON small = (HICON)LoadImageW(inst, MAKEINTRESOURCEW(1), IMAGE_ICON,
                                        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0);
        if (big) SendMessageW(c->hwnd, WM_SETICON, ICON_BIG, (LPARAM)big);
        if (small) SendMessageW(c->hwnd, WM_SETICON, ICON_SMALL, (LPARAM)small);
    }

    apply_dpi(c, c->dpi, NULL);
    /* 客户区必须是 cols*cell_w x rows*cell_h，外加边框后才是窗口尺寸。 */
    {
        c->cols = cols;
        c->rows = rows;
        RECT rc;
        rc.left = 0;
        rc.top = 0;
        rc.right = c->cell_w * cols;
        rc.bottom = c->cell_h * rows;
        AdjustWindowRectEx(&rc, WS_OVERLAPPEDWINDOW, FALSE, 0);
        SetWindowPos(c->hwnd, NULL, 0, 0, rc.right - rc.left, rc.bottom - rc.top,
                     SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
    recompute_grid(c, NULL, NULL);
    c->layout_ready = 1;
    push_resize(c);

    if (title) {
        wchar_t *wt = utf8_to_wide(title);
        if (wt) {
            SetWindowTextW(c->hwnd, wt);
            free(wt);
        }
    }
    ShowWindow(c->hwnd, SW_SHOW);
    UpdateWindow(c->hwnd);
    c->focused = 1;
    g_clip_ctx = c; /* 剪贴板操作需要 owner 窗口 */
    return c;
}

void w32_close(void *ctx) {
    struct w32_ctx *c = (struct w32_ctx *)ctx;
    if (!c) return;
    close_conpty(c);
    free_glyphs(c);
    destroy_buffer(c);
    destroy_ft(c);
    if (c->hwnd) DestroyWindow(c->hwnd);
    if (c->trace) fclose(c->trace);
    if (g_clip_ctx == c) g_clip_ctx = NULL;
    free(c);
}

int w32_next_event(void *ctx, w32_event *out) {
    struct w32_ctx *c = (struct w32_ctx *)ctx;
    if (!c || !out) return 0;

    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) {
            w32_event e;
            memset(&e, 0, sizeof(e));
            e.type = W32_EV_CLOSE;
            push_event(c, &e);
            continue;
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    if (c->q_head == c->q_tail) return 0;
    *out = c->queue[c->q_head];
    c->q_head = (c->q_head + 1) % EVENT_QUEUE_LEN;
    return 1;
}

void w32_set_title(void *ctx, const char *title) {
    struct w32_ctx *c = (struct w32_ctx *)ctx;
    if (!c || !c->hwnd || !title) return;
    wchar_t *wt = utf8_to_wide(title);
    if (wt) {
        SetWindowTextW(c->hwnd, wt);
        free(wt);
    }
}

/* ------------------------------------------------------------------ */
/* 剪贴板                                                              */
/* ------------------------------------------------------------------ */

/* 打开剪贴板；其它进程短暂占用时重试（实测过 OpenClipboard 一次失败就放弃
 * 会让 Ctrl+Shift+V 表现为“什么都没发生”）。 */
static int clip_open(void) {
    for (int i = 0; i < 20; i++) {
        if (OpenClipboard(g_clip_ctx ? g_clip_ctx->hwnd : NULL)) return 1;
        Sleep(5);
    }
    return 0;
}

/* 宽串（不含结尾 NUL）→ UTF-8。cap 不足时返回 -(需要字节数 + 1)，供调用方扩容重读。 */
static int wide_out(const wchar_t *w, size_t units, char *buf, int cap) {
    if (!w || units == 0) return 0;
    if (units > 0x7FFFFFFF) units = 0x7FFFFFFF;
    int need = WideCharToMultiByte(CP_UTF8, 0, w, (int)units, NULL, 0, NULL, NULL);
    if (need <= 0) return 0;
    if (need > cap - 1) return -(need + 1);
    int n = WideCharToMultiByte(CP_UTF8, 0, w, (int)units, buf, cap - 1, NULL, NULL);
    if (n <= 0) return 0;
    buf[n] = 0;
    return n;
}

int w32_clipboard_read(char *buf, int cap) {
    if (!buf || cap < 2) return -1;
    buf[0] = 0;
    if (!clip_open()) return -1;

    int result = -1;
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    if (h) {
        const wchar_t *w = (const wchar_t *)GlobalLock(h);
        if (w) {
            /* 长度以 GlobalSize 为上限，再按文本本身截到第一个 NUL：
             * 不用无界的 wcslen，也不把 GlobalSize 当成文本长度。 */
            SIZE_T bytes = GlobalSize(h);
            size_t max_units = bytes / sizeof(wchar_t);
            size_t len = 0;
            while (len < max_units && w[len] != 0) len++;
            result = wide_out(w, len, buf, cap);
            GlobalUnlock(h);
        }
    } else {
        /* 只有 CF_TEXT（ANSI）的剪贴板（部分老程序/远程会话）：按系统代码页转。
         * 不转的话表现为“从这些程序复制过来粘不进去”。 */
        HANDLE ha = GetClipboardData(CF_TEXT);
        if (ha) {
            const char *a = (const char *)GlobalLock(ha);
            if (a) {
                SIZE_T bytes = GlobalSize(ha);
                size_t len = 0;
                while (len < (size_t)bytes && a[len] != 0) len++;
                int wn = MultiByteToWideChar(CP_ACP, 0, a, (int)len, NULL, 0);
                if (wn > 0) {
                    wchar_t *w = (wchar_t *)malloc((size_t)wn * sizeof(wchar_t));
                    if (w) {
                        MultiByteToWideChar(CP_ACP, 0, a, (int)len, w, wn);
                        result = wide_out(w, (size_t)wn, buf, cap);
                        free(w);
                    }
                }
                GlobalUnlock(ha);
            }
        }
    }
    CloseClipboard();
    DBG("[win] clipboard-read cap=%d -> %d bytes%s\n", cap, result,
        result <= -2 ? " (需要扩容)" : "");
    return result;
}

void w32_clipboard_write(const char *utf8, int len) {
    if (!utf8 || len <= 0) return;
    DBG("[win] clipboard-write %d bytes\n", len);
    int wn = MultiByteToWideChar(CP_UTF8, 0, utf8, len, NULL, 0);
    if (wn <= 0) return;
    HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, (SIZE_T)(wn + 1) * sizeof(wchar_t));
    if (!mem) return;
    wchar_t *w = (wchar_t *)GlobalLock(mem);
    if (!w) {
        GlobalFree(mem);
        return;
    }
    MultiByteToWideChar(CP_UTF8, 0, utf8, len, w, wn);
    w[wn] = 0;
    GlobalUnlock(mem);

    /* 与读一致：别的进程短暂占用剪贴板时重试，否则复制会静默失败
     * （实测：并发占用时 Ctrl+Insert 看起来“没反应”）。 */
    if (!clip_open()) {
        GlobalFree(mem);
        DBG("[win] clipboard-write FAILED (open)\n");
        return;
    }
    EmptyClipboard();
    if (!SetClipboardData(CF_UNICODETEXT, mem)) GlobalFree(mem);
    CloseClipboard();
}

/* 供 Zig 侧写调试文件用（Windows CRT 的 FILE* 不便跨模块传递，这里用封装）。 */
void *w32_fopen(const char *path, const char *mode) { return (void *)fopen(path, mode); }
int w32_fwrite(const void *ptr, size_t size, size_t n, void *f) { return (int)fwrite(ptr, size, n, (FILE *)f); }
int w32_fclose(void *f) { return fclose((FILE *)f); }

int w32_file_exists(const char *path) {
    if (!path) return 0;
    wchar_t *wpath = utf8_to_wide(path);
    if (!wpath) return 0;
    DWORD attr = GetFileAttributesW(wpath);
    free(wpath);
    return (attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY)) ? 1 : 0;
}

int w32_read_file(const char *path, char *buf, int cap) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    size_t n = fread(buf, 1, (size_t)(cap > 0 ? cap - 1 : 0), f);
    fclose(f);
    if (cap > 0) buf[n] = 0;
    return (int)n;
}
