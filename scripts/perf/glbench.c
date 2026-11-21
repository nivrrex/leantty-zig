/* GPU 呈现/渲染路径对比探针
 *
 * 在同一台机器、同一窗口尺寸（1920x1080）下逐条测量每帧耗时：
 *   A. 整帧上传 + 四边形（当前实现）：glTexSubImage2D(8MB) → draw → swap
 *   B. PBO 异步上传：glMapBufferRange 写入 → glTexSubImage2D 从 PBO → draw → swap
 *   C. 字形图集（GPU 直画）：一次性上传 atlas，每帧 1 个 draw call 画 ~12k 个 quad
 *   D. texture-from-pixmap：XShm 写入 Pixmap → glXBindTexImageEXT → draw → swap
 *      （需要 GLXFBConfig 的 visual；窗口也用该 visual）
 *
 * 用法：glbench [A|B|C|D|all] [frames]
 */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XShm.h>
#define GL_GLEXT_PROTOTYPES 1
#include <GL/gl.h>
#include <GL/glext.h>
#include <GL/glx.h>
#include <GL/glxext.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <time.h>

#define W 1920
#define H 1080
#define CELLS_COLS 240
#define CELLS_ROWS 67 /* 240*67 ≈ 16k 个格子 */

static Display *dpy;
static int scr;
static Window win;
static GLXContext ctx;
static int F;

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

/* ---------- 公共：着色器 + 数据 ---------- */
static GLuint prog_tex; /* 采样整帧纹理 */
static GLuint prog_gly; /* 图集里取字形 */
static GLuint tex_frame, tex_atlas;
static GLuint vbo_quad, vbo_glyphs;
static int n_glyph_quads;

static const char *VS =
    "attribute vec2 a_pos;\n"
    "attribute vec2 a_uv;\n"
    "varying vec2 v_uv;\n"
    "void main(){ v_uv=a_uv; gl_Position=vec4(a_pos,0.0,1.0); }\n";
static const char *FS =
    "uniform sampler2D u_tex;\n"
    "varying vec2 v_uv;\n"
    "void main(){ gl_FragColor = texture2D(u_tex, v_uv); }\n";

static GLuint mkprog(const char *vs_src, const char *fs_src) {
    GLuint v = glCreateShader(GL_VERTEX_SHADER);
    glShaderSource(v, 1, &vs_src, NULL);
    glCompileShader(v);
    GLuint f = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(f, 1, &fs_src, NULL);
    glCompileShader(f);
    GLuint p = glCreateProgram();
    glAttachShader(p, v);
    glAttachShader(p, f);
    glLinkProgram(p);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetProgramInfoLog(p, sizeof(log), NULL, log);
        fprintf(stderr, "link failed: %s\n", log);
        exit(1);
    }
    return p;
}

