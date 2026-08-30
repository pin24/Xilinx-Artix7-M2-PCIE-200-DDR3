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

REM FIX-4: also remove the makecert-generated cert file (public key only,
REM the private key stays in PrivateCertStore so the cert can be reused
REM on the next build.cmd run without re-running makecert).
if exist "%~dp0WDKTestCert.cer" (
    del /q "%~dp0WDKTestCert.cer"
    echo   removed WDKTestCert.cer
)

echo === Clean DONE ===
echo NOTE: build\sys\ (driver package) was inside build\ and is also removed.
echo NOTE: WDKTestCert private key remains in Cert:\CurrentUser\PrivateCertStore
echo       so the next build.cmd run can re-export XDMA.cer without makecert.
echo       To purge the cert entirely: certutil -delstore PrivateCertStore WDKTestCert
endlocal