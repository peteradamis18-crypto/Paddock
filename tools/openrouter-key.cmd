@echo off
rem Paddock: save your OpenRouter key on this PC (one time). Paste the key when asked; it is hidden and never shown.
rem To remove it again: openrouter-key.cmd -Remove
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0openrouter-key.ps1" %*
