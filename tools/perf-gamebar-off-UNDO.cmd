@echo off
rem Paddock UNDO: Xbox Game Bar background recording back as it was
rem Puts the two Game Bar recording settings back to what they were before perf-gamebar-off.cmd.
rem Double-click to run. It changes one Windows setting, writes down what it was before (data\perf-tools-state.tsv) and logs to perf-tools.log.
rem Paddock and Claude never run this by themselves. To go back: the matching -UNDO file.
setlocal
title Paddock UNDO: Xbox Game Bar background recording back as it was
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0perf-tools.ps1" -Tool gamebar-off-undo
echo.
echo Done.
timeout /t 15 >nul