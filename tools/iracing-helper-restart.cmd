@echo off
rem Restarts iRacing's own helper service (iRacingService) with iRacing's own Stop and Start files, the step iRacing support
rem gives when its updater says "Download failed. Please check that iRacing is running and try again." (seen 2026-11-15 when
rem the AI RACE key accepted a 23 kB update). One click; Windows asks for admin once. Nothing to undo: the service is started
rem again exactly as it is at every boot.
setlocal
tasklist /fi "imagename eq iRacingSim64DX11.exe" 2>nul | find /i "iRacingSim64DX11.exe" >nul && (
  echo iRacing is driving right now. Close the sim first, then click this again.
  pause
  exit /b 1
)
net session >nul 2>&1 || (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "C:\Program Files (x86)\iRacing"
echo Stopping iRacing's helper service...
call Stop_iRacingService.bat
echo Starting it again...
call Start_iRacingService.bat
echo.
sc query iRacingService | findstr /i "STATE"
echo.
echo Done. Press AI RACE on the deck again.
pause
