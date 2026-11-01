@echo off
:: Win11VM Server Optimizer - double-click launcher
:: by Matt Hurley - https://matthurley.dev
:: Self-elevates to admin, then hands off to the PowerShell script.
:: Any arguments passed to this .bat are forwarded as-is, e.g.:
::   Run-Win11VM-ServerOptimizer.bat -DryRun
::   Run-Win11VM-ServerOptimizer.bat -ExclusionPaths "C:\AMP\Instances","D:\Plex\Transcode"
:: Exits with the optimizer's own exit code (1 if any action failed), so this is
:: usable from a scheduled task or wrapper as well as by double-click.

setlocal EnableExtensions

net session >nul 2>&1
if errorlevel 1 goto :need_elevation

set "SCRIPT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Win11VM-ServerOptimizer.ps1" %*
set "RC=%errorlevel%"

echo.
if not "%RC%"=="0" echo Win11VM-ServerOptimizer exited with code %RC% - see the log for details.
pause
exit /b %RC%

:need_elevation
call :elevate %*
exit /b %errorlevel%

:elevate
:: Runs as its own subroutine so each line is expanded when it executes - the
:: quoted self-path below needs the value set on the previous line.
echo Requesting administrator privileges...
set "SELF=%~f0"
set "SELF=%SELF:'=''%"
set "ELEVATED_ARGS=%*"
set "ELEVATED_ARGS=%ELEVATED_ARGS:'=''%"
powershell -NoProfile -Command "Start-Process -FilePath '%SELF%' -ArgumentList '%ELEVATED_ARGS%' -Verb RunAs"
if errorlevel 1 (
    echo Elevation was cancelled or failed - nothing was changed.
    exit /b 1
)
exit /b 0
