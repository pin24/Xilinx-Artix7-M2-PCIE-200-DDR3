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
* References:
* -----------
*       [1] pg195-pcie-dma.pdf - DMA/Bridge Subsystem for PCI Express v3.0 - Product Guide
*/

// ========================= include dependencies =================================================

#include "device.h"
#include "interrupt.h"
#include "dma_engine.h"
#include "trace.h"

#if defined(DBG) || defined(WPP_ENABLED)
// The trace message header (.tmh) file must be included in a source file before any WPP macro 
// calls and after defining a WPP_CONTROL_GUIDS macro (defined in trace.h). see trace.h
#include "dma_engine.tmh"
#endif

// ========================= constants ============================================================

#define XDMA_ENG_IRQ_NUM        (1)
#define XDMA_MPS_BYTES          (256)   // Gen2 x4 default MaxPayloadSize
#define XDMA_DESC_MAGIC         (0xAD4B0000)
#define XDMA_WB_COUNT_MASK      (0x00ffffffUL)
#define XDMA_WB_ERR_MASK        (BIT_N(31))

// ========================= static function declarations =========================================

static UINT32 EngineStatus(IN XDMA_ENGINE *engine, IN BOOLEAN clear);
static void EngineGetAlignments(IN OUT XDMA_ENGINE *engine);
static NTSTATUS EngineCreateDescriptorBuffer(IN OUT XDMA_ENGINE *engine);
static NTSTATUS EngineCreateRingBuffer(IN OUT XDMA_ENGINE* engine);
static NTSTATUS EngineCreateDescriptorPool(IN OUT XDMA_ENGINE *engine);
static NTSTATUS EngineCreateTxPool(IN OUT XDMA_ENGINE *engine);
static void EngineConfigureInterrupt(IN OUT XDMA_ENGINE *engine, IN UINT index);
static void EngineProcessTransfer(IN XDMA_ENGINE *engine);
static UINT EngineProcessRing(IN XDMA_ENGINE *engine);
static VOID EvtDmaWatchdogTimer(IN WDFTIMER Timer);   // REDUCED-ASYNC 2026-10-17
static void EngineRingAdvance(UINT* index);
static NTSTATUS EngineCreatePollWriteBackBuffer(IN OUT XDMA_ENGINE *engine);

// Mark these functions as pageable code
#ifdef ALLOC_PRAGMA
#pragma alloc_text (PAGE, ProbeEngines)
#endif

// WDK 10 static code analysis gives a false warning: "Allocating executable memory via specifying 
// a MM_PAGE_PRIORITY type without a bitwise OR with MdlMappingNoExecute"
// However this only applies to Windows 8 and above, thus disable this warning. 
// see https://msdn.microsoft.com/en-us/library/windows/hardware/ff554629(v=vs.85).aspx
#pragma warning (disable : 30030) 

// ======================== common engine functions ===============================================

static NTSTATUS EngineCreateDescriptorBuffer(IN OUT XDMA_ENGINE *engine) {
    // allocate host-side buffer for descriptors.
    // FIX-ROF 2026-10-05: descriptor bank for one full transfer, sliced into
    // <=XDMA_DESC_MAX_BYTES slices.
    // FIX-DESC 2026-10-20: bank size = XDMA_MAX_DESC_COUNT * sizeof(DMA_DESCRIPTOR)
    // + 1 spare = 2048 * 32 + 32 = 65568 B (~64.0 KB) per buffer, which covers the
    // worst case of one 4-KB MDL page per SG element. 4 such buffers exist per
    // engine (slot 0 legacy + 3 pool slots) = ~256 KB, ~2 MB for 8 engines.
    SIZE_T bufferSize = (SIZE_T)XDMA_MAX_DESC_COUNT * sizeof(DMA_DESCRIPTOR) + sizeof(DMA_DESCRIPTOR);

    NTSTATUS status = WdfCommonBufferCreate(engine->parentDevice->dmaEnabler, bufferSize,
                                            WDF_NO_OBJECT_ATTRIBUTES, &engine->descBuffer);
    if (!NT_SUCCESS(status)) {
        TraceError(DBG_INIT, "WdfCommonBufferCreate failed: %!STATUS!", status);
        return status;
    }

    // PLAN-3 P1 2026-10-17: slot 0 of the pool IS the legacy engine buffer, so
    // every current code path (ProgramDma / EngineProcessTransfer / ResetIdle /
    // RingProgramDma via engine->descBuffer) keeps working unchanged.
    // Only initialise slot 0 here; the free-bitmap and slots 1..N-1 are set up
    // by EngineCreateDescriptorPool (called right after this in EngineCreate).
    engine->descBufferPool[0] = engine->descBuffer;

    PHYSICAL_ADDRESS descBufferLA = WdfCommonBufferGetAlignedLogicalAddress(engine->descBuffer);
    PUCHAR descBufferVA = (PUCHAR)WdfCommonBufferGetAlignedVirtualAddress(engine->descBuffer);
    RtlZeroMemory(descBufferVA, bufferSize);

    // give hw the physical start address of the descriptor buffer
    engine->sgdma->firstDescLo = descBufferLA.LowPart;
    engine->sgdma->firstDescHi = descBufferLA.HighPart;
    engine->sgdma->firstDescAdj = 0; // depends on transfer - set later in ProgramDMA

    TraceVerbose(DBG_INIT, "descriptor buffer at 0x%08x%08x, size=%lld",
                 engine->sgdma->firstDescHi, engine->sgdma->firstDescLo, bufferSize);
    return status;
}

// ==========================================================================================
// PLAN-3 P1 2026-10-17: descriptor-block POOL (PREP-ONLY).
// ------------------------------------------------------------------------------------------
// Gives the engine N independent WDFCOMMONBUFFER blocks so a future increment can
// assign one to each WDFDMATRANSACTION instead of sharing a single descBuffer.
//   * slot 0 = the legacy engine->descBuffer (already created+bound by
//     EngineCreateDescriptorBuffer); it is the only slot the current code uses.
//   * slots 1..XDMA_DESC_POOL_SIZE-1 are allocated here and LEFT UNUSED: no code
//     path consumes them yet, so behaviour with the pool present is identical to
//     the single-buffer build.
//   * descPoolFree is a ULONG free-bitmap (bit i set = slot i free). Slot 0 is
//     marked permanently busy (it is the active engine buffer). Nothing is
//     granted today; the bitmap is the hand-out contract for the next increments.
// HELD at device init, PASSIVE_LEVEL.
// ==========================================================================================
static NTSTATUS EngineCreateDescriptorPool(IN OUT XDMA_ENGINE *engine) {
    SIZE_T bufferSize =
        (SIZE_T)XDMA_MAX_DESC_COUNT * sizeof(DMA_DESCRIPTOR) + sizeof(DMA_DESCRIPTOR);
    ULONG i;

    // bitmap: slot 0 is the live engine buffer -> never handed out (bit 0 clear).
    engine->descPoolFree = 0;

    for (i = 1; i < XDMA_DESC_POOL_SIZE; i++) {
        WDFCOMMONBUFFER buf = NULL;
        NTSTATUS st = WdfCommonBufferCreate(engine->parentDevice->dmaEnabler, bufferSize,
                                            WDF_NO_OBJECT_ATTRIBUTES, &buf);
        if (!NT_SUCCESS(st)) {
            TraceError(DBG_INIT, "EngineCreateDescriptorPool slot %lu failed: %!STATUS!", i, st);
            // roll back slots already created so EngineCreate fails cleanly; slot 0
            // (legacy descBuffer) is left to WDF/WdfDmaEnabler cleanup as before.
            XDMA_EngineDeleteDescriptorPool(engine);
            return st;
        }
        RtlZeroMemory(WdfCommonBufferGetAlignedVirtualAddress(buf), bufferSize);
        engine->descBufferPool[i] = buf;
        engine->descPoolFree |= ((ULONG)1u << i);
    }

    TraceInfo(DBG_INIT, "%s_%u descBufferPool ready: %u slots (slot0 legacy, free=0x%x)",
              DirectionToString(engine->dir), engine->channel,
              XDMA_DESC_POOL_SIZE, engine->descPoolFree);
    return STATUS_SUCCESS;
}

VOID XDMA_EngineDeleteDescriptorPool(IN XDMA_ENGINE *engine) {
    if (engine == NULL) {
        return;
    }
    // Free the pool slots WE created (1..N-1). Slot 0 is engine->descBuffer and
    // is intentionally NOT deleted here: it has exactly the same lifetime as the
    // original driver (WDF automatic cleanup, parent = WdfDmaEnabler) and we must
    // not change how the active engine buffer is torn down.
    for (ULONG i = 1; i < XDMA_DESC_POOL_SIZE; i++) {
        if (engine->descBufferPool[i] != NULL) {
            WdfObjectDelete(engine->descBufferPool[i]);
            engine->descBufferPool[i] = NULL;
        }
    }
    engine->descPoolFree = 0;
}

// ==========================================================================================
// PLAN-3 P2 2026-10-17: transaction POOL (PREP-ONLY).
// ------------------------------------------------------------------------------------------
// Mirrors the descriptor-block pool above, but for WDFDMATRANSACTION framework
// objects. Each WDFDMATRANSACTION is a reusable object created once against the
// engine's DMA enabler; it is bound to a specific request later by
// WdfDmaTransactionInitializeUsingRequest() and executed by
// WdfDmaTransactionExecute() (P3). Having N independent transactions is what
// allows the P3 pipeliner to overlap completion of one transfer with the setup
// of the next without re-arming the same shared transaction.
//   * slot 0 = the legacy engine->dmaTransaction (already created by
//     WdfDmaTransactionCreate in EngineCreate); it remains the ONLY transaction
//     every current code path uses -> zero behavior change.
//   * slots 1..XDMA_DESC_POOL_SIZE-1 are pre-created here and LEFT IDLE: never
//     initialized/executed, so behaviour with the pool present is identical to
//     the single-transaction build.
//   * dmaTxFree is a ULONG free-bitmap (bit i set = slot i grantable). Slot 0 is
//     marked permanently busy (it is the live transaction). Nothing is handed out
//     today; XDMA_EngineTxAllocSlot/XDMA_EngineTxFreeSlot are the hand-out
//     contract for the P3 pipeliner.
// Pre-created idle WDFDMATRANSACTION objects are harmless framework objects:
// they cost no resources until initialized. On failure we roll back via
// XDMA_EngineDeleteTxPool so EngineCreate fails cleanly.
// HELD at device init, PASSIVE_LEVEL.
// ==========================================================================================
static NTSTATUS EngineCreateTxPool(IN OUT XDMA_ENGINE *engine) {
    if (engine == NULL || engine->parentDevice == NULL) {
        return STATUS_INVALID_PARAMETER;
    }

    // bitmap: slot 0 is the live engine transaction -> never handed out (bit 0 clear).
    engine->dmaTxFree = 0;

    for (ULONG i = 1; i < XDMA_DESC_POOL_SIZE; i++) {
        WDFDMATRANSACTION txn = NULL;
        NTSTATUS st = WdfDmaTransactionCreate(engine->parentDevice->dmaEnabler,
                                              WDF_NO_OBJECT_ATTRIBUTES, &txn);
        if (!NT_SUCCESS(st)) {
            TraceError(DBG_INIT, "EngineCreateTxPool slot %lu failed: %!STATUS!", i, st);
            // roll back slots already created so EngineCreate fails cleanly; slot 0
            // (legacy dmaTransaction) is left to WDF cleanup as before.
            XDMA_EngineDeleteTxPool(engine);
            return st;
        }
        engine->dmaTxPool[i] = txn;
        engine->dmaTxFree |= ((ULONG)1u << i);
    }

    TraceInfo(DBG_INIT, "%s_%u dmaTxPool ready: %u slots (slot0 legacy, free=0x%x)",
              DirectionToString(engine->dir), engine->channel,
              XDMA_DESC_POOL_SIZE, engine->dmaTxFree);
    return STATUS_SUCCESS;
}

