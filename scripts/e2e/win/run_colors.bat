@echo off
rem Color evidence run for Windows. ASCII only (cmd.exe reads .bat in OEM codepage).
rem Edit EXE below if your build lives elsewhere.
setlocal
set "EXE=%~dp0..\..\..\zig-out\bin\leantty.exe"
if not exist "%EXE%" set "EXE=E:\Compiler\Leantty\leantty-zig.exe"
if not exist "%EXE%" (
  echo [ERROR] leantty-zig.exe not found. Edit the EXE line in this file.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_colors.ps1" -Exe "%EXE%" -Out "%~dp0.win-colors"
echo.
echo Done. Please zip and send the ".win-colors" folder next to this script.
pause
