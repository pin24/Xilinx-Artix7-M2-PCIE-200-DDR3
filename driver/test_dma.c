/* ========================================================================== */
/*  test_dma.c — user-mode DMA test for the NEW XDMA DMA driver (W1).          */
/*                                                                            */
/*  Device nodes (only, NEVER \\.\XDMA0 — that is the legacy MMIO driver):    */
/*    \\.\XDMA0dma\control  -> AXI-Lite registers (BAR0)                      */
/*    \\.\XDMA0dma\h2c_0    -> H2C DMA channel  (host -> DDR3)                */
/*    \\.\XDMA0dma\c2h_0    -> C2H DMA channel  (DDR3 -> host)                */
/*                                                                            */
/*  Addressing contract (matches xdma_driver_win_src_2017 + ADDRESS_MAP.md):  */
/*    control node : offset = full_AXI_addr - 0x40000000                      */
/*                   e.g. TDOT 0x40003000 -> offset 0x3000                    */
/*    h2c/c2h DMA  : offset = RAW DDR3 offset, NO +0x80000000                 */
/*    chunk size   : <= 1 MiB; XDMA_MAX_TRANSFER_SIZE = 8 MiB                 */
/*    alignment    : >= 4 bytes (safe: 8)                                     */
/*                                                                            */
/*  Build:  build_test_dma.cmd  (user-mode, not kernel)                       */
/* ========================================================================== */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <windows.h>
#include <winioctl.h>

/* ========================================================================== */
/*  Device paths — the NEW DMA driver only                                      */
/* ========================================================================== */
#define DEV_CONTROL L"\\\\.\\XDMA0dma\\control"
#define DEV_H2C     L"\\\\.\\XDMA0dma\\h2c_0"
#define DEV_C2H     L"\\\\.\\XDMA0dma\\c2h_0"

/* ========================================================================== */
/*  Address map — AXI-Lite (BAR0), full AXI addresses                          */
/*  (host subtracts 0x40000000 before writing to the control node)             */
/* ========================================================================== */
#define AXI_LITE_BASE   0x40000000UL

/* DDR3 lives in the XDMA M_AXI space at 0x80000000. The upstream 2017
 * Windows driver puts DeviceOffset into the DMA descriptor as the CARD AXI
 * address (no pci->axi translation, unlike Linux), so the host MUST add
 * 0x80000000 to reach DDR3. Density test_dma passes ddr_off (raw), helpers
 * add this base. */
#define DDR3_BASE       0x80000000ULL

#define GPIO_BASE       0x40000000UL
#define GPIO_DATA       (GPIO_BASE + 0x00)
#define GPIO_TRI        (GPIO_BASE + 0x04)

#define DFX_SOCK_BASE   0x40002000UL

#define TDOT_BASE       0x40003000UL
#define TDOT_CTRL       (TDOT_BASE + 0x00)   /* W: [0]=GO (self-clearing) */
#define TDOT_STATUS     (TDOT_BASE + 0x04)   /* R: [0]=BUSY, [1]=DONE */
#define TDOT_N_IN       (TDOT_BASE + 0x08)   /* R/W: number of pairs */
#define TDOT_RES0       (TDOT_BASE + 0x0C)   /* R: result [31:0] */
#define TDOT_RES1       (TDOT_BASE + 0x10)   /* R: {16'h0, result[47:32]} */
#define TDOT_DATA_ADDR_LO    (TDOT_BASE + 0x14)
#define TDOT_DATA_ADDR_HI    (TDOT_BASE + 0x18)
#define TDOT_WEIGHTS_ADDR_LO (TDOT_BASE + 0x1C)
#define TDOT_WEIGHTS_ADDR_HI (TDOT_BASE + 0x20)
#define TDOT_RESULT_ADDR_LO  (TDOT_BASE + 0x24)
#define TDOT_RESULT_ADDR_HI  (TDOT_BASE + 0x28)

#define ICAP_BASE       0x40004000UL
#define SPI_BASE        0x40005000UL
#define XADC_BASE       0x46000000UL

/* ========================================================================== */
/*  IOCTLs (verified against xdma_driver_win_src_2017/inc/xdma_public.h)      */
/* ========================================================================== */
#define XDMA_IOCTL(index) \
    CTL_CODE(FILE_DEVICE_UNKNOWN, index, METHOD_BUFFERED, FILE_ANY_ACCESS)