VOID XDMA_EngineDeleteTxPool(IN XDMA_ENGINE *engine) {
    if (engine == NULL) {
        return;
    }
    // Free the pool slots WE created (1..N-1). Slot 0 is engine->dmaTransaction
    // and is intentionally NOT deleted here: it has exactly the same lifetime as
    // the original driver (WDF automatic cleanup, parent = default) and we must
    // not change how the active transaction is torn down.
    for (ULONG i = 1; i < XDMA_DESC_POOL_SIZE; i++) {
        if (engine->dmaTxPool[i] != NULL) {
            WdfObjectDelete(engine->dmaTxPool[i]);
            engine->dmaTxPool[i] = NULL;
        }
    }
    engine->dmaTxFree = 0;
}

ULONG XDMA_EngineTxAllocSlot(IN XDMA_ENGINE *engine) {
    if (engine == NULL || engine->engineLock == NULL) {
        return 0;
    }
    ULONG slot = 0;
    WdfSpinLockAcquire(engine->engineLock);
    // scan for the lowest grantable slot (>0). dmaTxFree bits for slots 1..N-1
    // are the only ones ever set (slot 0 bit is always clear).
    ULONG free = engine->dmaTxFree;
    for (ULONG i = 1; i < XDMA_DESC_POOL_SIZE; i++) {
        if (free & ((ULONG)1u << i)) {
            slot = i;
            break;
        }
    }
    if (slot != 0) {
        engine->dmaTxFree &= ~((ULONG)1u << slot); // mark busy
    }
    WdfSpinLockRelease(engine->engineLock);
    return slot;
}

VOID XDMA_EngineTxFreeSlot(IN XDMA_ENGINE *engine, IN ULONG slot) {
    if (engine == NULL || engine->engineLock == NULL) {
        return;
    }
    if (slot == 0 || slot >= XDMA_DESC_POOL_SIZE) {
        return; // slot 0 is legacy and never granted; out-of-range is a no-op
    }
    WdfSpinLockAcquire(engine->engineLock);
    engine->dmaTxFree |= ((ULONG)1u << slot); // mark free again
    WdfSpinLockRelease(engine->engineLock);
}

static void EngineConfigureInterrupt(IN OUT XDMA_ENGINE *engine, IN UINT index) {
    // engine interrupt request bit(s) - interrupt bit depends on number of engines present
    // see Figure 2-4 on page 46 of pcie dma product guide [1]
    engine->irqBitMask = (1 << XDMA_ENG_IRQ_NUM) - 1;
    engine->irqBitMask <<= (index * XDMA_ENG_IRQ_NUM);

    // bind msi interrupt context with this engine
    if (engine->parentDevice->channelInterrupts[index] != NULL) {
        PIRQ_CONTEXT irqContext = GetIrqContext(engine->parentDevice->channelInterrupts[index]);
        irqContext->engine = engine;
    }

    // enable interrupts
    UINT32 regVal = XDMA_CTRL_IE_ALL;
    if ((engine->type == EngineType_ST) && (engine->dir == C2H)) {
        regVal |= XDMA_CTRL_IE_IDLE_STOPPED;
    }
    engine->regs->intEnableMaskW1S = regVal;
    engine->regs->controlW1S = regVal;
    TraceVerbose(DBG_INIT, "engineIrqBitMask=0x%08x, intEnableMask=0x%08x",
                 engine->irqBitMask, engine->regs->intEnableMask);
}

static void EngineProcessTransfer(IN XDMA_ENGINE *engine)
// service an SGDMA engine
{
    NTSTATUS status = STATUS_SUCCESS;
    WDFREQUEST request;
    UINT32 engineStatus;
    // FIX-DESC2 2026-10-20 (BUG-060 / D-2): "транзакция больше не владеет
    // банком дескрипторов". TRUE по умолчанию (ошибочные пути завершают request
    // и освобождают транзакцию — хвост нужен); в ветке STOPPED_OK уточняется
    // фактом WdfDmaTransactionDmaCompleted: при completed == FALSE KMDF уже
    // синхронно запрограммировал следующий WDF-пакет — хвост затер бы его
    // состояние (см. комментарий у хвоста).
    BOOLEAN txnReleased = TRUE;

    if (engine == NULL) {
        TraceError(DBG_DMA, "engine=NULL");
        return;
    }

    // spurious-irq guard (mirrors official Xilinx driver): if no request is
    // marked pending, the interrupt arrived without an active DMA -> do NOT
    // touch the engine / dmaTransaction (a NULL-dmaTransaction deref here
    // would trip Driver Verifier 0xE6/0x26). Just drop it.
    if (engine->engineLock) {
        WdfSpinLockAcquire(engine->engineLock);
        BOOLEAN pending = engine->isReqPending;
        WdfSpinLockRelease(engine->engineLock);
        if (!pending) {
            TraceError(DBG_DMA, "%s_%u spurious interrupt, no request pending",
                       DirectionToString(engine->dir), engine->channel);
            return;
        }
    }

    // FIX 2026-10-15 (BSOD 0x10D): единая защита от ПОВТОРНОГО входа в
    // EngineProcessTransfer на одной транзакции (параллельный вход: bounded-poll
    // WaitCompletion + ISR/DPC). Check-and-set txnDone под спинлоком ПОКРЫВАЕТ
    // все ветки (success и error): второй вход просто выходит раньше, чем успеет
    // вызвать WdfDmaTransactionDmaCompleted / Release / Complete повторно.
    if (engine->engineLock) {
        WdfSpinLockAcquire(engine->engineLock);
        BOOLEAN already = engine->txnDone;
        if (!already) { engine->txnDone = TRUE; engine->txnTimeout = FALSE; }
        WdfSpinLockRelease(engine->engineLock);
        if (already) {
            TraceError(DBG_DMA, "%s_%u transfer already processed; skip duplicate",
                       DirectionToString(engine->dir), engine->channel);
            return;
        }
    }

    TraceInfo(DBG_DMA, "%s_%u processing transfer completion",
              DirectionToString(engine->dir), engine->channel);

    request = WdfDmaTransactionGetRequest(engine->dmaTransaction);
    if (!request) {
        TraceInfo(DBG_DMA, "Interrupt but no request pending?");
        return;
    }

    // read and clear engine status 
    engineStatus = EngineStatus(engine, TRUE);

    EngineStop(engine);

    switch (engineStatus & XDMA_STAT_EXPECTED_ZERO) {
    case XDMA_ENGINE_STOPPED_OK: // engine not busy and no errors?
    {
        // FIX 2026-10-20 (v1.2.2): SYNCHRONOUS retirement, matching proven
        // v1.1.29 (b3e07b1). The 1.1.33 async model relied on KMDF calling
        // EvtTransferCompleteCb only when DmaCompleted returns TRUE, which made
        // completion depend on the (unreliable) channel interrupt/Msi-x arrival;
        // a lost interrupt left the request hanging until the watchdog. Here the
        // request is completed right in EngineProcessTransfer (called either from
        // the DPC or from XDMA_EngineWaitCompletion poll), so completion no longer
        // depends on the async callback. txnDone keeps it single-shot.
        BOOLEAN completed = WdfDmaTransactionDmaCompleted(engine->dmaTransaction, &status);
        size_t bytesTransferred = WdfDmaTransactionGetBytesTransferred(engine->dmaTransaction);
        // FIX-DESC2 (BUG-060/D-2): only a fully-completed (last-packet) transaction
        // releases the descriptor bank; intermediate packets keep it programmed.
        txnReleased = completed;

        TraceInfo(DBG_DMA, "%s_%u transaction%scomplete, bytesTransferred=%llu",
                  DirectionToString(engine->dir), engine->channel,
                  completed ? " " : " in", bytesTransferred);

        if (completed) {
            NTSTATUS uc = WdfRequestUnmarkCancelable(request);
            if (uc == STATUS_CANCELLED) {
                // cancel-путь уже владеет request — не завершаем и не отпускаем здесь
                break;
            }
            if (engine->dir == C2H) {
                XDMA_EngineResetIdle(engine); // иначе следующий C2H стартует BUSY
            }
            NTSTATUS rl = WdfDmaTransactionRelease(engine->dmaTransaction);
            if (!NT_SUCCESS(rl)) {
                TraceError(DBG_DMA, "WdfDmaTransactionRelease failed: %!STATUS!", rl);
            }
            WdfRequestCompleteWithInformation(request, rl, bytesTransferred);
        }
        break;
    }
    case XDMA_BUSY_BIT: // engine is still busy without sign of errors?
        TraceError(DBG_DMA, "Engine Still Busy, Descriptors Completed=%u",
                   engine->regs->completedDescCount);
    default: // any sign of errors
        TraceError(DBG_DMA, "Unexpected engine status 0x%08x", engineStatus);
        status = WdfRequestUnmarkCancelable(request);
        if (!NT_SUCCESS(status)) {
            TraceError(DBG_DMA, "WdfRequestUnmarkCancelable failed: %!STATUS!", status);
        }
        status = WdfDmaTransactionRelease(engine->dmaTransaction);
        if (!NT_SUCCESS(status)) {
            TraceError(DBG_DMA, "WdfDmaTransactionRelease failed: %!STATUS!", status);
        }
        WdfRequestComplete(request, STATUS_INTERNAL_ERROR);
    }

    // ============================================================================
    // FIX-DESC2 2026-10-20 (BUG-060 / D-2, аудит 39-b): хвост валиден ТОЛЬКО когда
    // транзакция реально завершена (txnReleased == TRUE). При completed == FALSE
    // KMDF УЖЕ синхронно запрограммировал следующий WDF-пакет внутри
    // WdfDmaTransactionDmaCompleted (EvtProgramDma -> XDMA_EngineProgramDma):
    // свежие дескрипторы лежат в descBuffer, isReqPending=TRUE выставлен,
    // EngineStart выполнен. Прежний БЕЗУСЛОВНЫЙ хвост: (a) гасил isReqPending —
    // spurious-irq guard отбрасывал завершение packet-2; (b) RtlZeroMemory затирал
    // банк дескрипторов ПОД работающим packet-2; (c) оставлял txnDone=TRUE — CAS
    // блокировал повторный вход => packet-2 никогда не завершался, IRP утекал,
    // sequential queue навсегда wedged (маскировалось host-чанкингом
    // DMA_CHUNK=1MiB: WDF-пакет всегда один). При txnReleased == FALSE: флаги и
    // банк НЕ трогаем, txnDone пере-вооружается FALSE, чтобы completion packet-2
    // прошёл CAS и обработался этим же EngineProcessTransfer (там выполнится
    // полный хвост). EvtIo* параллельно ждёт остальные пакеты циклом.
    // ============================================================================
    if (txnReleased) {
        // request handled -> clear pending flag (spurious-irq guard)
        if (engine->engineLock) {
            WdfSpinLockAcquire(engine->engineLock);
            engine->isReqPending = FALSE;
            // NOTE FIX 2026-10-15: НЕ сбрасываем engine->txnDone здесь — иначе
            // хвостовой DPC от той же транзакции снова пройдёт guard. txnDone
            // сбрасывается в начале следующего request (EvtIoWrite/ReadDma).
            WdfSpinLockRelease(engine->engineLock);
        }

        // clear descriptor buffer
        DMA_DESCRIPTOR* descriptorBuffer = (DMA_DESCRIPTOR*)WdfCommonBufferGetAlignedVirtualAddress(engine->descBuffer);
        size_t descBufferLength = WdfCommonBufferGetLength(engine->descBuffer);
        RtlZeroMemory(descriptorBuffer, descBufferLength);

        // clear poll writeback buffer
        if (engine->poll) {
            XDMA_POLL_WB* wbBuffer = (XDMA_POLL_WB*)WdfCommonBufferGetAlignedVirtualAddress(engine->pollWbBuffer);
            size_t wbBufferLength = WdfCommonBufferGetLength(engine->pollWbBuffer);
            RtlZeroMemory(wbBuffer, wbBufferLength);
        }
    } else {
        // multi-packet: packet N+1 уже программируется/выполняется — пере-вооружаем
        // single-shot CAS под его completion (см. комментарий выше).
        if (engine->engineLock) {
            WdfSpinLockAcquire(engine->engineLock);
            engine->txnDone = FALSE;
            WdfSpinLockRelease(engine->engineLock);
        }
    }
}