static void setup(void) {
    prog_tex = mkprog(VS, FS);
    prog_gly = mkprog(VS, FS);

    glGenTextures(1, &tex_frame);
    glBindTexture(GL_TEXTURE_2D, tex_frame);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, W, H, 0, GL_BGRA, GL_UNSIGNED_BYTE, NULL);

    /* 全屏四边形 */
    static const GLfloat quad[] = {
        -1.f, -1.f, 0.f, 1.f, 1.f, -1.f, 1.f, 1.f, 1.f, 1.f, 1.f, 0.f,
        -1.f, -1.f, 0.f, 1.f, 1.f, 1.f, 1.f, 0.f, -1.f, 1.f, 0.f, 0.f,
    };
    glGenBuffers(1, &vbo_quad);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_quad);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);

    /* 字形图集：1024x1024，随机填充成"字形覆盖率"的样子 */
    unsigned char *atlas = malloc(1024 * 1024 * 4);
    for (int i = 0; i < 1024 * 1024; i++) {
        unsigned char v = (unsigned char)((i * 37) & 0xff);
        atlas[i * 4 + 0] = v;
        atlas[i * 4 + 1] = v;
        atlas[i * 4 + 2] = v;
        atlas[i * 4 + 3] = 255;
    }
    glGenTextures(1, &tex_atlas);
    glBindTexture(GL_TEXTURE_2D, tex_atlas);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1024, 1024, 0, GL_BGRA, GL_UNSIGNED_BYTE, atlas);

    /* 字形 quad：每格 2 个三角形，模拟一整屏文字（240x67 格） */
    n_glyph_quads = CELLS_COLS * CELLS_ROWS;
    size_t verts = (size_t)n_glyph_quads * 6;
    GLfloat *g = malloc(verts * 4 * sizeof(GLfloat));
    float cw = 2.0f / CELLS_COLS, ch = 2.0f / CELLS_ROWS;
    size_t k = 0;
    for (int y = 0; y < CELLS_ROWS; y++) {
        for (int x = 0; x < CELLS_COLS; x++) {
            float x0 = -1.f + x * cw, y0 = -1.f + y * ch;
            float u0 = (float)((x * 7) % 32) / 32.f, v0 = (float)((y * 5) % 32) / 32.f;
            float u1 = u0 + 1.f / 32.f, v1 = v0 + 1.f / 32.f;
            GLfloat tri[24] = {
                x0,      y0,      u0, v1, x0 + cw, y0,      u1, v1, x0 + cw, y0 + ch, u1, v0,
                x0,      y0,      u0, v1, x0 + cw, y0 + ch, u1, v0, x0,      y0 + ch, u0, v0,
            };
            memcpy(&g[k], tri, sizeof(tri));
            k += 24;
        }
    }
    glGenBuffers(1, &vbo_glyphs);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_glyphs);
    glBufferData(GL_ARRAY_BUFFER, (long)(verts * 4 * sizeof(GLfloat)), g, GL_STATIC_DRAW);
    free(g);
    free(atlas);
}

static void draw_quad(GLuint prog, GLuint tex, GLuint uv_vbo) {
    glUseProgram(prog);
    glUniform1i(glGetUniformLocation(prog, "u_tex"), 0);
    glBindTexture(GL_TEXTURE_2D, tex);
    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);
    glBindBuffer(GL_ARRAY_BUFFER, uv_vbo);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), 0);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat),
                          (void *)(2 * sizeof(GLfloat)));
    if (uv_vbo == vbo_quad) glDrawArrays(GL_TRIANGLES, 0, 6);
    else glDrawArrays(GL_TRIANGLES, 0, n_glyph_quads * 6);
}

/* ---------- A: 整帧上传 ---------- */
static double bench_upload(unsigned char *frame) {
    double t0 = now_ms();
    glBindTexture(GL_TEXTURE_2D, tex_frame);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, W, H, GL_BGRA, GL_UNSIGNED_BYTE, frame);
    draw_quad(prog_tex, tex_frame, vbo_quad);
    glXSwapBuffers(dpy, win);
    return now_ms() - t0;
}

/* ---------- B: PBO 异步上传 ---------- */
static GLuint pbo[2];
static int pbo_idx;
static double bench_pbo(unsigned char *frame) {
    double t0 = now_ms();
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, pbo[pbo_idx]);
    void *p = glMapBufferRange(GL_PIXEL_UNPACK_BUFFER, 0, W * H * 4,
                               GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
    if (p) {
        memcpy(p, frame, (size_t)W * H * 4);
        glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
    }
    glBindTexture(GL_TEXTURE_2D, tex_frame);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, W, H, GL_BGRA, GL_UNSIGNED_BYTE, (void *)0);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    draw_quad(prog_tex, tex_frame, vbo_quad);
    glXSwapBuffers(dpy, win);
    pbo_idx ^= 1;
    return now_ms() - t0;
}

