@echo off
setlocal enabledelayedexpansion

set SYS_DIR=%~dp0sys
set EXE_DIR=%~dp0exe
set BUILD_SYS=%~dp0build\sys
set BUILD_EXE=%~dp0build\exe
set TMP_DIR=%~dp0build_tmp
set KIT_ROOT=C:\Program Files (x86)\Windows Kits\10
set KIT_BIN=C:\Program Files (x86)\Windows Kits\10\bin\x86
set WDK_VERSION=10.0.14393.0
set VS_ROOT=C:\Program Files (x86)\Microsoft Visual Studio 14.0
set CBT=75123401EF9C21BF68CA0EA1D2303D9154CC1A06

if not exist "%BUILD_SYS%" mkdir "%BUILD_SYS%"
if not exist "%BUILD_EXE%" mkdir "%BUILD_EXE%"
if not exist "%TMP_DIR%" mkdir "%TMP_DIR%"

echo === Setting VS2015 x64 environment ===
call "%VS_ROOT%\VC\vcvarsall.bat" x64
if %ERRORLEVEL% neq 0 (
    echo ERROR: vcvarsall.bat failed
    exit /b 1
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
    "%SYS_DIR%\driver.c"
if %ERRORLEVEL% neq 0 (
    echo ERROR: driver.c compilation failed
    exit /b 1
)

echo === Linking XDMA.sys ===
link.exe /nologo /entry:DriverEntry /subsystem:native /machine:x64 /driver /kernel /nodefaultlib ^
    "%TMP_DIR%\driver.obj" ^
    /out:"%BUILD_SYS%\XDMA.sys" ^
    /LIBPATH:"%KIT_ROOT%\Lib\%WDK_VERSION%\km\x64" ^
    /LIBPATH:"%KIT_ROOT%\Lib\%WDK_VERSION%\ucrt\x64" ^
    /LIBPATH:"%KIT_ROOT%\Lib\wdf\kmdf\x64\1.15" ^
    ntoskrnl.lib hal.lib wdfldr.lib wdfdriverentry.lib
if %ERRORLEVEL% neq 0 (
    echo ERROR: linking XDMA.sys failed
    exit /b 1
)

echo === Compiling test_xdma.exe ===
cl.exe /nologo /O2 /MT /D_WIN64 /DAMD64 ^
    /Fo"%TMP_DIR%\test_xdma.obj" ^
    "%EXE_DIR%\test_xdma.c" /Fe:"%BUILD_EXE%\test_xdma.exe" ^
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

echo === Copying INF and signing artifacts ===
copy /Y "%SYS_DIR%\XDMA.inx" "%BUILD_SYS%\XDMA.inf" >nul
copy /Y "%BUILD_SYS%\XDMA.inf" "%BUILD_EXE%\..\XDMA.inf" >nul 2>&1

echo === Signing XDMA.sys ===
"%KIT_BIN%\signtool.exe" sign /v /s My /sha1 %CBT% /fd sha256 "%BUILD_SYS%\XDMA.sys" >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo WARNING: signing failed, proceeding without signature
)

echo === Creating .cat catalog file ===
copy /Y "%~dp0build\XDMA.cat" "%BUILD_SYS%\XDMA.cat" >nul 2>&1
if not exist "%BUILD_SYS%\XDMA.cat" (
    echo WARNING: XDMA.cat not found in driver\build, continuing without .cat
)

echo === Exporting .cer certificate ===
powershell -Command "$c=Get-ChildItem 'Cert:\CurrentUser\My\%CBT%'; if($c){[System.IO.File]::WriteAllBytes('%BUILD_SYS:\=\%\\XDMA.cer',$c.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))}" >nul 2>&1
if not exist "%BUILD_SYS%\XDMA.cer" (
    echo WARNING: cert export failed, continuing without .cer
)

echo === Signing .cat ===
if exist "%BUILD_SYS%\XDMA.cat" (
    "%KIT_BIN%\signtool.exe" sign /v /s My /sha1 %CBT% /fd sha256 "%BUILD_SYS%\XDMA.cat" >nul 2>&1
    if %ERRORLEVEL% neq 0 (
        echo WARNING: .cat signing failed
    )
)

echo === Copying to build directory ===
copy /Y "%BUILD_SYS%\XDMA.sys"  "%~dp0build\XDMA.sys" >nul 2>&1
copy /Y "%BUILD_SYS%\XDMA.cat"  "%~dp0build\XDMA.cat" >nul 2>&1
copy /Y "%BUILD_SYS%\XDMA.cer"  "%~dp0build\XDMA.cer" >nul 2>&1
copy /Y "%BUILD_SYS%\XDMA.inf"  "%~dp0build\XDMA.inf" >nul 2>&1
copy /Y "%BUILD_EXE%\test_xdma.exe" "%~dp0build\test_xdma.exe" >nul 2>&1

echo.
echo === Build FULL SUCCESS ===
echo   driver: %BUILD_SYS%\XDMA.sys
echo   test:   %BUILD_EXE%\test_xdma.exe

echo.
echo === Files in %BUILD_SYS% ===
dir /b "%BUILD_SYS%"

echo.
echo === Files in %BUILD_EXE% ===
dir /b "%BUILD_EXE%"

endlocal