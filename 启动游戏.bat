@echo off
rem Double-click to play. Keep this file ASCII-only (see tools\launch.bat).
call "%~dp0tools\launch.bat" %*
exit /b %ERRORLEVEL%