/* ---------- C: 字形图集（GPU 直画）---------- */
static double bench_glyphs(void) {
    double t0 = now_ms();
    glClear(GL_COLOR_BUFFER_BIT);
    draw_quad(prog_gly, tex_atlas, vbo_glyphs);
    glXSwapBuffers(dpy, win);
    return now_ms() - t0;
}

/* ---------- D: texture-from-pixmap ---------- */
static Pixmap xpix;
static GLXPixmap glx_pix;
static XImage *pix_img;
static XShmSegmentInfo pix_shm;
static double bench_tfp(unsigned char *frame) {
    double t0 = now_ms();
    int bpl = pix_img->bytes_per_line;
    unsigned char *dst = (unsigned char *)pix_img->data;
    for (int y = 0; y < H; y++)
        memcpy(dst + (size_t)y * (size_t)bpl, frame + (size_t)y * W * 4, (size_t)W * 4);
    XShmPutImage(dpy, xpix, DefaultGC(dpy, scr), pix_img, 0, 0, 0, 0, W, H, False);
    XFlush(dpy);
    glXBindTexImageEXT(dpy, glx_pix, GLX_FRONT_EXT, NULL);
    draw_quad(prog_tex, tex_frame, vbo_quad);
    glXReleaseTexImageEXT(dpy, glx_pix, GLX_FRONT_EXT);
    glXSwapBuffers(dpy, win);
    return now_ms() - t0;
}

static void report(const char *name, double *samples, int n) {
    double sum = 0, mn = 1e9, mx = 0;
    for (int i = 0; i < n; i++) {
        sum += samples[i];
        if (samples[i] < mn) mn = samples[i];
        if (samples[i] > mx) mx = samples[i];
    }
    double avg = sum / n;
    printf("%-42s 平均 %6.2f ms  最小 %6.2f  最大 %6.2f   → %6.1f fps\n", name, avg, mn, mx, 1000.0 / avg);
}

