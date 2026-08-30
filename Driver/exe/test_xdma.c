#include <stdio.h>
#include <windows.h>
#include <winioctl.h>

/* ========================================================================== */
/*  Address map -- AXI-Lite BAR0 (XDMA_DDR3_V2 / DFX-based)                   */
/* ========================================================================== */

/* GPIO -- LED control */
#define GPIO_BASE       0x40000000UL
#define GPIO_DATA       (GPIO_BASE + 0x00)
#define GPIO_TRI        (GPIO_BASE + 0x04)

/* AXI HWICAP */
#define HWICAP_BASE     0x40001000UL
#define HWICAP_ID       (HWICAP_BASE + 0x02C)  /* ID register (offset 0x2C, 16-bit) */

/* DFX Socket -- decouple / shutdown control */
#define DFX_SOCKET_BASE     0x40002000UL
#define DFX_DECOUPLE        (DFX_SOCKET_BASE + 0x00)  /* GPIO: bit0=decouple, bit1=shutdown_master, bit2=shutdown_slave */
#define DFX_TRI             (DFX_SOCKET_BASE + 0x04)  /* GPIO tri */
#define DFX_STATUS          (DFX_SOCKET_BASE + 0x08)  /* GPIO2: status of shutdown / decouple */

/* TDOT compute core (inside DFX RP) */
#define TDOT_BASE       0x40010000UL
#define TDOT_CTRL       (TDOT_BASE + 0x00)   /* W: [0]=GO (self-clearing) */
#define TDOT_STATUS     (TDOT_BASE + 0x04)   /* R: [0]=BUSY, [1]=DONE */
#define TDOT_N_IN       (TDOT_BASE + 0x08)   /* R/W: number of pairs */
#define TDOT_RES0       (TDOT_BASE + 0x0C)   /* R: result [15:0] */
#define TDOT_RES1       (TDOT_BASE + 0x10)   /* R: result [47:32] */
#define TDOT_DATA_ADDR_LO   (TDOT_BASE + 0x14)
#define TDOT_DATA_ADDR_HI   (TDOT_BASE + 0x18)
#define TDOT_WEIGHTS_ADDR_LO (TDOT_BASE + 0x1C)
#define TDOT_WEIGHTS_ADDR_HI (TDOT_BASE + 0x20)
#define TDOT_RESULT_ADDR_LO (TDOT_BASE + 0x24)
#define TDOT_RESULT_ADDR_HI (TDOT_BASE + 0x28)
#define TDOT_CORE_RES0  (TDOT_BASE + 0x2C)
#define TDOT_CORE_RES1  (TDOT_BASE + 0x30)

/* Device path (XDMA Win driver -- single device, BAR0 through same handle) */
#define DEVICE_CONTROL  L"\\\\.\\XDMA0"

/* Timing */
#define POLL_INTERVAL_MS    10
#define POLL_TIMEOUT_MS     5000

/* ========================================================================== */
/*  Forward declarations                                                      */
/* ========================================================================== */

ULONG  ReadReg(HANDLE hDev, ULONG addr);
void   WriteReg(HANDLE hDev, ULONG addr, ULONG value);

BOOL   TestGpio(HANDLE hDev);
BOOL   TestTdotRegs(HANDLE hDev);
BOOL   TestDfxSocket(HANDLE hDev);
BOOL   TestTdotProtocol(HANDLE hDev);
BOOL   TestHwicap(HANDLE hDev);

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
            if (waitResult == WAIT_OBJECT_0)
                GetOverlappedResult(hDev, &ov, &br, FALSE);
            else
                CancelIo(hDev);
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
            if (waitResult == WAIT_OBJECT_0)
                GetOverlappedResult(hDev, &ov, &bw, FALSE);
            else
                CancelIo(hDev);
        }
    }
    CloseHandle(ov.hEvent);
}

/* ========================================================================== */
/*  Test: GPIO -- write tri-state, toggle LEDs, verify readback               */
/* ========================================================================== */

BOOL TestGpio(HANDLE hDev)
{
    printf("\n--- GPIO Test ---\n");

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

    ULONG res0 = ReadReg(hDev, TDOT_RES0);
    ULONG res1 = ReadReg(hDev, TDOT_RES1);
    ULONG st   = ReadReg(hDev, TDOT_STATUS);
    printf("  RES0=0x%08lX RES1=0x%08lX STATUS=0x%08lX (read-only, OK)\n",
           res0, res1, st);

    return TRUE;
}

/* ========================================================================== */
/*  Test: DFX Socket -- verify decouple / shutdown registers                   */
/* ========================================================================== */

