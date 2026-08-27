@echo off
setlocal enabledelayedexpansion

set SYS=%~dp0
set SYS=%SYS:~0,-1%
set BUILD=%SYS%\..\build\x64\XDMA_Driver\Win10_Release
set TMP=%SYS%\..\build_tmp\XDMA_Driver\x64\Win10_Release
set LIBXDMA=%SYS%\..\libxdma
set LIBXDMA_BUILD=%LIBXDMA%\..\build\x64\libxdma\Win10_Release
set WINKIT=C:\Program Files (x86)\Windows Kits\10
set WVER=10.0.14393.0
set INC=/I"%WINKIT%\Include\%WVER%\km" /I"%WINKIT%\Include\%WVER%\shared" /I"%WINKIT%\Include\%WVER%\um" /I"%WINKIT%\Include\%WVER%\ucrt" /I"%WINKIT%\Include\wdf\kmdf\1.15" /I"%LIBXDMA%" /I"%SYS%\..\inc"
set LIBPATH=/LIBPATH:"%WINKIT%\Lib\%WVER%\km\x64" /LIBPATH:"%WINKIT%\Lib\%WVER%\ucrt\x64" /LIBPATH:"%WINKIT%\Lib\wdf\kmdf\x64\1.15"

call "C:\Program Files (x86)\Microsoft Visual Studio 14.0\VC\vcvarsall.bat" x64 2>nul >nul
if not exist "%TMP%" mkdir "%TMP%"
if not exist "%BUILD%" mkdir "%BUILD%"

rem Step 1: Build libxdma
echo [1/4] Building libxdma...
msbuild "%LIBXDMA%\libxdma.vcxproj" /p:Configuration=Win10_Release /p:Platform=x64 /t:Build /nologo 2>nul
if not exist "%LIBXDMA_BUILD%\xdma.lib" (
    echo ERROR: libxdma build failed
    exit /b 1
)

rem Step 2: Compile
echo [2/4] Compiling...
cl.exe /c /nologo /O1 /GS- /kernel /Zp8 /Gy /GF /GR- /Gz /TC /D_WIN64 /D_AMD64_ /DAMD64 /DWINNT=1 /D_WIN32_WINNT=0x0A00 /DNTDDI_VERSION=0x0A000002 /D_UNICODE /DUNICODE %INC% "%SYS%\driver.c" /Fo"%TMP%\driver.obj"
if errorlevel 1 exit /b 1
cl.exe /c /nologo /O1 /GS- /kernel /Zp8 /Gy /GF /GR- /Gz /TC /D_WIN64 /D_AMD64_ /DAMD64 /DWINNT=1 /D_WIN32_WINNT=0x0A00 /DNTDDI_VERSION=0x0A000002 /D_UNICODE /DUNICODE %INC% "%SYS%\file_io.c" /Fo"%TMP%\file_io.obj"
if errorlevel 1 exit /b 1

rem Step 3: Link
echo [3/4] Linking...
link.exe /nologo /entry:DriverEntry /subsystem:native /machine:x64 /driver /kernel /nodefaultlib "%TMP%\driver.obj" "%TMP%\file_io.obj" "%LIBXDMA_BUILD%\xdma.lib" /out:"%BUILD%\XDMA.sys" %LIBPATH% ntoskrnl.lib hal.lib wdfldr.lib wdfdriverentry.lib
if errorlevel 1 exit /b 1

rem Step 4: Sign
echo [4/4] Signing...
signtool sign /v /s PrivateCertStore /n WDKTestCert /fd sha256 "%BUILD%\XDMA.sys" >nul 2>&1
if errorlevel 1 echo Signing: test signing enabled (signtool may be optional)

rem Copy results
copy /Y "%BUILD%\XDMA.sys" "%SYS%\XDMA.sys" >nul
echo BUILD OK
dir "%BUILD%\XDMA.sys"