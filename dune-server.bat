@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0dune-server.ps1" %*
if errorlevel 1 pause
