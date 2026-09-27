@echo off
setlocal enabledelayedexpansion

REM ============================================================================
REM build.cmd — автономная сборка DMA-драйвера XDMA (driver\dma).
REM
REM Собирает: dma_driver.c (гейтвей) + ПОДЛИННЫй upstream-стек
REM   xdma_driver_win_src_2017\{libxdma\device.c, libxdma\dma_engine.c,
REM   libxdma\interrupt.c, sys\file_io.c} + security_cookie.c
REM в driver\dma\build\sys\XDMA_DMA.sys + .inf + .cat + .cer.
REM
REM Проверенная схема сборки скопирована с рабочего driver\build.cmd
REM (FIX-8 /entry:FxDriverEntry, stampinf->inf2cat, WDKTestCert, signtool).
REM
REM ВАЖНО:
REM   * WPP-трассировка НЕ включается (без /DDBG — trace.h саб-инлайнит макросы,
REM     .tmh-файлы не требуются).
REM   * Подменённый (кастомный MMIO) xdma_driver_win_src_2017\sys\driver.c НЕ
REM     компилируется — он переименован в driver.c.substituted (анти-риск).
REM ============================================================================

set DMA_DIR=%~dp0
set DMA_DIR=%DMA_DIR:~0,-1%
set ROOT=%DMA_DIR%\..\..
set UPSTREAM=%ROOT%\xdma_driver_win_src_2017

set BUILD_DIR=%DMA_DIR%\build
set PKG_DIR=%DMA_DIR%\build\sys
set TMP_DIR=%DMA_DIR%\build_tmp

set KIT_ROOT=C:\Program Files (x86)\Windows Kits\10
set WDK_VERSION=10.0.14393.0
set VS_ROOT=C:\Program Files (x86)\Microsoft Visual Studio 14.0

REM Версия драйвера: меняй при каждом релизе (pnputil не заменяет пакет,
REM если новая DriverVer не строго новее установленной).
set DRIVER_VERSION=1.0.0.0