// REDUCED-ASYNC 2026-10-17: async transfer-completion callback. KMDF invokes
// this when EngineProcessTransfer's WdfDmaTransactionDmaCompleted() returns TRUE
// (last WDF packet of the transaction). Because the queue thread no longer blocks
// in EvtIoWriteDma/ReadDma, this callback is what retires the pending request.
// ORDER IS LOCKED (must not be reordered):
//   1) UnmarkCancelable FIRST: if a cancel routine already owns the request
//      (STATUS_CANCELLED), bail and hand it to the cancel path — do NOT touch
//      Release/Complete on it.
//   2) ResetIdle for C2H BEFORE Complete, otherwise the next read starts BUSY.
//   3) WdfDmaTransactionRelease, then WdfRequestCompleteWithInformation.
// Nothing below may be read AFTER WdfDmaTransactionRelease (the transaction is
// freed by the framework at that point).
VOID EvtTransferCompleteCb(IN WDFDMATRANSACTION Transaction,
                           IN WDFDEVICE Device,
                           IN WDFCONTEXT Context,
                           IN WDF_DMA_DIRECTION Direction,
                           IN DMA_COMPLETION_STATUS Status) {
    UNREFERENCED_PARAMETER(Device);
    UNREFERENCED_PARAMETER(Direction);
    XDMA_ENGINE* engine = (XDMA_ENGINE*)Context;
    if (engine == NULL || Transaction == NULL) {
        return;
    }
    WDFREQUEST request = WdfDmaTransactionGetRequest(Transaction);
    if (request == NULL) {
        return;
    }

    // read the bytes BEFORE Release (transaction is freed by Release)
    size_t bytes = WdfDmaTransactionGetBytesTransferred(Transaction);

    // UnmarkCancelable FIRST: if a concurrent cancel already owns the request,
    // it will complete it; do not touch it here.
    NTSTATUS st = WdfRequestUnmarkCancelable(request);
    if (st == STATUS_CANCELLED) {
        return; // отдать cancel-пути
    }

    // C2H reset before Complete (иначе следующий read начнёт BUSY).
    if (engine->dir == C2H) {
        XDMA_EngineResetIdle(engine);
    }

    WdfDmaTransactionRelease(Transaction);

    // NOTE: engine->txnDone / isReqPending остаются под управлением
    // EngineProcessTransfer (флаг pending сброшен там); здесь только retire.
    WdfRequestCompleteWithInformation(request, (NTSTATUS)Status, bytes);
}

// REDUCED-ASYNC 2026-10-17: per-engine watchdog. Armed (started) in
// EvtIoWriteDma/EvtIoReadDma after WdfDmaTransactionExecute and re-armed from
// this callback every 10 ms. Two exits:
//   * HW-transfer detected done (BUSY cleared + completedDescCount reached):
//       -> EngineProcessTransfer (DmaCompleted=TRUE) -> KMDF calls
//          EvtTransferCompleteCb -> request completed. timer NOT re-armed.
//   * watchdogCount exhausted (no MSI-X, dead FPGA): EngineStop + set
//       txnDone/isReqPending FALSE + UnmarkCancelable + Release + Complete(code)
//         STATUS_TIMEOUT. timer NOT re-armed.
// Otherwise (still in flight) re-arms itself for the next tick.
static VOID EvtDmaWatchdogTimer(IN WDFTIMER Timer) {
    DMA_WATCHDOG_CTX* wd = GetDmaWatchdogContext(Timer);
    if (wd == NULL || wd->engine == NULL) {
        return;
    }
    XDMA_ENGINE* engine = wd->engine;

    // если прерывание уже победило (txnDone TRUE) или нет активного запроса —
    // выход, не пере-армируем.
    BOOLEAN done = FALSE, pending = FALSE;
    if (engine->engineLock) {
        WdfSpinLockAcquire(engine->engineLock);
        done = engine->txnDone;
        pending = engine->isReqPending;
        WdfSpinLockRelease(engine->engineLock);
    }
    if (done || !pending) {
        return;
    }

    // проверить hwDone КАК XDMA_EngineWaitCompletion: прочитать statusRC
    // (read-clear, снимает BUSY) + completedDescCount.
    ULONG actual = engine->regs->completedDescCount;
    UINT32 st = engine->regs->statusRC;
    BOOLEAN hwDone = (st & XDMA_BUSY_BIT) == 0;
    if (hwDone && actual >= engine->numDescriptors) {
        EngineProcessTransfer(engine);   // -> DmaCompleted=TRUE -> CB -> request завершается
        return;                          // не пере-армируем
    }

    if (engine->watchdogCount-- == 0) {  // timeout
        // REVIEW-FIX 2026-10-17: ре-проверка ПОСЛЕ декремента. Охрана в начале
        // функции считывает done/pending в отдельной критической секции, а до
        // этой точки DPC/EvtCancelDma могли уже завершить транзакцию. Поэтому
        // именно здесь атомарно захватываем единоличное право на освобождение:
        // если txnDone уже TRUE или запрос не активен — выходим, НЕ трогая
        // Release/Complete (иначе двойное освобождение -> 0x10D/0xE6).
        BOOLEAN alreadyDone = FALSE;
        if (engine->engineLock) {
            WdfSpinLockAcquire(engine->engineLock);
            alreadyDone = engine->txnDone || !engine->isReqPending;
            if (!alreadyDone) {
                engine->isReqPending = FALSE;
                engine->txnDone = TRUE; // claim: этот watchdog — единственный владелец освобождения
            }
            WdfSpinLockRelease(engine->engineLock);
        }
        if (alreadyDone) {
            return; // завершил кто-то другой (DPC/cancel) — не освобождаем повторно
        }

        TraceError(DBG_DMA, "%s_%u watchdog TIMEOUT (descs completed=%u/%u)",
                   DirectionToString(engine->dir), engine->channel,
                   actual, engine->numDescriptors);
        EngineStop(engine);
        WDFREQUEST request = WdfDmaTransactionGetRequest(engine->dmaTransaction);
        if (request != NULL) {
            // REVIEW-FIX: если cancel-рутина уже перехватила request, отдаём ей
            // завершение — НЕ делаем здесь Release/Complete (иначе двойное).
            NTSTATUS uc = WdfRequestUnmarkCancelable(request);
            if (uc == STATUS_CANCELLED) {
                return;
            }
        }
        WdfDmaTransactionRelease(engine->dmaTransaction);
        if (request != NULL) {
            WdfRequestComplete(request, STATUS_TIMEOUT);
        }
        return;
    }

    // пере-армировать на следующий тик (10 мс)
    LARGE_INTEGER period;
    period.QuadPart = -100000; // 10 мс
    WdfTimerStart(engine->watchdogTimer, period.QuadPart);
}

static void DumpDescriptor(IN const DMA_DESCRIPTOR* const desc) {
#if DBG
    TraceVerbose(DBG_DESC, "descriptor={.control=0x%08X, .numBytes=%u, srcAddr=0x%08X%08X, .dstAddr=0x%08X%08X, nextAddr=0x%08X%08X}",
                 desc->control, desc->numBytes,
                 desc->srcAddrHi, desc->srcAddrLo,
                 desc->dstAddrHi, desc->dstAddrLo,
                 desc->nextHi, desc->nextLo);
#else 
    UNREFERENCED_PARAMETER(desc);
#endif
}

static BOOLEAN DescriptorIsAligned(IN XDMA_ENGINE *engine, IN DMA_DESCRIPTOR *desc)
// For alignment requirements see product guide [1] page 23 table 2-9
{
    if (engine->addressMode == AddressMode_Fixed) {
        const UINT32 dataPathWidth = (1 << (6 + engine->parentDevice->configRegs->pcieWidth)) / 8;
        const UINT32 addrMask = dataPathWidth - 1;

        if ((desc->dstAddrLo & addrMask) != (desc->srcAddrLo & addrMask) != 0) {
            TraceError(DBG_DESC, "misalignment detected! dataWidth=%u, src=0x%08llx, dst=0x%08llx, bytes=%llu",
                       dataPathWidth, desc->srcAddrLo, desc->dstAddrLo, desc->numBytes);
            return FALSE;
        }
        // todo length alignment requirement??

    } else { // AddressMode_Contiguous (i.e. incremental mode)
        BOOLEAN dstAddrMisaligned = (desc->dstAddrLo % engine->alignAddr) != 0;
        BOOLEAN lengthMisaligned = (desc->numBytes % engine->alignLength) != 0;
        BOOLEAN srcAddrMisaligned = (desc->srcAddrLo % engine->alignAddr) != 0;

        if (dstAddrMisaligned || lengthMisaligned || srcAddrMisaligned) {
            TraceVerbose(DBG_DESC, "descriptor alignments: src=0x%08llx, dst=0x%08llx, bytes=%llu",
                         desc->srcAddrLo, desc->dstAddrLo, desc->numBytes);
            TraceError(DBG_DESC, "misalignment detected! src?=%u dst?=%u length?=%u",
                       srcAddrMisaligned, dstAddrMisaligned, lengthMisaligned);
            return FALSE;
        }
    }
    return TRUE;
}

