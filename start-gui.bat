@echo off
rem ===========================================================
rem  SyncKit launcher - double-click to open the local GUI.
rem
rem  KEEP THIS FILE ASCII-ONLY WITH CRLF LINE ENDINGS.
rem  cmd.exe parses .bat with the OEM codepage (936 on a Chinese
rem  Windows) and finds line breaks by CR. Non-ASCII text or
rem  LF-only endings make cmd drop lines or run fragments as
rem  commands. All Chinese messages come from bin/start-gui.ps1.
rem ===========================================================
setlocal
cd /d "%~dp0"
title SyncKit

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bin\start-gui.ps1" %*

if errorlevel 1 (
  echo.
  echo   [ERROR] SyncKit did not start. Please read the messages above.
  pause
)
endlocal
