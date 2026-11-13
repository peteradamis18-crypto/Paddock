@echo off
rem UNDO: brings iRacing's own on-screen flag back. Close the sim first.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0hud-flag.ps1" -On
pause
