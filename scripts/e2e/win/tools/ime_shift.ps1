# Send a single Shift keypress to a target window (toggle IME CN/EN state).
# A lone Shift cannot be produced with SendKeys (its "+" is a modifier prefix),
# so this uses keybd_event. Target is matched by pid or command-line substring.
param(
    [string]$cmdLike = "",
    [int]$processId = 0,
    [int]$delay = 400
)
$src = @'
using System;
using System.Runtime.InteropServices;
public class S {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
}
'@
Add-Type -TypeDefinition $src

if ($processId -eq 0) {
    if ($cmdLike -eq "") { Write-Error "need -cmdLike or -processId"; exit 1 }
    $c = Get-CimInstance Win32_Process |
         Where-Object { $_.CommandLine -like ("*" + $cmdLike + "*") } |
         Select-Object -First 1
    if (-not $c) { Write-Error "no process with cmd like $cmdLike"; exit 1 }
    $processId = $c.ProcessId
}
$p = Get-Process -Id $processId -ErrorAction Stop
$h = $p.MainWindowHandle
if ($h -eq 0) { Write-Error "no window for pid $processId"; exit 1 }

$fg = [S]::GetForegroundWindow()
$tmp = [uint32]0
$fgtid = [S]::GetWindowThreadProcessId($fg, [ref]$tmp)
$mytid = [S]::GetCurrentThreadId()
[void][S]::AttachThreadInput($mytid, $fgtid, $true)
[void][S]::BringWindowToTop($h)
[void][S]::SetForegroundWindow($h)
[void][S]::AttachThreadInput($mytid, $fgtid, $false)
Start-Sleep -Milliseconds $delay

[S]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero)   # VK_SHIFT down
Start-Sleep -Milliseconds 60
[S]::keybd_event(0x10, 0, 2, [UIntPtr]::Zero)   # VK_SHIFT up
Start-Sleep -Milliseconds 300
Write-Output ("shift pid=" + $processId)
