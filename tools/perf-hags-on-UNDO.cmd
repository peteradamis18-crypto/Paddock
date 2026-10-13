@echo off
rem Paddock UNDO: hardware GPU scheduling back as it was
rem Puts the hardware GPU scheduling setting back to what it was before perf-hags-on.cmd (administrator approval once, then restart).
rem Double-click to run. It changes one Windows setting, writes down what it was before (data\perf-tools-state.tsv) and logs to perf-tools.log.
rem Paddock and Claude never run this by themselves. To go back: the matching -UNDO file.
setlocal
title Paddock UNDO: hardware GPU scheduling back as it was
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0perf-tools.ps1" -Tool hags-on-undo
echo.
echo Restart the PC for it to take effect.
timeout /t 15 >nul