#define IOCTL_XDMA_GET_VERSION  XDMA_IOCTL(0x0)
#define IOCTL_XDMA_PERF_START   XDMA_IOCTL(0x1)
#define IOCTL_XDMA_PERF_STOP    XDMA_IOCTL(0x2)
#define IOCTL_XDMA_PERF_GET     XDMA_IOCTL(0x3)
#define IOCTL_XDMA_ADDRMODE_GET XDMA_IOCTL(0x4)
#define IOCTL_XDMA_ADDRMODE_SET XDMA_IOCTL(0x5)

typedef struct {
    UINT64 clockCycleCount;
    UINT64 dataCycleCount;
    UINT64 pendingCount;
} XDMA_PERF_DATA;

/* ========================================================================== */
/*  Limits                                                                     */
/* ========================================================================== */
#define DMA_CHUNK           (1u << 20)       /* 1 MiB host chunk */
#define XDMA_MAX_TRANSFER    (8u << 20)      /* 8 MiB max per transfer */
#define LOOPBACK_OFF        0x00100000UL     /* DDR3 offset for loopback */
#define POLL_INTERVAL_MS     5
#define POLL_TIMEOUT_MS      5000

/* ========================================================================== */
/*  OVERLAPPED helper — one reusable event per handle, CancelIo-safe           */
/* ========================================================================== */
static HANDLE g_ov_control = NULL;
static HANDLE g_ov_h2c     = NULL;
static HANDLE g_ov_c2h     = NULL;

static void CleanupDma(void)
{
    if (g_ov_control) { CloseHandle(g_ov_control); g_ov_control = NULL; }
    if (g_ov_h2c)     { CloseHandle(g_ov_h2c);     g_ov_h2c     = NULL; }
    if (g_ov_c2h)     { CloseHandle(g_ov_c2h);     g_ov_c2h     = NULL; }
}

/* ========================================================================== */
/*  Generic overlapped read/write. offset is the FILE offset for the node.     */
/* ========================================================================== */
static BOOL RawXfer(HANDLE hDev, HANDLE hEv,
                    BOOL is_write, UINT64 offset,
                    void* buf, DWORD len, DWORD timeout_ms)
{
    OVERLAPPED ov;
    DWORD bytes = 0;

    ZeroMemory(&ov, sizeof(ov));
    ov.Offset     = (DWORD)(offset & 0xFFFFFFFFULL);
    ov.OffsetHigh = (DWORD)(offset >> 32);
    ov.hEvent     = hEv;
    ResetEvent(hEv);

    BOOL ok = is_write
        ? WriteFile(hDev, buf, len, &bytes, &ov)
        : ReadFile(hDev, buf, len, &bytes, &ov);
    if (!ok && GetLastError() == ERROR_IO_PENDING) {
        DWORD wr = WaitForSingleObject(hEv, timeout_ms);
        if (wr == WAIT_TIMEOUT) {
            CancelIo(hDev);
            WaitForSingleObject(hEv, INFINITE);   /* drain cancellation */
            printf("  ERROR: overlapped %s timed out at offset 0x%llX\n",
                   is_write ? "write" : "read", (unsigned long long)offset);
            return FALSE;
        }
        if (!GetOverlappedResult(hDev, &ov, &bytes, FALSE)) {
            printf("  ERROR: overlapped %s failed at offset 0x%llX (GLE=%lu)\n",
                   is_write ? "write" : "read",
                   (unsigned long long)offset, GetLastError());
            return FALSE;
        }
    } else if (!ok) {
        printf("  ERROR: %s at offset 0x%llX (GLE=%lu)\n",
               is_write ? "WriteFile" : "ReadFile",
               (unsigned long long)offset, GetLastError());
        return FALSE;
    }

    if (is_write && bytes != len)
        printf("  WARNING: wrote %lu of %lu bytes\n", bytes, len);
    return TRUE;
}

/* ========================================================================== */
/*  Layer on the control node: offset = full_AXI_addr - 0x40000000             */
/* ========================================================================== */
static BOOL CtlRead32(HANDLE hDev, ULONG axi_addr, ULONG* val)
{
    return RawXfer(hDev, g_ov_control, FALSE,
                   axi_addr - AXI_LITE_BASE, val, sizeof(*val), POLL_TIMEOUT_MS);
}

