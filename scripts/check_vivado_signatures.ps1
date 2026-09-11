# check_vivado_signatures.ps1 - diagnose "Unknown error occured while verifying
# the digital signature" (0x80096010) failures of the Vivado launcher.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\check_vivado_signatures.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\check_vivado_signatures.ps1 "C:\AMDDesignTools\2025.2\Vivado"
#
# Notes: the launcher verifies signatures of the DLLs it loads. On hosts with an
# aggressive AV (observed: 360 Total Security) that check can fail intermittently
# while the file signature itself is valid - see driver/ERROR-FIX-LOG.md (E-11).
param([string]$VivadoRoot = 'C:\AMDDesignTools\2025.2\Vivado')
$lib = Join-Path $VivadoRoot 'lib\win64.o'
if (!(Test-Path $lib)) { Write-Host "ERROR: not found: $lib"; exit 2 }

$files = Get-ChildItem $lib -File | Where-Object { $_.Extension -in '.dll','.exe','.pyd' }
$ok = 0; $unsigned = 0; $bad = @()
foreach ($f in $files) {
    $s = Get-AuthenticodeSignature $f.FullName
    switch ("$($s.Status)") {
        'Valid'     { $ok++ }
        'NotSigned' { $unsigned++ }
        default     { $bad += ("{0}  => {1}" -f $f.Name, $s.Status) }
    }
}
Write-Host ("Vivado lib check: valid={0}  notsigned={1}  problems={2}  total={3}" -f $ok, $unsigned, $bad.Count, $files.Count)
if ($bad.Count) {
    Write-Host "PROBLEMS (hash mismatch / untrusted):"
    $bad | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "OK: no hash/trust problems. If the launcher still failed, it was likely"
Write-Host "    intermittent AV interference - add exclusions (C:\AMDDesignTools, project"
Write-Host "    dir) and retry; see driver/ERROR-FIX-LOG.md E-11."
exit 0