static void OptimizeDescriptors(IN XDMA_ENGINE *engine, IN DMA_DESCRIPTOR * const desc,
                                IN const ULONG numDesc)
    // Optimize descriptors for PCIe block fetches.
    // Multiple descriptors which reside in host memory can be fetched in a single PCIe transaction
    // by the device. This is achieved as follows:
    //      - For the first fetch, the number of additional (adjacent) descriptors to fetch is 
    //        specified by writing to engine->sgdma->firstDescAdj register. 
    //      - For subsequent fetches, the last descriptor of the previous fetch specifies the number of
    //        additional (adjacent) descriptors in the control->nextAdj field 
    // There are several factors which limit the amount of descriptors which can be fetched together:
    //      1. The PCIe Max Read Request Size
    //      2. The physical address of the descriptors within a block must not cross a 4K address 
    //         boundary
    //      3. The number of descriptors remaining in the transfer
{
    const ULONG mrrsBytes = 1 << (engine->parentDevice->configRegs->pcieMRRS + 7);
    const ULONG adjMax = mrrsBytes / sizeof(DMA_DESCRIPTOR) - 1;
    const ULONG adjTotal = numDesc - 1;
    const ULONG adjTo4k = (0x1000 - (engine->sgdma->firstDescLo & 0xFFF)) / sizeof(DMA_DESCRIPTOR) - 1;

    // set the number of adjacent descriptors for the first fetch
    ULONG firstAdj = adjTotal < adjMax ? adjTotal : adjMax;
    engine->sgdma->firstDescAdj = adjTo4k < firstAdj ? adjTo4k : firstAdj;
    //TraceVerbose(DBG_DMA, "first: PA=%04u, this4k=%04u, total=%04u, thisBlock=%04u",
    //             engine->sgdma->firstDescLo & 0xFFF, adjTo4k, adjTotal, engine->sgdma->firstDescAdj);

    // set the number of adjacent descriptors for subsequent fetches
    ULONG nextAdjMax = adjMax - 1;
    for (UINT i = 0; i < numDesc; i++) {
        // if not last desc then get total desc adj to next desc, else last desc has no next desc
        const ULONG nextAdjTotal = (i != adjTotal) ? adjTotal - (i + 1) : 0;
        const ULONG nextAdjTo4k = (0x1000 - (desc[i].nextLo & 0xFFF)) / sizeof(DMA_DESCRIPTOR) - 1;

        ULONG nextAdj = nextAdjTotal < nextAdjMax ? nextAdjTotal : nextAdjMax;
        if (nextAdj > nextAdjTo4k) {
            nextAdj = nextAdjTo4k;
        }

        desc[i].control |= (nextAdj << 8);
        //TraceVerbose(DBG_DMA, "next: PA=%04u, this4k=%04u, total=%04u, thisBlock=%04u",
        //             desc[i].nextLo & 0xFFF, nextAdjTo4k, nextAdjTotal, nextAdj);

        // update current max adj count for this block
        if (nextAdjMax != 0) {
            nextAdjMax--;
        } else { // wrap-around
            nextAdjMax = adjMax;
        }
    }
}

static BOOLEAN EngineExists(PXDMA_DEVICE xdma, DirToDev dir, ULONG channel) {
    const ULONG offset = (dir * BLOCK_OFFSET) + (channel * ENGINE_OFFSET);
    const ULONG engineEnd = offset + sizeof(XDMA_ENGINE_REGS);

    if (xdma->barLength[xdma->configBarIdx] < engineEnd) {
        return FALSE;
    }

    PUCHAR configBarAddr = (PUCHAR)xdma->bar[xdma->configBarIdx];
    XDMA_ENGINE_REGS* engineRegs = (XDMA_ENGINE_REGS*)(configBarAddr + offset);
    UINT32 engineID = engineRegs->identifier;
    return (engineID & XDMA_ID_MASK) == XDMA_ID;
}

static NTSTATUS EngineCreate(PXDMA_DEVICE xdma, XDMA_ENGINE* engine, DirToDev dir, ULONG channel,
                             ULONG engineIndex) {

    NTSTATUS status;

    engine->parentDevice = xdma;
    engine->channel = channel;
    engine->dir = dir;
    const ULONG offset = (dir * BLOCK_OFFSET) + (channel * ENGINE_OFFSET);
    const ULONG engineEnd = offset + SGDMA_BLOCK_OFFSET + sizeof(XDMA_SGDMA_REGS);

    // Проверка: хватит ли BAR'а для обращения к регистрам этого engine
    if (xdma->barLength[xdma->configBarIdx] < engineEnd) {
        TraceWarning(DBG_INIT, "EngineCreate: BAR too small for %s_%u (need %u, have %u)",
                     dir == H2C ? "H2C" : "C2H", channel,
                     engineEnd, xdma->barLength[xdma->configBarIdx]);
        return STATUS_DEVICE_CONFIGURATION_ERROR;
    }

    PUCHAR configBarAddr = (PUCHAR)xdma->bar[xdma->configBarIdx];
    engine->regs = (XDMA_ENGINE_REGS*)(configBarAddr + offset);
    engine->sgdma = (XDMA_SGDMA_REGS*)(configBarAddr + offset + SGDMA_BLOCK_OFFSET);

    // AXI-MM or AXI-ST? 0 = MM, 1 = ST
    engine->type = (engine->regs->identifier & XDMA_ID_ST_BIT) != 0;

    // Incremental or Non-Incremental address mode? 0 = inc, 1=non-inc
    engine->addressMode = (engine->regs->control & XDMA_CTRL_NON_INCR_ADDR) != 0;
    // DIAG 2026-10-03: по умолчанию база DDR3 добавляется (translateAxiBase=TRUE).
    // h2c_bram_0/c2h_bram_0 выставляют FALSE в EvtDeviceFileCreate.
    engine->translateAxiBase = TRUE;

    // set interrupt sources
    EngineConfigureInterrupt(engine, engineIndex);

    // create common buffer for poll mode descriptor write back - if used
    status = EngineCreatePollWriteBackBuffer(engine);
    if (!NT_SUCCESS(status)) {
        TraceError(DBG_INIT, "EngineCreatePollWriteBackBuffer() failed: %!STATUS!", status);
        return status;
    }

    // capture alignment requirements
    EngineGetAlignments(engine);

    // create and bind dma desciptor buffer to hw
    status = EngineCreateDescriptorBuffer(engine);
    if (!NT_SUCCESS(status)) {
        TraceError(DBG_INIT, "EngineCreateDescriptorBuffer() failed: %!STATUS!",
                   status);
        return status;
    }

    // PLAN-3 P1 2026-10-17: pre-allocate the descriptor-block pool. Pure
    // addition: slot 0 remains the live engine buffer (unchanged behaviour) and
    // slots 1..N-1 are parked until a future increment consumes them. On failure
    // the pool is rolled back internally and EngineCreate fails gracefully.
    status = EngineCreateDescriptorPool(engine);
    if (!NT_SUCCESS(status)) {
        TraceError(DBG_INIT, "EngineCreateDescriptorPool() failed: %!STATUS!", status);
        return status;
    }

    // allocate wdf dma transaction object
    status = WdfDmaTransactionCreate(xdma->dmaEnabler, WDF_NO_OBJECT_ATTRIBUTES,
                                     &engine->dmaTransaction);
    if (!NT_SUCCESS(status)) {
        TraceError(DBG_INIT, "WdfDmaTransactionCreate() failed: %!STATUS!", status);
        return status;
    }

    // PLAN-3 P2 2026-10-17: bind the legacy transaction to pool slot 0 and
    // pre-create the transaction pool. Pure addition: slot 0 keeps pointing at
    // engine->dmaTransaction (unchanged behaviour) and slots 1..N-1 are idle
    // WDFDMATRANSACTION objects parked for the P3 pipeliner. On failure the pool
    // is rolled back internally and EngineCreate fails gracefully.
    engine->dmaTxPool[0] = engine->dmaTransaction;
    status = EngineCreateTxPool(engine);
    if (!NT_SUCCESS(status)) {
        TraceError(DBG_INIT, "EngineCreateTxPool() failed: %!STATUS!", status);
        return status;
    }

    if ((engine->type == EngineType_ST) && (engine->dir == C2H)) {
        engine->work = EngineProcessRing;
        status = EngineCreateRingBuffer(engine);
        if (!NT_SUCCESS(status)) {
            TraceError(DBG_INIT, "EngineCreateStreamBuffers() failed: %!STATUS!", status);
            return status;
        }

        engine->parentDevice->sgdmaRegs->creditModeEnableW1S = BIT_N(engine->channel) << 16;
        TraceInfo(DBG_INIT, "creditModeEnable=0x%x", engine->parentDevice->sgdmaRegs->creditModeEnable);
    } else {
        engine->work = EngineProcessTransfer;
    }

    engine->enabled = TRUE;

    // spurious-irq protection (mirrors official Xilinx driver)
    engine->isReqPending = FALSE;
    engine->txnDone = FALSE;   // FIX 2026-10-15 (BSOD 0x10D): явная инициализация
    status = WdfSpinLockCreate(WDF_NO_OBJECT_ATTRIBUTES, &engine->engineLock);
    if (!NT_SUCCESS(status)) {
        TraceError(DBG_INIT, "EngineCreate: WdfSpinLockCreate failed: %!STATUS!", status);
        return status;
    }

    // REDUCED-ASYNC 2026-10-17: per-engine watchdog timer (async completion
    // fallback for a lost MSI-X). Period is set at WdfTimerStart time (10 ms);
    // the timer is NOT auto-repeating — each callback re-arms itself manually.
    // Parent is the WDFDEVICE so the timer lives exactly as long as the device.
    {
        WDF_TIMER_CONFIG timerCfg;
        WDF_TIMER_CONFIG_INIT(&timerCfg, EvtDmaWatchdogTimer);
        WDF_OBJECT_ATTRIBUTES timerAttr;
        WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&timerAttr, DMA_WATCHDOG_CTX);
        timerAttr.ParentObject = engine->parentDevice->wdfDevice;
        status = WdfTimerCreate(&timerCfg, &timerAttr, &engine->watchdogTimer);
        if (!NT_SUCCESS(status)) {
            TraceError(DBG_INIT, "EngineCreate: WdfTimerCreate failed: %!STATUS!", status);
            return status;
        }
        GetDmaWatchdogContext(engine->watchdogTimer)->engine = engine;
    }
    engine->watchdogBudget = 1000; // 1000 тиков x 10 мс = 10 с (как прежний WaitCompletion)
    engine->watchdogCount = 0;

    return status;
}

