@echo off
rem _pand_loop.bat - 6 full DFX builds (P&R @125MHz) legacy + PACKED6.
rem   vivado -mode batch -source scripts/build_dfx.tcl -tclargs NUM_MAC=32 ADDERS=<A> ELEM_FMT=<F> JOBS=19
rem Runs (NUM_MAC=32, ADDERS 4/8/16, FMT 0=legacy / 2=PACKED6):
rem   legacy32_4 legacy32_8 legacy32_16 packed32_4 packed32_8 packed32_16
rem Results per run in separate PROJ_DIR + log in build/logs/.
rem Usage: set VIVADO=C:\...\vivado.bat ; _pand_loop.bat

setlocal enabledelayedexpansion
if not defined VIVADO set VIVADO=vivado

set SRC=scripts\build_dfx.tcl
set BASE=C:/build_dfx_loop
set LOGDIR=build\logs
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

if exist "%BASE%" rmdir /s /q "%BASE%"
if not exist "%BASE%" mkdir "%BASE%"

set RUNS=legacy32_4:0:4 legacy32_8:0:8 legacy32_16:0:16 packed32_4:2:4 packed32_8:2:8 packed32_16:2:16

echo ==== _pand_loop.bat: 6 DFX builds, JOBS=19 ====

for %%R in (%RUNS%) do (
    for /f "tokens=1-3 delims=:" %%a in ("%%R") do (
        set NAME=%%a
        set FMT=%%b
        set AD=%%c
        set PJ=!BASE!/!NAME!
        set LOG=!LOGDIR!/!NAME!.log
        echo.
        echo === RUN !NAME!: ELEM_FMT=!FMT! NUM_MAC=32 ADDERS=!AD! PROJ_DIR=!PJ! ===
        "%VIVADO%" -mode batch -source %SRC% -tclargs NUM_MAC=32 ADDERS=!AD! ELEM_FMT=!FMT! JOBS=19 > "!LOG!" 2>&1
        echo RUN !NAME! exitcode=!ERRORLEVEL! log=!LOG!
    )
)

echo.
echo ==== All 6 builds finished. Logs in %LOGDIR%\ ====
endlocal