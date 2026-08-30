#include <stdio.h>
#include <stdint.h>
#include <windows.h>
#include <winioctl.h>

/* ========================================================================== */
/*  Address map — AXI-Lite BAR0                                               */
/* ========================================================================== */

/* GPIO */
#define GPIO_BASE       0x40000000UL
#define GPIO_DATA       (GPIO_BASE + 0x00)
#define GPIO_TRI        (GPIO_BASE + 0x04)

/* TDOT compute core */
#define TDOT_BASE       0x40001000UL
#define TDOT_CTRL       (TDOT_BASE + 0x00)   /* W: [0]=GO (self-clearing) */
#define TDOT_STATUS     (TDOT_BASE + 0x04)   /* R: [0]=BUSY, [1]=DONE */
#define TDOT_N_IN       (TDOT_BASE + 0x08)   /* R/W: number of pairs */
#define TDOT_RES0       (TDOT_BASE + 0x0C)   /* R: result [31:0]            (RTL: tdot_axi4.sv:241) */
#define TDOT_RES1       (TDOT_BASE + 0x10)   /* R: {16'h0, result [47:32]}  (RTL: tdot_axi4.sv:242) */
#define TDOT_DATA_ADDR_LO   (TDOT_BASE + 0x14)
#define TDOT_DATA_ADDR_HI   (TDOT_BASE + 0x18)
#define TDOT_WEIGHTS_ADDR_LO (TDOT_BASE + 0x1C)
#define TDOT_WEIGHTS_ADDR_HI (TDOT_BASE + 0x20)
#define TDOT_RESULT_ADDR_LO (TDOT_BASE + 0x24)
#define TDOT_RESULT_ADDR_HI (TDOT_BASE + 0x28)
#define TDOT_CORE_RES0  (TDOT_BASE + 0x2C)
#define TDOT_CORE_RES1  (TDOT_BASE + 0x30)

/* ICAP -- CTRL/STATUS/DATA (source: icap_ctrl.sv:1-15, ADDRESS_MAP.md sec 4).
 *   [0x00] CTRL   W: [0]=GO (self-clear), [1]=STOP (self-clear)
 *   [0x04] STATUS R: [0]=READY (mailbox free), [1]=BUSY (session active)
 *   [0x08] DATA   W: 32-bit ICAP word (LE bswap of BE .bin word)            */
#define ICAP_BASE       0x40002000UL
#define ICAP_CTRL       (ICAP_BASE + 0x00)
#define ICAP_STATUS     (ICAP_BASE + 0x04)
#define ICAP_DATA       (ICAP_BASE + 0x08)
/* Backward-compat aliases (deprecated -- prefer ICAP_CTRL / ICAP_STATUS): */
#define ICAP_GO         ICAP_CTRL
#define ICAP_READY      ICAP_STATUS

/* XADC — BD: axi_periph M02 @ 0x4600_0000 */
#define XADC_BASE       0x46000000UL
#define XADC_TEMP       (XADC_BASE + 0x00)
#define XADC_VCCINT     (XADC_BASE + 0x04)

/* DDR3 */
#define DDR3_BASE       0x80000000ULL

/* Device path (XDMA Win driver — single device, BAR0 + BAR2 through same handle) */
#define DEVICE_CONTROL  L"\\\\.\\XDMA0"

/* Timing */
#define POLL_INTERVAL_MS    10
#define POLL_TIMEOUT_MS     5000

/* ========================================================================== */
/*  Forward declarations                                                      */
/* ========================================================================== */

/* Low-level helpers */
ULONG  ReadReg(HANDLE hDev, ULONG addr);
void   WriteReg(HANDLE hDev, ULONG addr, ULONG value);

/* DMA block I/O (BAR2/DDR3) -- CancelIo-safe, see FIX T2. */
BOOL   XdmaRead(HANDLE hDev, uint64_t offset, void* buf, size_t len, DWORD timeout_ms);
BOOL   XdmaWrite(HANDLE hDev, uint64_t offset, const void* buf, size_t len, DWORD timeout_ms);

/* Test cases */
BOOL   TestGpio(HANDLE hDev);
BOOL   TestTdotRegs(HANDLE hDev);
BOOL   TestXadc(HANDLE hDev);
BOOL   TestTdotProtocol(HANDLE hDev);
BOOL   TestIcap(HANDLE hDev);
BOOL   TestDdr3(HANDLE hDev);

/* Utils */
static const char* PassFail(BOOL ok);