static void EngineGetAlignments(IN OUT XDMA_ENGINE *engine) {

    UINT32 alignments = 0;
    __try {
        alignments = engine->regs->alignments;
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        TraceWarning(DBG_INIT, "EngineGetAlignments: access violation on %s_%u, using defaults",
                     engine->dir == H2C ? "H2C" : "C2H", engine->channel);
    }

    UINT32 align_bytes = (alignments & 0x00ff0000U) >> 16;
    UINT32 granularity_bytes = (alignments & 0x0000ff00U) >> 8;
    UINT32 address_bits = (alignments & 0x000000ffU);

    if (alignments) {
        engine->alignAddr = align_bytes;
        engine->alignLength = granularity_bytes;
        engine->alignAddrBits = address_bits;
    } else {
        // FIX-ROF 2026-09-28: weak defaults (1/1) let sub-MPS, misaligned SG
        // elements reach the engine -> PCIe Receiver Overflow (BugCheck 0x124,
        // AER ROF) seen during loopback. Default to XDMA_MPS_BYTES (256B)
        // alignment so descriptors are always multiples of the PCIe payload.
        engine->alignAddr = XDMA_MPS_BYTES;       // 256
        engine->alignLength = XDMA_MPS_BYTES;     // 256
        engine->alignAddrBits = 64;
    }

    TraceVerbose(DBG_INIT, "engine[%u][%u] alignments: bytes=%u, granularity=%u, addrBits=%u",
                 engine->channel, engine->dir, engine->alignAddr, engine->alignLength, engine->alignAddrBits);

}

static UINT32 EngineStatus(IN XDMA_ENGINE *engine, IN BOOLEAN clear)
// read and optionally clear the engine status
{
    UINT32 status = 0;

    if (clear) { // request to clear engine status after read? 
        TraceVerbose(DBG_DMA, "%s_%u engine status cleared after next read",
                     DirectionToString(engine->dir), engine->channel);
        status = engine->regs->statusRC;
    } else {
        status = engine->regs->status;
    }

    TraceInfo(DBG_DMA, "%s_%u status=0x%08x (%s%s%s%s%s%s%s%s%s)",
              DirectionToString(engine->dir), engine->channel, status,
              (status & XDMA_BUSY_BIT) ? "BUSY " : "IDLE ",
              (status & XDMA_DESCRIPTOR_STOPPED_BIT) ? "DESCRIPTOR_STOPPED " : " ",
              (status & XDMA_DESCRIPTOR_COMPLETED_BIT) ? "DESCRIPTOR_COMPLETED " : " ",
              (status & XDMA_ALIGN_MISMATCH_BIT) ? "ALIGN_MISMATCH " : " ",
              (status & XDMA_MAGIC_STOPPED_BIT) ? "MAGIC_STOPPED " : " ",
              (status & XDMA_FETCH_STOPPED_BIT) ? "FETCH_STOPPED" : " ",
              (status & XDMA_STAT_READ_ERROR) ? "READ_ERROR " : " ",
              (status & XDMA_STAT_DESCRIPTOR_ERROR) ? "DESCRIPTOR_ERROR " : " ",
              (status & XDMA_IDLE_STOPPED_BIT) ? "IDLE_STOPPED" : " ");

    return status;
}

BOOLEAN XDMA_EngineProgramDma(IN WDFDMATRANSACTION Transaction, IN WDFDEVICE Device,
                              IN WDFCONTEXT context, IN WDF_DMA_DIRECTION Direction,
                              IN PSCATTER_GATHER_LIST SgList)
    // this programs the engine to start a dma transfer
{
    UNREFERENCED_PARAMETER(Device);

    WDFREQUEST request = WdfDmaTransactionGetRequest(Transaction);
    WDF_REQUEST_PARAMETERS params;
    WDF_REQUEST_PARAMETERS_INIT(&params);
    WdfRequestGetParameters(request, &params);
    LONGLONG deviceOffset = (Direction == WdfDmaDirectionWriteToDevice) ?
        (SIZE_T)params.Parameters.Write.DeviceOffset :
        (SIZE_T)params.Parameters.Read.DeviceOffset;

    // get virtual and physical pointers to descriptor buffer
    XDMA_ENGINE * engine = (XDMA_ENGINE*)context;
    DMA_DESCRIPTOR *descriptor = (DMA_DESCRIPTOR*)WdfCommonBufferGetAlignedVirtualAddress(engine->descBuffer);

    // DIAG 2026-10-04 (E-19 / BUG-053): count every EvtProgramDma invocation so
    // we can see from user mode whether WDF programs packet 2+ of a multi-packet
    // (>512B) transaction (read via IOCTL_XDMA_DIAG_GET).
    engine->progDmaCalls++;

    // offset into the transaction (if it is split)
    deviceOffset += WdfDmaTransactionGetBytesTransferred(Transaction);

    // Central AXI-base translation for the HOST (clean "raw offset from
    // 0x80000000" contract). This Windows-upstream driver has NO pci->axi map
    // (unlike Linux), so the host passes a plain DDR3 offset; we add the AXI
    // base here for BOTH H2C (dstAddr) and C2H (srcAddr) since both use
    // deviceOffset below. Matches ADDRESS_MAP §6 (DDR3 @ 0x80000000).
    // DIAG 2026-10-03 (BRAM bypass): if the engine was opened via the *_bram_0
    // nodes (translateAxiBase=FALSE), do NOT add the base -> host drives the
    // full card address (0x0..0x1FFF = local BRAM, 0x80000000+ = DDR3).
    if (engine->translateAxiBase) {
        deviceOffset += XDMA_DDR3_AXI_BASE;
    }

    // FIX-ROF2 2026-10-05 (audit 3): reject card addresses that leave the DDR3 aperture
    // (0x80000000 + 256 MB). Otherwise XDMA issues a read/write to unmapped space, gets
    // AXI DECERR -> Completer-Abort/UR -> WHEA 0x124/ROF on the Root Port (8086:7f3c).
    if (engine->translateAxiBase && SgList != NULL) {
        ULONGLONG endOff = (ULONGLONG)deviceOffset;
        for (ULONG bi = 0; bi < SgList->NumberOfElements; bi++) {
            endOff += SgList->Elements[bi].Length;
        }
        if (endOff > XDMA_DDR3_AXI_BASE + 0x10000000ULL) {
            TraceError(DBG_DMA, "ROF-guard: card range [0x%llx..0x%llx] beyond DDR3 aperture; reject",
                       (ULONGLONG)deviceOffset, endOff);
            return FALSE;
        }
    }

    // DBG-SRCADDR 2026-09-28: always visible in DebugView (plain DbgPrint,
    // independent of WPP). Reports the exact card-side address and SG count
    // programmed for each H2C/C2H descriptor so the C2H-reads-wrong-region
    // mismatch (write=0xD2 read=0xD9@idx434) can be pinned to src/dst.
    DbgPrint("XDMA_DMA [%s] ch%u dir=%u progDma: cardAddr=0x%08x%08x descCount=%u\n",
             engine ? DirectionToString(engine->dir) : "?",
             engine ? engine->channel : 0xFFFFFFFF,
             (UINT)Direction,
             (UINT)(deviceOffset >> 32), (UINT)deviceOffset,
             SgList ? SgList->NumberOfElements : 0);

    TraceVerbose(DBG_DMA, "device addr=%lld, num descriptors=%d",
                 deviceOffset, SgList->NumberOfElements);

    // ============================================================================
    // FIX-ROF 2026-10-05: build ONE descriptor chain of <=XDMA_DESC_MAX_BYTES
    // slices so the XDMA receiver is never flooded (prevents PCIe Receiver-Overflow
    // / WHEA 0x124, see CHANGE_LOG_2026-09-27 §6N). This is a single engine run
    // (one WDF packet per request), so it does NOT reload the engine between
    // packets. The bank is sized for the worst-case 4-KB SG fragmentation
    // (XDMA_MAX_DESC_COUNT = 2048), so the clamp below is unreachable for legal
    // <=8 MB packets (see FIX-DESC 2026-10-20 in dma_engine.h).
    // ============================================================================
    const ULONG ne = SgList->NumberOfElements;
    ULONG total = 0;
    ULONG i;
    UINT64 reqBytes = 0;    // FIX-DESC 2026-10-20: payload the SG list actually asks for
    for (i = 0; i < ne; i++) {
        total += (ULONG)((SgList->Elements[i].Length + XDMA_DESC_MAX_BYTES - 1) / XDMA_DESC_MAX_BYTES);
        reqBytes += SgList->Elements[i].Length;
    }

    // safety clamp: never write past the allocated double-freeze bank
    SIZE_T descBankLens = WdfCommonBufferGetLength(engine->descBuffer) / sizeof(DMA_DESCRIPTOR);
    if (total > (ULONG)descBankLens) {
        // FIX-DESC 2026-10-20: kept as a hard clamp - writing past the bank would
        // corrupt host memory - but it must never fire silently. A legal <=8 MB
        // packet needs <=2048 descs (worst case one 4-KB MDL page per SG element)
        // and the bank now holds 2049, so reaching here means the SG list is
        // pathological and the TAIL OF THE PAYLOAD WILL NOT BE TRANSFERRED while
        // the request still reports success.
        TraceError(DBG_DMA,
                   "FIX-DESC: TRANSFER WILL BE INCOMPLETE - %llu bytes need %u descs, bank holds %Iu (max %Iu);"
                   " clamping, %u descs = tail of payload NOT programmed",
                   (unsigned long long)reqBytes, total, descBankLens, (SIZE_T)XDMA_MAX_DESC_COUNT,
                   total - (ULONG)descBankLens);
        total = (ULONG)descBankLens;
    }

    PHYSICAL_ADDRESS descBase = WdfCommonBufferGetAlignedLogicalAddress(engine->descBuffer);
    ULONG di = 0;                       // current descriptor index
    UINT64 devAddr = deviceOffset;      // running card address (AXI base already added)
    UINT64 progBytes = 0;               // FIX-DESC 2026-10-20: bytes actually described

    for (i = 0; i < ne && di < total; i++) {
        ULONG len = SgList->Elements[i].Length;
        PHYSICAL_ADDRESS ha = SgList->Elements[i].Address;
        UINT64 hostBase = ((UINT64)(ULONG)ha.HighPart << 32) | (UINT64)ha.LowPart;
        UINT64 off = 0;

        while (off < len && di < total) {
            ULONG cur = (len - off > XDMA_DESC_MAX_BYTES)
                        ? (ULONG)XDMA_DESC_MAX_BYTES
                        : (ULONG)(len - off);
            UINT64 hostCur = hostBase + off;
            descriptor[di].control = XDMA_DESC_MAGIC;
            descriptor[di].numBytes = cur;
            if (Direction == WdfDmaDirectionWriteToDevice) {
                descriptor[di].srcAddrLo = LIMIT_TO_32(hostCur);
                descriptor[di].srcAddrHi = (LONG)(hostCur >> 32);
                descriptor[di].dstAddrLo = LIMIT_TO_32(devAddr);
                descriptor[di].dstAddrHi = LIMIT_TO_32(devAddr >> 32);
            } else {
                descriptor[di].srcAddrLo = LIMIT_TO_32(devAddr);
                descriptor[di].srcAddrHi = LIMIT_TO_32(devAddr >> 32);
                descriptor[di].dstAddrLo = LIMIT_TO_32(hostCur);
                descriptor[di].dstAddrHi = (LONG)(hostCur >> 32);
            }

            // next descriptor bus address (physical slot di+1)
            if (di + 1 < total) {
                PHYSICAL_ADDRESS next = descBase;
                next.QuadPart += (di + 1) * sizeof(DMA_DESCRIPTOR);
                descriptor[di].nextLo = next.LowPart;
                descriptor[di].nextHi = next.HighPart;
            } else { // last descriptor
                descriptor[di].nextLo = 0;
                descriptor[di].nextHi = 0;
                descriptor[di].control |= (XDMA_DESC_STOP_BIT | XDMA_DESC_COMPLETED_BIT);
                if (engine->type == EngineType_ST) {
                    descriptor[di].control |= XDMA_DESC_EOP_BIT;
                }
            }

            if (engine->addressMode == AddressMode_Contiguous) {
                devAddr += cur;
            }

            if (FALSE == DescriptorIsAligned(engine, &(descriptor[di]))) {
                TraceWarning(DBG_DMA, "Error: Dma Transfer is not aligned");
            }
            off += cur;
            progBytes += cur;
            di++;
        }
    }

    // FIX-DESC 2026-10-20: exact, loud accounting if the clamp above fired. The
    // descriptor loop stops at `total`, so a truncated build shows up as
    // progBytes < reqBytes (SG list not fully consumed), not as di < total.
    // Flow unchanged - the engine still runs, but the loss is now visible.
    if (progBytes < reqBytes) {
        TraceError(DBG_DMA,
                   "FIX-DESC: TRANSFER INCOMPLETE - programmed %llu of %llu bytes (%llu bytes LOST) in %u descs",
                   (unsigned long long)progBytes, (unsigned long long)reqBytes,
                   (unsigned long long)(reqBytes - progBytes), di);
    }

    TraceVerbose(DBG_DMA, "progDma: %u SG -> %u desc descriptors (max %u B each)",
                 ne, di, (unsigned)XDMA_DESC_MAX_BYTES);

    OptimizeDescriptors(engine, descriptor, di);

    // FIX-ROF2 2026-10-05 (audit 3): (1) always set numDescriptors so the completion
    // poll in interrupt mode actually WAITS for the transfer (it was only set under
    // engine->poll == 0 before -> expected=0 -> XDMA_EngineWaitCompletion returned
    // SUCCESS immediately, leaving completion to a (unreliable) MSI-X -> C2H-BUSY/ROF).
    // (2) disable multi-descriptor prefetch (nextAdj=0) to smooth posted-write bursts
    // to the Root Port (reduces ROF on 8086:7f3c).
    engine->numDescriptors = di;
    engine->sgdma->firstDescAdj = 0;
    for (ULONG k2 = 0; k2 < di; k2++) {
        descriptor[k2].control &= (UINT32)~(0xFFu << 8); /* clear nextAdj[15:8] */
    }

    for (ULONG k = 0; k < di; k++) {
        DumpDescriptor(&(descriptor[k]));
    }

    // FIX 2026-10-04 (E-19 / BUG-053, option B2): reset the engine to idle BEFORE
    // EVERY packet start (stop RUN, read-and-clear status/BUSY, re-arm firstDesc).
    // The XDMA engine on this board does not continue to WDF packet 2..N on its
    // own: after packet 1 it lands in DESC_STOPPED|DESC_COMPLETED and a plain
    // EngineStart(same firstDesc) is ignored, so the host IRP hangs. ResetIdle
    // gives the engine a clean idle state so each packet starts from scratch.
    // Data is not affected (only engine status + descriptor pointer; descriptors
    // for this packet were already written above). See docs/DIAG_MULTIPACKET §6.
    XDMA_EngineResetIdle(engine);

    MemoryBarrier();

    // mark a request pending (spurious-irq guard, mirrors official driver)
    if (engine->engineLock) {
        WdfSpinLockAcquire(engine->engineLock);
        engine->isReqPending = TRUE;
        WdfSpinLockRelease(engine->engineLock);
    }

    // start the engine
    EngineStart(engine);

    MemoryBarrier();

    return TRUE;
}

