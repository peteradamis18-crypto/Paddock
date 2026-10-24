@echo off
rem One time only: links Paddock to your Midea AC through the Midea Air app's own route (Midea's server).
rem If it works, the login is saved on this PC only, encrypted by Windows for your user, so the AC keys and auto-cool can use it.
cd /d "%~dp0.."
title Paddock - connect the AC
echo.
echo   PADDOCK - connect your AC (one time)
echo   Type the email and password you use in the Midea Air app.
echo   If the AC answers, they are saved on this PC only (encrypted) so the PC can control the AC.
echo.
tools\python\python.exe -I -X utf8 ac\cloudtry.py
echo.
if exist ac\cloud.bin (
  echo   Done. Tell Claude it worked.
) else (
  echo   That did not work. Tell Claude - the details are in ac\getkey.log.
)
echo.
pause