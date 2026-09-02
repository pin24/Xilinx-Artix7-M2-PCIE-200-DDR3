@echo off
REM ============================================================================
REM build.bat — wrapper для запуска Vivado 2025.2 сборки DFX-варианта проекта
REM ============================================================================
REM Автоматически создаёт виртуальный диск (subst) для обхода лимита
REM Windows в 260 символов на длину пути (проблема MIG IP генерации).
REM
REM Запуск из корня репозитория:
REM   scripts\build.bat                 — сборка с NUM_MAC=32 (по умолчанию)
REM   scripts\build.bat NUM_MAC=16       — сборка с NUM_MAC=16
REM   scripts\build.bat SKIP_SYNTH=1    — только создать проект без synth
REM
REM Запускает scripts\build_dfx.tcl — DFX-вариант (xdma_ddr3_dfx.bd).
REM Проект создаётся в C:\build_dfx (см. build_dfx.tcl).
REM
REM Особенности:
REM   * Авто-поиск Vivado 2025.2 в стандартных путях
REM   * Авто-subst: если путь к репозиторию длиннее 40 символов, создаётся
REM     виртуальный диск (X:/Z:/Y:/W:...) для обхода Windows 260-byte лимита.
REM     После сборки виртуальный диск отключается автоматически.
REM ============================================================================

setlocal enabledelayedexpansion

REM --- Переход в корень репозитория ---
set SCRIPT_DIR=%~dp0
set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%
pushd "%SCRIPT_DIR%\.."
set REPO_ROOT=%CD%

REM --- Поиск Vivado 2025.2 ---
set VIVADO_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
if not exist "%VIVADO_BIN%\vivado.bat" set VIVADO_BIN=C:\AMDDesignTools\2025.2\bin
if not exist "%VIVADO_BIN%\vivado.bat" set VIVADO_BIN=C:\AMDDesignTools\Vivado\2025.2\bin
if not exist "%VIVADO_BIN%\vivado.bat" set VIVADO_BIN=C:\Xilinx\Vivado\2025.2\bin
if not exist "%VIVADO_BIN%\vivado.bat" (
    for /f "delims=" %%I in ('where vivado.bat 2^>nul') do set VIVADO_BIN=%%~dpI
)
if not exist "%VIVADO_BIN%\vivado.bat" (
    echo ERROR: Vivado 2025.2 not found.
    echo Expected locations:
    echo   C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
    echo   C:\AMDDesignTools\Vivado\2025.2\bin\vivado.bat
    echo   C:\Xilinx\Vivado\2025.2\bin\vivado.bat
    echo Or add vivado.bat to PATH.
    popd
    exit /b 1
)

echo === Using Vivado: %VIVADO_BIN% ===
echo === Repository root: %REPO_ROOT% ===

REM ============================================================================
REM Авто-subst: сокращаем путь если он слишком длинный (> 40 символов)
REM Vivado + MIG IP создают глубокие вложенные пути (260+ символов),
REM что ломает сборку на Windows с ограничением MAX_PATH.
REM ============================================================================
set SUBST_DRIVE=
set NEED_SUBST=0

REM Считаем длину пути (упрощённо: через string substitution)
set "STR=%REPO_ROOT%"
set LEN=0
:len_loop
if defined STR (
    set "STR=!STR:~1!"
    set /a LEN+=1
    goto :len_loop
)

REM Если путь длиннее 40 символов — используем subst
if %LEN% GTR 40 (
    set NEED_SUBST=1
)

if %NEED_SUBST% equ 1 (
    REM Ищем свободную букву диска: X:, потом Z:, потом Y:, потом W:, и т.д.
    set "CANDIDATES=X Z Y W V U T"
    set SUBST_DRIVE=
    for %%D in (!CANDIDATES!) do (
        if not defined SUBST_DRIVE (
            if not exist %%D:\ (
                set SUBST_DRIVE=%%D:
            )
        )
    )
    if not defined SUBST_DRIVE (
        echo ERROR: No free drive letter for subst (X/Z/Y/W/V/U/T all in use).
        echo Please free one of these drives or shorten repository path.
        popd
        exit /b 1
    )

    echo === Path length %LEN% chars ^> 40 — using subst !SUBST_DRIVE! for short path ===
    subst !SUBST_DRIVE! "%REPO_ROOT%"
    if errorlevel 1 (
        echo ERROR: subst command failed.
        popd
        exit /b 1
    )

    REM Переходим на виртуальный диск
    pushd !SUBST_DRIVE!\
    set REPO_ROOT=!SUBST_DRIVE!\
    echo === Short path: !REPO_ROOT! ===
) else (
    echo === Path length %LEN% chars — no subst needed ===
)

echo === Build script: scripts\build_dfx.tcl ===
echo.

REM --- Запуск Vivado (DFX-вариант) ---
"%VIVADO_BIN%\vivado.bat" -mode batch -source scripts\build_dfx.tcl -tclargs %*

set EXITCODE=%ERRORLEVEL%

REM --- Возврат в исходный каталог и отключение subst ---
popd
if %NEED_SUBST% equ 1 (
    popd
    subst !SUBST_DRIVE! /D
    echo === Unmounted virtual drive !SUBST_DRIVE! ===
)

echo.
if %EXITCODE% equ 0 (
    echo === BUILD SUCCESS ===
    echo Artifacts in: build\artifacts_dfx\
) else (
    echo === BUILD FAILED (exit code %EXITCODE%) ===
)

exit /b %EXITCODE%