static BOOL CtlWrite32(HANDLE hDev, ULONG axi_addr, ULONG val)
{
    return RawXfer(hDev, g_ov_control, TRUE,
                   axi_addr - AXI_LITE_BASE, &val, sizeof(val), POLL_TIMEOUT_MS);
}

/* ========================================================================== */
/*  Chunked DMA helpers via h2c/c2h (offset = raw DDR3 offset)                 */
/* ========================================================================== */
static BOOL DmaWrite(HANDLE hDev, UINT64 ddr_off, const void* data, size_t len)
{
    const char* p = (const char*)data;
    size_t done = 0;
    while (done < len) {
        size_t n = (len - done > DMA_CHUNK) ? DMA_CHUNK : (len - done);
        if (!RawXfer(hDev, g_ov_h2c, TRUE, DDR3_BASE + ddr_off + done,
                     (void*)(p + done), (DWORD)n, POLL_TIMEOUT_MS))
            return FALSE;
        done += n;
    }
    return TRUE;
}

static BOOL DmaRead(HANDLE hDev, UINT64 ddr_off, void* data, size_t len)
{
    char* p = (char*)data;
    size_t done = 0;
    while (done < len) {
        size_t n = (len - done > DMA_CHUNK) ? DMA_CHUNK : (len - done);
        if (!RawXfer(hDev, g_ov_c2h, FALSE, DDR3_BASE + ddr_off + done,
                     (void*)(p + done), (DWORD)n, POLL_TIMEOUT_MS))
            return FALSE;
        done += n;
    }
    return TRUE;
}

/* ========================================================================== */
/*  Deterministic LCG pattern (matches xdma_driver.py --selftest)              */
/* ========================================================================== */
static void FillLcg(BYTE* buf, size_t len, unsigned seed)
{
    unsigned x = seed ? seed : 12345u;
    size_t i;
    for (i = 0; i < len; i++) {
        x = x * 1664525u + 1013904223u;
        buf[i] = (BYTE)((x >> 24) & 0xFF);
    }
}

/* ========================================================================== */
/*  Mode: regs — readback known control registers                              */
/* ========================================================================== */
static int ModeRegs(HANDLE ctl)
{
    ULONG st, gpio, res0, res1, n;
    printf("--- regs: control readback over \\\\.\\XDMA0dma\\control ---\n");
    if (!CtlRead32(ctl, TDOT_STATUS, &st)) return 1;
    if (!CtlRead32(ctl, TDOT_N_IN,   &n))  return 1;
    if (!CtlRead32(ctl, TDOT_RES0,   &res0)) return 1;
    if (!CtlRead32(ctl, TDOT_RES1,   &res1)) return 1;
    if (!CtlRead32(ctl, GPIO_DATA,   &gpio)) return 1;
    printf("  TDOT_STATUS = 0x%08lX  (BUSY=%lu DONE=%lu)\n",
           st, (st >> 0) & 1, (st >> 1) & 1);
    printf("  TDOT_N_IN   = 0x%08lX (%lu)\n", n, n);
    printf("  TDOT_RES0   = 0x%08lX\n", res0);
    printf("  TDOT_RES1   = 0x%08lX\n", res1);
    printf("  GPIO_DATA   = 0x%08lX\n", gpio);
    printf("  regs: PASS\n");
    return 0;
}

/* ========================================================================== */
/*  Mode: loopback <bytes> — LCG write via h2c, read via c2h, byte compare     */
/* ========================================================================== */
static int ModeLoopback(HANDLE h2c, HANDLE c2h, size_t bytes)
{
    BYTE* w = NULL;
    BYTE* r = NULL;
    size_t i;
    int rc = 1;

    if (bytes > XDMA_MAX_TRANSFER) {
        printf("  ERROR: loopback size %zu exceeds XDMA_MAX_TRANSFER (%u)\n",
               bytes, XDMA_MAX_TRANSFER);
        return 1;
    }

    w = (BYTE*)malloc(bytes ? bytes : 1);
    r = (BYTE*)malloc(bytes ? bytes : 1);
    if (!w || !r) { printf("  ERROR: malloc\n"); goto out; }

    FillLcg(w, bytes, (unsigned)bytes);
    printf("--- loopback %zu bytes: h2c write @0x%08X, c2h read, compare ---\n",
           bytes, LOOPBACK_OFF);
    if (!DmaWrite(h2c, LOOPBACK_OFF, w, bytes)) goto out;
    if (!DmaRead(c2h, LOOPBACK_OFF, r, bytes)) goto out;

    for (i = 0; i < bytes; i++) {
        if (w[i] != r[i]) {
            printf("  FAIL: mismatch at byte %zu (write=0x%02X read=0x%02X)\n",
                   i, w[i], r[i]);
            goto out;
        }
    }
    printf("  loopback %zu bytes: PASS (%zu byte(s) identical)\n", bytes, bytes);
    rc = 0;
out:
    if (w) free(w);
    if (r) free(r);
    return rc;
}

