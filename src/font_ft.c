/* 平台无关的 FreeType 字体层实现（见 font_ft.h）。 */
#include "font_ft.h"

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_SYNTHESIS_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define STYLE_SLOTS 4

struct ft_font {
    FT_Library lib;
    FT_Face faces[FT_FONT_MAX_FACES];
    int n_faces;
    int style_face[STYLE_SLOTS]; /* 指向 faces 的下标，-1 = 无 */
    int first_fallback;          /* faces[first_fallback..] 是回退链 */
    const char *face_path[FT_FONT_MAX_FACES];
    int pixel_size;
    /* 跨字面合并后的度量（见 recompute_metrics）。baseline 与行高必须按所有字面的最大值来算，
     * 否则 CJK 回退字体的字形顶部会被主字体的 ascent 裁掉（实测 1px，见 REPORT 6.52）。 */
    int m_ascent, m_descent, m_height, m_advance;
};

static void recompute_metrics(ft_font *f);

static int env_dbg(void) {
    const char *v = getenv("LEANTTY_FONTDBG");
    return v && v[0] && v[0] != '0';
}

/* 打开一个 face 并设定尺寸；纯位图字体（CBDT/COLR 固定 strike，如 Noto Color Emoji 只有 128px）
 * 不接受任意像素尺寸，退化为最近的 strike，由渲染侧缩放。 */
static FT_Face open_face(FT_Library lib, const char *path, int pixel_size) {
    FT_Face face = NULL;
    if (!path) return NULL;
    FT_Error err = FT_New_Face(lib, path, 0, &face);
    if (err != 0) {
        if (env_dbg()) fprintf(stderr, "fontdbg: open failed path=%s err=%d\n", path, (int)err);
        return NULL;
    }
    if (FT_Set_Pixel_Sizes(face, 0, (FT_UInt)pixel_size) != 0) {
        if (face->num_fixed_sizes > 0) {
            FT_Select_Size(face, 0);
        } else {
            FT_Done_Face(face);
            return NULL;
        }
    }
    if (env_dbg()) {
        const char *ps = FT_Get_Postscript_Name(face);
        fprintf(stderr,
                "fontdbg: px=%d ps=%s family=%s style=%s asc=%d desc=%d height=%d fixed=%d\n",
                pixel_size, ps ? ps : "?",
                face->family_name ? face->family_name : "?",
                face->style_name ? face->style_name : "?",
                (int)face->size->metrics.ascender >> 6,
                (int)face->size->metrics.descender >> 6,
                (int)face->size->metrics.height >> 6,
                face->num_fixed_sizes);
    }
    return face;
}

ft_font *ft_font_open(const char *const *paths, int n_paths, int n_style, int pixel_size) {
    if (n_style > STYLE_SLOTS) n_style = STYLE_SLOTS;
    ft_font *f = calloc(1, sizeof(*f));
    if (!f) return NULL;
    f->pixel_size = pixel_size;
    for (int i = 0; i < STYLE_SLOTS; i++) f->style_face[i] = -1;
    if (FT_Init_FreeType(&f->lib) != 0) {
        free(f);
        return NULL;
    }
    /* 同路径只开一次：样式回落到 normal 时复用同一个 face，避免重复占用与重复释放。 */
    for (int i = 0; i < n_style; i++) {
        const char *p = paths[i];
        if (!p) continue;
        int found = -1;
        for (int j = 0; j < f->n_faces; j++) {
            if (f->face_path[j] && strcmp(f->face_path[j], p) == 0) {
                found = j;
                break;
            }
        }
        if (found >= 0) {
            f->style_face[i] = found;
            continue;
        }
        FT_Face face = open_face(f->lib, p, pixel_size);
        if (!face) continue;
        if (f->n_faces < FT_FONT_MAX_FACES) {
            f->style_face[i] = f->n_faces;
            f->face_path[f->n_faces] = p;
            f->faces[f->n_faces++] = face;
        } else {
            FT_Done_Face(face);
        }
    }
    if (f->style_face[0] < 0) {
        FT_Done_FreeType(f->lib);
        free(f);
        return NULL;
    }
    /* 缺失的样式槽回落到 normal（不做合成粗体/斜体：与 alacritty / Rust 版一致） */
    for (int i = 1; i < STYLE_SLOTS; i++) {
        if (f->style_face[i] < 0) f->style_face[i] = f->style_face[0];
    }
    f->first_fallback = f->n_faces;
    for (int i = n_style; i < n_paths; i++) {
        if (!paths[i]) continue;
        if (f->n_faces >= FT_FONT_MAX_FACES) break;
        FT_Face face = open_face(f->lib, paths[i], pixel_size);
        if (face && f->n_faces < FT_FONT_MAX_FACES) {
            f->face_path[f->n_faces] = paths[i];
            f->faces[f->n_faces++] = face;
        } else if (face) {
            FT_Done_Face(face);
        }
    }
    recompute_metrics(f);
    return f;
}

/* 格子度量：**只取主字体（normal 样式）**，与 alacritty 同口径
 * （cell_height = ascent + descent + line_gap = FT 的 height）。
 *
 * 为什么不取所有字面的最大值：那会把行高抬 1–2px，与 alacritty 不一致（用户实测"字体过长"）。
 * 回退字体（CJK）字形比主字体高时，改由渲染侧允许纵向溢出格子（见 render.zig / win32.c），
 * 不再靠抬高行高来容错。
 *
 * 行高兜底：若主字体 height < ascent+descent（少数字体报错），按 ascent+descent 取。 */
