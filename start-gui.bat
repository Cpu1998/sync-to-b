@echo off
chcp 65001 >nul
cd /d "%~dp0"
title SyncKit 增量备份中心
echo.
echo   正在启动本地界面（浏览器会自动打开）...
echo   关闭本窗口即停止服务。
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bin\start-gui.ps1" %*
if errorlevel 1 (
  echo.
  echo   启动失败，请查看上方错误信息。
  pause
)
