import sys, time, ctypes
from ctypes import wintypes
class Ch():
    def __init__(self, path):
        self.k = ctypes.WinDLL("kernel32", use_last_error=True)
        self.k.CreateFileW.restype=wintypes.HANDLE
        self.k.CreateFileW.argtypes=[wintypes.LPCWSTR,wintypes.DWORD,wintypes.DWORD,ctypes.c_void_p,wintypes.DWORD,wintypes.DWORD,wintypes.HANDLE]
        self.k.WriteFile.argtypes=[wintypes.HANDLE,ctypes.c_void_p,wintypes.DWORD,ctypes.POINTER(wintypes.DWORD),ctypes.c_void_p]
        self.k.ReadFile.argtypes=[wintypes.HANDLE,ctypes.c_void_p,wintypes.DWORD,ctypes.POINTER(wintypes.DWORD),ctypes.c_void_p]
        self.k.WaitForSingleObject.argtypes=[wintypes.HANDLE,wintypes.DWORD]
        self.k.CreateEventW.restype=wintypes.HANDLE
        self.k.CreateEventW.argtypes=[ctypes.c_void_p,wintypes.BOOL,wintypes.BOOL,wintypes.LPCWSTR]
        class _OV(ctypes.Structure):
            pass
        _OV._fields_=[("Internal",ctypes.c_void_p),("InternalHigh",ctypes.c_void_p),("Offset",wintypes.DWORD),("OffsetHigh",wintypes.DWORD),("hEvent",wintypes.HANDLE)]
        self.ovT=_OV
        self.ev=self.k.CreateEventW(None,True,False,None)
        self.h=self.k.CreateFileW(path,0xC0000000,0,None,3,0x40000000,None)
    def xfer(self, write, data, off, exp_len):
        ov=self.ovT(); ov.Offset=off&0xFFFFFFFF; ov.OffsetHigh=(off>>32)&0xFFFFFFFF; ov.hEvent=self.ev
        self.k.ResetEvent(self.ev)
        n=wintypes.DWORD(0)
        buf=ctypes.create_string_buffer(data,len(data)) if write else ctypes.create_string_buffer(exp_len)
        fn=self.k.WriteFile if write else self.k.ReadFile
        ok=fn(self.h,buf,len(data) if write else exp_len,ctypes.byref(n),ctypes.byref(ov))
        if not ok and self.k.WaitForSingleObject(self.ev,30000)!=0:
            raise TimeoutError("timeout")
        return None if write else bytes(buf.raw[:exp_len])

h0=Ch(r"\\.\XDMA0dma\h2c_0"); c0=Ch(r"\\.\XDMA0dma\c2h_0")
off=0x00C00000
print("size(KB)  write MB/s   read MB/s")
for kb in [4,16,64,256,1024,2048,4096,8192]:
    sz=kb*1024; pat=bytes(i&255 for i in range(sz))
    reps = max(1, min(16, (8<<20)//max(sz,4096)))  # ~8MB total
    h0.xfer(True, pat, off, 0)  # warmup
    t=time.time()
    for _ in range(reps):
        h0.xfer(True, pat, off, 0)
    wdt=max((time.time()-t)/reps, 1e-9)
    t=time.time()
    for _ in range(reps):
        c0.xfer(False, None, off, sz)
    rdt=max((time.time()-t)/reps, 1e-9)
    wmb=(sz/wdt/1e6); rmb=(sz/rdt/1e6)
    print("%6d  %8.1f   %8.1f" % (kb, wmb, rmb))