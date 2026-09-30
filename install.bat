@echo off
title BalatroSync Installer
echo Starting BalatroSync Installation...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo PowerShell script exited with error code %ERRORLEVEL%.
    pause
)