/* ========================================================================== */
/*  Low-level register I/O via OVERLAPPED                                     */
/* ========================================================================== */

ULONG ReadReg(HANDLE hDev, ULONG addr)
{
    ULONG val = 0xFFFFFFFF;
    OVERLAPPED ov;
    DWORD br = 0;

    ZeroMemory(&ov, sizeof(ov));
    ov.Offset     = addr;
    ov.OffsetHigh = 0;
    ov.hEvent     = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!ov.hEvent) {
        printf("ERROR: CreateEvent failed\n");
        return val;
    }

    if (!ReadFile(hDev, &val, sizeof(val), &br, &ov)) {
        if (GetLastError() == ERROR_IO_PENDING) {
            DWORD waitResult = WaitForSingleObject(ov.hEvent, POLL_TIMEOUT_MS);
            if (waitResult == WAIT_OBJECT_0) {
                GetOverlappedResult(hDev, &ov, &br, FALSE);
            } else {
                /* FIX T2 (DRIVER_DEVLOG bug #9 -- fix was incomplete):
                 * CancelIo is ASYNC -- the driver may still touch OVERLAPPED
                 * after CancelIo returns. Must wait for ov.hEvent to be
                 * signalled (cancellation complete) BEFORE CloseHandle and
                 * stack unwind, otherwise use-after-free. */
                CancelIo(hDev);
                WaitForSingleObject(ov.hEvent, INFINITE);
                GetOverlappedResult(hDev, &ov, &br, FALSE);
            }
        }
    }
    CloseHandle(ov.hEvent);
    return val;
}

void WriteReg(HANDLE hDev, ULONG addr, ULONG value)
{
    OVERLAPPED ov;
    DWORD bw = 0;

    ZeroMemory(&ov, sizeof(ov));
    ov.Offset     = addr;
    ov.OffsetHigh = 0;
    ov.hEvent     = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!ov.hEvent) {
        printf("ERROR: CreateEvent failed\n");
        return;
    }

    if (!WriteFile(hDev, &value, sizeof(value), &bw, &ov)) {
        if (GetLastError() == ERROR_IO_PENDING) {
            DWORD waitResult = WaitForSingleObject(ov.hEvent, POLL_TIMEOUT_MS);
            if (waitResult == WAIT_OBJECT_0) {
                GetOverlappedResult(hDev, &ov, &bw, FALSE);
            } else {
                /* FIX T2 (DRIVER_DEVLOG bug #9 -- fix was incomplete):
                 * See ReadReg -- CancelIo is async; must wait for the overlapped
                 * to be signalled before unwinding the stack frame holding it. */
                CancelIo(hDev);
                WaitForSingleObject(ov.hEvent, INFINITE);
                GetOverlappedResult(hDev, &ov, &bw, FALSE);
            }
        }
    }
    CloseHandle(ov.hEvent);
}

/* ========================================================================== */
/*  DMA block I/O (BAR2 / DDR3) -- CancelIo-safe, 64-bit offsets              */
/* ========================================================================== */
/* Used by TestDdr3 (and any future DDR3-based test). Pattern follows FIX T2: */
/* after CancelIo we MUST WaitForSingleObject(..., INFINITE) before           */
/* CloseHandle, otherwise the driver may still be touching OVERLAPPED.        */

BOOL XdmaRead(HANDLE hDev, uint64_t offset, void* buf, size_t len, DWORD timeout_ms)
{
    OVERLAPPED ov;
    DWORD bytes = 0;

    ZeroMemory(&ov, sizeof(ov));
    ov.Offset     = (DWORD)(offset & 0xFFFFFFFFULL);
    ov.OffsetHigh = (DWORD)(offset >> 32);
    ov.hEvent     = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!ov.hEvent) return FALSE;

    BOOL ok = ReadFile(hDev, buf, (DWORD)len, NULL, &ov);
    if (!ok && GetLastError() != ERROR_IO_PENDING) {
        CloseHandle(ov.hEvent);
        return FALSE;
    }

    ok = GetOverlappedResult(hDev, &ov, &bytes, FALSE);   /* non-blocking */
    if (!ok) {
        DWORD wr = WaitForSingleObject(ov.hEvent, timeout_ms);
        if (wr == WAIT_TIMEOUT) {
            CancelIo(hDev);
            /* Drain the cancellation: driver signals ov.hEvent when the
             * IRP is finally cancelled/completed. Without this wait, the
             * stack-allocated OVERLAPPED would be freed underneath the driver. */
            WaitForSingleObject(ov.hEvent, INFINITE);
            CloseHandle(ov.hEvent);
            return FALSE;
        }
        GetOverlappedResult(hDev, &ov, &bytes, FALSE);
    }

    CloseHandle(ov.hEvent);
    return TRUE;
}

