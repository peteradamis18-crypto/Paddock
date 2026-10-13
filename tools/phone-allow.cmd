@echo off
rem Paddock: let your iPhone in (one time)
rem Double-click once. Windows asks for permission (click Yes). It marks your home network as Private (home) if Windows calls it
rem Public, adds ONE firewall rule 'Paddock phone (irdash 8199 in)' (TCP 8199, Private network, your own network only, dash\irdash.exe
rem only) and writes dash\phone-allowed.txt. Paddock then shows a code on the top screen to scan with the iPhone camera.
rem Paddock and Claude never run this by themselves. To go back: phone-undo.cmd.
setlocal
title Paddock: let your iPhone in
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0phone-tools.ps1" -Do allow
timeout /t 3 >nul
