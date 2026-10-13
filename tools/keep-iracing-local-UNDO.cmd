@echo off
rem Undo keep-iracing-local.cmd: takes the "always keep on this device" mark off Documents\iRacing again
rem (attrib -P), so OneDrive goes back to deciding for itself. Double-click it.
setlocal
set "LOG=%~dp0keep-iracing-local.log"
for /f "usebackq delims=" %%D in (`powershell -NoProfile -Command "[Environment]::GetFolderPath('MyDocuments')"`) do set "DOCS=%%D"
set "TARGET=%DOCS%\iRacing"
echo %date% %time%  keep-iracing-local UNDO: %TARGET% > "%LOG%"
if not exist "%TARGET%\" (
  echo The folder %TARGET% was not found. >> "%LOG%"
  echo The folder %TARGET% was not found.
  timeout /t 8 >nul
  exit /b 1
)
echo Taking the "always keep on this device" mark off iRacing's folder...
attrib -P "%TARGET%" /D >> "%LOG%" 2>&1
attrib -P "%TARGET%\*" /S /D >> "%LOG%" 2>&1
powershell -NoProfile -Command "$d='%TARGET%'; $all=@(Get-Item -LiteralPath $d -Force)+@(Get-ChildItem -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue); $p=@($all | Where-Object { [int]$_.Attributes -band 0x80000 }).Count; 'still pinned: ' + $p + ' of ' + $all.Count + ' files and folders'" >> "%LOG%" 2>&1
type "%LOG%"
echo.
echo Done.
timeout /t 10 >nul