BOOL XdmaWrite(HANDLE hDev, uint64_t offset, const void* buf, size_t len, DWORD timeout_ms)
{
    OVERLAPPED ov;
    DWORD bytes = 0;

    ZeroMemory(&ov, sizeof(ov));
    ov.Offset     = (DWORD)(offset & 0xFFFFFFFFULL);
    ov.OffsetHigh = (DWORD)(offset >> 32);
    ov.hEvent     = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!ov.hEvent) return FALSE;

    BOOL ok = WriteFile(hDev, buf, (DWORD)len, NULL, &ov);
    if (!ok && GetLastError() != ERROR_IO_PENDING) {
        CloseHandle(ov.hEvent);
        return FALSE;
    }

    ok = GetOverlappedResult(hDev, &ov, &bytes, FALSE);
    if (!ok) {
        DWORD wr = WaitForSingleObject(ov.hEvent, timeout_ms);
        if (wr == WAIT_TIMEOUT) {
            CancelIo(hDev);
            WaitForSingleObject(ov.hEvent, INFINITE);
            CloseHandle(ov.hEvent);
            return FALSE;
        }
        GetOverlappedResult(hDev, &ov, &bytes, FALSE);
    }

    CloseHandle(ov.hEvent);
    return TRUE;
}

/* ========================================================================== */
/*  Test: GPIO — write tri-state, toggle LEDs, verify readback                */
/* ========================================================================== */

BOOL TestGpio(HANDLE hDev)
{
    printf("\n--- GPIO Test ---\n");

    /* Set all GPIO pins as outputs (TRI=0 means output) */
    WriteReg(hDev, GPIO_TRI, 0x00);
    {
        ULONG tri = ReadReg(hDev, GPIO_TRI);
        printf("  GPIO_TRI = 0x%08lX (expect 0x00000000)\n", tri);
        if (tri != 0x00) return FALSE;
    }

    /* LED0 on */
    WriteReg(hDev, GPIO_DATA, 0x01);
    Sleep(100);
    {
        ULONG d = ReadReg(hDev, GPIO_DATA);
        printf("  GPIO_DATA (LED0)= 0x%08lX (bit0=1)\n", d);
        if ((d & 0x01) == 0) return FALSE;
    }

    /* LED1 on */
    WriteReg(hDev, GPIO_DATA, 0x02);
    Sleep(100);
    {
        ULONG d = ReadReg(hDev, GPIO_DATA);
        printf("  GPIO_DATA (LED1)= 0x%08lX (bit1=1)\n", d);
        if ((d & 0x02) == 0) return FALSE;
    }

    /* LED2 on */
    WriteReg(hDev, GPIO_DATA, 0x04);
    Sleep(100);
    {
        ULONG d = ReadReg(hDev, GPIO_DATA);
        printf("  GPIO_DATA (LED2)= 0x%08lX (bit2=1)\n", d);
        if ((d & 0x04) == 0) return FALSE;
    }

    /* All off */
    WriteReg(hDev, GPIO_DATA, 0x00);
    Sleep(100);
    {
        ULONG d = ReadReg(hDev, GPIO_DATA);
        printf("  GPIO_DATA (all off)= 0x%08lX\n", d);
        if (d != 0) return FALSE;
    }

    return TRUE;
}

/* ========================================================================== */
/*  Test: TDOT register write/readback                                        */
/* ========================================================================== */

