/* 读取指定控制台进程的屏幕文本（用于 IME 交叉对照：cmd 里能否打出中文）。
 * 编译：zig cc -target x86_64-windows-gnu tools/conread.c -o conread.exe
 * 用法：conread.exe <pid>
 */
#include <stdio.h>
#include <stdlib.h>
#include <windows.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: conread <pid>\n");
        return 1;
    }
    DWORD pid = (DWORD)atoi(argv[1]);
    FreeConsole();
    if (!AttachConsole(pid)) {
        fprintf(stderr, "attach failed %lu\n", (unsigned long)GetLastError());
        return 2;
    }
    HANDLE h = CreateFileW(L"CONOUT$", GENERIC_READ | GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "conout failed %lu\n", (unsigned long)GetLastError());
        FreeConsole();
        return 3;
    }
    CONSOLE_SCREEN_BUFFER_INFO ci;
    if (!GetConsoleScreenBufferInfo(h, &ci)) {
        CloseHandle(h);
        FreeConsole();
        return 4;
    }
    DWORD total = (DWORD)ci.dwSize.X * (DWORD)ci.dwSize.Y;
    wchar_t *buf = (wchar_t *)malloc(sizeof(wchar_t) * ((size_t)total + 1));
    if (!buf) {
        CloseHandle(h);
        FreeConsole();
        return 5;
    }
    COORD origin = { 0, 0 };
    DWORD got = 0;
    if (ReadConsoleOutputCharacterW(h, buf, total, origin, &got)) {
        /* 转 UTF-8 输出（中文要能保住，用 WideCharToMultiByte） */
        int need = WideCharToMultiByte(CP_UTF8, 0, buf, (int)got, NULL, 0, NULL, NULL);
        if (need > 0) {
            char *out = (char *)malloc((size_t)need + 1);
            if (out) {
                WideCharToMultiByte(CP_UTF8, 0, buf, (int)got, out, need, NULL, NULL);
                out[need] = 0;
                fwrite(out, 1, (size_t)need, stdout);
                free(out);
            }
        }
    }
    free(buf);
    CloseHandle(h);
    FreeConsole();
    return 0;
}
