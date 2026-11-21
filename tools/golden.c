/* 跨平台字体黄金文件工具：用同一份 FreeType 字体层（font_ft.c）输出
 * 度量与字形位图哈希，Linux 与 Windows 各跑一次做 diff。
 *
 * 用法：golden <pixel_size> <字体文件> [更多回退字体...] -- <码点(十六进制)...>
 * 输出：稳定的文本格式（同一输入必须逐字节相同），便于存成黄金文件比对。
 */
#include "../src/font_ft.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned int fnv1a(const unsigned char *p, size_t n) {
    unsigned int h = 2166136261u;
    for (size_t i = 0; i < n; i++) {
        h ^= p[i];
        h *= 16777619u;
    }
    return h;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <pixel_size> <font> [fallbacks...] -- <codepoint-hex...>\n", argv[0]);
        return 2;
    }
    int px = atoi(argv[1]);
    if (px <= 0) return 2;

    const char *paths[FT_FONT_MAX_FACES];
    int n_paths = 0;
    int cp_start = -1;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--") == 0) {
            cp_start = i + 1;
            break;
        }
        if (n_paths < FT_FONT_MAX_FACES) paths[n_paths++] = argv[i];
    }
    if (n_paths == 0 || cp_start < 0) return 2;

    /* 第一个字体同时占 4 个样式槽（金色文件只验证字形层，不涉及样式选择）。 */
    const char *slot[FT_FONT_MAX_FACES];
    int n = 0;
    for (int i = 0; i < 4; i++) slot[n++] = paths[0];          /* 4 个样式槽都用主字体 */
    for (int i = 1; i < n_paths && n < FT_FONT_MAX_FACES; i++) slot[n++] = paths[i];

    ft_font *f = ft_font_open(slot, n, 4, px);
    if (!f) {
        fprintf(stderr, "font open failed\n");
        return 1;
    }
    int asc = 0, desc = 0, lh = 0, adv = 0;
    if (ft_font_metrics(f, &asc, &desc, &lh, &adv) != 0) {
        fprintf(stderr, "metrics failed\n");
        ft_font_close(f);
        return 1;
    }
    printf("version 1\n");
    printf("pixel %d\n", px);
    printf("metrics ascent=%d descent=%d height=%d advance=%d\n", asc, desc, lh, adv);
    int nfaces = ft_font_face_count(f);
    printf("faces %d\n", nfaces);
    printf("style faces: %d %d %d %d first_fallback=%d\n",
           ft_font_style_face(f, 0), ft_font_style_face(f, 1),
           ft_font_style_face(f, 2), ft_font_style_face(f, 3),
           ft_font_first_fallback(f));
    for (int i = 0; i < nfaces; i++)
        printf("face %d ps=%s\n", i, ft_font_postscript(f, i) ? ft_font_postscript(f, i) : "?");

    static unsigned char buf[144 * 144 * 4];
    for (int i = cp_start; i < argc; i++) {
        unsigned long cp = strtoul(argv[i], NULL, 16);
        int w = 0, h = 0, left = 0, top = 0, a2 = 0, bpp = 1, premul = 1;
        int nb = ft_font_glyph(f, (uint32_t)cp, 0, buf, (int)sizeof(buf),
                               &w, &h, &left, &top, &a2, &bpp, &premul);
        if (nb < 0) {
            printf("glyph %06lx error=%d\n", cp, nb);
            continue;
        }
        printf("glyph %06lx w=%d h=%d left=%d top=%d adv=%d bpp=%d premul=%d hash=%08x\n",
               cp, w, h, left, top, a2, bpp, premul, fnv1a(buf, (size_t)nb));
    }
    ft_font_close(f);
    return 0;
}
