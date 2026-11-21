param([string]$cmdLike = "", [int]$processId = 0, [int]$x = 80, [int]$y = 80, [switch]$drag, [int]$x2 = 200, [int]$y2 = 140)
# Left-click (optionally drag) inside a leantty window, selected by pid or
# command-line substring. Client coordinates are pixels.
$src = 'using System; using System.Runtime.InteropServices; public class M1 { [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p); [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y); [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e); [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h); [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; } }'
Add-Type -TypeDefinition $src
if ($processId -eq 0) {
    $c = Get-CimInstance Win32_Process -Filter "Name='leantty.exe'" |
         Where-Object { $_.CommandLine -like ("*" + $cmdLike + "*") } | Select-Object -First 1
    if (-not $c) { Write-Error "no leantty with cmd like $cmdLike"; exit 1 }
    $processId = $c.ProcessId
}
$p = Get-Process -Id $processId -ErrorAction Stop
$h = $p.MainWindowHandle
if ($h -eq 0) { Write-Error "no window"; exit 1 }
[void][M1]::BringWindowToTop($h)
[void][M1]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 300
$pt = New-Object M1+POINT
$pt.X = $x; $pt.Y = $y
[void][M1]::ClientToScreen($h, [ref]$pt)
[void][M1]::SetCursorPos($pt.X, $pt.Y)
Start-Sleep -Milliseconds 200
[M1]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 150
if ($drag) {
    $pt2 = New-Object M1+POINT
    $pt2.X = $x2; $pt2.Y = $y2
    [void][M1]::ClientToScreen($h, [ref]$pt2)
    for ($i = 1; $i -le 5; $i++) {
        $mx = $pt.X + [int](($pt2.X - $pt.X) * $i / 5)
        $my = $pt.Y + [int](($pt2.Y - $pt.Y) * $i / 5)
        [void][M1]::SetCursorPos($mx, $my)
        Start-Sleep -Milliseconds 60
    }
}
[M1]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
Write-Output ("click pid=" + $processId + " at " + $x + "," + $y)