NTSTATUS ProbeEngines(IN PXDMA_DEVICE xdma) {
    PAGED_CODE();

    ULONG engineIndex = 0;

    // iterate over H2C (FPGA performs PCIe reads towards FPGA),
    // then C2H (FPGA performs PCIe writes from FPGA)
    for (UINT dir = H2C; dir < 2; dir++) { // 0=H2C, 1=C2H
        for (ULONG ch = 0; ch < XDMA_MAX_NUM_CHANNELS; ch++) {

            if (EngineExists(xdma, dir, ch)) {
                XDMA_ENGINE* engine = &(xdma->engines[ch][dir]);
                NTSTATUS status = EngineCreate(xdma, engine, dir, ch, engineIndex);
                if (!NT_SUCCESS(status)) {
                    TraceError(DBG_INIT, "EngineCreate failed! %!STATUS!", status);
                    return status;
                }
                engineIndex++;
                TraceInfo(DBG_INIT, "%s_%u engine created (AXI-%s)",
                          DirectionToString(dir), ch, engine->type == EngineType_ST ? "ST" : "MM");
            } else {     // skip inactive engines
                TraceInfo(DBG_INIT, "Skipping non-existing engine %s_%u",
                          DirectionToString(dir), ch);
            }
        }
    }
    return STATUS_SUCCESS;
}

void EngineStart(IN XDMA_ENGINE *engine) {
    engine->regs->controlW1S = XDMA_CTRL_RUN_BIT;
    TraceInfo(DBG_DMA, "%s_%u engine started (control=0x%08x)",
              DirectionToString(engine->dir), engine->channel, engine->regs->control);
}

void EngineStop(IN XDMA_ENGINE *engine) {
    engine->regs->controlW1C = XDMA_CTRL_RUN_BIT;
    TraceInfo(DBG_DMA, "%s_%u engine stopped (control=0x%08x)",
              DirectionToString(engine->dir), engine->channel, engine->regs->control);
}

void XDMA_EngineResetIdle(IN XDMA_ENGINE *engine) {
    // Explicit reset back to a known idle state. C2H engine in this DFX build can
    // stay BUSY after a completed/aborted transfer; BUSY is cleared by reading
    // statusRC (read-and-clear) and by clearing RUN.
    // FIX-AUDIT-C2H 2026-09-30 (rev2): do NOT zero firstDescLo/Hi - they are
    // rearmed ONCE at EngineCreateDescriptorBuffer and NOT rewritten per-transfer
    // by XDMA_EngineProgramDma (that only writes firstDescAdj). Zeroing them would
    // make every subsequent C2H fetch sample address 0 -> descriptor error/hang.
    // Instead: halt RUN, read-clear busy/status, and RE-ARM firstDesc to the
    // descriptor buffer base so the next transfer starts from the real buffer.
    if (engine == NULL) return;
    engine->regs->controlW1C = XDMA_CTRL_RUN_BIT;   // stop
    (void)engine->regs->statusRC;                    // read-clear BUSY/errors
    (void)engine->regs->completedDescCount;          // observe (read-only)
    // re-arm the descriptor pointer to the persistent buffer (never leave 0)
    PHYSICAL_ADDRESS db = WdfCommonBufferGetAlignedLogicalAddress(engine->descBuffer);
    engine->sgdma->firstDescLo = db.LowPart;
    engine->sgdma->firstDescHi = db.HighPart;
    engine->sgdma->firstDescAdj = 0;
    MemoryBarrier();
    TraceInfo(DBG_DMA, "%s_%u reset idle (firstDesc rearmed, control=0x%08x, status=0x%08x)",
              DirectionToString(engine->dir), engine->channel,
              engine->regs->control, engine->regs->status);
}

void EngineEnableInterrupt(IN XDMA_ENGINE* engine) {
    if (!engine) {
        TraceError(DBG_IRQ, "engine ptr is NULL!");
        return;

    }
    engine->parentDevice->interruptRegs->channelIntEnableW1S = engine->irqBitMask;
    TraceInfo(DBG_IRQ, "%s_%u enabled interrupt", DirectionToString(engine->dir), engine->channel);
}

void EngineDisableInterrupt(IN XDMA_ENGINE* engine) {
    if (!engine) {
        TraceError(DBG_IRQ, "engine ptr is NULL");
        return;
    }
    engine->parentDevice->interruptRegs->channelIntEnableW1C = engine->irqBitMask;
    TraceInfo(DBG_IRQ, "%s_%u disabled interrupt", DirectionToString(engine->dir), engine->channel);
}

char* DirectionToString(const DirToDev dir) {
    return dir == H2C ? "H2C" : "C2H";
}

// ========================= streaming engine ============================================

static NTSTATUS EngineCreateRingBuffer(IN XDMA_ENGINE* engine) {

    // create dma result buffer
    size_t resultBufferSize = (XDMA_MAX_TRANSFER_SIZE / PAGE_SIZE + 2) * sizeof(DMA_RESULT);
    NTSTATUS status = WdfCommonBufferCreate(engine->parentDevice->dmaEnabler, resultBufferSize,
                                            WDF_NO_OBJECT_ATTRIBUTES, &engine->ring.results);
    if (!NT_SUCCESS(status)) {
        TraceError(DBG_INIT, "WdfCommonBufferCreate failed: %!STATUS!", status);
        return status;
    }
    PUCHAR resultBufferVA = (PUCHAR)WdfCommonBufferGetAlignedVirtualAddress(engine->ring.results);
    RtlZeroMemory(resultBufferVA, resultBufferSize);

    TraceVerbose(DBG_INIT, "engine[%u][%u] dma result buffer @ pa=0x%08llx",
                 engine->channel, engine->dir,
                 WdfCommonBufferGetAlignedLogicalAddress(engine->ring.results).QuadPart);

    // create dma data buffer
    PHYSICAL_ADDRESS low, high, skip;
    low.QuadPart = 0;
    high.QuadPart = 0xFFFFFFFFFFFFFFFF;
    skip.QuadPart = PAGE_SIZE;
    PMDL mdl = MmAllocatePagesForMdlEx(low, high, skip, XDMA_RING_NUM_BLOCKS * XDMA_RING_BLOCK_SIZE, MmNonCached, NormalPagePriority);
    if (!mdl) {
        TraceError(DBG_INIT, "MmAllocatePagesForMdlEx failed!");
        return STATUS_INTERNAL_ERROR;
    }

    PVOID rxBufferVa = MmMapLockedPagesSpecifyCache(mdl, KernelMode, MmNonCached, NULL, FALSE, NormalPagePriority);
    if (!rxBufferVa) {
        TraceError(DBG_INIT, "MmMapLockedPagesSpecifyCache failed!");
        return STATUS_INTERNAL_ERROR;
    }

    TraceInfo(DBG_INIT, "mdl VA=%p, byteCount=%u, next=%p", rxBufferVa, MmGetMdlByteCount(mdl), mdl->Next);

    // MDL ring
    for (UINT i = 0; i < XDMA_RING_NUM_BLOCKS; ++i) {
        engine->ring.mdl[i] = IoAllocateMdl((PUCHAR)rxBufferVa + (i * XDMA_RING_BLOCK_SIZE), XDMA_RING_BLOCK_SIZE, TRUE, FALSE, NULL);
        if (!engine->ring.mdl[i]) {
            TraceError(DBG_INIT, "IoAllocateMdl failed!");
            return STATUS_INTERNAL_ERROR;
        }
    }

    for (UINT i = 0; i < XDMA_RING_NUM_BLOCKS; ++i) {
        TraceVerbose(DBG_INIT, "sub-mdl VA=%p, byteCount=%u, next=%p",
                     MmGetMdlVirtualAddress(engine->ring.mdl[i]),
                     MmGetMdlByteCount(engine->ring.mdl[i]),
                     engine->ring.mdl[i]->Next);
    }

    status = WdfSpinLockCreate(WDF_NO_OBJECT_ATTRIBUTES, &engine->ring.lock);
    if (!NT_SUCCESS(status)) {
        TraceError(DBG_INIT, "WdfSpinLockCreate failed: %!STATUS!", status);
        return status;
    }

    KeInitializeEvent(&engine->ring.completionSignal, NotificationEvent, FALSE);

    return status;
}

