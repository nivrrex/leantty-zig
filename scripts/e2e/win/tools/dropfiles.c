/* 拖放"发送器"探针（Windows）：构造一个 HDROP 并给目标窗口发 WM_DROPFILES。
 *
 * 为什么需要它：真实拖放要人拿鼠标从资源管理器拖，自动化做不到。WM_DROPFILES
 * 的载荷就是一个 HGLOBAL 里的 DROPFILES 结构 + 双 NUL 结尾的宽字符路径列表，
 * 手工构造即可等价于"拖进来"（这是 Windows 上常见的测试手法）。
 *
 * 用法：
 *   dropfiles.exe <窗口句柄（十进制或 0x…）> <文件路径> [文件路径…]
 *
 * 注意：SendMessage 之后内存所有权交给接收方，由它的 DragFinish() 释放；
 * 这里再 GlobalFree 会 double free。
 */
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h> /* DROPFILES：mingw 的头把它放在 shlobj.h（MSVC 在 shellapi.h） */
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

int main(void) {
    int argc = 0;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc < 3) {
        fprintf(stderr, "用法: dropfiles.exe <窗口句柄> <路径> [路径…]\n");
        return 1;
    }
    const HWND hwnd = (HWND)(ULONG_PTR)wcstoull(argv[1], NULL, 0);
    if (!hwnd || !IsWindow(hwnd)) {
        fprintf(stderr, "dropfiles: 窗口句柄无效\n");
        return 1;
    }

    size_t chars = 1; /* 结尾双 NUL */
    for (int i = 2; i < argc; i++) chars += wcslen(argv[i]) + 1;
    const size_t bytes = sizeof(DROPFILES) + chars * sizeof(wchar_t);
    HGLOBAL g = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes);
    if (!g) {
        fprintf(stderr, "dropfiles: GlobalAlloc 失败\n");
        return 1;
    }
    DROPFILES *df = (DROPFILES *)GlobalLock(g);
    if (!df) {
        GlobalFree(g);
        fprintf(stderr, "dropfiles: GlobalLock 失败\n");
        return 1;
    }
    df->pFiles = (DWORD)sizeof(DROPFILES);
    df->fWide = TRUE;
    wchar_t *p = (wchar_t *)((BYTE *)df + sizeof(DROPFILES));
    for (int i = 2; i < argc; i++) {
        const size_t n = wcslen(argv[i]);
        memcpy(p, argv[i], n * sizeof(wchar_t));
        p += n + 1; /* 每个路径以 NUL 结尾 */
    }
    *p = L'\0'; /* 列表以空串结束 */
    GlobalUnlock(g);

    /* 同步发送：接收方在自己的消息循环里处理，处理完我们才返回，
     * 便于脚本紧接着读探针文件做断言。 */
    LRESULT r = SendMessageW(hwnd, WM_DROPFILES, (WPARAM)g, 0);
    printf("dropfiles: WM_DROPFILES sent (result=%ld, files=%d)\n", (long)r, argc - 2);
    LocalFree(argv);
    return 0;
}
