# Color evidence run (Windows). ASCII only: PowerShell 5.1 may read .ps1 as ANSI.
# Writes a 48-line ANSI color sample, runs the given exe, and exports every cell's
# final fg/bg via APP_DUMP_COLORS (row col fg bg). No screenshots needed.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File run_colors.ps1 -Exe "Z:\...\leantty.exe"

param(
    [string]$Exe = ".\leantty-zig.exe",
    [string]$Out = ".win-colors"
)

$ErrorActionPreference = "Stop"
$esc = [char]27
$outDir = [System.IO.Path]::GetFullPath($Out)
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$cfgPath = Join-Path $outDir "colors.toml"
$cfg = @"
[window]
dimensions = { columns = 80, lines = 60 }

[font]
size = 13.0

[colors]
draw_bold_text_with_bright_colors = true

[colors.primary]
background = "#F3F1E9"
foreground = "#303238"

[colors.normal]
black = "#303238"
red = "#B94B4B"
green = "#39804D"
yellow = "#A87925"
blue = "#3568A8"
magenta = "#98628D"
cyan = "#398D91"
white = "#85847D"

[colors.bright]
black = "#77766F"
red = "#D45B55"
green = "#4C9660"
yellow = "#BD913C"
blue = "#527FBD"
magenta = "#AE78A1"
cyan = "#54A5A4"
white = "#E5E2D9"
"@
[System.IO.File]::WriteAllText($cfgPath, $cfg, (New-Object System.Text.UTF8Encoding($false)))

$l = New-Object System.Collections.Generic.List[string]
$reset = $esc + "[0m"
for ($i = 0; $i -lt 8; $i++)  { $l.Add($esc + "[" + (30 + $i)  + "m########" + $reset) }
for ($i = 0; $i -lt 8; $i++)  { $l.Add($esc + "[" + (90 + $i)  + "m########" + $reset) }
for ($i = 0; $i -lt 8; $i++)  { $l.Add($esc + "[" + (40 + $i)  + "m        " + $reset) }
for ($i = 0; $i -lt 8; $i++)  { $l.Add($esc + "[" + (100 + $i) + "m        " + $reset) }
foreach ($c in 16, 21, 196, 226, 46, 201, 244, 255) {
    $l.Add($esc + "[48;5;" + $c + "m        " + $reset)
}
foreach ($rgb in "255;0;0", "0;255;0", "0;0;255", "18;52;86") {
    $l.Add($esc + "[48;2;" + $rgb + "m        " + $reset)
}
$l.Add($esc + "[1;31m########" + $reset)
$l.Add($esc + "[1m########" + $reset)
$l.Add($esc + "[2;31m########" + $reset)
$l.Add($esc + "[7m########" + $reset)
$samplePath = Join-Path $outDir "sample.txt"
[System.IO.File]::WriteAllText($samplePath, ($l -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

$dumpPath = Join-Path $outDir "zig-colors.txt"
if (Test-Path $dumpPath) { Remove-Item $dumpPath -Force }
$env:APP_COLS = "80"
$env:APP_ROWS = "60"
$env:LEANTTY_CONFIG = $cfgPath
$env:APP_DUMP_COLORS = $dumpPath

#  /  / SHA256 / 
$fi = Get-Item $Exe
# Get-FileHash  PowerShell2.0/ .NET 
function Get-Sha256([string]$path) {
    $fs = [System.IO.File]::OpenRead($path)
    try {
        $alg = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = $alg.ComputeHash($fs)
            return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
        } finally { $alg.Dispose() }
    } finally { $fs.Dispose() }
}
$sha = Get-Sha256 $Exe
Write-Host ("psver  : " + $PSVersionTable.PSVersion.ToString())
Write-Host "exe    : $Exe"
Write-Host ("size   : {0} bytes   mtime: {1}" -f $fi.Length, $fi.LastWriteTime)
Write-Host "sha256 : $sha"
try { $ver = & $Exe --version 2>&1 | Select-Object -First 1; Write-Host "version: $ver" } catch { }
Write-Host "sample : $samplePath ($($l.Count) lines)"
Write-Host "config : $cfgPath"
Write-Host "dump   : $dumpPath"

$argList = @("--config-file", $cfgPath, "-e", "cmd.exe", "/c",
             "type `"$samplePath`" & ping -n 12 127.0.0.1 > nul")
$p = Start-Process -FilePath $Exe -ArgumentList $argList -PassThru
Start-Sleep -Seconds 5
if (-not $p.HasExited) { $p.Kill() }
Start-Sleep -Milliseconds 500

if (-not (Test-Path $dumpPath)) {
    Write-Warning "no dump produced. Is EXE the new build (with APP_DUMP_COLORS)?"
    exit 1
}
$rows = Get-Content $dumpPath
Write-Host ""
Write-Host "samples (first cell of rows 0/8/16/24/32/40/44/45/46/47):"
foreach ($r in 0, 8, 16, 24, 32, 40, 44, 45, 46, 47) {
    $hit = $rows | Where-Object { $_ -match "^$r " } | Select-Object -First 1
    if ($hit) { Write-Host ("  " + $hit) }
}
Write-Host ""
Write-Host "dump lines: $($rows.Count)"
Write-Host "Send back: $dumpPath  (or zip the whole folder)"
