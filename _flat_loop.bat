@echo off
rem ============================================================================
rem _flat_loop.bat - 6 FULL FLAT (no-DFX) P&R builds of tdot_axi4 @125MHz
rem   legacy  (ELEM_FMT=0) and PACKED6 (ELEM_FMT=2)
rem   x NUM_MAC=32 , ADDERS in {4,8,16} , JOBS=13
rem Each build gets its own PROJ_DIR=C:/build_flat_loop/<name> ,
rem log -> build/logs_flat/<name>.log .
rem Command per build:
rem   vivado -mode batch -source scripts/build_flat.tcl ^
rem     -tclargs NUM_MAC=32 ADDERS=<A> ELEM_FMT=<F> JOBS=13
rem ASCII-only on purpose (cmd mangles Cyrillic in .bat encoding).
rem ============================================================================

setlocal
set ROOT=%~dp0
set LOOP_DIR=C:/build_flat_loop
set LOG_DIR=%ROOT%build\logs_flat
set JOBS=13
set NUM_MAC=32

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if not exist "%LOOP_DIR%" mkdir "%LOOP_DIR%"

call :run_build legacy_a4  0 4
call :run_build legacy_a8  0 8
call :run_build legacy_a16 0 16
call :run_build p6_a4      2 4
call :run_build p6_a8      2 8
call :run_build p6_a16     2 16

echo.
echo ALL 6 FLAT BUILDS DONE. Logs in %LOG_DIR%
exit /b 0

:run_build
set NAME=%~1
set EFMT=%~2
set ADDR=%~3
set PROJ_DIR=%LOOP_DIR%/%NAME%
echo ============================================================
echo BUILD %NAME% : NUM_MAC=%NUM_MAC% ADDERS=%ADDR% ELEM_FMT=%EFMT%
echo ============================================================
call vivado -mode batch -source scripts/build_flat.tcl -tclargs NUM_MAC=%NUM_MAC% ADDERS=%ADDR% ELEM_FMT=%EFMT% JOBS=%JOBS% > "%LOG_DIR%\%NAME%.log" 2>&1
if errorlevel 1 (
    echo [ERROR] build %NAME% FAILED (see %LOG_DIR%\%NAME%.log)
) else (
    echo [OK] build %NAME% complete
)
exit /b 0