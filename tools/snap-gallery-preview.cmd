@echo off
rem Renders docs\gallery-preview.html (thumbnails of the candidate gallery photos) to docs\gallery-preview.png with
rem headless Chrome, so the lead can check the light by eye before any download. Run via Explorer.
set CH=%ProgramFiles%\Google\Chrome\Application\chrome.exe
if not exist "%CH%" set CH=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe
"%CH%" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="%TEMP%\paddock-preview" --window-size=1600,1800 --virtual-time-budget=20000 --screenshot="%~dp0..\docs\gallery-preview.png" "file:///%~dp0..\docs\gallery-preview.html"
