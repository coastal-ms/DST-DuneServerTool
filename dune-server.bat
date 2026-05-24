@echo off
setlocal
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0dune-server.ps1" %*
set EC=%errorlevel%
if %EC% NEQ 0 (
    echo.
    echo [dune-server.bat] PowerShell exited with code %EC%.
    echo Any background jobs spawned by this run have been cleaned up.
    pause
)
endlocal & exit /b %EC%
