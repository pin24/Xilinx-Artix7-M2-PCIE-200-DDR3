@echo off
REM ==========================================================================
REM install.cmd — XDMA DDR3 Ternary Accelerator driver installer (test-signed)
REM
REM Consumes the driver package produced by build.cmd at build\sys\:
REM   build\sys\XDMA.sys   — signed kernel-mode driver
REM   build\sys\XDMA.inf   — INF (with [XDMA_Inst.NT.Wdf] section)
REM   build\sys\XDMA.cat   — signed catalog
REM   build\sys\XDMA.cer   — test certificate (WDKTestCert public key)
REM
REM Run as Administrator on the TARGET machine (the machine that will host
REM the FPGA board). On the dev machine, build.cmd already performs steps
REM 1-3 below, so install.cmd is only needed there if you skipped the
REM sc-create path and want a PnP-managed install instead.
REM
REM Created by FIX-4 (Task ID: FIX-4) — see /home/z/my-project/worklog.md
REM ==========================================================================
setlocal

REM --- Admin check (FIX F2 requirement) ---
net session >nul 2>&1
if errorlevel 1 (
    echo ERROR: Run as Administrator.
    echo        Right-click cmd.exe -> "Run as administrator" and re-run install.cmd
    exit /b 1
)

set SCRIPT_DIR=%~dp0

REM Sanity check: ensure the driver package exists.
if not exist "%SCRIPT_DIR%build\sys\XDMA.inf" (
    echo ERROR: %SCRIPT_DIR%build\sys\XDMA.inf not found.
    echo        Run build.cmd first on the dev machine to produce the driver package.
    exit /b 1
)
if not exist "%SCRIPT_DIR%build\sys\XDMA.cer" (
    echo ERROR: %SCRIPT_DIR%build\sys\XDMA.cer not found.
    echo        Run build.cmd first on the dev machine to export the test certificate.
    exit /b 1
)

REM 1. Install the test certificate into Root + TrustedPublisher.
REM    Without this, Windows rejects the test-signed driver with
REM    STATUS_INVALID_IMAGE_HASH (error 0xC0000428 / code 39 in Device Manager).
echo [1/4] Installing certificate into Root and TrustedPublisher...
certutil -addstore -f Root "%SCRIPT_DIR%build\sys\XDMA.cer"
if errorlevel 1 (
    echo WARNING: certutil -addstore Root returned non-zero (already present?)
)
certutil -addstore -f TrustedPublisher "%SCRIPT_DIR%build\sys\XDMA.cer"
if errorlevel 1 (
    echo WARNING: certutil -addstore TrustedPublisher returned non-zero (already present?)
)

REM 2. Enable kernel test signing (REQUIRES REBOOT).
REM    Without this, even with the cert in Root, Windows 10/11 refuses to
REM    load test-signed kernel drivers. Secure Boot must be OFF for this to stick.
echo [2/4] Enabling test signing (requires reboot)...
bcdedit /set testsigning on
if errorlevel 1 (
    echo ERROR: bcdedit /set testsigning on failed.
    echo        Check that Secure Boot is disabled in BIOS.
    exit /b 1
)

REM 3. Install the driver via PnP (preferred over sc create).
REM    pnputil /add-driver copies XDMA.sys to DriverStore, registers the INF
REM    as oemNN.inf, and binds it to the PCI device VEN_10ee&DEV_7024 when
REM    the FPGA enumerates. Requires XDMA.inf to reference [XDMA_Inst.NT.Wdf]
REM    (added by FIX F1) or WDF loader fails with STATUS_WDF_VERIFICATION_FAILURE.
echo [3/4] Installing driver via pnputil...
pnputil /add-driver "%SCRIPT_DIR%build\sys\XDMA.inf" /install
if errorlevel 1 (
    echo WARNING: pnputil /add-driver returned non-zero.
    echo        The INF may already be installed, or the device is not present yet.
    echo        Falling back to manual sc-create path is available in build.cmd.
)

REM 4. Optional: manual sc-create path (commented out by default).
REM    Use this only if pnputil fails AND you want to test without the FPGA
REM    board physically present (e.g. for driver load smoke-testing).
REM sc create XDMA type= kernel binpath= "%SCRIPT_DIR%build\sys\XDMA.sys" start= demand
REM sc start XDMA

echo [4/4] Done.
echo.
echo IMPORTANT: Reboot required for test signing to take effect.
echo After reboot:
echo   1. Insert the FPGA board (PCIe / M.2 slot).
echo   2. Wait for PnP to enumerate (Device Manager -> System devices
echo      -> "XDMA DDR3 Ternary Accelerator v1.0", no yellow bang).
echo   3. Run test_xdma.exe to verify GPIO/TDOT/XADC/ICAP tests PASS.
echo.
echo To uninstall: run uninstall.cmd (also as Administrator).
echo.
pause
endlocal