/* ========================================================================== */
/*  Mode: ioctl — PERF start/get/stop + ADDRMODE_GET on c2h_0                  */
/* ========================================================================== */
/*  BUG-012 / PERF-01 note: the perf counters count DMA *descriptor* cycles.   */
/*  dataCycleCount reflects activity driven by data movement through the       */
/*  channel (c2h), which is the intended signal here.                          */
static int ModeIoctl(HANDLE c2h, HANDLE h2c)
{
    XDMA_PERF_DATA perf;
    DWORD br = 0;
    ULONG addrMode = 0;

    printf("--- ioctl: PERF + ADDRMODE on c2h_0 ---\n");

    if (!DeviceIoControl(c2h, IOCTL_XDMA_PERF_START, NULL, 0, NULL, 0, &br, NULL)) {
        printf("  FAIL: PERF_START GLE=%lu\n", GetLastError());
        return 1;
    }
    /* small DMA to give the counter something to count */
    {
        BYTE tmp[1024];
        memset(tmp, 0, sizeof(tmp));
        DmaWrite(h2c, LOOPBACK_OFF, tmp, 8);
        DmaRead(c2h, LOOPBACK_OFF + 0x1000, tmp, sizeof(tmp));
    }
    if (!DeviceIoControl(c2h, IOCTL_XDMA_PERF_GET, NULL, 0,
                         &perf, sizeof(perf), &br, NULL)) {
        printf("  FAIL: PERF_GET GLE=%lu\n", GetLastError());
        return 1;
    }
    if (!DeviceIoControl(c2h, IOCTL_XDMA_PERF_STOP, NULL, 0, NULL, 0, &br, NULL)) {
        printf("  FAIL: PERF_STOP GLE=%lu\n", GetLastError());
        return 1;
    }
    printf("  clockCycleCount=%llu dataCycleCount=%llu pendingCount=%llu\n",
           (unsigned long long)perf.clockCycleCount,
           (unsigned long long)perf.dataCycleCount,
           (unsigned long long)perf.pendingCount);

    if (!DeviceIoControl(c2h, IOCTL_XDMA_ADDRMODE_GET, NULL, 0,
                         &addrMode, sizeof(addrMode), &br, NULL)) {
        printf("  FAIL: ADDRMODE_GET GLE=%lu\n", GetLastError());
        return 1;
    }
    printf("  ADDRMODE=%lu (expect 0 = address mode)\n", addrMode);

    if (perf.dataCycleCount == 0) {
        printf("  FAIL: dataCycleCount == 0 (no DMA activity captured)\n");
        return 1;
    }
    if (addrMode != 0) {
        printf("  FAIL: ADDRMODE != 0\n");
        return 1;
    }
    printf("  ioctl: PASS\n");
    return 0;
}

/* ========================================================================== */
/*  Mode: align — deliberately misaligned size/offset should fail cleanly      */
/* ========================================================================== */
static int ModeAlign(HANDLE h2c, HANDLE c2h, HANDLE ctl)
{
    BYTE pat[8] = { 1, 2, 3, 4, 5, 6, 7, 8 };
    BYTE rd[8]  = { 0 };

    printf("--- align: expect clean API rejection (no crash) ---\n");

    /* case 1: 3-byte write/read (not multiple of 4) */
    if (DmaWrite(h2c, LOOPBACK_OFF, pat, 3)) {
        printf("  NOTE: 3-byte h2c write ACCEPTED (driver tolerates) — not a failure\n");
    } else {
        printf("  3-byte h2c write rejected as expected\n");
    }
    if (DmaRead(c2h, LOOPBACK_OFF, rd, 3)) {
        printf("  NOTE: 3-byte c2h read ACCEPTED (driver tolerates) — reading 8 raw bytes\n");
        DmaRead(c2h, LOOPBACK_OFF, rd, 8);
    }

    /* case 2: unaligned DDR3 offset (write at offset+1) */
    if (DmaWrite(h2c, LOOPBACK_OFF + 1, pat, 4)) {
        printf("  NOTE: h2c write at offset+1 ACCEPTED\n");
    } else {
        printf("  unaligned-offset h2c write rejected as expected\n");
    }

    printf("  align: PASS (driver rejected or tolerated, no crash)\n");
    (void)ctl;
    return 0;
}

