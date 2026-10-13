@echo off
title Paddock - sign in to OpenAI Codex
echo Sign in with your OpenAI (ChatGPT Pro) account in the browser window that opens.
"%~dp0codex\codex-x86_64-pc-windows-msvc.exe" login
echo.
echo Done - you can close this window.
pause
