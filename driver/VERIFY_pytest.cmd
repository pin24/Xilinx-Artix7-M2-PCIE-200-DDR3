@echo off
REM ==========================================================================
REM VERIFY.cmd - reproducible full check: driver build + host (Python) part.
REM Run as Administrator (driver build/install need elevation).
REM Expected results are documented in AUDIT-REPORT.md / HANDOFF.md.
REM ==========================================================================
setlocal
set ROOT=%~dp0
set PY=C:\Python39\python.exe


echo [3/6] Python: syntax check (all .py under project root)...
for /r "%ROOT%.." %%F in (*.py) do "%PY%" -m py_compile "%%F" || (echo *** PY SYNTAX FAIL: %%F *** & exit /b 1)
echo    OK

echo [4/6] ternary_sw unit tests...
pushd "%ROOT%..\ternary_sw"
"%PY%" -m pytest tests -q || (echo *** TESTS FAILED *** & popd & exit /b 1)
popd

echo [5/6] Driver emulators (no hardware needed)...
"%PY%" "%ROOT%emulate_test.py" || (echo *** EMULATE FAILED *** & exit /b 1)
"%PY%" "%ROOT%edge_cases.py"   || (echo *** EDGE CASES FAILED *** & exit /b 1)

echo [6/6] Hardware smoke tests (safe subset)...
"%ROOT%build\test_xdma.exe" ddr3
echo    ^(ddr3 must print SKIP on the DFX build; exit code 0^)
"%ROOT%build\test_xdma.exe" gpio tdot xadc

echo.

endlocal
