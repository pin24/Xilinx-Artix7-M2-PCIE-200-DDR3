import sys, threading, time
sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\pytorch_layer")
result = {}
def worker():
    try:
        from test_dma_win import XdmaWinDma
        dev = XdmaWinDma(base=r"\\.\XDMA0dma")
        # write 64 bytes at offset 0x4000, then read back
        t0 = time.perf_counter()
        dev.write_dma(0x00004000, bytes(range(64)))
        wms = (time.perf_counter()-t0)*1000
        t0 = time.perf_counter()
        got = dev.read_dma(0x00004000, 64)
        rms = (time.perf_counter()-t0)*1000
        result['write_ms'] = round(wms,1)
        result['read_ms'] = round(rms,1)
        result['ok_bytes'] = (got == bytes(range(64)))
        result['first'] = list(got[:8])
        try: dev.close()
        except Exception: pass
        result['ok'] = True
    except Exception as e:
        result['ok'] = False
        result['err'] = repr(e)

t = threading.Thread(target=worker, daemon=True)
t.start()
t.join(timeout=6.0)
print("worker alive (hanging):", t.is_alive())
print("RESULT:", result)
if t.is_alive():
    print("DMA_READBACK: HUNG")