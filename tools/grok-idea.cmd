@echo off
rem Double-click: type an idea in plain words; Grok turns it into a proper task card. "Grok - Build all" then builds it.
start "Paddock - new idea" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0grok-idea.ps1"
