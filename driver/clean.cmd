@echo off
setlocal

set BUILD_DIR=%~dp0build
set TMP_DIR=%~dp0build_tmp

echo === Cleaning build artifacts ===

if exist "%BUILD_DIR%" (
    rmdir /s /q "%BUILD_DIR%"
    echo   removed %BUILD_DIR%
)

if exist "%TMP_DIR%" (
    rmdir /s /q "%TMP_DIR%"
    echo   removed %TMP_DIR%
)

if exist "%~dp0XDMA.sys" (
    del /q "%~dp0XDMA.sys"
    echo   removed XDMA.sys
)

echo === Clean DONE ===
endlocal