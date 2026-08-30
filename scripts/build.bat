@echo off
REM ============================================================================
REM build.bat — wrapper для запуска Vivado 2021.2 сборки проекта
REM ============================================================================
REM Запуск из корня репозитория:
REM   scripts\build.bat                 — сборка с NUM_MAC=32
REM   scripts\build.bat NUM_MAC=16      — сборка с NUM_MAC=16
REM   scripts\build.bat SKIP_SYNTH=1    — только создать проект без synth
REM ============================================================================

setlocal

REM --- Поиск Vivado 2021.2 ---
set VIVADO_BIN=C:\Xilinx\Vivado\2021.2\bin
if not exist "%VIVADO_BIN%\vivado.bat" set VIVADO_BIN=C:\AMDDesignTools\Vivado\2021.2\bin
if not exist "%VIVADO_BIN%\vivado.bat" (
    for /f "delims=" %%I in ('where vivado.bat 2^>nul') do set VIVADO_BIN=%%~dpI
)
if not exist "%VIVADO_BIN%\vivado.bat" (
    echo ERROR: Vivado 2021.2 not found.
    echo Expected locations:
    echo   C:\Xilinx\Vivado\2021.2\bin\vivado.bat
    echo   C:\AMDDesignTools\Vivado\2021.2\bin\vivado.bat
    echo Or add vivado.bat to PATH.
    exit /b 1
)

echo === Using Vivado: %VIVADO_BIN% ===

REM --- Переход в корень репозитория ---
set SCRIPT_DIR=%~dp0
set REPO_ROOT=%SCRIPT_DIR:~0,-1%
pushd "%REPO_ROOT%\.."

echo === Repository root: %CD% ===
echo === Build script: scripts\build.tcl ===
echo.

"%VIVADO_BIN%\vivado.bat" -mode batch -source scripts\build.tcl -tclargs %*

set EXITCODE=%ERRORLEVEL%
popd

echo.
if %EXITCODE% equ 0 (
    echo === BUILD SUCCESS ===
    echo Artifacts in: build\artifacts\
) else (
    echo === BUILD FAILED (exit code %EXITCODE%) ===
)

exit /b %EXITCODE%
