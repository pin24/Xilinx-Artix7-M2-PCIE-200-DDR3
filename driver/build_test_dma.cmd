@echo off
setlocal

REM ==========================================================================
REM  build_test_dma.cmd — compile the user-mode DMA test (test_dma.c).
REM
REM  Builds build\test_dma.exe against the WDK user-mode (um) headers/libs,
REM  exactly like the user-mode half of driver\build.cmd (the test_xdma step).
REM  This is USER-MODE only — no kernel compile, no WDKTestCert, no driver
REM  build. The driver itself is built by driver\build.cmd (NOT redone here).
REM ==========================================================================

set BUILD_DIR=%~dp0build
set TMP_DIR=%~dp0build_tmp
set KIT_ROOT=C:\Program Files (x86)\Windows Kits\10
set WDK_VERSION=10.0.14393.0
set VS_ROOT=C:\Program Files (x86)\Microsoft Visual Studio 14.0

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
if not exist "%TMP_DIR%"  mkdir "%TMP_DIR%"

echo === Setting VS2015 x64 environment ===
call "%VS_ROOT%\VC\vcvarsall.bat" x64
if %ERRORLEVEL% neq 0 (
    echo ERROR: vcvarsall.bat failed
    exit /b 1
)

echo === Compiling test_dma.exe (user-mode) ===
cl.exe /nologo /W4 /O2 /MT /D_WIN64 /DAMD64 ^
    /Fo"%TMP_DIR%\test_dma.obj" ^
    "%~dp0test_dma.c" /Fe:"%BUILD_DIR%\test_dma.exe" ^
    /I"%KIT_ROOT%\Include\%WDK_VERSION%\um" ^
    /I"%KIT_ROOT%\Include\%WDK_VERSION%\shared" ^
    /I"%KIT_ROOT%\Include\%WDK_VERSION%\ucrt" ^
    /link ^
    /LIBPATH:"%KIT_ROOT%\Lib\%WDK_VERSION%\um\x64" ^
    /LIBPATH:"%KIT_ROOT%\Lib\%WDK_VERSION%\ucrt\x64" ^
    kernel32.lib user32.lib
if %ERRORLEVEL% neq 0 (
    echo ERROR: test_dma.c compilation failed
    exit /b 1
)

echo.
echo === Build SUCCESS ===
dir "%BUILD_DIR%\test_dma.exe"
endlocal