BOOL TestDfxSocket(HANDLE hDev)
{
    printf("\n--- DFX Socket Test ---\n");

    /* Read initial state */
    ULONG decouple = ReadReg(hDev, DFX_DECOUPLE);
    ULONG tri      = ReadReg(hDev, DFX_TRI);
    ULONG status   = ReadReg(hDev, DFX_STATUS);
    printf("  Initial: DECOUPLE=0x%08lX TRI=0x%08lX STATUS=0x%08lX\n",
           decouple, tri, status);

    /* Set DFX GPIO pins as outputs (TRI=0) */
    WriteReg(hDev, DFX_TRI, 0x00);
    {
        ULONG r = ReadReg(hDev, DFX_TRI);
        printf("  DFX_TRI = 0x%08lX (expect 0x00000000)\n", r);
        if (r != 0x00) return FALSE;
    }

    /* Assert decouple (bit 0), keep shutdown de-asserted */
    WriteReg(hDev, DFX_DECOUPLE, 0x01);
    Sleep(10);
    {
        ULONG d = ReadReg(hDev, DFX_DECOUPLE);
        printf("  DECOUPLE after set bit0 = 0x%08lX (bit0=1)\n", d);
        if ((d & 0x01) == 0) return FALSE;
    }

    /* De-assert decouple */
    WriteReg(hDev, DFX_DECOUPLE, 0x00);
    Sleep(10);
    {
        ULONG d = ReadReg(hDev, DFX_DECOUPLE);
        printf("  DECOUPLE after clear = 0x%08lX (bit0=0)\n", d);
        if (d != 0) return FALSE;
    }

    /* Set all: decouple + shutdown_master + shutdown_slave */
    WriteReg(hDev, DFX_DECOUPLE, 0x07);
    Sleep(10);
    {
        ULONG d = ReadReg(hDev, DFX_DECOUPLE);
        printf("  DECOUPLE bits[2:0]=111 = 0x%08lX\n", d);
        if ((d & 0x07) != 0x07) return FALSE;
    }

    /* All off again */
    WriteReg(hDev, DFX_DECOUPLE, 0x00);
    Sleep(10);
    {
        ULONG d = ReadReg(hDev, DFX_DECOUPLE);
        printf("  DECOUPLE all clear = 0x%08lX\n", d);
        if (d != 0) return FALSE;
    }

    return TRUE;
}

/* ========================================================================== */
/*  Test: TDOT full compute protocol                                           */
/* ========================================================================== */

BOOL TestTdotProtocol(HANDLE hDev)
{
    printf("\n--- TDOT Protocol Test ---\n");

    WriteReg(hDev, TDOT_N_IN,               8);
    WriteReg(hDev, TDOT_DATA_ADDR_LO,       0x80000000UL);
    WriteReg(hDev, TDOT_DATA_ADDR_HI,       0);
    WriteReg(hDev, TDOT_WEIGHTS_ADDR_LO,    0x80001000UL);
    WriteReg(hDev, TDOT_WEIGHTS_ADDR_HI,    0);
    WriteReg(hDev, TDOT_RESULT_ADDR_LO,     0x80002000UL);
    WriteReg(hDev, TDOT_RESULT_ADDR_HI,     0);

    {
        ULONG n = ReadReg(hDev, TDOT_N_IN);
        if (n != 8) {
            printf("  N_IN readback = %lu (expected 8)\n", n);
            return FALSE;
        }
    }

    WriteReg(hDev, TDOT_CTRL, 0x01);
    printf("  GO asserted, waiting for DONE...\n");

    BOOL    done   = FALSE;
    int     waited = 0;
    ULONG   status = 0;

    while (waited < POLL_TIMEOUT_MS) {
        status = ReadReg(hDev, TDOT_STATUS);
        if (status & 0x02) {
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

    ULONG res0   = ReadReg(hDev, TDOT_RES0);
    ULONG res1   = ReadReg(hDev, TDOT_RES1);
    ULONG cres0  = ReadReg(hDev, TDOT_CORE_RES0);
    ULONG cres1  = ReadReg(hDev, TDOT_CORE_RES1);

    ULONG64 result = ((ULONG64)(res1 & 0xFFFF) << 32) | (res0 & 0xFFFF);

    printf("  RES0=0x%08lX  RES1=0x%08lX  -> combined=0x%012llX\n",
           res0, res1, result);
    printf("  CORE_RES0=0x%08lX  CORE_RES1=0x%08lX\n", cres0, cres1);

    return TRUE;
}

/* ========================================================================== */
/*  Test: HWICAP -- verify ID register (read only)                             */
/* ========================================================================== */

BOOL TestHwicap(HANDLE hDev)
{
    printf("\n--- HWICAP Test ---\n");

    ULONG id = ReadReg(hDev, HWICAP_ID);
    printf("  HWICAP_ID = 0x%04lX (expect 0x0263 or 0x4261 for Xilinx HWICAP)\n",
           id & 0xFFFF);

    if ((id & 0xFFFF) == 0 || (id & 0xFFFF) == 0xFFFF)
        return FALSE;

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

    printf("=== XDMA DDR3 V2 (DFX) Test ===\n\n");
    printf("Device: %ws\n", DEVICE_CONTROL);

    hDev = OpenXdmDev();
    if (hDev == INVALID_HANDLE_VALUE) {
        printf("Cannot open XDMA device.  Is the driver installed?\n");
        return 1;
    }

    printf("Device opened OK.\n\n");

    printf("[GPIO]       ");
    BOOL ok = TestGpio(hDev);
    printf(" -> %s\n", PassFail(ok));
    if (ok) pass++; else fail++;

    printf("[TDOT_REGS]  ");
    ok = TestTdotRegs(hDev);
    printf(" -> %s\n", PassFail(ok));
    if (ok) pass++; else fail++;

    printf("[DFX_SOCKET] ");
    ok = TestDfxSocket(hDev);
    printf(" -> %s\n", PassFail(ok));
    if (ok) pass++; else fail++;

    printf("[TDOT_PROTO] ");
    ok = TestTdotProtocol(hDev);
    printf(" -> %s\n", PassFail(ok));
    if (ok) pass++; else fail++;

    printf("[HWICAP]     ");
    ok = TestHwicap(hDev);
    printf(" -> %s\n", PassFail(ok));
    if (ok) pass++; else fail++;

    printf("\n=== Summary: %d PASS, %d FAIL (%d total) ===\n",
           pass, fail, pass + fail);

    CloseHandle(hDev);
    return (fail > 0) ? 1 : 0;
}