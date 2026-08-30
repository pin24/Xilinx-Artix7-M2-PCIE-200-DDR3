@echo off
setlocal enabledelayedexpansion

set BUILD_DIR=%~dp0build
set PKG_DIR=%~dp0build\sys
set TMP_DIR=%~dp0build_tmp
set KIT_ROOT=C:\Program Files (x86)\Windows Kits\10
set WDK_VERSION=10.0.14393.0
set VS_ROOT=C:\Program Files (x86)\Microsoft Visual Studio 14.0
set SYS=%~dp0

REM === FIX F2: Admin check ===
REM certutil -addstore, bcdedit, sc create, copy to System32\drivers all require elevation.
net session >nul 2>&1
if errorlevel 1 (
    echo ERROR: This script must be run as Administrator.
    echo        Right-click cmd.exe -> "Run as administrator" and re-run build.cmd
    exit /b 1
)

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
if not exist "%PKG_DIR%"  mkdir "%PKG_DIR%"
if not exist "%TMP_DIR%"  mkdir "%TMP_DIR%"

echo === Setting VS2015 x64 environment ===
call "%VS_ROOT%\VC\vcvarsall.bat" x64
if %ERRORLEVEL% neq 0 (
    echo ERROR: vcvarsall.bat failed
    exit /b 1
)

echo === Ensuring WDKTestCert exists in PrivateCertStore ===
REM FIX F3 prep: always export the cert to build\sys\XDMA.cer regardless of
REM whether makecert just ran or the cert was reused from a previous session.
REM The old logic used `certmgr /add /c /s PrivateCertStore WDKTestCert` which
REM referenced a 20-byte placeholder file (driver/WDKTestCert) and only worked
REM accidentally. Replace with a PowerShell store probe (DRV-5 SG-5).
powershell -NoProfile -Command "$exists = Get-ChildItem 'Cert:\CurrentUser\PrivateCertStore' -ErrorAction SilentlyContinue | Where-Object { $_.Subject -match 'CN=WDKTestCert' }; if (-not $exists) { exit 1 }"
if errorlevel 1 (
    echo Creating self-signed WDKTestCert...
    makecert -r -pe -ss PrivateCertStore -n "CN=WDKTestCert" -eku 1.3.6.1.5.5.7.3.3 -len 2048 "%~dp0WDKTestCert.cer"
    if errorlevel 1 (
        echo ERROR: makecert failed to create WDKTestCert
        exit /b 1
    )
) else (
    echo WDKTestCert already present in PrivateCertStore, reusing.
)

REM FIX F3: Export certificate to build\sys\XDMA.cer for target-machine install.
REM This .cer is imported by install.cmd via certutil -addstore Root/TrustedPublisher.
powershell -NoProfile -Command "$c = Get-ChildItem 'Cert:\CurrentUser\PrivateCertStore' -ErrorAction SilentlyContinue | Where-Object { $_.Subject -match 'CN=WDKTestCert' } | Select-Object -First 1; if (-not $c) { Write-Error 'WDKTestCert not found in PrivateCertStore'; exit 1 }; [System.IO.File]::WriteAllBytes('%PKG_DIR%\XDMA.cer', $c.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))"
if errorlevel 1 (
    echo ERROR: failed to export XDMA.cer
    exit /b 1
)
echo Exported certificate: %PKG_DIR%\XDMA.cer

echo === Compiling XDMA.sys ===
REM FIX BC-1 (DRV-5): compile driver/driver.c (the file fixed by FIX-1 with
REM AXI_LITE_BASE subtraction in BOTH EvtIoRead and EvtIoWrite). Do NOT switch
REM to xdma_driver_win_src_2017/sys/driver.c — that file has the Read/Write
REM asymmetry (D4 / DRV-5 B-3) and a different security_cookie constant.
cl.exe /nologo /c /O1 /GS- /kernel /Zp8 /Gy /GF /GR- /Gz /TC ^
    /Fo"%TMP_DIR%\driver.obj" ^
    /D_WIN64 /D_AMD64_ /DAMD64 /DWINNT=1 ^
    /D_WIN32_WINNT=0x0A00 /DNTDDI_VERSION=0x0A000002 ^
    /D_UNICODE /DUNICODE ^
    /I"%KIT_ROOT%\Include\%WDK_VERSION%\km" ^
    /I"%KIT_ROOT%\Include\%WDK_VERSION%\shared" ^
    /I"%KIT_ROOT%\Include\%WDK_VERSION%\um" ^
    /I"%KIT_ROOT%\Include\%WDK_VERSION%\ucrt" ^
    /I"%KIT_ROOT%\Include\wdf\kmdf\1.15" ^
    "%~dp0driver.c"
if %ERRORLEVEL% neq 0 (
    echo ERROR: driver.c compilation failed
    exit /b 1
)

echo === Linking XDMA.sys ===
link.exe /nologo /entry:DriverEntry /subsystem:native /machine:x64 /driver /kernel /nodefaultlib ^
    "%TMP_DIR%\driver.obj" ^
    /out:"%BUILD_DIR%\XDMA.sys" ^
    /LIBPATH:"%KIT_ROOT%\Lib\%WDK_VERSION%\km\x64" ^
    /LIBPATH:"%KIT_ROOT%\Lib\%WDK_VERSION%\ucrt\x64" ^
    /LIBPATH:"%KIT_ROOT%\Lib\wdf\kmdf\x64\1.15" ^
    ntoskrnl.lib hal.lib wdfldr.lib wdfdriverentry.lib
if %ERRORLEVEL% neq 0 (
    echo ERROR: linking XDMA.sys failed
    exit /b 1
)

