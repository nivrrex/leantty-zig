/* altui.exe: fake full-screen TUI -- enter alt screen, draw a few lines, park the cursor
 * at the requested cell, then hold. Usage: altui.exe [row] [col] [seconds]
 * Purpose: reproduce "alt screen + cursor away from the first row" for IME candidate tests. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    int row = argc > 1 ? atoi(argv[1]) : 20;
    int col = argc > 2 ? atoi(argv[2]) : 5;
    int secs = argc > 3 ? atoi(argv[3]) : 30;
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD mode = 0;
    if (GetConsoleMode(out, &mode))
        SetConsoleMode(out, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);

    /* alt screen + clear + a few fake UI lines */
    printf("\x1b[?1049h\x1b[2J\x1b[H");
    printf("=== altui (fake TUI) ===\r\n");
    for (int i = 1; i <= 8; i++) printf("line %d: 0123456789 abcdefghij\r\n", i);
    printf("\x1b[1;1H\x1b[7m status bar \x1b[0m");
    /* park the cursor where asked (TUIs rarely leave it on row 1) */
    printf("\x1b[%d;%dH", row, col);
    fflush(stdout);
    Sleep((DWORD)secs * 1000);
    printf("\x1b[?1049l");
    fflush(stdout);
    return 0;
}
