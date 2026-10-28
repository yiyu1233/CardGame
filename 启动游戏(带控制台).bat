@echo off
rem Same as the plain launcher, but keeps the engine logs on screen after the
rem game exits (use this when the game fails to start or a script errors).
rem Keep this file ASCII-only (see tools\launch.bat).
set "CARDGAME_CONSOLE=1"
call "%~dp0tools\launch.bat" %*
exit /b %ERRORLEVEL%
