/*
* XDMA Scatter-Gather DMA Engines
* ===============================
*
* Copyright 2017 Xilinx Inc.
* Copyright 2010-2012 Sidebranch
* Copyright 2010-2012 Leon Woestenberg <leon@sidebranch.com>
*
* Maintainer:
* -----------
* Alexander Hornburg <alexande@xilinx.com>
*
*/

#pragma once

// ========================= include dependencies =================================================

#include <ntddk.h>
#include <ntintsafe.h>
#include <wdf.h>
#include "reg.h"
#include "xdma_public.h"

// ========================= constants ============================================================

#define XDMA_MAX_NUM_CHANNELS   (4)
#define XDMA_NUM_DIRECTIONS     (2)
#define XDMA_MAX_CHAN_IRQ       (XDMA_NUM_DIRECTIONS * XDMA_MAX_NUM_CHANNELS)
#define XDMA_RING_NUM_BLOCKS    (258U)
#define XDMA_RING_BLOCK_SIZE    (PAGE_SIZE)
#define XDMA_MAX_TRANSFER_SIZE  (8UL * 1024UL * 1024UL)
// FIX-ROF 2026-10-05: cap every SGDMA descriptor at XDMA_DESC_MAX_BYTES (8192 B
// since v1.2.4; was 512 B) so the XDMA receiver never gets one huge transaction
// (prevents PCIe Receiver-Overflow / WHEA 0x124, see CHANGE_LOG_2026-09-27 §6N
// and DIAG_MULTIPACKET). ProgramDma slices each SG element into
// <=XDMA_DESC_MAX_BYTES descriptors in a single engine run.
#define XDMA_DESC_MAX_BYTES     (8192UL)
// FIX-DESC 2026-10-20: the descriptor bank must be sized for the WORST-CASE
// FRAGMENTATION of a transfer, not for the slice size above. A host buffer is
// handed to ProgramDma as SG elements that are MDL pages (4 KB granularity), so
// an 8 MB packet arrives as up to 2048 elements of <=4 KB each, i.e. one 8192-B
// slice per element = 2048 descriptors. Deriving the count from
// XDMA_DESC_MAX_BYTES (8MB/8192) gave only 1024, and ProgramDma then silently
// clamped 2048 -> 1024: half of the payload was never programmed, with no error.
// 4096 below is the page/MDL granularity, NOT the slice size.
#define XDMA_MAX_DESC_COUNT     (XDMA_MAX_TRANSFER_SIZE / 4096UL)

// PLAN-3 P1 2026-10-17: descriptor-block POOL size. Slots 1..N-1 are extra
// WDFCOMMONBUFFER blocks pre-allocated now so a future increment can give each
// WDFDMATRANSACTION its own descriptor buffer (no more one shared
// engine->descBuffer per engine). Slot 0 stays bound to the legacy field below
// and every current code path keeps using it -> zero behavior change. No
// consumer of slots 1..N-1 exists yet. Must fit a ULONG free-bitmap.
#define XDMA_DESC_POOL_SIZE     (4U)

// ========================= forward declarations =================================================

struct XDMA_DEVICE_T; 
typedef struct XDMA_DEVICE_T XDMA_DEVICE;
struct XDMA_ENGINE_T;

// ========================= type declarations ====================================================

/// Direction of the DMA transfer/engine
typedef enum DirToDev_t {
    H2C = 0, // Host-to-Card - write to device
    C2H = 1  // Card-to-Host - read from device
} DirToDev;

/// Ring buffer abstraction for streaming DMA
typedef struct XDMA_RING_T {
    WDFCOMMONBUFFER results;
    PMDL mdl[XDMA_RING_NUM_BLOCKS]; // memory descriptor list - host side
    CHAR dmaTransferContext[DMA_TRANSFER_CONTEXT_SIZE_V1];
    UINT head;
    UINT tail;
    WDFSPINLOCK lock;
    KEVENT completionSignal;
}XDMA_RING, *PXDMA_RING;

/// engine specific work to perform after dma transfer completion is detected
typedef VOID(*PFN_XDMA_ENGINE_WORK)(IN struct XDMA_ENGINE_T *engine);

/// Engine address mode. 
/// Determines how the DMA engine interprets the device address (destination address on H2C and 
/// source address on C2H).
/// When AddressMode_Contiguous is chosen, the device address only needs to be set for the first 
/// descriptor and the engine assumes that all subsequent descriptors device addresses follow
/// sequentially. 
/// When AddressMode_Fixed is selected, the device addresses of each descriptor must be explicitly
/// set.
typedef enum AddressMode_T {
    AddressMode_Contiguous,  // incremental
    AddressMode_Fixed,       // non-incremental
} AddressMode;

