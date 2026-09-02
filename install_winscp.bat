@echo off
setlocal
title SyncPulse - Setup ^& Launch

echo ========================================================
echo          SyncPulse - Setup and Launcher
echo ========================================================
echo.

REM 1. Check if WinSCP is already installed
where WinSCP.com >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] WinSCP is already installed.
    goto :launch
)

if exist "%ProgramFiles%\WinSCP\WinSCP.com" (
    echo [OK] WinSCP is already installed in Program Files.
    goto :launch
)
if exist "%ProgramFiles(x86)%\WinSCP\WinSCP.com" (
    echo [OK] WinSCP is already installed in Program Files (x86).
    goto :launch
)
if exist "%LOCALAPPDATA%\Programs\WinSCP\WinSCP.com" (
    echo [OK] WinSCP is already installed in Local AppData.
    goto :launch
)

REM 2. Install WinSCP via winget if missing
echo [INFO] WinSCP was not detected on this system.
echo [INFO] Installing WinSCP via Windows Package Manager (winget)...
echo.
winget install --id WinSCP.WinSCP -e --accept-package-agreements --accept-source-agreements

if %errorlevel% neq 0 (
    echo.
    echo [ERROR] WinSCP installation failed or was cancelled.
    echo Please install WinSCP manually from https://winscp.net/
    pause
    exit /b %errorlevel%
)

echo.
echo [OK] WinSCP installed successfully!

:launch
echo.
echo [INFO] Launching SyncPulse System Tray...
set "SCRIPT_DIR=%~dp0"
start "" wscript.exe "%SCRIPT_DIR%Start-Tray.vbs"
echo [OK] SyncPulse is now running in your notification area.
echo.
timeout /t 3 >nul
