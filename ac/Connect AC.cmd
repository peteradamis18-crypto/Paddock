@echo off
rem One time only: links Paddock to your Midea AC. Midea gives the AC's local key only to the account that owns it,
rem so this asks for your MSmartHome email and password HERE. They are used once and never saved anywhere.
cd /d "%~dp0.."
title Paddock - connect the AC
echo.
echo   PADDOCK - connect your AC (one time)
echo   Type the email and password you use in the MSmartHome app.
echo   They are used once to get the AC's key and are NOT saved.
echo.
set /p ACMAIL=  MSmartHome email:
tools\python\python.exe -I ac\getkey.py 192.168.7.26 --account "%ACMAIL%"
set ACMAIL=
echo.
if exist ac\ac.json (
  tools\python\python.exe -I ac\ac.py status
  echo.
  echo   Done. The AC keys on the Stream Deck work now. You can close this window.
) else (
  echo   That did not work. Check the email and password and run this again.
)
echo.
pause