static UINT EngineProcessRing(IN XDMA_ENGINE *engine) {

    UINT32 engineStatus = EngineStatus(engine, TRUE);
    if (engineStatus & XDMA_ALIGN_MISMATCH_BIT & XDMA_MAGIC_STOPPED_BIT & XDMA_FETCH_STOPPED_BIT
        & XDMA_STAT_READ_ERROR & XDMA_STAT_DESCRIPTOR_ERROR) {
        TraceError(DBG_DMA, "Engine error during transfer! 0x%08x", engineStatus);
    }
    UINT eopCount = 0;
    DMA_RESULT* results = (DMA_RESULT*)WdfCommonBufferGetAlignedVirtualAddress(engine->ring.results);

    WdfSpinLockAcquire(engine->ring.lock);
    UINT tail = engine->ring.tail;
    UINT head = engine->ring.head;
    WdfSpinLockRelease(engine->ring.lock);

    TraceInfo(DBG_DMA, "%s_%u ring head=%u, tail=%u, eop=%u, credits=%u",
              DirectionToString(engine->dir), engine->channel, head, tail, eopCount,
              engine->sgdma->descCredits);

    for (; results[tail].status; EngineRingAdvance(&tail)) {

        if (results[tail].status & XDMA_RESULT_EOP_BIT) {
            eopCount++;
        }

        results[tail].status = 0; // mark current dma result as processed
    }

    TraceInfo(DBG_DMA, "%s_%u ring head=%u, tail=%u, eop=%u, credits=%u",
              DirectionToString(engine->dir), engine->channel, head, tail, eopCount,
              engine->sgdma->descCredits);

    WdfSpinLockAcquire(engine->ring.lock);
    engine->ring.tail = tail;
    WdfSpinLockRelease(engine->ring.lock);

    // If any packets are completed, start the Io Read queue 
    // also start the queue on an overflow since we need to tell the client that an overflow happened
    if (eopCount > 0) {
        TraceVerbose(DBG_DMA, "starting engine queue");
        KeSetEvent(&engine->ring.completionSignal, IO_NO_INCREMENT, FALSE);
    }


    // clear poll writeback buffer
    if (engine->poll) {
        XDMA_POLL_WB* wbBuffer = (XDMA_POLL_WB*)WdfCommonBufferGetAlignedVirtualAddress(engine->pollWbBuffer);
        size_t wbBufferLength = WdfCommonBufferGetLength(engine->pollWbBuffer);
        RtlZeroMemory(wbBuffer, wbBufferLength);
        engine->numDescriptors = 0;
    }

    return eopCount;
}

static void EngineRingProgramDma(IN XDMA_ENGINE* engine) {

    // get virtual and physical pointers to descriptor buffer
    DMA_DESCRIPTOR *descriptor = (DMA_DESCRIPTOR*)WdfCommonBufferGetAlignedVirtualAddress(engine->descBuffer);
    PHYSICAL_ADDRESS nextDescLA = WdfCommonBufferGetAlignedLogicalAddress(engine->descBuffer);

    // get physical address to dma result buffer
    PHYSICAL_ADDRESS resultBufferLA = WdfCommonBufferGetAlignedLogicalAddress(engine->ring.results);

    // fill descriptors 
    for (ULONG i = 0; i < XDMA_RING_NUM_BLOCKS; ++i) {
        descriptor[i].control = (XDMA_DESC_MAGIC | XDMA_DESC_EOP_BIT | XDMA_DESC_COMPLETED_BIT);
        descriptor[i].numBytes = XDMA_RING_BLOCK_SIZE;

        // source address are unused, will be overwritten by hardware with dma result
        descriptor[i].srcAddrLo = resultBufferLA.LowPart;
        descriptor[i].srcAddrHi = resultBufferLA.HighPart;
        resultBufferLA.QuadPart += sizeof(DMA_RESULT);

        // destination is host memory
        PHYSICAL_ADDRESS dst = MmGetPhysicalAddress(MmGetMdlVirtualAddress(engine->ring.mdl[i]));
        descriptor[i].dstAddrLo = dst.LowPart;
        descriptor[i].dstAddrHi = dst.HighPart;

        // next descriptor bus address 
        nextDescLA.QuadPart += sizeof(DMA_DESCRIPTOR);
        descriptor[i].nextLo = nextDescLA.LowPart;
        descriptor[i].nextHi = nextDescLA.HighPart;

        if (FALSE == DescriptorIsAligned(engine, descriptor)) {
            TraceWarning(DBG_DMA, "Error: Dma Transfer is not aligned");
        }
    }

    // make the discriptor list circular
    nextDescLA = WdfCommonBufferGetAlignedLogicalAddress(engine->descBuffer);
    DMA_DESCRIPTOR* last = &descriptor[XDMA_RING_NUM_BLOCKS - 1];
    last->nextLo = nextDescLA.LowPart;
    last->nextHi = nextDescLA.HighPart;

    // Optimize for PCIe fetches
    OptimizeDescriptors(engine, descriptor, XDMA_RING_NUM_BLOCKS);

    // Print to log
    TraceVerbose(DBG_DMA, "first desc @ 0x%08x%08x",
                 engine->sgdma->firstDescHi, engine->sgdma->firstDescLo);
    for (ULONG i = 0; i < XDMA_RING_NUM_BLOCKS; i++) {
        DumpDescriptor(&(descriptor[i]));
    }
    TraceVerbose(DBG_DMA, "last desc points to 0x%08x%08x", last->nextHi, last->nextLo);

    if (engine->poll) {
        engine->numDescriptors = 0;
    }

    // set initial descriptor credits for throtteling
    engine->sgdma->descCredits = XDMA_RING_NUM_BLOCKS - 1;
    TraceInfo(DBG_DMA, "%s_%u set %u initial descriptor credits",
              DirectionToString(engine->dir), engine->channel, engine->sgdma->descCredits);

    MemoryBarrier();

    // start the engine
    EngineStart(engine);

    MemoryBarrier();
}

static void EngineClearDmaResults(IN XDMA_ENGINE *engine) {
    TraceVerbose(DBG_DMA, "clearing DMA results...");
    DMA_RESULT * results = (DMA_RESULT*)WdfCommonBufferGetAlignedVirtualAddress(engine->ring.results);
    for (UINT i = 0; i < XDMA_RING_NUM_BLOCKS; ++i) {
        results[i].status = 0;
        results[i].length = 0;
    }
}

static void EngineRingAdvance(UINT* index) {
    if (*index == XDMA_RING_NUM_BLOCKS - 1) { // wrap-around
        *index = 0;
    } else { // normal increment
        ++(*index);
    }
}

void EngineRingSetup(IN XDMA_ENGINE *engine) {
    engine->ring.head = 0;
    engine->ring.tail = 0;
    KeClearEvent(&engine->ring.completionSignal);
    EngineRingProgramDma(engine);
}

void EngineRingTeardown(IN XDMA_ENGINE *engine) {
    EngineStop(engine);
    EngineClearDmaResults(engine);
    engine->ring.head = 0;
    engine->ring.tail = 0;
}

NTSTATUS EngineRingCopyBytesToMemory(IN XDMA_ENGINE *engine, WDFMEMORY outputMem, 
                                   size_t length, LARGE_INTEGER timeout, size_t* bytesRead ) {
    NTSTATUS status = 0;
    if (engine->poll) { // poll mode - poll for completion
        status = EnginePollRing(engine);
        if (!NT_SUCCESS(status)) {
            goto ErrorExit;
        }
    } else { // interrupt mode - wait for completion signal
        status = KeWaitForSingleObject(&engine->ring.completionSignal, Executive, KernelMode, FALSE, &timeout);
        if (status == STATUS_TIMEOUT) {
            goto ErrorExit;
        }
    }

    DMA_RESULT* results = (DMA_RESULT*)WdfCommonBufferGetAlignedVirtualAddress(engine->ring.results);
    size_t offset = 0;
    UINT32 numDescProcessed = 0;
    size_t numBytesRemaining = length;
    WdfSpinLockAcquire(engine->ring.lock);
    UINT head = engine->ring.head;
    UINT tail = engine->ring.tail;
    WdfSpinLockRelease(engine->ring.lock);

    TraceVerbose(DBG_DMA, "%s_%u head=%u, tail=%u, credits=%u",
                 DirectionToString(engine->dir), engine->channel, head, tail, engine->sgdma->descCredits);

    while ((head != tail) && numBytesRemaining) {

        // get dma ring buffer address and bytes transferred
        PVOID rxBufferVa = MmGetMdlVirtualAddress(engine->ring.mdl[head]);
        size_t numBytesReceived = results[head].length;

        // limit buffer size
        if (numBytesReceived > numBytesRemaining) {
            numBytesReceived = numBytesRemaining;
        } else if (numBytesReceived == 0) {
            KeClearEvent(&engine->ring.completionSignal);
            break;
        }

        // copy to user
        status = WdfMemoryCopyFromBuffer(outputMem, offset, rxBufferVa, numBytesReceived);
        if (!NT_SUCCESS(status)) {
            TraceError(DBG_DMA, "WdfMemoryCopyFromBuffer failed: %!STATUS!", status);
            goto ErrorExit;
        }

        numDescProcessed++;
        offset += numBytesReceived;
        numBytesRemaining -= numBytesReceived;

        results[head].length = 0;
        EngineRingAdvance(&head);
    }

    if (results[head].length == 0) {
        KeClearEvent(&engine->ring.completionSignal);
    }

    WdfSpinLockAcquire(engine->ring.lock);
    engine->ring.head = head;
    engine->sgdma->descCredits = numDescProcessed;
    WdfSpinLockRelease(engine->ring.lock);

    *bytesRead = length - numBytesRemaining;

    TraceVerbose(DBG_DMA, "%s_%u read %lluB available,  head=%u, tail=%u, credits=%u",
                 DirectionToString(engine->dir), engine->channel, *bytesRead, head, tail,
                 engine->sgdma->descCredits);

ErrorExit:
    return status;
}