int main(int argc, char **argv) {
    const char *which = argc > 1 ? argv[1] : "all";
    F = argc > 2 ? atoi(argv[2]) : 120;
    dpy = XOpenDisplay(NULL);
    if (!dpy) { printf("no display\n"); return 1; }
    scr = DefaultScreen(dpy);

    /* 选带 PIXMAP_BIT + 可绑纹理的 FBConfig（D 需要它；A/B/C 也用它的 visual） */
    int ncfg = 0;
    int att[] = {
        GLX_DRAWABLE_TYPE, GLX_WINDOW_BIT | GLX_PIXMAP_BIT,
        GLX_RENDER_TYPE, GLX_RGBA_BIT,
        GLX_BIND_TO_TEXTURE_RGBA_EXT, True,
        GLX_BIND_TO_TEXTURE_TARGETS_EXT, GLX_TEXTURE_2D_BIT_EXT,
        GLX_DOUBLEBUFFER, True,
        GLX_RED_SIZE, 8, GLX_GREEN_SIZE, 8, GLX_BLUE_SIZE, 8,
        None,
    };
    GLXFBConfig *cfgs = glXChooseFBConfig(dpy, scr, att, &ncfg);
    if (!cfgs || ncfg == 0) { printf("no fbconfig with pixmap+texture\n"); return 1; }
    GLXFBConfig cfg = cfgs[0];
    XVisualInfo *vi = glXGetVisualFromFBConfig(dpy, cfg);
    printf("fbconfig: visualid=0x%lx depth=%d\n", vi->visualid, vi->depth);

    XSetWindowAttributes swa;
    memset(&swa, 0, sizeof(swa));
    swa.colormap = XCreateColormap(dpy, RootWindow(dpy, scr), vi->visual, AllocNone);
    swa.background_pixel = 0x101010;
    swa.event_mask = ExposureMask | KeyPressMask;
    win = XCreateWindow(dpy, RootWindow(dpy, scr), 0, 0, W, H, 0, vi->depth, InputOutput,
                        vi->visual, CWColormap | CWBackPixel | CWEventMask, &swa);
    XStoreName(dpy, win, "glbench");
    XMapWindow(dpy, win);
    XFlush(dpy);

    ctx = glXCreateContext(dpy, vi, NULL, GL_TRUE);
    if (!ctx || !glXMakeCurrent(dpy, win, ctx)) { printf("no gl\n"); return 1; }
    /* 关 vsync，测的是提交成本而不是刷新率 */
    {
        PFNGLXSWAPINTERVALEXTPROC si = (PFNGLXSWAPINTERVALEXTPROC)
            glXGetProcAddress((const GLubyte *)"glXSwapIntervalEXT");
        if (si) si(dpy, win, 0);
    }
    printf("GL_RENDERER: %s   vsync=0\n", glGetString(GL_RENDERER));
    setup();

    unsigned char *frame = malloc((size_t)W * H * 4);
    for (size_t i = 0; i < (size_t)W * H; i++) {
        frame[i * 4 + 0] = (unsigned char)(i & 0xff);
        frame[i * 4 + 1] = (unsigned char)((i >> 8) & 0xff);
        frame[i * 4 + 2] = (unsigned char)((i >> 16) & 0xff);
        frame[i * 4 + 3] = 255;
    }
    glGenBuffers(2, pbo);
    for (int i = 0; i < 2; i++) {
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, pbo[i]);
        glBufferData(GL_PIXEL_UNPACK_BUFFER, (long)W * H * 4, NULL, GL_STREAM_DRAW);
    }
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);

    double *s = malloc(sizeof(double) * F);

    if (!strcmp(which, "all") || !strcmp(which, "A")) {
        for (int i = 0; i < 10; i++) bench_upload(frame); /* 预热 */
        for (int i = 0; i < F; i++) s[i] = bench_upload(frame);
        report("A 整帧上传 glTexSubImage2D", s, F);
    }
    if (!strcmp(which, "all") || !strcmp(which, "B")) {
        for (int i = 0; i < 10; i++) bench_pbo(frame);
        for (int i = 0; i < F; i++) s[i] = bench_pbo(frame);
        report("B PBO 双缓冲异步上传", s, F);
    }
    if (!strcmp(which, "all") || !strcmp(which, "C")) {
        for (int i = 0; i < 10; i++) bench_glyphs();
        for (int i = 0; i < F; i++) s[i] = bench_glyphs();
        report("C 字形图集（GPU 直画 16k 格）", s, F);
    }
    if (!strcmp(which, "all") || !strcmp(which, "D")) {
        xpix = XCreatePixmap(dpy, win, W, H, (unsigned)vi->depth);
        int pattrs[] = { GLX_TEXTURE_TARGET_EXT, GLX_TEXTURE_2D_EXT,
                         GLX_TEXTURE_FORMAT_EXT, GLX_TEXTURE_FORMAT_RGBA_EXT, None };
        glx_pix = glXCreatePixmap(dpy, cfg, xpix, pattrs);
        if (!glx_pix) {
            printf("D texture-from-pixmap: 该 visual 无法创建 GLXPixmap\n");
        } else {
            pix_img = XShmCreateImage(dpy, vi->visual, (unsigned)vi->depth, ZPixmap, NULL,
                                      &pix_shm, W, H);
            pix_shm.shmid = shmget(IPC_PRIVATE, (size_t)pix_img->bytes_per_line * H,
                                   IPC_CREAT | 0600);
            pix_shm.shmaddr = pix_img->data = shmat(pix_shm.shmid, NULL, 0);
            pix_shm.readOnly = False;
            XShmAttach(dpy, &pix_shm);
            XSync(dpy, False);
            shmctl(pix_shm.shmid, IPC_RMID, NULL);
            for (int i = 0; i < 10; i++) bench_tfp(frame);
            for (int i = 0; i < F; i++) s[i] = bench_tfp(frame);
            report("D texture-from-pixmap (XShm→Pixmap)", s, F);
        }
    }

    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
