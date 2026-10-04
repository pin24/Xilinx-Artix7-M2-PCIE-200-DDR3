Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class XdmaDiag {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess,
        uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr CreateEventW(IntPtr attrs, bool manual, bool initialState, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool ReadFile(IntPtr hFile, byte[] buf, uint toRead, out uint read, IntPtr ovr);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool WriteFile(IntPtr hFile, byte[] buf, uint toWrite, out uint written, IntPtr ovr);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetOverlappedResult(IntPtr hFile, IntPtr ovr, out uint bytes, bool wait);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CancelIo(IntPtr hFile);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr h);
}
'@ -Language CSharp

# OVERLAPPED (x64): Internal@0(8b), InternalHigh@8(8b), Offset@16(4b), OffsetHigh@20(4b), hEvent@24(8b)
$OV_OFF_LO = 16; $OV_OFF_HI = 20; $OV_EVT = 24

function Open-Dev([string]$path) {
    $GENERIC_RW = [uint32]3221225472   # 0xC0000000 = GENERIC_READ|GENERIC_WRITE (как unsigned)
    $OPEN_EXISTING = [uint32]3
    $OVERLAPPED = [uint32]0x40000000
    $h = [XdmaDiag]::CreateFileW($path, $GENERIC_RW, 0, [IntPtr]::Zero, $OPEN_EXISTING, $OVERLAPPED, [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { throw "cannot open $path GLE=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    return $h
}

# Build OVERLAPPED byte array with offset and a fresh (manual-reset) event handle.
function New-Ovr([uint64]$off) {
    $ov = [byte[]]::new(32)
    $lo = [uint32]($off -band 0xFFFFFFFF)
    $hi = [uint32](($off -shr 32) -band 0xFFFFFFFF)
    [System.BitConverter]::GetBytes([uint32]$lo).CopyTo($ov, $OV_OFF_LO)
    [System.BitConverter]::GetBytes([uint32]$hi).CopyTo($ov, $OV_OFF_HI)
    $evt = [XdmaDiag]::CreateEventW([IntPtr]::Zero, $true, $false, $null)
    $evtPtr = [System.BitConverter]::GetBytes([int64]$evt)
    $evtPtr.CopyTo($ov, $OV_EVT)
    return @{ ov = $ov; evt = $evt }
}

function Read-Eng([IntPtr]$h, [uint64]$off) {
    $o = New-Ovr $off
    $gch = [System.Runtime.InteropServices.GCHandle]::Alloc($o.ov, [System.Runtime.InteropServices.GCHandleType]::Pinned)
    try {
        $buf = [byte[]]::new(4)
        $rd = [uint32]0
        if (-not [XdmaDiag]::ReadFile($h, $buf, 4, [ref]$rd, $gch.AddrOfPinnedObject())) {
            $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            if ($err -ne 997) { throw "ReadFile GLE=$err" }
            [XdmaDiag]::WaitForSingleObject($o.evt, 3000) | Out-Null
            [XdmaDiag]::GetOverlappedResult($h, $gch.AddrOfPinnedObject(), [ref]$rd, $true) | Out-Null
        }
        return [System.BitConverter]::ToUInt32($buf, 0)
    } finally {
        $gch.Free()
        if ($o.evt -ne [IntPtr]::Zero) { [XdmaDiag]::CloseHandle($o.evt) | Out-Null }
    }
}

function Write-Eng([IntPtr]$h, [uint64]$off, [byte[]]$data, [int]$timeoutMs) {
    $o = New-Ovr $off
    $gch = [System.Runtime.InteropServices.GCHandle]::Alloc($o.ov, [System.Runtime.InteropServices.GCHandleType]::Pinned)
    try {
        $written = [uint32]0
        if (-not [XdmaDiag]::WriteFile($h, $data, [uint32]$data.Length, [ref]$written, $gch.AddrOfPinnedObject())) {
            $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            if ($err -ne 997) { throw "WriteFile GLE=$err" }
            $w = [XdmaDiag]::WaitForSingleObject($o.evt, [uint32]$timeoutMs)
            if ($w -eq 258) {
                [XdmaDiag]::CancelIo($h) | Out-Null
                return "TIMEOUT (IRP hung, cancelled)"
            }
            [XdmaDiag]::GetOverlappedResult($h, $gch.AddrOfPinnedObject(), [ref]$written, $true) | Out-Null
        }
        return "OK written=$written"
    } finally {
        $gch.Free()
        if ($o.evt -ne [IntPtr]::Zero) { [XdmaDiag]::CloseHandle($o.evt) | Out-Null }
    }
}

"=== XDMA H2C0 engine register diagnostic (multi-packet / limit 512) ==="
$H2C0_STAT   = 0x40
$H2C0_STATRC = 0x44
$H2C0_COMPL  = 0x48

$cfg = Open-Dev '\\.\XDMA0dma\control'

$c0 = Read-Eng $cfg $H2C0_COMPL
$s0 = Read-Eng $cfg $H2C0_STAT
"BEFORE: H2C0 completedDescCount=0x{0:X8} ({1})  status=0x{2:X8} (BUSY={3})" -f $c0,$c0,$s0,(($s0 -band 1))
""

$h2c = Open-Dev '\\.\XDMA0dma\h2c_0'
$buf = New-Object byte[] 1024
for ($i=0; $i -lt 1024; $i++) { $buf[$i] = ($i * 7 + 13) -band 0xFF }
"Writing 1024 B to DDR3 offset 0x100000 (h2c_0) -- expected to HANG (multi-packet)..."
$wm = Write-Eng $h2c 0x100000 $buf 4000
"WRITE result: $wm"
[XdmaDiag]::CloseHandle($h2c) | Out-Null
Start-Sleep -Milliseconds 100

$c1 = Read-Eng $cfg $H2C0_COMPL
$s1 = Read-Eng $cfg $H2C0_STAT
$r1 = Read-Eng $cfg $H2C0_STATRC
"AFTER : H2C0 completedDescCount=0x{0:X8} ({1})  status=0x{2:X8} (BUSY={3})  statusRC=0x{4:X8}" -f $c1,$c1,$s1,(($s1 -band 1)),$r1
[XdmaDiag]::CloseHandle($cfg) | Out-Null
""
if ($c1 -le 1) { "KEY: completedDescCount stopped at <=1 => packet-1 completed/exited; packet-2 NOT advanced by host (ISR not delivered)." }
else { "KEY: completedDescCount >= 2 => engine kept running past first packet; issue is in host completion/advance path." }
"NOTE: statusRC is read-and-clear; reading it last clears BUSY (engine left in STOPPED_OK, safe to reuse)."