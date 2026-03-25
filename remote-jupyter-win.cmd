@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Remote Jupyter GPU Launcher

set "WORKDIR=%USERPROFILE%\Documents\RemoteJupyter"
set "STATE_DIR=%USERPROFILE%\.remote-jupyter"
set "VENV_DIR=%WORKDIR%\.venv-gpu"
set "TORCH_CUDA_CHANNEL=%TORCH_CUDA_CHANNEL%"
if "%TORCH_CUDA_CHANNEL%"=="" set "TORCH_CUDA_CHANNEL=cu128"

mkdir "%WORKDIR%" 2>nul
mkdir "%STATE_DIR%" 2>nul

echo.
echo == Checking winget ==
where winget >nul 2>nul || (
  echo winget not found. Install App Installer from Microsoft Store first.
  pause
  exit /b 1
)

call :ensure_cmd node "OpenJS.NodeJS.LTS"
call :ensure_python
if errorlevel 1 exit /b 1

echo.
echo == Installing tunnel tools ==
call :ensure_cmd cloudflared "Cloudflare.cloudflared"
call :ensure_cmd ngrok "Ngrok.Ngrok" optional

REM Find launcher_helper.py next to this script
set "HELPER_PY=%~dp0launcher_helper.py"
if not exist "%HELPER_PY%" (
  echo launcher_helper.py not found next to this script.
  echo Expected: %HELPER_PY%
  pause
  exit /b 1
)

echo.
echo == Launching ==
python "%HELPER_PY%"
if errorlevel 1 (
  echo.
  echo Failed. Check logs under "%STATE_DIR%".
  pause
  exit /b 1
)

echo.
echo Press any key to close this window. Jupyter stays running.
pause >nul
exit /b 0

:ensure_python
where python >nul 2>nul && exit /b 0
echo.
echo == Installing Python 3.12 ==
winget install --id Python.Python.3.12 --exact --accept-package-agreements --accept-source-agreements --scope user --silent
call :refresh_path
where python >nul 2>nul && exit /b 0
if exist "%LocalAppData%\Programs\Python\Python312\python.exe" (
  set "PATH=%LocalAppData%\Programs\Python\Python312;%LocalAppData%\Programs\Python\Python312\Scripts;%PATH%"
  exit /b 0
)
echo Python installation failed or PATH was not updated.
exit /b 1

:ensure_cmd
set "CMD_NAME=%~1"
set "PKG_ID=%~2"
set "OPTIONAL=%~3"
where "%CMD_NAME%" >nul 2>nul && exit /b 0
echo.
echo == Installing %CMD_NAME% ==
winget install --id %PKG_ID% --exact --accept-package-agreements --accept-source-agreements --scope user --silent
call :refresh_path
where "%CMD_NAME%" >nul 2>nul && exit /b 0
if /i "%CMD_NAME%"=="node" if exist "%LocalAppData%\Programs\nodejs\node.exe" (
  set "PATH=%LocalAppData%\Programs\nodejs;%PATH%"
  exit /b 0
)
if /i "%CMD_NAME%"=="cloudflared" for /d %%D in ("%LocalAppData%\Microsoft\WinGet\Packages\Cloudflare.cloudflared*") do set "PATH=%%~fD;%PATH%"
where "%CMD_NAME%" >nul 2>nul && exit /b 0
if /i "%OPTIONAL%"=="optional" exit /b 0
echo %CMD_NAME% installation failed.
exit /b 1

:refresh_path
for /f "tokens=2,*" %%A in ('reg query "HKCU\Environment" /v Path 2^>nul ^| find "Path"') do set "USER_PATH=%%B"
if defined USER_PATH set "PATH=%USER_PATH%;%PATH%"
exit /b 0