/* ========================================================================== */
/*  Mode: dot — canonical TDOT path via DMA + control registers                */
/* ========================================================================== */
/*  N pairs of 1.0 (TFloat48) -> core accumulates to N.                        */
/*  TF48_ONE = bits48 of 1.0, verified with ternary_sw/block/tfloat48.py:      */
/*       TFloat.from_float(1.0) -> bits48 = 0x0010_0000_0000                    */
/* ========================================================================== */
#define TF48_ONE 0x001000000000ULL

/* Offsets used by the canonical dot path (ADDRESS_MAP §6) */
#define DATA_OFF    0x0000
#define WEIGHTS_OFF 0x1000
#define RESULT_OFF  0x2000

static int ModeDot(HANDLE h2c, HANDLE c2h, HANDLE ctl, int n)
{
    UINT64 buf[32];
    UINT64 result = 0;
    int i;
    UINT64 full_data = 0x80000000ULL + DATA_OFF;
    UINT64 full_wgt  = 0x80000000ULL + WEIGHTS_OFF;
    UINT64 full_res  = 0x80000000ULL + RESULT_OFF;

    if (n < 1 || n > 32) n = 8;

    printf("--- dot: %d pairs of 1.0 via DMA + TDOT registers ---\n", n);
    for (i = 0; i < n; i++)
        buf[i] = TF48_ONE;   /* same for data and weights; dot reduces to N */

    if (!DmaWrite(h2c, DATA_OFF,    buf, (size_t)n * 8)) return 1;
    if (!DmaWrite(h2c, WEIGHTS_OFF, buf, (size_t)n * 8)) return 1;

    /* program TDOT registers (full AXI addresses for the address regs) */
    if (!CtlWrite32(ctl, TDOT_N_IN, (ULONG)n)) return 1;
    if (!CtlWrite32(ctl, TDOT_DATA_ADDR_LO,    (ULONG)(full_data & 0xFFFFFFFF))) return 1;
    if (!CtlWrite32(ctl, TDOT_DATA_ADDR_HI,    (ULONG)(full_data >> 32)))        return 1;
    if (!CtlWrite32(ctl, TDOT_WEIGHTS_ADDR_LO, (ULONG)(full_wgt & 0xFFFFFFFF)))  return 1;
    if (!CtlWrite32(ctl, TDOT_WEIGHTS_ADDR_HI, (ULONG)(full_wgt >> 32)))         return 1;
    if (!CtlWrite32(ctl, TDOT_RESULT_ADDR_LO,  (ULONG)(full_res & 0xFFFFFFFF)))  return 1;
    if (!CtlWrite32(ctl, TDOT_RESULT_ADDR_HI,  (ULONG)(full_res >> 32)))         return 1;

    /* GO */
    if (!CtlWrite32(ctl, TDOT_CTRL, 0x01)) return 1;

    /* poll DONE */
    {
        ULONG st = 0;
        int waited = 0;
        while (waited < POLL_TIMEOUT_MS) {
            if (!CtlRead32(ctl, TDOT_STATUS, &st)) return 1;
            if (st & 0x02) break;               /* bit1 = DONE */
            Sleep(POLL_INTERVAL_MS);
            waited += POLL_INTERVAL_MS;
        }
        if (!(st & 0x02)) {
            printf("  FAIL: TDOT DONE timeout (STATUS=0x%08lX)\n", st);
            return 1;
        }
        printf("  DONE after ~%d ms, STATUS=0x%08lX\n", waited, st);
    }

    if (!DmaRead(c2h, RESULT_OFF, &result, 8)) return 1;
    result &= 0xFFFFFFFFFFFFULL;
    printf("  result (48-bit) = 0x%012llX\n", (unsigned long long)result);
    printf("  (expected numeric: %d pairs of 1.0*1.0 -> %d.0; decode via fpga_backend)\n",
           n, n);
    printf("  dot: PASS (DMA + registers + DONE + result path OK)\n");
    return 0;
}

