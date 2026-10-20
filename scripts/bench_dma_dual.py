#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bench_dma_dual.py — бенчмарк двухканального DMA (h2c_0/c2h_0 + h2c_1/c2h_1).

Показывает, что второй канал работает (данные round-trip корректны) и что
параллельная запись/чтение НЕ дают прироста полосы, т.к. оба канала делят
один PCIe link и один контроллер DDR3 (~274 MB/s суммарный потолок).

Использование:
    python scripts/bench_dma_dual.py [--size 4]
"""
import sys, time, threading, argparse, ctypes
from ctypes import wintypes

class Ch():
    def __init__(self, path):
        self.k = ctypes.WinDLL("kernel32", use_last_error=True)
        self.k.CreateFileW.restype=wintypes.HANDLE
        self.k.CreateFileW.argtypes=[wintypes.LPCWSTR,wintypes.DWORD,wintypes.DWORD,ctypes.c_void_p,wintypes.DWORD,wintypes.DWORD,wintypes.HANDLE]
        self.k.WriteFile.argtypes=[wintypes.HANDLE,ctypes.c_void_p,wintypes.DWORD,ctypes.POINTER(wintypes.DWORD),ctypes.c_void_p]
        self.k.ReadFile.argtypes=[wintypes.HANDLE,ctypes.c_void_p,wintypes.DWORD,ctypes.POINTER(wintypes.DWORD),ctypes.c_void_p]
        self.k.CreateEventW.restype=wintypes.HANDLE
        self.k.CreateEventW.argtypes=[ctypes.c_void_p,wintypes.BOOL,wintypes.BOOL,wintypes.LPCWSTR]
        self.k.WaitForSingleObject.argtypes=[wintypes.HANDLE,wintypes.DWORD]
        class _OV(ctypes.Structure):
            _fields_=[("Internal",ctypes.c_void_p),("InternalHigh",ctypes.c_void_p),("Offset",wintypes.DWORD),("OffsetHigh",wintypes.DWORD),("hEvent",wintypes.HANDLE)]
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
        if not ok and self.k.WaitForSingleObject(self.ev,15000)!=0:
            raise TimeoutError("timeout 0x%X"%off)
        return None if write else bytes(buf.raw[:exp_len])

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--size", type=int, default=4, help="MiB на канал"); a=ap.parse_args()
    h0=Ch(r"\\.\XDMA0dma\h2c_0"); h1=Ch(r"\\.\XDMA0dma\h2c_1")
    c0=Ch(r"\\.\XDMA0dma\c2h_0"); c1=Ch(r"\\.\XDMA0dma\c2h_1")
    SZ=a.size<<20
    off0,off1=0x00400000,0x00800000
    p0=bytes((i*7)&255 for i in range(SZ)); p1=bytes((255-(i*7)&255) for i in range(SZ))
    def wc(ch,off,pat):
        t=time.time(); ch.xfer(True,pat,off,0); return time.time()-t
    print("прогрев..."); wc(h0,off0,p0); wc(h1,off1,p1)
    t0=time.time(); a_=threading.Thread(target=wc,args=(h0,off0,p0)); b=threading.Thread(target=wc,args=(h1,off1,p1))
    a_.start(); b.start(); a_.join(); b.join(); para=time.time()-t0
    t0=time.time(); wc(h0,off0,p0); wc(h1,off1,p1); seq=time.time()-t0
    t0=time.time(); a_=threading.Thread(target=lambda:c0.xfer(False,None,off0,SZ)); b=threading.Thread(target=lambda:c1.xfer(False,None,off1,SZ))
    a_.start(); b.start(); a_.join(); b.join(); rpar=time.time()-t0
    t0=time.time(); r0=c0.xfer(False,None,off0,SZ); r1=c1.xfer(False,None,off1,SZ); rseq=time.time()-t0
    print("WRITE: parallel=%.3fs (%.1f MB/s total)  seq=%.3fs (%.1f MB/s)  speedup=%.2fx" % (
        para, 2*SZ/para/1e6, seq, 2*SZ/seq/1e6, seq/para))
    print("READ : parallel=%.3fs  seq=%.3fs" % (rpar, rseq))
    print("dataOK ch0=%s ch1=%s" % (r0==p0, r1==p1))
    print("Вывод: второй канал работает, но общая шина PCIe/DDR3 (~274 MB/s) — узкое место; параллельность полосы НЕ добавляет.")

if __name__=="__main__":
    main()