@echo off
rem Paddock: switch Xbox Game Bar background recording off
rem Windows can record game video in the background, which costs graphics-card time. This switches that off (two per-user settings, no administrator needed).
rem Double-click to run. It changes one Windows setting, writes down what it was before (data\perf-tools-state.tsv) and logs to perf-tools.log.
rem Paddock and Claude never run this by themselves. To go back: the matching -UNDO file.
setlocal
title Paddock: switch Xbox Game Bar background recording off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0perf-tools.ps1" -Tool gamebar-off
echo.
echo Done - see above. perf-gamebar-off-UNDO.cmd puts it back.
timeout /t 15 >nul