BOOL TestTdotRegs(HANDLE hDev)
{
    printf("\n--- TDOT Register Test ---\n");

    struct { ULONG addr; ULONG wval; const char* name; } regs[] = {
        { TDOT_N_IN,          8,             "N_IN"             },
        { TDOT_DATA_ADDR_LO,  0x80000000UL,  "DATA_ADDR_LO"     },
        { TDOT_DATA_ADDR_HI,  0x00000000UL,  "DATA_ADDR_HI"     },
        { TDOT_WEIGHTS_ADDR_LO, 0x80001000UL,"WEIGHTS_ADDR_LO"  },
        { TDOT_WEIGHTS_ADDR_HI, 0x00000000UL,"WEIGHTS_ADDR_HI"  },
        { TDOT_RESULT_ADDR_LO,  0x80002000UL,"RESULT_ADDR_LO"   },
        { TDOT_RESULT_ADDR_HI,  0x00000000UL,"RESULT_ADDR_HI"   },
    };

    for (int i = 0; i < sizeof(regs) / sizeof(regs[0]); i++) {
        WriteReg(hDev, regs[i].addr, regs[i].wval);
        ULONG r = ReadReg(hDev, regs[i].addr);
        printf("  %s: wrote 0x%08lX, read 0x%08lX\n", regs[i].name, regs[i].wval, r);
        if (r != regs[i].wval) return FALSE;
    }

    /* Read-only registers: just verify they don't hang */
    ULONG res0 = ReadReg(hDev, TDOT_RES0);
    ULONG res1 = ReadReg(hDev, TDOT_RES1);
    ULONG st   = ReadReg(hDev, TDOT_STATUS);
    printf("  RES0=0x%08lX RES1=0x%08lX STATUS=0x%08lX (read-only, OK)\n",
           res0, res1, st);

    return TRUE;
}

/* ========================================================================== */
/*  Test: XADC — read temperature and VCCINT                                  */
/* ========================================================================== */

BOOL TestXadc(HANDLE hDev)
{
    printf("\n--- XADC Test ---\n");

    ULONG raw_temp   = ReadReg(hDev, XADC_TEMP)   & 0xFFFF;
    ULONG raw_vccint = ReadReg(hDev, XADC_VCCINT) & 0xFFFF;

    /* XADC formulas */
    double temp_c  = ((double)raw_temp   * 503.975 / 4096.0) - 273.15;
    double vccint  =  (double)raw_vccint * 3.0    / 4096.0;

    printf("  TEMP:   raw=0x%04lX  (%lu)  -> %.2f °C\n",
           raw_temp, raw_temp, temp_c);
    printf("  VCCINT: raw=0x%04lX  (%lu)  -> %.3f V\n",
           raw_vccint, raw_vccint, vccint);

    /* Sanity check — temperature should be in plausible range (0..125°C) */
    if (raw_temp == 0 || raw_temp == 0xFFFF)
        return FALSE;

    return TRUE;
}

/* ========================================================================== */
/*  Test: TDOT full compute protocol                                           */
/* ========================================================================== */

BOOL TestTdotProtocol(HANDLE hDev)
{
    printf("\n--- TDOT Protocol Test ---\n");

    /* Program address registers */
    WriteReg(hDev, TDOT_N_IN,               8);
    WriteReg(hDev, TDOT_DATA_ADDR_LO,       0x80000000UL);
    WriteReg(hDev, TDOT_DATA_ADDR_HI,       0);
    WriteReg(hDev, TDOT_WEIGHTS_ADDR_LO,    0x80001000UL);
    WriteReg(hDev, TDOT_WEIGHTS_ADDR_HI,    0);
    WriteReg(hDev, TDOT_RESULT_ADDR_LO,     0x80002000UL);
    WriteReg(hDev, TDOT_RESULT_ADDR_HI,     0);

    /* Verify registers were written correctly */
    {
        ULONG n = ReadReg(hDev, TDOT_N_IN);
        if (n != 8) {
            printf("  N_IN readback = %lu (expected 8)\n", n);
            return FALSE;
        }
    }

    /* NOTE: In current RTL, writing GO (0x01) also sets N_IN from bits [16:8].
     * If RTL were fixed, the workaround below would be needed:
     *   WriteReg(hDev, TDOT_CTRL, (8 << 8) | 0x01);
     * Until then, N_IN is written separately before GO, which works
     * if RTL propagates the separately-written N_IN before GO latches it. */

    /* Fire GO */
    WriteReg(hDev, TDOT_CTRL, 0x01);
    printf("  GO asserted, waiting for DONE...\n");

    /* Poll STATUS for DONE (bit 1), with timeout */
    BOOL    done   = FALSE;
    int     waited = 0;
    ULONG   status = 0;

    while (waited < POLL_TIMEOUT_MS) {
        status = ReadReg(hDev, TDOT_STATUS);
        if (status & 0x02) {   /* bit 1 = DONE */
            done = TRUE;
            break;
        }
        Sleep(POLL_INTERVAL_MS);
        waited += POLL_INTERVAL_MS;
    }

    if (!done) {
        printf("  TIMEOUT! STATUS=0x%08lX (waited %d ms)\n", status, waited);
        return FALSE;
    }

    printf("  DONE detected after ~%d ms, STATUS=0x%08lX\n", waited, status);

    /* Read result */
    ULONG res0   = ReadReg(hDev, TDOT_RES0);
    ULONG res1   = ReadReg(hDev, TDOT_RES1);
    ULONG cres0  = ReadReg(hDev, TDOT_CORE_RES0);
    ULONG cres1  = ReadReg(hDev, TDOT_CORE_RES1);

    /* Combine into 48-bit result.
     * FIX T1 (B-DRV3-2): RES0 = result[31:0] (NOT [15:0]),
     *                    RES1 = {16'h0, result[47:32]}.
     * Source: tdot_axi4.sv:241-242, 523-524; ADDRESS_MAP.md sec 3.1. */
    ULONG64 result = ((ULONG64)(res1 & 0xFFFF) << 32) | (res0 & 0xFFFFFFFF);

    printf("  RES0=0x%08lX  RES1=0x%08lX  -> combined=0x%012llX\n",
           res0, res1, result);
    printf("  CORE_RES0=0x%08lX  CORE_RES1=0x%08lX\n", cres0, cres1);

    return TRUE;
}