typedef enum EngineType_t {
    EngineType_MM,      // Memory Mapped
    EngineType_ST,      // Streaming
} EngineType;

/// DMA engine abstraction
typedef struct XDMA_ENGINE_T {

    XDMA_DEVICE *parentDevice; // the xdma device to which this engine belongs

    // register access
    volatile XDMA_ENGINE_REGS *regs; // control regs
    volatile XDMA_SGDMA_REGS *sgdma;

    // engine configuration
    UINT32 irqBitMask;
    UINT32 alignAddr;
    UINT32 alignLength;
    UINT32 alignAddrBits;
    DWORD channel;
    DirToDev dir;               // data flow direction (H2C or C2H)
    BOOLEAN enabled;
    EngineType type;            // MemoryMapped or Streaming
    AddressMode addressMode;    // incremental (contiguous) or non-incremental (fixed)

    // dma transfer related
    WDFCOMMONBUFFER descBuffer;
    WDFDMATRANSACTION dmaTransaction;
    PFN_XDMA_ENGINE_WORK work; // engine work for interrupt processing

    // REDUCED-ASYNC 2026-10-17: per-engine watchdog timer used as an async
    // completion fallback. The queue thread no longer blocks polling for
    // completion (EvtIoWriteDma/ReadDma return right after WdfDmaTransactionExecute).
    // When the channel interrupt (MSI-X) is lost, EvtDmaWatchdogTimer retires the
    // transfer after watchdogBudget x 10ms (~10s, matching the old
    // XDMA_EngineWaitCompletion bound).
    WDFTIMER watchdogTimer;     // per-engine watchdog (завершение при потерянном MSI-X)
    ULONG     watchdogCount;    // счётчик оставшихся тиков до timeout
    ULONG     watchdogBudget;   // const: количество тиков (установить в EngineCreate)

    // PLAN-3 P1 2026-10-17: descriptor-block pool (PREP-ONLY).
    // descBufferPool[0] IS the legacy descBuffer above (same WDFCOMMONBUFFER,
    // bound in EngineCreateDescriptorBuffer) so all current code paths are
    // unchanged. Slots 1..XDMA_DESC_POOL_SIZE-1 are allocated in EngineCreate
    // but NOT handed out yet (no consumer). The grant bookkeeping is a ULONG
    // free-bitmap: bit i set => slot i is free to be granted. Currently slot 0
    // is never granted (bit 0 clear) and slots 1..N-1 are all free.
    // Future increments: grant a slot per WDFDMATRANSACTION, then point
    // ProgramDma at engine->descBufferPool[slot] instead of engine->descBuffer.
    WDFCOMMONBUFFER descBufferPool[XDMA_DESC_POOL_SIZE];
    ULONG descPoolFree;

    // PLAN-3 P2 2026-10-17: transaction POOL (PREP-ONLY).
    // Mirrors descBufferPool above. Slot 0 IS engine->dmaTransaction (the legacy
    // live transaction used by every current code path) -> zero behavior change.
    // Slots 1..XDMA_DESC_POOL_SIZE-1 are pre-created idle WDFDMATRANSACTION
    // objects (reusable framework objects, never initialized/executed yet) parked
    // as capital for the P3 pipeliner. dmaTxFree is a ULONG free-bitmap: bit i set
    // = slot i may be granted; slot 0 is never granted (bit 0 clear).
    // Hand-out contract: XDMA_EngineTxAllocSlot / XDMA_EngineTxFreeSlot.
    WDFDMATRANSACTION dmaTxPool[XDMA_DESC_POOL_SIZE];
    ULONG dmaTxFree;

    // specific to streaming interface
    XDMA_RING ring;

    // specific to poll mode
    ULONG poll;
    WDFCOMMONBUFFER pollWbBuffer; // buffer for holding poll mode descriptor writeback data
    ULONG numDescriptors; // keep count of descriptors in transfer for poll mode

    // spurious-interrupt protection (mirrors official Xilinx driver)
    WDFSPINLOCK engineLock;
    BOOLEAN isReqPending;

    // DIAG 2026-10-03 (BRAM bypass): TRUE (default) -> ProgramDma adds
    // XDMA_DDR3_AXI_BASE to every desc; FALSE for h2c_bram_0/c2h_bram_0 so
    // host can address local BRAM 0x0 directly. Set in EvtDeviceFileCreate.
    BOOLEAN translateAxiBase;

    // DIAG 2026-10-04 (E-19 / BUG-053): number of EvtProgramDma invocations for
    // the current DMA request. Reset to 0 in EvtIoWriteDma/EvtIoReadDma before
    // WdfDmaTransactionExecute. Read via IOCTL_XDMA_DIAG_GET from user mode to
    // see whether WDF programs packet 2+ of a >512B multi-packet transaction.
    ULONG progDmaCalls;

    // FIX 2026-10-15 (BSOD 0x10D): flag "DMA transaction completion already
    // processed". EngineProcessTransfer may be entered from BOTH the bounded
    // poll (WaitCompletion) and the ISR/DPC path; calling
    // WdfDmaTransactionDmaCompleted twice on one transaction is a KMDF
    // Driver-Verifier violation (BugCheck 0x10D). Set TRUE after the first
    // DmaCompleted, reset in EvtIoWriteDma/EvtIoReadDma before Execute.
    BOOLEAN txnDone;

} XDMA_ENGINE;