REM FIX F2: нужны права администратора (certutil -addstore, bcdedit).
net session >nul 2>&1
if errorlevel 1 (
    echo ERROR: This script must be run as Administrator.
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
powershell -NoProfile -Command "$exists = Get-ChildItem 'Cert:\CurrentUser\PrivateCertStore' -ErrorAction SilentlyContinue | Where-Object { $_.Subject -match 'CN=WDKTestCert' }; if (-not $exists) { exit 1 }"
if errorlevel 1 (
    echo Creating self-signed WDKTestCert...
    makecert -r -pe -ss PrivateCertStore -n "CN=WDKTestCert" -eku 1.3.6.1.5.5.7.3.3 -len 2048 "%DMA_DIR%\WDKTestCert.cer"
    if errorlevel 1 (
        echo ERROR: makecert failed to create WDKTestCert
        exit /b 1
    )
)

REM Export cert for target-machine install.
powershell -NoProfile -Command "$c = Get-ChildItem 'Cert:\CurrentUser\PrivateCertStore' -ErrorAction SilentlyContinue | Where-Object { $_.Subject -match 'CN=WDKTestCert' } | Select-Object -First 1; if (-not $c) { Write-Error 'WDKTestCert not found'; exit 1 }; [System.IO.File]::WriteAllBytes('%PKG_DIR%\XDMA_DMA.cer', $c.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))"
if errorlevel 1 (
    echo ERROR: failed to export XDMA_DMA.cer
    exit /b 1
)

REM Анти-риск: если upstream sys\driver.c (подмена!) НЕ переименован — отказ.
if exist "%UPSTREAM%\sys\driver.c" (
    echo ERROR: xdma_driver_win_src_2017\sys\driver.c still exists.
    echo        It is a SUBSTITUTED MMIO copy and must be renamed to driver.c.substituted
    echo        before building the DMA driver.
    exit /b 1
)

REM ============================================================================
echo === Compiling sources (WPP off, no /DBG) ===
REM Include paths: this dir (dma_driver.h) + km/shared + wdf kmdf 1.15 + upstream inc/libxdma/sys.
set INC=/I"%DMA_DIR%" /I"%KIT_ROOT%\Include\%WDK_VERSION%\km" /I"%KIT_ROOT%\Include\%WDK_VERSION%\shared" /I"%KIT_ROOT%\Include\wdf\kmdf\1.15" /I"%UPSTREAM%\inc" /I"%UPSTREAM%\libxdma" /I"%UPSTREAM%\sys"

set CFLAGS=/nologo /c /O1 /GS- /kernel /Zp8 /Gy /GF /GR- /Gz /TC /D_WIN64 /D_AMD64_ /DAMD64 /DWINNT=1 /D_WIN32_WINNT=0x0A00 /DNTDDI_VERSION=0x0A000002 /D_UNICODE /DUNICODE

echo -- dma_driver.c -- 
cl.exe %CFLAGS% %INC% /Fo"%TMP_DIR%\dma_driver.obj" "%DMA_DIR%\dma_driver.c" || exit /b 1
echo -- file_io.c (upstream) -- 
cl.exe %CFLAGS% %INC% /Fo"%TMP_DIR%\file_io.obj" "%UPSTREAM%\sys\file_io.c" || exit /b 1
echo -- libxdma\device.c -- 
cl.exe %CFLAGS% %INC% /Fo"%TMP_DIR%\device.obj" "%UPSTREAM%\libxdma\device.c" || exit /b 1
echo -- libxdma\dma_engine.c -- 
cl.exe %CFLAGS% %INC% /Fo"%TMP_DIR%\dma_engine.obj" "%UPSTREAM%\libxdma\dma_engine.c" || exit /b 1
echo -- libxdma\interrupt.c -- 
cl.exe %CFLAGS% %INC% /Fo"%TMP_DIR%\interrupt.obj" "%UPSTREAM%\libxdma\interrupt.c" || exit /b 1
echo -- security_cookie.c -- 
cl.exe %CFLAGS% %INC% /Fo"%TMP_DIR%\security_cookie.obj" "%DMA_DIR%\security_cookie.c" || exit /b 1

REM ============================================================================
echo === Linking XDMA_DMA.sys ===
REM FIX-8: точка входа — FxDriverEntry (стаб wdfdriverentry.lib инициализирует
REM WdfFunctions/WdfDriverGlobals ДО нашего DriverEntry). Без этого — NULL-jump.
link.exe /nologo /entry:FxDriverEntry /subsystem:native /machine:x64 /driver /kernel /nodefaultlib ^
    "%TMP_DIR%\dma_driver.obj" "%TMP_DIR%\file_io.obj" "%TMP_DIR%\device.obj" ^
    "%TMP_DIR%\dma_engine.obj" "%TMP_DIR%\interrupt.obj" "%TMP_DIR%\security_cookie.obj" ^
    /out:"%BUILD_DIR%\XDMA_DMA.sys" ^
    /LIBPATH:"%KIT_ROOT%\Lib\%WDK_VERSION%\km\x64" ^
    /LIBPATH:"%KIT_ROOT%\Lib\wdf\kmdf\x64\1.15" ^
    ntoskrnl.lib hal.lib wdfldr.lib wdfdriverentry.lib
if %ERRORLEVEL% neq 0 (
    echo ERROR: linking XDMA_DMA.sys failed
    exit /b 1
)

REM ============================================================================
echo === Creating INF from INX (version %DRIVER_VERSION%) ===
REM stampinf в WDK 14393 НЕ имеет опции -o (правит -f in-place): копируем
REM шаблон в .inf, затем штампуем копию.
copy /Y "%DMA_DIR%\XDMA_DMA.inx" "%TMP_DIR%\XDMA_DMA.inf" >nul || exit /b 1
REM inf2cat отбрасывает DriverVer в будущем (сравнивает с UTC). Штампуем вчера.
powershell -NoProfile -Command "(Get-Date).ToUniversalTime().AddDays(-1).ToString('MM\/dd\/yyyy',[Globalization.CultureInfo]::InvariantCulture)" > "%TMP_DIR%\infdate.txt"
set /p INF_DATE=<"%TMP_DIR%\infdate.txt"
del "%TMP_DIR%\infdate.txt" >nul 2>&1
stampinf -f "%TMP_DIR%\XDMA_DMA.inf" -d %INF_DATE% -a "amd64" -v "%DRIVER_VERSION%" -k "1.15" -x
if %ERRORLEVEL% neq 0 (
    echo ERROR: stampinf failed
    exit /b 1
)
copy /Y "%TMP_DIR%\XDMA_DMA.inf" "%BUILD_DIR%\XDMA_DMA.inf" >nul

echo === Creating catalog file ===
inf2cat /driver:"%BUILD_DIR%" /os:10_x64 /verbose
if %ERRORLEVEL% neq 0 (
    echo WARNING: Inf2Cat failed, creating catalog manually...
    signtool cat /v "%BUILD_DIR%\XDMA_DMA.sys" /out:"%BUILD_DIR%\XDMA_DMA.cat" >nul 2>&1
)

echo === Signing XDMA_DMA.sys ===
signtool sign /v /s PrivateCertStore /n WDKTestCert /fd sha256 "%BUILD_DIR%\XDMA_DMA.sys"

echo === Signing catalog ===
if exist "%BUILD_DIR%\XDMA_DMA.cat" (
    signtool sign /v /s PrivateCertStore /n WDKTestCert /fd sha256 "%BUILD_DIR%\XDMA_DMA.cat"
)

echo === Staging package in build\sys ===
copy /Y "%BUILD_DIR%\XDMA_DMA.sys" "%PKG_DIR%\XDMA_DMA.sys" >nul
copy /Y "%BUILD_DIR%\XDMA_DMA.inf" "%PKG_DIR%\XDMA_DMA.inf" >nul
if exist "%BUILD_DIR%\XDMA_DMA.cat" copy /Y "%BUILD_DIR%\XDMA_DMA.cat" "%PKG_DIR%\XDMA_DMA.cat" >nul

REM === INSTALL TEST CERT + TEST SIGNING ===
certutil -addstore -f Root "%PKG_DIR%\XDMA_DMA.cer" >nul 2>&1
certutil -addstore -f TrustedPublisher "%PKG_DIR%\XDMA_DMA.cer" >nul 2>&1
bcdedit /set testsigning on >nul 2>&1

echo.
echo === Build FULL SUCCESS ===
dir "%PKG_DIR%\"
endlocal