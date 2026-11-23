# conpty.dll / OpenConsole.exe 来源与许可

这两个二进制来自 **Windows Terminal** 项目（microsoft/terminal），许可为 **MIT**。
它们是 OpenConsole —— Windows Terminal 使用的 ConPTY 实现，按字节流直通 VT 序列，
因此 **括号粘贴标记（`ESC[200~`/`ESC[201~`）与 kitty 键盘协议** 能完整到达子进程；
kernel32 自带的 inbox conhost 会把这些序列翻译成键记录从而丢弃。

- 本目录中的副本取自 leantty（Rust 版）v0.2.13 的 Windows 包（该包已随包分发同样文件）。
- 运行时行为：`leantty.exe` 启动时按 `exe 同目录 conpty.dll` → 系统 `conpty.dll` →
  kernel32 的顺序装载（见 `src/win32.c::load_conpty`）。删除本目录的两个文件后，
  打包出的 zip 不含它们，程序会回退 inbox conhost（行为同 0.1.18）。
- 上游：https://github.com/microsoft/terminal （MIT，见该仓库 LICENSE）
