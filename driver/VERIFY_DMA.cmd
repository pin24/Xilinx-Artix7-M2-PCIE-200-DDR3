@echo off
setlocal

REM ==========================================================================
REM  VERIFY_DMA.cmd — test-launch scenario for the NEW DMA driver (W1).
REM
REM  Scope: proves the new driver's device nodes (\\.\XDMA0dma\control,
REM  \\.\XDMA0dma\h2c_0, \\.\XDMA0dma\c2h_0) answer correctly.
REM
REM  Order: regs -> small loopback -> ioctl -> dot.
REM  This is a MANUAL stand script — it is NOT run automatically.
REM ==========================================================================

set EXE=%~dp0build\test_dma.exe

if not exist "%EXE%" (
    echo ERROR: %EXE% not found. Run build_test_dma.cmd first.
    exit /b 1
)

echo ============================================================
echo  [1/4] regs — control readback
echo ============================================================
"%EXE%" regs
if errorlevel 1 ( echo ### STEP 1 FAILED && goto :fail ) else ( echo --- step 1 OK )

echo.
echo ============================================================
echo  [2/4] loopback 4 / 1024 / 1048576 bytes
echo ============================================================
"%EXE%" loopback 4
if errorlevel 1 ( echo ### loopback 4 FAILED && goto :fail ) else ( echo --- loopback 4 OK )

"%EXE%" loopback 1024
if errorlevel 1 ( echo ### loopback 1024 FAILED && goto :fail ) else ( echo --- loopback 1024 OK )

"%EXE%" loopback 1048576
if errorlevel 1 ( echo ### loopback 1048576 FAILED && goto :fail ) else ( echo --- loopback 1048576 OK )

echo.
echo ============================================================
echo  [3/4] ioctl — PERF start/get/stop + ADDRMODE
echo ============================================================
"%EXE%" ioctl
if errorlevel 1 ( echo ### ioctl FAILED && goto :fail ) else ( echo --- ioctl OK )

echo.
echo ============================================================
echo  [4/4] dot — canonical TDOT path via DMA
echo ============================================================
"%EXE%" dot 8
if errorlevel 1 ( echo ### dot FAILED && goto :fail ) else ( echo --- dot OK )

echo.
echo ============================================================
echo  VERIFY_DMA: ALL STEPS PASSED
echo ============================================================
exit /b 0

:fail
echo.
echo ============================================================
echo  VERIFY_DMA: FAILED (see step above)
echo ============================================================
exit /b 1