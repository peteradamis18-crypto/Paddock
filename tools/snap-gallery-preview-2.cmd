@echo off
rem Renders docs\gallery-preview-2.html (thumbnails of the round-2 candidate photos: celebrations, IMSA GTP / LMP2) to
rem docs\gallery-preview-2.png with headless Chrome, so the lead can check the light and sharpness by eye before any download.
rem Run via Explorer. Runs at low priority on two cores, and shows no window.
set CH=%ProgramFiles%\Google\Chrome\Application\chrome.exe
if not exist "%CH%" set CH=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe
start "" /wait /belownormal /affinity 3 "%CH%" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="%TEMP%\paddock-preview-2" --window-size=2000,870 --virtual-time-budget=30000 --screenshot="%~dp0..\docs\gallery-preview-2.png" "file:///%~dp0..\docs\gallery-preview-2.html"

