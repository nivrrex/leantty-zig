param(
    [string]$cmdLike = "",
    [int]$processId = 0,
    [Parameter(Mandatory = $true)][string]$keys,
    [int]$delay = 350
)
# Focus a leantty instance (found by pid or by a unique command-line substring)
# and inject keystrokes with SendKeys. Never touches other leantty instances.
$src = 'using System; using System.Runtime.InteropServices; public class K { [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h); [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid); [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f); [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId(); }'
Add-Type -TypeDefinition $src
Add-Type -AssemblyName System.Windows.Forms

if ($processId -eq 0) {
    $c = Get-CimInstance Win32_Process -Filter "Name='leantty.exe'" |
         Where-Object { $_.CommandLine -like ("*" + $cmdLike + "*") } | Select-Object -First 1
    if (-not $c) { Write-Error "no leantty with cmd like $cmdLike"; exit 1 }
    $processId = $c.ProcessId
}
$p = Get-Process -Id $processId -ErrorAction Stop
$h = $p.MainWindowHandle
if ($h -eq 0) { Write-Error "no window for pid $processId"; exit 1 }

$fg = [K]::GetForegroundWindow()
$tmp = [uint32]0
$fgtid = [K]::GetWindowThreadProcessId($fg, [ref]$tmp)
$mytid = [K]::GetCurrentThreadId()
[void][K]::AttachThreadInput($mytid, $fgtid, $true)
[void][K]::BringWindowToTop($h)
[void][K]::SetForegroundWindow($h)
[void][K]::AttachThreadInput($mytid, $fgtid, $false)
Start-Sleep -Milliseconds $delay
[System.Windows.Forms.SendKeys]::SendWait($keys)
Start-Sleep -Milliseconds 200
Write-Output ("send pid=" + $processId + " keys=" + $keys)
