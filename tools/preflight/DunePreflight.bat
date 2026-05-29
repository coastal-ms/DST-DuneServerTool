@echo off
:: DunePreflight.bat - Launcher for DunePreflight.ps1
:: - Verifies admin (does NOT auto-elevate — right-click this file -> Run as administrator)
:: - Prefers PowerShell 7 (pwsh) but falls back to Windows PowerShell 5.1
:: - Bypasses ExecutionPolicy so the .ps1 runs even from a downloaded zip
:: - Unblocks the .ps1 to strip Mark-of-the-Web

setlocal

set "PS1=%~dp0DunePreflight.ps1"
if not exist "%PS1%" (
    echo.
    echo ERROR: DunePreflight.ps1 not found next to this .bat file.
    echo Expected: %PS1%
    echo.
    pause
    exit /b 1
)

:: --- Verify admin (do NOT auto-elevate) -------------------------------------
net session >nul 2>&1
if errorlevel 1 (
    echo.
    echo ============================================================
    echo   Not running as administrator.
    echo ============================================================
    echo   The preflight needs admin to query Hyper-V, Windows
    echo   features, the local firewall, and HTTP.sys.
    echo.
    echo   Close this window, RIGHT-CLICK DunePreflight.bat, and
    echo   choose "Run as administrator".
    echo ============================================================
    echo.
    pause
    exit /b 1
)

:: --- Pick a PowerShell host (prefer pwsh 7) ---------------------------------
where pwsh.exe >nul 2>&1
if not errorlevel 1 (
    set "PSEXE=pwsh.exe"
) else (
    set "PSEXE=powershell.exe"
)

:: --- Unblock the .ps1 if it has Zone.Identifier (MOTW) ----------------------
%PSEXE% -NoProfile -Command "Unblock-File -LiteralPath '%PS1%' -ErrorAction SilentlyContinue"

:: --- Run the preflight ------------------------------------------------------
%PSEXE% -NoProfile -ExecutionPolicy Bypass -STA -File "%PS1%"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo Preflight script exited with code %RC%.
    pause
)

endlocal & exit /b %RC%
