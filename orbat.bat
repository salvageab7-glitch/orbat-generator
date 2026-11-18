@echo off
chcp 65001 >nul 2>&1
setlocal

REM ORBAT CLI 启动器：自动定位 Dart SDK
set "APP_DIR=%~dp0"
set "DART="

REM 1) 环境变量 ORBAT_DART
if defined ORBAT_DART if exist "%ORBAT_DART%" set "DART=%ORBAT_DART%"

REM 2) Flutter SDK 自带 dart
if not defined DART if exist "C:/flutter/bin/dart.bat" set "DART=C:/flutter/bin/dart.bat"

REM 3) PATH 里的 dart
if not defined DART (
  for /f "delims=" %%i in ('where dart 2^>nul') do if not defined DART set "DART=%%i"
)

if not defined DART (
  echo {"ok":false,"command":"bootstrap","error":"未找到 Dart SDK。请安装 Dart 或设置 ORBAT_DART 环境变量。"}
  exit /b 2
)

call "%DART%" run "%APP_DIR%lib\cli\main.dart" %*
exit /b %ERRORLEVEL%
