@echo off
:: Throwaway-VM round-trip test - launcher
:: by Matt Hurley - https://matthurley.dev
::
:: REQUIRES A DISPOSABLE MACHINE. This applies the real optimizer, then restores it.
:: Use it inside a Windows Sandbox or a VM you can revert. The harness refuses to run
:: without -IAmInAThrowawayMachine, and this launcher does not add that for you.
::
:: Self-elevates to admin (the optimizer requires it), then hands off to the PowerShell harness.
:: Any arguments are forwarded as-is, e.g.:
::   Run-RoundTripTest.bat -IAmInAThrowawayMachine
::   Run-RoundTripTest.bat -IAmInAThrowawayMachine -SkipAppX

setlocal EnableExtensions

net session >nul 2>&1
if errorlevel 1 goto :need_elevation

set "SCRIPT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Invoke-RoundTripTest.ps1" %*
set "RC=%errorlevel%"

echo.
if not "%RC%"=="0" echo Round-trip test exited with code %RC% - see the report for details.
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
    echo Elevation was cancelled or failed - nothing was run.
    exit /b 1
)
exit /b 0
