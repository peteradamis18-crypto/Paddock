@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rig-cleanup.ps1" -Undo
