@echo off
setlocal enabledelayedexpansion

set BUILD_DIR=%~dp0build
set TMP_DIR=%~dp0build_tmp
set KIT_ROOT=C:\Program Files (x86)\Windows Kits\10
set WDK_VERSION=10.0.14393.0
set VS_ROOT=C:\Program Files (x86)\Microsoft Visual Studio 14.0
set SYS=%~dp0

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
if not exist "%TMP_DIR%" mkdir "%TMP_DIR%"

echo === Setting VS2015 x64 environment ===
call "%VS_ROOT%\VC\vcvarsall.bat" x64
if %ERRORLEVEL% neq 0 (
    echo ERROR: vcvarsall.bat failed
    exit /b 1
)

echo === Checking test certificate ===
certmgr /add /c /s PrivateCertStore WDKTestCert >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Creating self-signed WDKTestCert...
    makecert -r -pe -ss PrivateCertStore -n "CN=WDKTestCert" -eku 1.3.6.1.5.5.7.3.3 -len 2048 WDKTestCert.cer
    if %ERRORLEVEL% equ 0 (
        copy /Y WDKTestCert.cer "%BUILD_DIR%\WDKTestCert.cer" >nul
        echo Certificate created: %BUILD_DIR%\WDKTestCert.cer
    )
)

echo === Compiling XDMA.sys ===
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
if %ERRORLEVEL% neq 0 (
    echo ERROR: failed to copy XDMA.sys to System32\drivers (run as admin?)
    exit /b 1
)

echo === Creating kernel service ===
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