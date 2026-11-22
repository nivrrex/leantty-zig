# Type literal key presses (keybd_event) into a target window.
# SendKeys is NOT usable for IME tests: it pushes characters in a way that the
# IME conversion path ignores (verified: same Shift+text yields ASCII via
# SendKeys but a real composition via keybd_event).
# Supported: a-z A-Z 0-9 space and a few punctuation chars via VkKeyScanW.
param(
    [string]$cmdLike = "",
    [int]$processId = 0,
    [Parameter(Mandatory = $true)][string]$keys,
    [int]$delay = 400,
    [int]$gap = 90
)
$src = @'
using System;
using System.Runtime.InteropServices;
public class T {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern short VkKeyScanW(char ch);
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

$fg = [T]::GetForegroundWindow()
$tmp = [uint32]0
$fgtid = [T]::GetWindowThreadProcessId($fg, [ref]$tmp)
$mytid = [T]::GetCurrentThreadId()
[void][T]::AttachThreadInput($mytid, $fgtid, $true)
[void][T]::BringWindowToTop($h)
[void][T]::SetForegroundWindow($h)
[void][T]::AttachThreadInput($mytid, $fgtid, $false)
Start-Sleep -Milliseconds $delay

foreach ($ch in $keys.ToCharArray()) {
    $vk = [byte]([char]::ToUpper($ch))
    if ($ch -eq ' ') { $vk = 0x20 }
    [T]::keybd_event($vk, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    [T]::keybd_event($vk, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds $gap
}
Write-Output ("typed pid=" + $processId + " keys=" + $keys)
