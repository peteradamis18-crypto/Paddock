@echo off
rem Paddock: try hardware GPU scheduling ON
rem An experiment, not a fix: Windows hardware-accelerated GPU scheduling switched on (needs administrator approval once, then a restart). Paddock marks the change and compares your sessions before and after.
rem Double-click to run. It changes one Windows setting, writes down what it was before (data\perf-tools-state.tsv) and logs to perf-tools.log.
rem Paddock and Claude never run this by themselves. To go back: the matching -UNDO file.
setlocal
title Paddock: try hardware GPU scheduling ON
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0perf-tools.ps1" -Tool hags-on
echo.
echo Restart the PC for it to take effect.
timeout /t 15 >nul