@echo off
rem Double-click me (prompts for SKUs), or drag a skus.txt onto me.
rem Or from a console: lookup.bat 0345865 0700343 ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fastenal-lookup.ps1" -Pretty %*
pause
