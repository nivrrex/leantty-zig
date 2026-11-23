/* 按键/粘贴字节探针：开启 bracketed paste，把 stdin 收到的原始字节按十六进制逐行落盘。
 * 用途：断言终端发出的转义序列是否**逐字节**正确（方向键、Ctrl 组合、粘贴包裹等），
 * 不依赖截图，也不依赖被测试程序如何解释它们。
 *
 * 编译：zig cc -o keydump scripts/e2e/tools/keydump.c
 *      zig cc -target x86_64-windows-gnu scripts/e2e/tools/keydump.c -o keydump.exe
 * 用法：环境变量 KEYDUMP_OUT 指定落盘路径，默认 /tmp/keydump.txt
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(_WIN32)
#include <io.h>
#define RAW_READ _read
#define RAW_FILENO _fileno
#else
#include <unistd.h>
#include <termios.h>
#define RAW_READ read
#define RAW_FILENO fileno
#endif

int main(void) {
#if !defined(_WIN32)
    /* 必须把 stdin 设成 raw：默认是规范模式，收到的 ESC 序列会攒在行缓冲里，
     * 直到换行才交给 read —— 第一版没设，探针文件里永远是空的。 */
    if (isatty(STDIN_FILENO)) {
        struct termios t;
        if (tcgetattr(STDIN_FILENO, &t) == 0) {
            cfmakeraw(&t);
            tcsetattr(STDIN_FILENO, TCSANOW, &t);
        }
    }
#endif
    const char *out = getenv("KEYDUMP_OUT");
    if (!out || !out[0]) out = "/tmp/keydump.txt";
    /* 只开 bracketed paste（?2004h）：此时方向键是 CSI 形式（ESC[A..D），
     * 与默认终端模式一致，断言更好写。要看应用光标键模式（ESC O A）时，
     * 在断言前发一次 "\033[?1h" 即可。 */
    printf("\033[?2004h");
    printf("KEYDUMP-READY\r\n");
    fflush(stdout);

    FILE *f = fopen(out, "wb");
    if (!f) return 1;
    fprintf(f, "start\n");
    fflush(f);
    /* 必须用裸 read：用 fread 时 stdio 会攒满 4KB 才返回，
     * 断言脚本读到的文件永远是空的（第一版就踩了这个坑）。 */
    unsigned char buf[4096];
    for (;;) {
        int n = (int)RAW_READ(RAW_FILENO(stdin), buf, sizeof buf);
        if (n <= 0) break;
        for (int i = 0; i < n; i++) fprintf(f, "%02x ", buf[i]);
        fprintf(f, "\n");
        fflush(f);
    }
    fprintf(f, "eof\n");
    fclose(f);
    return 0;
}