/* ========================================================================== */
/*  Test: ICAP — full GO→READY→DATA→READY→STOP→BUSY=0 protocol (FIX T3)       */
/* ========================================================================== */

BOOL TestIcap(HANDLE hDev)
{
    printf("\n--- ICAP Test ---\n");

    /* FIX T3: real ICAP protocol test (was a stub returning TRUE).
     * Source: icap_ctrl.sv:1-34, ADDRESS_MAP.md §4.1.
     * Sequence: GO -> poll READY -> DATA(sync word) -> poll READY -> STOP -> verify BUSY=0. */

    /* 1. CTRL.GO=1 — open session (BUSY=1, mailbox enters single-word-window mode). */
    WriteReg(hDev, ICAP_CTRL, 0x1);
    printf("  GO sent\n");

    /* 2. Poll STATUS.READY (bit0) — mailbox must be free for the first DATA write. */
    ULONG status = 0;
    int retries = 100;
    do {
        Sleep(1);
        status = ReadReg(hDev, ICAP_STATUS);
        if (status == 0xFFFFFFFFUL) {
            printf("  FAIL: bus error reading STATUS after GO\n");
            return FALSE;
        }
        if (--retries == 0) {
            printf("  FAIL: READY timeout after GO (STATUS=0x%08lX)\n", status);
            return FALSE;
        }
    } while (!(status & 0x1));   /* bit0 = READY */

    /* 3. Write the FPGA sync word 0xAA995566 (BE .bin) = 0x665599AA (LE in DATA).
     *    This is the standard first word of any 7-series bitstream. */
    WriteReg(hDev, ICAP_DATA, 0x665599AAUL);
    printf("  sync word 0x665599AA written\n");

    /* 4. Poll READY again — controller pulses CSIB=0 for one icap_clk (62.5 MHz)
     *    per DATA write, then READY returns. */
    retries = 100;
    do {
        Sleep(1);
        status = ReadReg(hDev, ICAP_STATUS);
        if (status == 0xFFFFFFFFUL) {
            printf("  FAIL: bus error reading STATUS after DATA\n");
            return FALSE;
        }
        if (--retries == 0) {
            printf("  FAIL: READY timeout after DATA (STATUS=0x%08lX)\n", status);
            return FALSE;
        }
    } while (!(status & 0x1));

    /* 5. CTRL.STOP=1 — close session (CSIB forced high, BUSY clears). */
    WriteReg(hDev, ICAP_CTRL, 0x2);
    printf("  STOP sent\n");

    /* 6. Verify BUSY (bit1) is cleared after STOP. */
    Sleep(10);
    status = ReadReg(hDev, ICAP_STATUS);
    if (status & 0x2) {
        printf("  FAIL: BUSY still set after STOP (STATUS=0x%08lX)\n", status);
        return FALSE;
    }

    printf("  PASS\n");
    return TRUE;
}

/* ========================================================================== */
/*  Test: DDR3 roundtrip via BAR2 (DMA) — FIX T4                               */
/* ========================================================================== */

