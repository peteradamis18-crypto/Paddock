@echo off
rem Double-click: Grok works through every open task card in docs\TASKS.md, one after another (each one built by the
rem fast model, then checked by the strong model), until done or until the Grok usage limit.
rem Progress: "Grok - Progress".  Stop after the current task: "Grok - Stop".
if exist "%~dp0..\docs\tasks\STOP" del "%~dp0..\docs\tasks\STOP"
start "Paddock - Grok building" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0grok-queue.ps1" -AllOpen
