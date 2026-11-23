param([int]$processId = 0, [string]$cmdLike = "")
# Focus a leantty window by pid (or command-line substring) and report whether it is
# really foreground. Used before injecting keybd_event keys: keybd_event goes to the
# foreground window, and the developer machine may have an unrelated window focused
# (sending arrows/Ctrl+A there would be destructive).
$src = @'
using System;
using System.Runtime.InteropServices;
public class F {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
}
'@
Add-Type -TypeDefinition $src

if ($processId -eq 0) {
    if ($cmdLike -eq "") { Write-Error "need -processId or -cmdLike"; exit 2 }
    $c = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like ("*" + $cmdLike + "*") } | Select-Object -First 1
    if (-not $c) { Write-Error "no process like $cmdLike"; exit 2 }
    $processId = $c.ProcessId
}
$p = Get-Process -Id $processId -ErrorAction Stop
$h = $p.MainWindowHandle
if ($h -eq 0) {
    Start-Sleep -Milliseconds 300
    $p = Get-Process -Id $processId -ErrorAction Stop
    $h = $p.MainWindowHandle
}
if ($h -eq 0) { Write-Output "FOCUS_FAIL no-window"; exit 1 }

[void][F]::ShowWindow($h, 5)   # SW_SHOW
$fg = [F]::GetForegroundWindow()
$tmp = [uint32]0
$fgtid = [F]::GetWindowThreadProcessId($fg, [ref]$tmp)
$mytid = [F]::GetCurrentThreadId()
[void][F]::AttachThreadInput($mytid, $fgtid, $true)
[void][F]::BringWindowToTop($h)
[void][F]::SetForegroundWindow($h)
[void][F]::AttachThreadInput($mytid, $fgtid, $false)
Start-Sleep -Milliseconds 150

$now = [F]::GetForegroundWindow()
if ($now -eq $h) { Write-Output "FOCUS_OK" ; exit 0 }
Write-Output "FOCUS_FAIL other-window"
exit 1
