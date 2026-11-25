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
#include <windows.h>
#define RAW_READ _read
#define RAW_FILENO _fileno
#else
#include <unistd.h>
#include <termios.h>
#define RAW_READ read
#define RAW_FILENO fileno
#endif

int main(int argc, char **argv) {
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
#if defined(_WIN32)
    /* Windows/ConPTY 下必须打开 VT 输入模式：否则方向键会被 conhost 变成
     * "键记录"（VK_UP 之类），而 _read 只能读到字符 —— 探针文件永远是空的，
     * 会误判成"终端没发字节"。开了之后 conhost 会把 ESC[A 之类的序列原样给出。 */
    if (!getenv("KEYDUMP_CHAR_MODE")) {
        HANDLE hin = GetStdHandle(STD_INPUT_HANDLE);
        DWORD mode = 0;
        if (GetConsoleMode(hin, &mode)) {
            SetConsoleMode(hin, (mode & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT)) |
                                  ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_EXTENDED_FLAGS);
        }
    }
#endif
    const char *out = getenv("KEYDUMP_OUT");
    if (!out || !out[0]) out = "/tmp/keydump.txt";
    /* 模式由可选参数决定，便于对比"同一按键在不同协议下应该发什么"：
     *   （无参数） 只开 bracketed paste：方向键是 CSI 形式（ESC[A..D）
     *   app        应用光标键模式（?1h）：方向键是 SS3 形式（ESC O A..D）
     *   kitty      键盘协议 push（CSI > 1 u）：pi/vim 这类程序用的就是它
     *   kitty-all  push + 所有 flag（含 report alternate keys / all keys）
     *   modify     xterm modifyOtherKeys=2（CSI > 4 ; 2 m）
     * 注意：这些序列本身会先写进 stdin 探针文件的前几行，断言时按行剔除。 */
    const char *mode = (argc > 1) ? argv[1] : getenv("KEYDUMP_MODE");
    if (!mode) mode = "";
    /* KEYDUMP_NO_BRACKETED=1：不开 DEC 2004，用于验证"程序没要求 bracketed 时
     * 终端不该自作主张包裹"（拖放/粘贴两条路径的空包裹分支）。 */
    if (!getenv("KEYDUMP_NO_BRACKETED")) printf("\033[?2004h");
    if (strcmp(mode, "app") == 0) printf("\033[?1h");
    else if (strcmp(mode, "kitty") == 0) printf("\033[>1u");
    else if (strcmp(mode, "kitty-all") == 0) printf("\033[>31u");
    else if (strcmp(mode, "modify") == 0) printf("\033[>4;2m");
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
