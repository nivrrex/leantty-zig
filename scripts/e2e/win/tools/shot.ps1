param([int]$processId = 0, [string]$cmdLike = "", [string]$out = "shot.png")
# Capture a leantty window to PNG (PrintWindow: works even when covered).
# Target is selected by pid or by a unique command-line substring.
$src = 'using System; using System.Runtime.InteropServices; public class Shot { [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r); [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags); [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; } }'
Add-Type -TypeDefinition $src
Add-Type -AssemblyName System.Drawing
if ($processId -eq 0 -and $cmdLike -ne "") {
    $c = Get-CimInstance Win32_Process -Filter "Name='leantty.exe'" |
         Where-Object { $_.CommandLine -like ("*" + $cmdLike + "*") } | Select-Object -First 1
    if (-not $c) { Write-Error "no leantty with cmd like $cmdLike"; exit 1 }
    $processId = $c.ProcessId
}
$p = Get-Process -Id $processId -ErrorAction Stop
$h = $p.MainWindowHandle
if ($h -eq 0) { Write-Error "no window for pid $processId"; exit 1 }
[void][Shot]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 300
$r = New-Object Shot+RECT
[void][Shot]::GetWindowRect($h, [ref]$r)
$w = $r.R - $r.L
$ht = $r.B - $r.T
if ($w -le 0 -or $ht -le 0) { Write-Error "bad rect"; exit 1 }
$bmp = New-Object System.Drawing.Bitmap $w, $ht
$g = [System.Drawing.Graphics]::FromImage($bmp)
$dc = $g.GetHdc()
[void][Shot]::PrintWindow($h, $dc, 0)
$g.ReleaseHdc($dc)
$g.Dispose()
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output ("saved " + $out + " " + $w + "x" + $ht)
