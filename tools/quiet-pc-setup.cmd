@echo off
rem Paddock: Quiet PC (one click, once)
rem While a session is on, Paddock pauses Windows Update, search indexing and OneDrive, and keeps the sim at high priority.
rem When the session ends it hands back exactly what was running. This click lets it do that by itself from now on:
rem it adds two tasks to Windows ("Paddock Quiet PC on" and "Paddock Quiet PC off"). Windows asks for permission once.
rem Paddock and Claude never run this by themselves. To go back: quiet-pc-setup-UNDO.cmd
setlocal
title Paddock: Quiet PC
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0quiet-pc.ps1" -Setup
echo.
echo Done. Quiet PC now happens by itself in every session. quiet-pc-setup-UNDO.cmd takes it away again.
timeout /t 15 >nul
