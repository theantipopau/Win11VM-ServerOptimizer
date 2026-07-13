@echo off
:: Win11VM Server Optimizer - double-click launcher
:: by Matt Hurley - https://matthurley.dev
:: Self-elevates to admin, then hands off to the PowerShell script.
:: Any arguments passed to this .bat are forwarded as-is, e.g.:
::   Run-Win11VM-ServerOptimizer.bat -DryRun
::   Run-Win11VM-ServerOptimizer.bat -ExclusionPaths "C:\AMP\Instances","D:\Plex\Transcode"

setlocal

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

set "SCRIPT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Win11VM-ServerOptimizer.ps1" %*

echo.
pause
