@echo off
rem One-off repair (2026-10-09): irdashies was installed from inside the Claude app, so Windows put its files in
rem the Claude app's private AppData copy, where Stream Deck, startup and irdash cannot see them. This copies the
rem app and its settings to the normal AppData folders. It must run as a normal program (started via Explorer).
set SRC=%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache
robocopy "%SRC%\Local\irdashies" "%LOCALAPPDATA%\irdashies" /E /NFL /NDL /NP > "%~dp0fix-overlay-install.log"
robocopy "%SRC%\Roaming\irdashies" "%APPDATA%\irdashies" /E /NFL /NDL /NP >> "%~dp0fix-overlay-install.log"
if exist "%LOCALAPPDATA%\irdashies\app-1.1.0\irdashies.exe" (echo app ok >> "%~dp0fix-overlay-install.log") else (echo app MISSING >> "%~dp0fix-overlay-install.log")
if exist "%APPDATA%\irdashies\config.json" (echo config ok >> "%~dp0fix-overlay-install.log") else (echo config MISSING >> "%~dp0fix-overlay-install.log")
