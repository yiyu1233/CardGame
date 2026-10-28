@echo off
rem ============================================================
rem  Card Game launcher (shared logic)
rem  Called by the two wrapper .bat files in the project root.
rem  Those wrappers have Chinese file names; only the file NAME is Chinese,
rem  the batch code inside every .bat is ASCII on purpose (see the note below).
rem  Set CARDGAME_CONSOLE=1 to prefer the console build and
rem  keep the window open after the game exits.
rem  Extra arguments are passed straight to Godot, e.g.
rem      tools\launch.bat --headless --quit-after 60
rem
rem  NOTE: keep this file ASCII-only. cmd.exe parses .bat files using the
rem  console code page, so non-ASCII batch content gets mangled (it breaks
rem  lines and commands). Chinese text belongs in the file NAME or in
rem  README.md, never inside the batch code.
rem ============================================================

setlocal
title Card Game - Launcher
set "PROJECT_DIR=%~dp0.."
pushd "%PROJECT_DIR%" >nul 2>&1
if errorlevel 1 (
	echo [ERROR] Cannot enter project folder: %PROJECT_DIR%
	pause
	exit /b 1
)
set "PROJECT_DIR=%CD%"

set "WANT_CONSOLE="
if defined CARDGAME_CONSOLE set "WANT_CONSOLE=1"
set "SUFFIX=Godot_v4.7.1-stable_win64.exe"
if defined WANT_CONSOLE set "SUFFIX=Godot_v4.7.1-stable_win64_console.exe"

rem ---- find the Godot executable -------------------------------------------
set "GODOT_EXE="
if defined GODOT if exist "%GODOT%" set "GODOT_EXE=%GODOT%"
if defined GODOT_EXE goto :found
call :try "%PROJECT_DIR%\godot\%SUFFIX%"
if defined GODOT_EXE goto :found
call :try "D:\Godot_v4.7.1-stable_win64.exe\%SUFFIX%"
if defined GODOT_EXE goto :found
call :try "%LOCALAPPDATA%\Programs\Godot\%SUFFIX%"
if defined GODOT_EXE goto :found
call :try "%ProgramFiles%\Godot\%SUFFIX%"
if defined GODOT_EXE goto :found
call :try "%USERPROFILE%\scoop\apps\godot\current\%SUFFIX%"
if defined GODOT_EXE goto :found
rem any other Godot version dropped into the portable "godot" folder
for %%F in ("%PROJECT_DIR%\godot\Godot*.exe") do if not defined GODOT_EXE set "GODOT_EXE=%%~fF"
if defined GODOT_EXE goto :found
for /f "delims=" %%P in ('where godot 2^>nul') do if not defined GODOT_EXE set "GODOT_EXE=%%P"
if defined GODOT_EXE goto :found

echo [ERROR] Godot 4 executable not found.
echo.
echo Pick one of these and try again:
echo   1. Unzip Godot into the "godot" subfolder of this project (portable, recommended)
echo   2. Point the GODOT environment variable at the Godot .exe, e.g.
echo        setx GODOT "D:\Godot\Godot_v4.7.1-stable_win64.exe"
echo   3. Install Godot and add it to PATH
echo.
echo Download: https://godotengine.org/download/windows/
echo This project needs Godot 4.7 (config/features = 4.7 in project.godot).
popd >nul
pause
exit /b 1

:found
echo ============================================================
echo   Card Game (Godot 4.7)
echo   engine : %GODOT_EXE%
echo   project: %PROJECT_DIR%
echo ============================================================
echo.
"%GODOT_EXE%" --path "%PROJECT_DIR%" %*
set "EXITCODE=%ERRORLEVEL%"

if defined WANT_CONSOLE (
	echo.
	echo Game exited with code %EXITCODE%.
	pause
) else if not "%EXITCODE%"=="0" (
	echo.
	echo [ERROR] The game exited with code %EXITCODE%.
	echo Check the engine output above; run the console launcher for full logs.
	echo.
	echo Common causes:
	echo   * outdated GPU driver / no OpenGL compatibility support
	echo   * the CardGame folder was moved or is incomplete
	pause
)
popd >nul
exit /b %EXITCODE%

:try
if not defined GODOT_EXE if exist "%~1" set "GODOT_EXE=%~1"
goto :eof
