@echo off
rem Paddock: UNDO - shut the phone out again
rem Removes the firewall rule 'Paddock phone (irdash 8199 in)', puts the network back to what it was, deletes dash\phone-allowed.txt
rem and forgets every paired phone. Paddock answers this PC only again within 30 seconds.
setlocal
title Paddock: shut the phone out
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0phone-tools.ps1" -Do undo
timeout /t 3 >nul
