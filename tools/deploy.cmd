@echo off
rem the lead's deploy: through the broker like every other job, so deploys never collide
set PADDOCK_NO_DEPLOY=1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\dash\build.ps1"