static void recompute_metrics(ft_font *f) {
    FT_Face face = f->style_face[0] >= 0 ? f->faces[f->style_face[0]] : NULL;
    int asc = 0, desc = 0, height = 0;
    if (face && face->size) {
        asc = (int)(face->size->metrics.ascender >> 6);
        desc = (int)(-face->size->metrics.descender >> 6);
        height = (int)(face->size->metrics.height >> 6);
    }
    if (height < asc + desc) height = asc + desc;
    f->m_ascent = asc;
    f->m_descent = desc;
    f->m_height = height;

    f->m_advance = 0;
    if (f->style_face[0] >= 0) {
        FT_Face face = f->faces[f->style_face[0]];
        if (face && FT_Load_Char(face, 'M', FT_LOAD_RENDER) == 0)
            f->m_advance = (int)(face->glyph->advance.x >> 6);
    }
    if (env_dbg())
        fprintf(stderr, "fontdbg: merged metrics asc=%d desc=%d height=%d adv=%d (faces=%d)\n",
                f->m_ascent, f->m_descent, f->m_height, f->m_advance, f->n_faces);
}

void ft_font_close(ft_font *f) {
    if (!f) return;
    for (int i = 0; i < f->n_faces; i++) {
        if (f->faces[i]) FT_Done_Face(f->faces[i]);
    }
    FT_Done_FreeType(f->lib);
    free(f);
}

const char *ft_font_postscript(ft_font *f, int index) {
    if (!f || index < 0 || index >= f->n_faces || !f->faces[index]) return NULL;
    return FT_Get_Postscript_Name(f->faces[index]);
}

const char *ft_font_family(ft_font *f, int index) {
    if (!f || index < 0 || index >= f->n_faces || !f->faces[index]) return NULL;
    return f->faces[index]->family_name;
}

/* 选面：样式槽有该字就用它；否则 normal；否则按顺序查回退链。 */
static FT_Face pick_face(ft_font *f, uint32_t cp, int style) {
    if (style < 0 || style >= STYLE_SLOTS) style = 0;
    int slot = f->style_face[style];
    if (slot >= 0 && FT_Get_Char_Index(f->faces[slot], (FT_ULong)cp) != 0) return f->faces[slot];
    slot = f->style_face[0];
    if (slot >= 0 && FT_Get_Char_Index(f->faces[slot], (FT_ULong)cp) != 0) return f->faces[slot];
    for (int i = f->first_fallback; i < f->n_faces; i++) {
        if (FT_Get_Char_Index(f->faces[i], (FT_ULong)cp) != 0) return f->faces[i];
    }
    return f->style_face[0] >= 0 ? f->faces[f->style_face[0]] : NULL;
}

int ft_font_glyph(ft_font *f, uint32_t codepoint, int style,
                  unsigned char *out, int cap,
                  int *w, int *h, int *left, int *top, int *advance,
                  int *bpp, int *premul) {
    if (!f || !out) return -1;
    FT_Face face = pick_face(f, codepoint, style);
    if (!face) return -1;
    /* FT_LOAD_COLOR：彩色字体（CBDT/COLR）返回 BGRA；单色字体不受影响。 */
    if (FT_Load_Char(face, (FT_ULong)codepoint, FT_LOAD_RENDER | FT_LOAD_COLOR) != 0) return -1;
    FT_GlyphSlot g = face->glyph;
    int ww = (int)g->bitmap.width;
    int hh = (int)g->bitmap.rows;
    if (w) *w = ww;
    if (h) *h = hh;
    if (left) *left = g->bitmap_left;
    if (top) *top = g->bitmap_top;
    if (advance) *advance = (int)(g->advance.x >> 6);
    if (ww <= 0 || hh <= 0) return 0;
    int is_bgra = g->bitmap.pixel_mode == FT_PIXEL_MODE_BGRA;
    if (bpp) *bpp = is_bgra ? 4 : 1;
    int need = ww * hh * (is_bgra ? 4 : 1);
    if (need > cap) return -1;
    if (!is_bgra) {
        for (int y = 0; y < hh; y++)
            memcpy(out + (size_t)y * (size_t)ww,
                   g->bitmap.buffer + (size_t)y * (size_t)g->bitmap.pitch, (size_t)ww);
        return need;
    }
    /* BGRA：逐行拷贝并判定是否预乘 alpha（不同字体/FreeType 版本不一致，
     * 按数据判定，避免渲染侧重复乘 alpha 导致偏暗）。 */
    int premul_flag = 1;
    for (int y = 0; y < hh; y++) {
        const unsigned char *row = g->bitmap.buffer + (size_t)y * (size_t)g->bitmap.pitch;
        memcpy(out + (size_t)y * (size_t)ww * 4, row, (size_t)ww * 4);
        if (premul_flag) {
            for (int x = 0; x < ww; x++) {
                unsigned char b = row[x * 4 + 0], gg = row[x * 4 + 1];
                unsigned char r = row[x * 4 + 2], a = row[x * 4 + 3];
                if (r > a || gg > a || b > a) {
                    premul_flag = 0;
                    break;
                }
            }
        }
    }
    if (premul) *premul = premul_flag;
    return need;
}

int ft_font_face_count(ft_font *f) { return f ? f->n_faces : 0; }

int ft_font_style_face(ft_font *f, int slot) {
    if (!f || slot < 0 || slot >= STYLE_SLOTS) return -1;
    return f->style_face[slot];
}

int ft_font_first_fallback(ft_font *f) { return f ? f->first_fallback : -1; }

int ft_font_metrics(ft_font *f, int *ascent, int *descent, int *line_height, int *advance) {
    if (!f || f->style_face[0] < 0) return -1;
    /* 用跨字面合并值：单个字面的 ascender 不足以容纳回退字体的字形高度。 */
    if (ascent) *ascent = f->m_ascent;
    if (descent) *descent = f->m_descent;
    if (line_height) *line_height = f->m_height;
    if (advance) *advance = f->m_advance;
    return 0;
}