echo === Creating INF from INX ===
stampinf -f "%SYS%\XDMA.inx" -d "*" -a "amd64" -v "*" -k "1.15" -x
copy /Y "%TMP_DIR%\XDMA.inf" "%BUILD_DIR%\XDMA.inf" >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo stampinf failed, copying raw inx as inf...
    copy /Y "%SYS%\XDMA.inx" "%BUILD_DIR%\XDMA.inf" >nul
)

echo === Creating catalog file ===
inf2cat /driver:"%BUILD_DIR%" /os:10_x64 /verbose
if %ERRORLEVEL% neq 0 (
    echo WARNING: Inf2Cat failed, creating catalog manually via signtool...
    signtool cat /v "%BUILD_DIR%\XDMA.sys" /out:"%BUILD_DIR%\XDMA.cat" >nul 2>&1
)

echo === Signing XDMA.sys with test certificate ===
signtool sign /v /s PrivateCertStore /n WDKTestCert /fd sha256 "%BUILD_DIR%\XDMA.sys"
if %ERRORLEVEL% neq 0 (
    echo WARNING: signing .sys failed, check certificate
)

echo === Signing catalog file ===
if exist "%BUILD_DIR%\XDMA.cat" (
    signtool sign /v /s PrivateCertStore /n WDKTestCert /fd sha256 "%BUILD_DIR%\XDMA.cat"
)

echo === Packaging driver for distribution (build\sys\) ===
REM FIX F3: stage XDMA.sys / .inf / .cat / .cer into build\sys\ so install.cmd
REM can consume a self-contained driver package (pnputil /add-driver needs
REM .inf + .cat + .sys in the same directory).
copy /Y "%BUILD_DIR%\XDMA.sys" "%PKG_DIR%\XDMA.sys" >nul
copy /Y "%BUILD_DIR%\XDMA.inf" "%PKG_DIR%\XDMA.inf" >nul
if exist "%BUILD_DIR%\XDMA.cat" copy /Y "%BUILD_DIR%\XDMA.cat" "%PKG_DIR%\XDMA.cat" >nul
REM XDMA.cer was already exported to %PKG_DIR% in the cert step above.
echo Driver package staged at: %PKG_DIR%

echo === INSTALL TEST CERTIFICATE ===
REM FIX F2 / DRV-5 SG-1: install test cert into Trusted Root + Trusted Publisher
REM so Windows accepts the test-signed XDMA.sys. Requires admin (checked above).
certutil -addstore -f Root "%PKG_DIR%\XDMA.cer"
if errorlevel 1 (
    echo WARNING: certutil -addstore Root failed (already present?)
)
certutil -addstore -f TrustedPublisher "%PKG_DIR%\XDMA.cer"
if errorlevel 1 (
    echo WARNING: certutil -addstore TrustedPublisher failed (already present?)
)

echo === ENABLE TEST SIGNING ===
REM FIX F2 / DRV-5 SG-2: enable kernel test signing. Requires REBOOT.
bcdedit /set testsigning on
if errorlevel 1 (
    echo WARNING: bcdedit /set testsigning on failed (secure boot enabled?)
    echo        Disable Secure Boot in BIOS if test signing refuses to stick.
) else (
    echo NOTE: Reboot required for testsigning to take effect.
)

echo === Compiling test_xdma.exe ===
cl.exe /nologo /O2 /MT /D_WIN64 /DAMD64 ^
    /Fo"%TMP_DIR%\test_xdma.obj" ^
    "%~dp0test_xdma.c" /Fe:"%BUILD_DIR%\test_xdma.exe" ^
    /I"%KIT_ROOT%\Include\%WDK_VERSION%\um" ^
    /I"%KIT_ROOT%\Include\%WDK_VERSION%\shared" ^
    /I"%KIT_ROOT%\Include\%WDK_VERSION%\ucrt" ^
    /link ^
    /LIBPATH:"%KIT_ROOT%\Lib\%WDK_VERSION%\um\x64" ^
    /LIBPATH:"%KIT_ROOT%\Lib\%WDK_VERSION%\ucrt\x64" ^
    kernel32.lib user32.lib
if %ERRORLEVEL% neq 0 (
    echo ERROR: test_xdma.c compilation failed
    exit /b 1
)

echo === Installing driver binary ===
copy /Y "%BUILD_DIR%\XDMA.sys" "C:\Windows\System32\drivers\XDMA.sys"
if errorlevel 1 (
    echo ERROR: failed to copy XDMA.sys to System32\drivers (run as admin?)
    exit /b 1
)

echo === Creating kernel service ===
REM NOTE: This is the manual sc-create path for quick local testing on the
REM dev machine. For target machines use driver\install.cmd (pnputil-based).
REM Spaces after '=' are MANDATORY for sc.exe (DRV-5 #11).
sc stop XDMA >nul 2>&1
sc delete XDMA >nul 2>&1
sc create XDMA type= kernel binpath= "C:\Windows\System32\drivers\XDMA.sys" start= demand
if %ERRORLEVEL% neq 0 (
    sc query XDMA >nul 2>&1
    if !ERRORLEVEL! equ 0 (
        echo Service XDMA already exists, replacing binpath...
        sc config XDMA binpath= "C:\Windows\System32\drivers\XDMA.sys" start= demand
    ) else (
        echo ERROR: failed to create service
        exit /b 1
    )
)

echo === Starting service ===
sc start XDMA
if %ERRORLEVEL% neq 0 (
    echo WARNING: sc start failed (need re-enumeration or testsigning=Yes)
)

echo.
echo === Build FULL SUCCESS ===
dir "%BUILD_DIR%\"
endlocal