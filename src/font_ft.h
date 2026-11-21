/* 平台无关的 FreeType 字体层：Linux（fontconfig 解析路径）与 Windows（扫描字体目录）
 * 共用同一份加载/光栅/度量代码，保证两平台的观感与格子度量一致。
 *
 * 调用方职责：把"家族名 → 字体文件路径"解析好（Linux 用 fontconfig，Windows 用目录索引），
 * 然后把路径数组交给本层。本层不接触任何平台 API。 */
#ifndef LEANTTY_FONT_FT_H
#define LEANTTY_FONT_FT_H

#include <stdint.h>

#define FT_FONT_MAX_FACES 24

typedef struct ft_font ft_font;

/* paths 的前 n_style 个是样式槽（normal/bold/italic/bold_italic），可为 NULL；
 * 其余是回退链（按顺序）。pixel_size 为期望像素大小；纯位图字体会退化到最近的 strike。 */
ft_font *ft_font_open(const char *const *paths, int n_paths, int n_style, int pixel_size);

void ft_font_close(ft_font *f);

/* 调试用：某个 face 的 PostScript 名/家族名（越界返回 NULL）。 */
const char *ft_font_postscript(ft_font *f, int index);
const char *ft_font_family(ft_font *f, int index);

/* 取字形位图。返回字节数（<0 表示出错，0 表示空字形）。
 * bpp/premul 仅在非 NULL 时写入：bpp=1 灰度覆盖度，bpp=4 BGRA（彩色 emoji）。 */
int ft_font_glyph(ft_font *f, uint32_t codepoint, int style,
                  unsigned char *out, int cap,
                  int *w, int *h, int *left, int *top, int *advance,
                  int *bpp, int *premul);

/* 诊断用：样式槽指向的 face 下标 / 回退链起始下标。 */
int ft_font_face_count(ft_font *f);
int ft_font_style_face(ft_font *f, int slot);
int ft_font_first_fallback(ft_font *f);

/* 以 'M' 为基准的度量：ascent/descent 向下为正、height 含 line gap、advance 为 'M' 的步进。 */
int ft_font_metrics(ft_font *f, int *ascent, int *descent, int *line_height, int *advance);

#endif
