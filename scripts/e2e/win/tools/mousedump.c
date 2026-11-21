/* 鼠标上报探针：打开 1002/1006 后把收到的字节按十六进制回显到屏幕。
 * 用途：run_mouse.sh 里检测 conhost 是否把 DECSET 1002/1006 转发给了终端。
 * 编译：zig cc -target x86_64-windows-gnu tools/mousedump.c -o mousedump.exe
 */
#include <stdio.h>
#include <windows.h>

int main(void) {
    HANDLE hin = GetStdHandle(STD_INPUT_HANDLE);
    DWORD mode = 0;
    if (GetConsoleMode(hin, &mode)) {
        mode &= ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
        mode |= ENABLE_VIRTUAL_TERMINAL_INPUT;
        SetConsoleMode(hin, mode);
    }
    HANDLE hout = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD omode = 0;
    if (GetConsoleMode(hout, &omode)) SetConsoleMode(hout, omode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);

    printf("MOUSE-PROBE-READY\r\n");
    printf("\x1b[?1002h\x1b[?1006h"); /* 请求 button 模式 + SGR 编码 */
    fflush(stdout);

    char buf[256];
    while (1) {
        DWORD n = 0;
        if (!ReadFile(hin, buf, sizeof(buf), &n, NULL) || n == 0) break;
        printf("BYTES");
        for (DWORD i = 0; i < n; i++) printf(" %02X", (unsigned char)buf[i]);
        printf("\r\n");
        fflush(stdout);
    }
    return 0;
}
