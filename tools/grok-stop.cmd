@echo off
rem Double-click: Grok finishes the task it is on (so nothing is left half-done), then stops. Start again with "Grok - Build all".
echo stop requested %date% %time%> "%~dp0..\docs\tasks\STOP"
powershell -NoProfile -Command "Add-Type -AssemblyName PresentationFramework; [void][System.Windows.MessageBox]::Show('Grok will finish the task it is on, then stop.','Paddock - Grok')"
