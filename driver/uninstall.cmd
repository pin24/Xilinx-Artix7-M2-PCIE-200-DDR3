@echo off
REM ==========================================================================
REM uninstall.cmd — XDMA DDR3 Ternary Accelerator driver uninstaller
REM
REM Reverses install.cmd: stops + deletes the kernel service, removes the
REM PnP driver package (if installed via pnputil), and optionally disables
REM test signing. Does NOT remove the test certificate from Root / Trusted
REM Publisher by default (leaving it allows re-installing without re-import).
REM To fully purge the cert, uncomment the certutil -delstore lines below.
REM
REM Created by FIX-4 (Task ID: FIX-4) — see /home/z/my-project/worklog.md
REM ==========================================================================
setlocal

REM --- Admin check ---
net session >nul 2>&1
if errorlevel 1 (
    echo ERROR: Run as Administrator.
    exit /b 1
)

echo [1/4] Stopping service (if running)...
sc stop XDMA 2>nul
if errorlevel 1 (
    echo   service not running or does not exist (OK)
)

echo [2/4] Deleting service (if present)...
sc delete XDMA 2>nul
if errorlevel 1 (
    echo   service not found (OK)
)

echo [3/4] Removing PnP driver package (if installed via pnputil)...
REM pnputil /enum-drivers output (Windows 10+):
REM   Published Name:     oem12.inf      <- we want this
REM   Original Name:      xdma.inf       <- matches our driver
REM   Provider Name:      MultiTool
REM   Class Name:         System
REM   ...
REM "Published Name:" precedes "Original Name:", so we track the most recent
REM published name and delete it when we see "Original Name: xdma.inf".
REM Robust against multiple installs (loops until none remain).
powershell -NoProfile -Command "$out = pnputil /enum-drivers; $published = $null; foreach ($line in $out) { if ($line -match 'Published Name:\s+(oem\d+\.inf)') { $published = $matches[1] } elseif ($line -match 'Original Name:\s+xdma\.inf' -and $published) { Write-Host ('  removing ' + $published); pnputil /delete-driver $published /uninstall /force 2>$null; $published = $null } }"

echo [4/4] Disable test signing (optional, requires reboot)...
REM Uncomment the next line to turn test signing OFF. Leave it commented to
REM keep test signing enabled for other test drivers.
REM bcdedit /set testsigning off

REM Optional: remove the test certificate from cert stores.
REM Uncomment to fully purge (will require re-import on next install.cmd run).
REM certutil -delstore Root WDKTestCert
REM certutil -delstore TrustedPublisher WDKTestCert

echo.
echo Done. Reboot recommended (especially if test signing was toggled).
echo.
pause
endlocal
