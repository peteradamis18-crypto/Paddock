@echo off
rem Paddock UNDO: Quiet PC off for good
rem Hands back Windows Update, search indexing and OneDrive if they are paused, and removes the two Quiet PC tasks.
rem Windows asks for permission once. Paddock and Claude never run this by themselves.
setlocal
title Paddock UNDO: Quiet PC off for good
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0quiet-pc.ps1" -Undo
echo.
echo Done. Windows looks after updates, search and OneDrive on its own again.
timeout /t 15 >nul
