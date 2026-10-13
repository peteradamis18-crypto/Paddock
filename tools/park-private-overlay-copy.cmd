@echo off
rem One-off (2026-10-09): after fix-overlay-install.cmd copied irdashies to the normal AppData folders, move the old
rem private copy out of the Claude app's redirected AppData (into backup\, not deleted) so tools started from the
rem Claude session read and write the same irdashies files as everything else. Run via Explorer.
set SRC=%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache
set DST=%~dp0..\backup\claude-private-irdashies
robocopy "%SRC%\Local\irdashies" "%DST%\Local" /E /MOVE /NFL /NDL /NP > "%~dp0park-private-overlay-copy.log"
robocopy "%SRC%\Roaming\irdashies" "%DST%\Roaming" /E /MOVE /NFL /NDL /NP >> "%~dp0park-private-overlay-copy.log"
if exist "%SRC%\Local\irdashies" (echo local copy STILL THERE >> "%~dp0park-private-overlay-copy.log") else (echo local copy moved >> "%~dp0park-private-overlay-copy.log")
if exist "%SRC%\Roaming\irdashies" (echo roaming copy STILL THERE >> "%~dp0park-private-overlay-copy.log") else (echo roaming copy moved >> "%~dp0park-private-overlay-copy.log")
