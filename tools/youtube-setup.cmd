@echo off
rem Paddock: the one-time YouTube setup (about 10 minutes, Peter does it once; docs\YOUTUBE-SETUP.md has every click).
rem Opens the guide and Google's console side by side. When Google gives you the file (Download JSON), just download it:
rem Paddock takes it from your Downloads folder by itself within a minute, then SIGN IN on RACES turns on.
setlocal
start "" notepad.exe "%~dp0..\docs\YOUTUBE-SETUP.md"
start "" "https://console.cloud.google.com"
