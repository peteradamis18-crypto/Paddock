@echo off
rem Keep Documents\iRacing always on this PC. OneDrive holds Documents; "always keep on this device" (the Pinned
rem attribute, attrib +P) stops OneDrive turning iRacing's settings, setups and telemetry into online-only files.
rem Run it by double-clicking (it starts as a normal program through Explorer). It only sets that one attribute on
rem Documents\iRacing and what is inside it; no file contents change. To go back: keep-iracing-local-UNDO.cmd
setlocal
set "LOG=%~dp0keep-iracing-local.log"
for /f "usebackq delims=" %%D in (`powershell -NoProfile -Command "[Environment]::GetFolderPath('MyDocuments')"`) do set "DOCS=%%D"
set "TARGET=%DOCS%\iRacing"
echo %date% %time%  keep-iracing-local: %TARGET% > "%LOG%"
if not exist "%TARGET%\" (
  echo The folder %TARGET% was not found. >> "%LOG%"
  echo The folder %TARGET% was not found.
  timeout /t 8 >nul
  exit /b 1
)
echo Keeping iRacing's files on this PC (OneDrive: always keep on this device)...
attrib +P "%TARGET%" /D >> "%LOG%" 2>&1
attrib +P "%TARGET%\*" /S /D >> "%LOG%" 2>&1
powershell -NoProfile -Command "$d='%TARGET%'; $all=@(Get-Item -LiteralPath $d -Force)+@(Get-ChildItem -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue); $p=@($all | Where-Object { [int]$_.Attributes -band 0x80000 }).Count; 'pinned: ' + $p + ' of ' + $all.Count + ' files and folders'" >> "%LOG%" 2>&1
type "%LOG%"
echo.
echo Done. Rig Doctor on the dashboard shows green for this on its next check.
timeout /t 10 >nul