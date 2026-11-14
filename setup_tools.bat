@echo off
title Media Workflow X - Setup & Tool Downloader
cd /d "%~dp0"
echo ==================================================================
echo   MEDIA WORKFLOW X - Menjalankan Setup & Unduh Tools Otomatis
echo ==================================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_tools.ps1" %*
echo.
echo ==================================================================
echo   Tekan tombol apa saja untuk menutup jendela ini...
echo ==================================================================
pause >nul
