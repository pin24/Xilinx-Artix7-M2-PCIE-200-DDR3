Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DiagIoctl {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr CreateFileW(string p, uint a, uint s, IntPtr sa, uint d, uint f, IntPtr t);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr CreateEventW(IntPtr a, bool m, bool i, string n);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteFile(IntPtr h, byte[] b, uint n, out uint w, IntPtr o);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool DeviceIoControl(IntPtr h, uint code, byte[] inb, uint isz, byte[] outb, uint osz, out uint ret, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetOverlappedResult(IntPtr h, IntPtr o, out uint n, bool w);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CancelIo(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
}
'@ -Language CSharp

$OV_OFF_LO=16; $OV_OFF_HI=20; $OV_EVT=24
$DIAG_IOCTL = 0x00220018  # CTL_CODE(0x22, 0x6, METHOD_BUFFERED=0, FILE_ANY_ACCESS=0)

function DiagGet([IntPtr]$h2c) {
    $out = New-Object byte[] 16
    $ret = [uint32]0
    if (-not [DiagIoctl]::DeviceIoControl($h2c, $DIAG_IOCTL, $null, 0, $out, 16, [ref]$ret, [IntPtr]::Zero)) {
        throw "DeviceIoControl DIAG_GET failed GLE=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    $calls = [System.BitConverter]::ToUInt32($out,0)
    $bt = [System.BitConverter]::ToUInt64($out,8)
    return @{ calls=$calls; bytes=$bt }
}

function OpenDev([string]$path) {
    $h = [DiagIoctl]::CreateFileW($path, [uint32]3221225472, 0, [IntPtr]::Zero, 3, [uint32]0x40000000, [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { throw "cannot open $path GLE=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    return $h
}

"=== DIAG: how many times is EvtProgramDma invoked for a 1024B write (WDF multi-packet, limit 512) ==="
$h2c = OpenDev '\\.\XDMA0dma\h2c_0'

$d0 = DiagGet $h2c
"BEFORE: progDmaCalls=$($d0.calls)  bytesTransferred=$($d0.bytes)"

# write 1024 bytes (will hang ~5s) with OVERLAPPED
$ov = New-Object byte[] 32
[BitConverter]::GetBytes([uint32]0x00100000).CopyTo($ov,16)   # offset 0x100000 (DDR3 LOOPBACK_OFF)
[BitConverter]::GetBytes([uint32]0).CopyTo($ov,20)
$evt = [DiagIoctl]::CreateEventW([IntPtr]::Zero, $true, $false, $null)
$evtBytes = [BitConverter]::GetBytes([int64]$evt); $evtBytes.CopyTo($ov,24)
$gch = [Runtime.InteropServices.GCHandle]::Alloc($ov, [Runtime.InteropServices.GCHandleType]::Pinned)
$buf = New-Object byte[] 1024
for($i=0;$i -lt 1024;$i++){ $buf[$i]=($i*7+13) -band 0xFF }
$wr=[uint32]0
if (-not [DiagIoctl]::WriteFile($h2c, $buf, 1024, [ref]$wr, $gch.AddrOfPinnedObject())) {
    $err=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($err -eq 997) {
        $w=[DiagIoctl]::WaitForSingleObject($evt, 4500)
        if ($w -eq 258) { [DiagIoctl]::CancelIo($h2c) | Out-Null; "WRITE: TIMEOUT (IRP hung), cancelled" }
        else { [DiagIoctl]::GetOverlappedResult($h2c, $gch.AddrOfPinnedObject(), [ref]$wr, $true) | Out-Null; "WRITE: OK ($wr bytes)" }
    } else { "WRITE: FAIL GLE=$err" }
} else { "WRITE: OK immediate ($wr bytes)" }
$gch.Free()
[DiagIoctl]::CloseHandle($evt) | Out-Null
Start-Sleep -Milliseconds 200

$d1 = DiagGet $h2c
"AFTER : progDmaCalls=$($d1.calls)  bytesTransferred=$($d1.bytes)"
[DiagIoctl]::CloseHandle($h2c) | Out-Null
""
if ($d1.calls -le 1) { "KEY: progDmaCalls=1 => WDF called EvtProgramDma ONCE (packet 2 NOT programmed) -> packet2 relies on a call that never happens." }
if ($d1.calls -ge 2) { "KEY: progDmaCalls>=2 => WDF DID program packet 2; the hang is in the engine/start, not packet programming." }