//========================= polling interface =====================================================

static NTSTATUS EngineCreatePollWriteBackBuffer(IN OUT XDMA_ENGINE *engine) {
    // allocate host-side buffer for poll mode descriptor write back info

    NTSTATUS status = WdfCommonBufferCreate(engine->parentDevice->dmaEnabler, sizeof(XDMA_POLL_WB),
                                            WDF_NO_OBJECT_ATTRIBUTES, &engine->pollWbBuffer);
    if (!NT_SUCCESS(status)) {
        TraceError(DBG_INIT, "WdfCommonBufferCreate failed: %!STATUS!", status);
        return status;
    }

    PHYSICAL_ADDRESS wbBufferLA = WdfCommonBufferGetAlignedLogicalAddress(engine->pollWbBuffer);
    PUCHAR wbBufferVA = (PUCHAR)WdfCommonBufferGetAlignedVirtualAddress(engine->pollWbBuffer);
    RtlZeroMemory(wbBufferVA, sizeof(XDMA_POLL_WB));

    engine->regs->pollModeWbLo = wbBufferLA.LowPart;
    engine->regs->pollModeWbHi = wbBufferLA.HighPart;

    TraceInfo(DBG_INIT, "poll wb buffer at 0x%08x%08x, size=%lld",
              engine->regs->pollModeWbHi, engine->regs->pollModeWbLo, sizeof(XDMA_POLL_WB));
    return status;
}

NTSTATUS EnginePollTransfer(IN XDMA_ENGINE* engine) {

    XDMA_POLL_WB* writeback_data = (XDMA_POLL_WB*)WdfCommonBufferGetAlignedVirtualAddress(engine->pollWbBuffer);
    const ULONG expected = engine->numDescriptors;
    volatile ULONG actual = 0;

    do {
        actual = writeback_data->completedDescCount;

        if (actual & XDMA_WB_ERR_MASK) {
            TraceError(DBG_DMA, "error on writeback %u", actual);
            return STATUS_INTERNAL_ERROR;
        }
        actual &= XDMA_WB_COUNT_MASK;

        if (actual > expected) {
            actual = expected | XDMA_WB_ERR_MASK;
        }
    } while (expected != actual);

    TraceVerbose(DBG_DMA, "%u descriptors completed", actual);

    EngineProcessTransfer(engine);

    return STATUS_SUCCESS;
}

NTSTATUS XDMA_EngineWaitCompletion(IN XDMA_ENGINE* engine, IN ULONG maxIterations)
// Bounded completion poll: wait (with a hard iteration cap) until the engine
// finishes the current transfer by reading its completedDescCount register,
// then invoke EngineProcessTransfer. Fallback for when the channel interrupt
// does not reach the host (MSI-X not delivered). Differs from
// EnginePollTransfer (which spins forever on the writeback buffer) by using
// the SGDMA status register with a finite iteration bound, so a dead FPGA
// cannot hang the system.
{
    if (engine == NULL) {
        return STATUS_INVALID_PARAMETER;
    }

    const ULONG expected = engine->numDescriptors;
    ULONG iter = 0;
    // FIX-AUDIT-VS 2026-10-20 (D4): 50us * maxIterations (200000) is ~10 s of a
    // fully busy core, and this poll runs at PASSIVE (queue thread). Sleep
    // instead: 50us*20 == 1 ms, so cap the sleeps at maxIterations/20 to keep the
    // same ~10 s bound. At DISPATCH_LEVEL sleeping is illegal -> busy-wait there.
    const ULONG passiveMaxIter = maxIterations / 20;
    ULONG passiveIters = 0;

    // BUSY clears via reading statusRC: the XDMA engine clears its BUSY status
    // when software reads the read-and-clear status register. If we poll the
    // read-only `status` register instead, BUSY never clears and the engine
    // never signals completion -> every transfer times out. So we must read
    // statusRC here to both observe AND clear BUSY. To avoid swallowing the
    // error bits (the earlier bug), we record the raw status and pass it into
    // EngineProcessTransfer below (which then reads statusRC as the last
    // owner). EngineProcessTransfer reads statusRC once itself; if it read
    // zero because we cleared it, that is how a clean STOP looks anyway.
    for (iter = 0; iter < maxIterations; iter++) {
        volatile UINT32* completed = &engine->regs->completedDescCount;
        ULONG actual = *completed;

        // read-and-clear: this is what clears BUSY so the engine can finish
        UINT32 status = engine->regs->statusRC;
        BOOLEAN hwDone = (status & XDMA_BUSY_BIT) == 0;

        if (hwDone && actual >= expected) {
            EngineProcessTransfer(engine);
            return STATUS_SUCCESS;
        }

        // FIX-AUDIT-VS 2026-10-20 (D4): sleep at PASSIVE, busy-wait at DISPATCH.
        if (KeGetCurrentIrql() == PASSIVE_LEVEL) {
            LARGE_INTEGER interval;     // MSVC C mode: no designated initializer
            interval.QuadPart = -10000; // relative, 100-ns units => 1 ms
            KeDelayExecutionThread(KernelMode, FALSE, &interval);
            if (++passiveIters >= passiveMaxIter) {
                break; // PASSIVE bound reached (same ~10 s as the 50us path)
            }
        } else {
            KeStallExecutionProcessor(50); // 50us
        }
    }

    // FIX-AUDIT-C2H 2026-09-30: on timeout, also clear the spurious-irq guard
    // so a late interrupt cannot touch a released transaction.
    // FIX-BUG-064 2026-10-20 (аудит-VS P1-1 / реестр 39 D-4): на таймауте poll-путь
    // обязан ЗАХВАТИТЬ владение транзакцией (CAS txnDone FALSE->TRUE под
    // engineLock). Раньше гасился только isReqPending: поздний DPC (передача
    // дошла сразу после истечения итераций) проходил txnDone-guard, делал
    // Release/DmaCompleted уже ПОСЛЕ того, как вызывающий (EvtIoReadDma/
    // EvtIoWriteDma) завершил IRP по STATUS_TIMEOUT -> двойное завершение
    // (BSOD 0x10D/0xE6). Владелец дополнительно глушит движок EngineStop,
    // чтобы зависшая передача не породила новых DPC после Release.
    // Если txnDone уже TRUE (DPC/cancel успели стать владельцем между последней
    // итерацией и этим спинлоком) — возвращаем STATUS_CANCELLED: вызывающий НЕ
    // имеет права трогать request/транзакцию, IRP завершает владелец.
    TraceError(DBG_DMA, "XDMA_EngineWaitCompletion TIMEOUT %u descriptors "
               "(completed=%u, status=0x%08x) after %u iters",
               expected, engine->regs->completedDescCount,
               engine->regs->status, iter);
    {
        BOOLEAN owner = TRUE;   // нет спинлока — сохраняем прежнее поведение
        if (engine->engineLock) {
            WdfSpinLockAcquire(engine->engineLock);
            engine->isReqPending = FALSE;
            owner = !engine->txnDone;
            if (owner) {
                engine->txnDone = TRUE;
                engine->txnTimeout = TRUE;   // poll-owner will NOT complete   // poll-путь становится владельцем
            }
            WdfSpinLockRelease(engine->engineLock);
        } else {
            engine->isReqPending = FALSE;
        }
        if (owner) {
            EngineStop(engine);
            return STATUS_TIMEOUT;
        }
        return STATUS_CANCELLED;   // IRP завершает другой владелец — не трогаем
    }
}

NTSTATUS EnginePollRing(IN XDMA_ENGINE* engine) {
    XDMA_POLL_WB* writeback_data = (XDMA_POLL_WB*)WdfCommonBufferGetAlignedVirtualAddress(engine->pollWbBuffer);
    volatile ULONG completed = 0;
    volatile UINT eopCount = 0;
    UINT tryCount = 0;
    do {
        completed = writeback_data->completedDescCount;


        if (completed & XDMA_WB_ERR_MASK) {
            TraceError(DBG_DMA, "error on writeback %u", completed);
            return STATUS_INTERNAL_ERROR;
        }
        if (completed) {
            eopCount = EngineProcessRing(engine);
            TraceVerbose(DBG_DMA, "complete=%u, eop=%u", completed, eopCount);
        }
        tryCount++;
        if (tryCount >= 100000) {
            break;
        }

    } while (!eopCount);

    TraceVerbose(DBG_DMA, "complete=%u, eop=%u, tryCount=%u", completed, eopCount, tryCount);

    return STATUS_SUCCESS;
}

//========================= performance counters interface ========================================

void EngineStartPerf(IN XDMA_ENGINE* engine) {
    ASSERTMSG("argument engine is NULL!", engine != NULL);

    // Automatically stops performance counters when a descriptor with the stop bit is completed.
    engine->regs->perfCtrl = XDMA_PERF_CLEAR;
    engine->regs->perfCtrl = XDMA_PERF_AUTO | XDMA_PERF_RUN;
}

void EngineGetPerf(IN XDMA_ENGINE* engine, OUT XDMA_PERF_DATA* perfData) {
    TraceVerbose(DBG_DMA, "cycleCount=0x%08x%08x dataCount=0x%08x%08x pendingCount=0x%08x%08x",
                 engine->regs->perfCycHi, engine->regs->perfCycLo,
                 engine->regs->perfDatHi, engine->regs->perfDatLo,
                 engine->regs->perfPndHi, engine->regs->perfPndLo);

    ASSERTMSG("argument engine is NULL!", engine != NULL);
    ASSERTMSG("argument perfData is NULL!", perfData != NULL);

    perfData->clockCycleCount = ((UINT64)engine->regs->perfCycHi << 32) + engine->regs->perfCycLo;
    perfData->dataCycleCount = ((UINT64)engine->regs->perfDatHi << 32) + engine->regs->perfDatLo;
    perfData->pendingCount = ((UINT64)engine->regs->perfPndHi << 32) + engine->regs->perfPndHi;
}

void XDMA_EngineSetPollMode(XDMA_ENGINE* engine, BOOLEAN pollMode) {

    EXPECT(engine != NULL);

    if (engine->enabled == TRUE) {
        if (pollMode) {
            //EngineDisableInterrupt(engine);
            engine->regs->controlW1S = XDMA_CTRL_POLL_MODE;
            engine->regs->controlW1C = XDMA_CTRL_IE_ALL;
        } else {
            engine->regs->controlW1C = XDMA_CTRL_POLL_MODE;
            engine->regs->controlW1S = XDMA_CTRL_IE_ALL;
            //EngineEnableInterrupt(engine);
        }
        engine->poll = pollMode;
    }
}