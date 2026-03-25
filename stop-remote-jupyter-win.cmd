@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "STATE_DIR=%USERPROFILE%\.remote-jupyter"

for %%F in ("%STATE_DIR%\tunnel.pid" "%STATE_DIR%\jupyter.pid") do (
  if exist "%%~fF" (
    set /p PID=<"%%~fF"
    if defined PID taskkill /PID !PID! /F >nul 2>nul
    del /f /q "%%~fF" >nul 2>nul
  )
)

echo Stopped remote Jupyter processes if they were running.
pause