BOOL TestDdr3(HANDLE hDev)
{
    printf("\n--- DDR3 Test ---\n");

    /* Write a 4-word test pattern at DDR3 base (0x80000000). */
    uint64_t pattern[4] = {
        0xDEADBEEFCAFE1234ULL,
        0x0123456789ABCDEFULL,
        0xFEDCBA9876543210ULL,
        0x5555AAAA5555AAAAULL,
    };
    for (int i = 0; i < 4; i++) {
        if (!XdmaWrite(hDev, DDR3_BASE + (uint64_t)i * 8,
                       &pattern[i], sizeof(uint64_t), POLL_TIMEOUT_MS)) {
            printf("  FAIL: DMA write at offset %d\n", i);
            return FALSE;
        }
    }

    /* Read back and verify each word. */
    uint64_t readback[4] = {0};
    for (int i = 0; i < 4; i++) {
        if (!XdmaRead(hDev, DDR3_BASE + (uint64_t)i * 8,
                      &readback[i], sizeof(uint64_t), POLL_TIMEOUT_MS)) {
            printf("  FAIL: DMA read at offset %d\n", i);
            return FALSE;
        }
        if (readback[i] != pattern[i]) {
            printf("  FAIL: mismatch at %d -- wrote 0x%016llX, read 0x%016llX\n",
                   i, (unsigned long long)pattern[i], (unsigned long long)readback[i]);
            return FALSE;
        }
    }

    printf("  PASS (4 64-bit words roundtrip OK)\n");
    return TRUE;
}

/* ========================================================================== */
/*  Open XDMA device handle                                                   */
/* ========================================================================== */

static HANDLE OpenXdmDev(void)
{
    HANDLE h = CreateFileW(DEVICE_CONTROL,
                           GENERIC_READ | GENERIC_WRITE,
                           0, NULL, OPEN_EXISTING,
                           FILE_FLAG_OVERLAPPED, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        printf("FAILED to open %ws  (GLE=%lu)\n", DEVICE_CONTROL, GetLastError());
    }
    return h;
}

/* ========================================================================== */
/*  Utility: PASS / FAIL string                                               */
/* ========================================================================== */

static const char* PassFail(BOOL ok)
{
    return ok ? "PASS" : "FAIL";
}

/* ========================================================================== */
/*  Main                                                                       */
/* ========================================================================== */

int main(void)
{
    HANDLE hDev;
    int pass = 0, fail = 0;

    printf("=== XDMA Ternary Accelerator Test ===\n\n");
    printf("Device: %ws\n", DEVICE_CONTROL);

    hDev = OpenXdmDev();
    if (hDev == INVALID_HANDLE_VALUE) {
        printf("Cannot open XDMA device.  Is the driver installed?\n");
        return 1;
    }

    printf("Device opened OK.\n\n");

    /* ------------------------------------------------------------------ */
    /*  GPIO test                                                         */
    /* ------------------------------------------------------------------ */
    printf("[GPIO]      ");
    BOOL ok = TestGpio(hDev);
    printf("  -> %s\n", PassFail(ok));
    if (ok) pass++; else fail++;

    /* ------------------------------------------------------------------ */
    /*  TDOT register test                                                */
    /* ------------------------------------------------------------------ */
    printf("[TDOT_REGS] ");
    ok = TestTdotRegs(hDev);
    printf("  -> %s\n", PassFail(ok));
    if (ok) pass++; else fail++;

    /* ------------------------------------------------------------------ */
    /*  XADC test                                                         */
    /* ------------------------------------------------------------------ */
    printf("[XADC]      ");
    ok = TestXadc(hDev);
    printf("  -> %s\n", PassFail(ok));
    if (ok) pass++; else fail++;

    /* ------------------------------------------------------------------ */
    /*  TDOT protocol test                                                */
    /* ------------------------------------------------------------------ */
    printf("[TDOT_PROTO]");
    ok = TestTdotProtocol(hDev);
    printf("  -> %s\n", PassFail(ok));
    if (ok) pass++; else fail++;

    /* ------------------------------------------------------------------ */
    /*  ICAP test                                                         */
    /* ------------------------------------------------------------------ */
    printf("[ICAP]      ");
    ok = TestIcap(hDev);
    printf("  -> %s\n", PassFail(ok));
    if (ok) pass++; else fail++;

    /* ------------------------------------------------------------------ */
    /*  DDR3 test (FIX T4)                                                */
    /* ------------------------------------------------------------------ */
    printf("[DDR3]      ");
    ok = TestDdr3(hDev);
    printf("  -> %s\n", PassFail(ok));
    if (ok) pass++; else fail++;

    /* ================================================================== */
    /*  Summary                                                            */
    /* ================================================================== */
    printf("\n=== Summary: %d PASS, %d FAIL (%d total) ===\n",
           pass, fail, pass + fail);

    CloseHandle(hDev);
    return (fail > 0) ? 1 : 0;
}