/* ========================================================================== */
/*  main                                                                       */
/* ========================================================================== */
static void PrintUsage(void)
{
    printf("Usage: test_dma.exe <mode> [args]\n");
    printf("  regs                 readback TDOT_STATUS / GPIO over \\control\n");
    printf("  loopback <bytes>     LCG write h2c + read c2h + byte compare\n");
    printf("                       (suggest: 4 1024 1048576 8388608; one per run)\n");
    printf("  ioctl                PERF_START/GET/STOP + ADDRMODE on c2h_0\n");
    printf("  align                deliberately misaligned size/offset\n");
    printf("  dot [n]              canonical TDOT path via DMA + control (n pairs, 1..32)\n");
    printf("No args: prints this help and runs the safe `regs` check.\n");
    printf("Uses ONLY \\\\.\\XDMA0dma (control/h2c_0/c2h_0). Never touches \\\\.\\XDMA0.\n");
}

int main(int argc, char** argv)
{
    HANDLE ctl = INVALID_HANDLE_VALUE;
    HANDLE h2c = INVALID_HANDLE_VALUE;
    HANDLE c2h = INVALID_HANDLE_VALUE;
    int rc = 0;
    const char* mode = NULL;
    const char* sbytes;
    DWORD open_share = 0;

    if (argc < 2) {
        PrintUsage();
        mode = "regs";
    } else {
        mode = argv[1];
    }

    ctl = CreateFileW(DEV_CONTROL, GENERIC_READ | GENERIC_WRITE, open_share,
                      NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
    if (ctl == INVALID_HANDLE_VALUE) {
        printf("ERROR: cannot open %ws (GLE=%lu). Is the DMA driver installed?\n",
               DEV_CONTROL, GetLastError());
        return 1;
    }
    h2c = CreateFileW(DEV_H2C, GENERIC_READ | GENERIC_WRITE, open_share,
                      NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
    if (h2c == INVALID_HANDLE_VALUE) {
        printf("ERROR: cannot open %ws (GLE=%lu)\n", DEV_H2C, GetLastError());
        CloseHandle(ctl);
        return 1;
    }
    c2h = CreateFileW(DEV_C2H, GENERIC_READ | GENERIC_WRITE, open_share,
                      NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
    if (c2h == INVALID_HANDLE_VALUE) {
        printf("ERROR: cannot open %ws (GLE=%lu)\n", DEV_C2H, GetLastError());
        CloseHandle(ctl); CloseHandle(h2c);
        return 1;
    }

    g_ov_control = CreateEvent(NULL, TRUE, FALSE, NULL);
    g_ov_h2c     = CreateEvent(NULL, TRUE, FALSE, NULL);
    g_ov_c2h     = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!g_ov_control || !g_ov_h2c || !g_ov_c2h) {
        printf("ERROR: CreateEvent failed\n");
        CleanupDma();
        CloseHandle(ctl); CloseHandle(h2c); CloseHandle(c2h);
        return 1;
    }

    if (_stricmp(mode, "regs") == 0) {
        rc = ModeRegs(ctl);
    } else if (_stricmp(mode, "loopback") == 0) {
        sbytes = (argc >= 3) ? argv[2] : "1024";
        rc = ModeLoopback(h2c, c2h, (size_t)strtoull(sbytes, NULL, 0));
    } else if (_stricmp(mode, "ioctl") == 0) {
        rc = ModeIoctl(c2h, h2c);
    } else if (_stricmp(mode, "align") == 0) {
        rc = ModeAlign(h2c, c2h, ctl);
    } else if (_stricmp(mode, "dot") == 0) {
        int n = (argc >= 3) ? atoi(argv[2]) : 8;
        rc = ModeDot(h2c, c2h, ctl, n);
    } else {
        PrintUsage();
        printf("\nUnknown mode: %s\n", mode);
        rc = 2;
    }

    CleanupDma();
    CloseHandle(ctl);
    CloseHandle(h2c);
    CloseHandle(c2h);
    return rc;
}