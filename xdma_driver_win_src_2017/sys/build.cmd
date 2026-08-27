@echo off
setlocal
set SYS=C:\A7_M2\EXAMPLES\XDMA\XDMA_Driver_App\xdma_driver_win_src_2017\sys
set BUILD=%SYS%\..\build\x64\XDMA_Driver\Win10_Release
set WINKIT=C:\PROGRA~2\Windows Kits\10
set WVER=10.0.14393.0
set INC=/I"%WINKIT%\Include\%WVER%\km" /I"%WINKIT%\Include\%WVER%\shared" /I"%WINKIT%\Include\%WVER%\um" /I"%WINKIT%\Include\%WVER%\ucrt"
set LIBPATH=/LIBPATH:"%WINKIT%\Lib\%WVER%\km\x64" /LIBPATH:"%WINKIT%\Lib\%WVER%\ucrt\x64"

call "C:\PROGRA~2\Microsoft Visual Studio 14.0\VC\vcvarsall.bat" x64 2>nul >nul
if not exist "%BUILD%" mkdir "%BUILD%"

echo [1/3] Compiling...
cl.exe /c /nologo /O1 /GS- /kernel /Zp8 /Gy /GF /GR- /Gz /TC /D_WIN64 /D_AMD64_ /DAMD64 /DWINNT=1 /D_WIN32_WINNT=0x0A00 /DNTDDI_VERSION=0x0A000002 /D_UNICODE /DUNICODE %INC% "%SYS%\driver.c" /Fo"%SYS%\driver.obj"
if errorlevel 1 goto err

echo [2/3] Linking...
link.exe /nologo /entry:DriverEntry /subsystem:native /machine:x64 /driver /kernel /nodefaultlib "%SYS%\driver.obj" /out:"%BUILD%\XDMA.sys" %LIBPATH% ntoskrnl.lib hal.lib
if errorlevel 1 goto err

echo [3/3] Signing...
signtool sign /v /s PrivateCertStore /n WDKTestCert /fd sha256 "%BUILD%\XDMA.sys" >nul 2>&1
if errorlevel 1 echo Signing optional (testsigning=Yes)

copy /Y "%BUILD%\XDMA.sys" "C:\Windows\System32\drivers\XDMA.sys" >nul
sc stop XDMA >nul 2>&1
sc delete XDMA >nul 2>&1
sc create XDMA type=kernel binpath="C:\Windows\System32\drivers\XDMA.sys" start=demand >nul 2>&1

echo BUILD OK
dir "%BUILD%\XDMA.sys"
goto end

:err
echo BUILD FAILED
exit /b 1

:end