// REDUCED-ASYNC 2026-10-17: per-timer object context so EvtDmaWatchdogTimer can
// recover the owning XDMA_ENGINE. The timer's WDF parent is the WDFDEVICE (so it
// is torn down with the device), not the engine, hence the engine pointer must be
// carried in the timer object's context.
typedef struct _DMA_WATCHDOG_CTX {
    XDMA_ENGINE* engine;
} DMA_WATCHDOG_CTX;
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DMA_WATCHDOG_CTX, GetDmaWatchdogContext)

#pragma pack(1)

/// \brief Descriptor for a single contiguous memory block transfer.
///
/// Multiple descriptors are linked a 'next' pointer. An additional extra adjacent number gives the 
/// amount of subsequent contiguous descriptors. The descriptors are in root complex memory, and the
/// bytes in the 32-bit words must be in little-endian byte ordering.
typedef struct xdma_descriptor_t {
    UINT32 control;
    UINT32 numBytes;  // transfer length in bytes
    UINT32 srcAddrLo; // source address (low 32-bit)
    UINT32 srcAddrHi; // source address (high 32-bit)
    UINT32 dstAddrLo; // destination address (low 32-bit)
    UINT32 dstAddrHi; // destination address (high 32-bit)
                      // next descriptor in the single-linked list of descriptors, 
                      // this is the bus address of the next descriptor in the root complex memory.
    UINT32 nextLo;    // next desc address (low 32-bit)
    UINT32 nextHi;    // next desc address (high 32-bit)
} DMA_DESCRIPTOR;

/// Result buffer of the streaming DMA operation. 
/// The XDMA IP core writes the result of the DMA transfer to the host memory
typedef struct {
    UINT32 status;
    UINT32 length;
    UINT32 reserved_1[6]; // padding
} DMA_RESULT;

/// \brief Structure for polled mode descriptor writeback
///
/// XDMA IP core writes number of completed descriptors to this memory, which the driver can then
/// poll to detect transfer completion
typedef struct {
    UINT32 completedDescCount;
    UINT32 reserved_1[7];
} XDMA_POLL_WB;

#pragma pack()

// ========================= function declarations ================================================

struct XDMA_DEVICE_T;
typedef struct XDMA_DEVICE_T* PXDMA_DEVICE;

/// Initialize an XDMA_ENGINE for each engine configured in HW
NTSTATUS ProbeEngines(IN PXDMA_DEVICE xdma);

/// Start the DMA engine
/// The transfer descriptors should be initialized and bound to HW before calling this function
VOID EngineStart(IN XDMA_ENGINE *engine);

/// Stop the DMA engine
VOID EngineStop(IN XDMA_ENGINE *engine);

/// Configure the streaming ring buffer and start the cyclic DMA transfer
VOID EngineRingSetup(IN XDMA_ENGINE *engine);

/// Reset the streaming ring buffer and stop the cyclic DMA transfer
VOID EngineRingTeardown(IN XDMA_ENGINE *engine);

/// Poll the write-back buffer for DMA transfer completion
NTSTATUS EnginePollTransfer(IN XDMA_ENGINE* engine);

