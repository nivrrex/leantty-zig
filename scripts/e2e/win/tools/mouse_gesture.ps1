# Drive real mouse gestures at client-cell coordinates of a window.
# path: "col,row" single click, "col,row>col,row" drag.
param(
    [string]$cmdLike = "",
    [int]$processId = 0,
    [Parameter(Mandatory = $true)][string]$path,   # "col,row[>col,row]" client cell coords; '>' = drag
    [int]$cellW = 8,
    [int]$cellH = 18,
    [int]$wait = 700
)
# Drive real mouse gestures at client-cell coordinates of a window.
# path examples: "2,3" (single click), "2,3>12,6" (press at 2,3, drag to 12,6, release)
$src = @'
using System;
using System.Runtime.InteropServices;
public class M {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
}
'@
Add-Type -TypeDefinition $src

if ($processId -eq 0) {
    if ($cmdLike -eq "") { Write-Error "need -cmdLike or -processId"; exit 1 }
    $c = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like ("*" + $cmdLike + "*") } | Select-Object -First 1
    if (-not $c) { Write-Error "no process like $cmdLike"; exit 1 }
    $processId = $c.ProcessId
}
$p = Get-Process -Id $processId -ErrorAction Stop
$h = $p.MainWindowHandle
if ($h -eq 0) { Write-Error "no window"; exit 1 }
[void][M]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 400

$origin = New-Object M+POINT
[void][M]::ClientToScreen($h, [ref]$origin)

function ToScreen($cell) {
    $parts = $cell.Split(',')
    $pt = New-Object M+POINT
    $pt.x = [int]$parts[0]; $pt.y = [int]$parts[1]
    return @{ x = $origin.x + $pt.x * $cellW + [int]($cellW / 2); y = $origin.y + $pt.y * $cellH + [int]($cellH / 2) }
}

$segs = $path.Split('>')
$a = ToScreen $segs[0]
[void][M]::SetCursorPos($a.x, $a.y)
Start-Sleep -Milliseconds 150
[M]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)   # LEFTDOWN
Start-Sleep -Milliseconds 120
if ($segs.Count -gt 1) {
    $b = ToScreen $segs[1]
    $steps = 12
    for ($i = 1; $i -le $steps; $i++) {
        $x = [int]($a.x + ($b.x - $a.x) * $i / $steps)
        $y = [int]($a.y + ($b.y - $a.y) * $i / $steps)
        [void][M]::SetCursorPos($x, $y)
        Start-Sleep -Milliseconds 40
    }
}
Start-Sleep -Milliseconds 100
[M]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)   # LEFTUP
Start-Sleep -Milliseconds $wait
Write-Output ("mouse path=" + $path + " screen=" + $a.x + "," + $a.y + " origin=" + $origin.x + "," + $origin.y)
