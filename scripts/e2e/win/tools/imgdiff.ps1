param(
    [string]$a = "",
    [string]$b = "",
    [int]$top = 0,
    [int]$bottom = 0,
    [int]$left = 0,
    [int]$right = 0
)
# Mean absolute difference (0-255) between two PNGs over an optional rectangle.
Add-Type -AssemblyName System.Drawing
$ia = [System.Drawing.Bitmap]::FromFile($a)
$ib = [System.Drawing.Bitmap]::FromFile($b)
if ($ia.Width -ne $ib.Width -or $ia.Height -ne $ib.Height) {
    Write-Output "SIZE_MISMATCH $($ia.Width)x$($ia.Height) vs $($ib.Width)x$($ib.Height)"
    exit 2
}
if ($right -le 0 -or $right -gt $ia.Width) { $right = $ia.Width }
if ($bottom -le 0 -or $bottom -gt $ia.Height) { $bottom = $ia.Height }
$sum = 0.0; $n = 0
for ($y = $top; $y -lt $bottom; $y += 2) {
    for ($x = $left; $x -lt $right; $x += 2) {
        $pa = $ia.GetPixel($x, $y); $pb = $ib.GetPixel($x, $y)
        $sum += [Math]::Abs($pa.R - $pb.R) + [Math]::Abs($pa.G - $pb.G) + [Math]::Abs($pa.B - $pb.B)
        $n += 3
    }
}
$ia.Dispose(); $ib.Dispose()
Write-Output ("MAD {0:N2}" -f ($sum / [Math]::Max(1, $n)))