/// Bounded completion poll: wait (with a hard timeout) for the engine to finish
/// the current transfer by reading its completedDescCount register, then invoke
/// EngineProcessTransfer. Fallback for when the channel interrupt does not reach
/// the host (BSOD case / MSI-X not delivered). Safe to call from EvtIoWriteDma.
NTSTATUS XDMA_EngineWaitCompletion(IN XDMA_ENGINE* engine, IN ULONG timeoutUs);

/// Explicitly bring the engine back to a known idle state. The C2H engine in
/// this DFX build can get stuck with BUSY set after a transfer; without picing
/// statusRC and clearing RUN/reset it never completes the next read. Call right
/// before starting a C2H transfer. Safe for a stopped/idle engine too.
VOID XDMA_EngineResetIdle(IN XDMA_ENGINE* engine);

/// REDUCED-ASYNC 2026-10-17: async transfer-completion callback.
/// KMDF invokes it when WdfDmaTransactionDmaCompleted() returns TRUE (i.e. every
/// WDF packet of the transaction finished). It RETIRES the request that the
/// queue thread left pending after WdfDmaTransactionExecute: UnmarkCancelable ->
/// (C2H ResetIdle) -> Release -> CompleteWithInformation. Must NOT be read after
/// Release. Also registered for H2C and C2H write/read paths.
VOID EvtTransferCompleteCb(IN WDFDMATRANSACTION Transaction, IN WDFDEVICE Device,
                           IN WDFCONTEXT Context, IN WDF_DMA_DIRECTION Direction,
                           IN DMA_COMPLETION_STATUS Status);

/// PLAN-3 P1 2026-10-17: delete the descriptor-block POOL slots (1..N-1) of one
/// engine. Slot 0 is the legacy engine->descBuffer and is intentionally left to
/// WDF automatic cleanup (same lifetime as the original) because we must not
/// change how it is torn down. Idempotent (NULL guards), safe at PASSIVE_LEVEL
/// during device teardown. Call from XDMA_DeviceClose for each enabled engine.
VOID XDMA_EngineDeleteDescriptorPool(IN XDMA_ENGINE* engine);

/// PLAN-3 P2 2026-10-17: allocate a free transaction-pool slot (>=1) for a new
/// request, or 0 if none is free / the engine has no pool. The returned slot is
/// marked busy. Slot 0 (the active legacy transaction) is intentionally never
/// handed out. GUARDED by engine->engineLock (safe from EvtIoWriteDma/ReadDma).
/// NOT used by any code path yet (prep for P3); slot 0 / engine->dmaTransaction
/// remains the only active path.
ULONG XDMA_EngineTxAllocSlot(IN XDMA_ENGINE* engine);

/// PLAN-3 P2 2026-10-17: return a previously granted transaction-pool slot
/// (mark it free again). Safe no-op for slot 0 or an out-of-range slot.
/// GUARDED by engine->engineLock. NOT used yet (prep for P3).
VOID XDMA_EngineTxFreeSlot(IN XDMA_ENGINE* engine, IN ULONG slot);

/// PLAN-3 P2 2026-10-17: delete the pre-created transaction-pool slots (1..N-1)
/// of one engine. Slot 0 (engine->dmaTransaction) is left to WDF automatic
/// cleanup (unchanged lifetime). Idempotent (NULL/zero guards), safe at
/// PASSIVE_LEVEL during device teardown. Call from XDMA_DeviceClose alongside
/// XDMA_EngineDeleteDescriptorPool.
VOID XDMA_EngineDeleteTxPool(IN XDMA_ENGINE* engine);

/// Poll the write-back buffer for DMA transfer completion
NTSTATUS EnginePollRing(IN XDMA_ENGINE* engine);

/// enable the engines interrupt
VOID EngineEnableInterrupt(IN XDMA_ENGINE* engine);

/// disable the engines interrupt
VOID EngineDisableInterrupt(IN XDMA_ENGINE* engine);

/// Arm the performance counters of the XDMA engine
/// Automatically stops when a dma descriptor with the stop bit is completed
VOID EngineStartPerf(IN XDMA_ENGINE* engine);

/// Get the performance counters 
VOID EngineGetPerf(IN XDMA_ENGINE* engine, OUT XDMA_PERF_DATA* perfData);

/// Stringify the Engine direction (H2C/C2H)
char* DirectionToString(DirToDev dir);

/// Copy data from the ring buffer directly into a WDFMEMORY object
NTSTATUS EngineRingCopyBytesToMemory(IN XDMA_ENGINE *engine, WDFMEMORY outputMem,
                                     size_t length, LARGE_INTEGER timeout, size_t* bytesRead);