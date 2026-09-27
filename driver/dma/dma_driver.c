/*
 * dma_driver.c — автономный KMDF DMA-гейтвей для XDMA.
 *
 * Переиспользует ПОДЛИННЫЙ upstream-стек из xdma_driver_win_src_2017:
 *   - libxdma\device.c       (XDMA_DeviceOpen / XDMA_DeviceClose / MapBARs / WdfDmaEnabler)
 *   - libxdma\dma_engine.c   (ProbeEngines / SGDMA ProgramDma)
 *   - libxdma\interrupt.c    (SetupInterrupts)
 *   - sys\file_io.c          (FileNameLUT: control/user/h2c_N/c2h_N/event_N,
 *                            EvtDeviceFileCreate, EvtIoRead/Write + DMA)
 *
 * Этот файл — то самое «недостающее звено» (драйвер-гейтвей), которого нет в
 * дереве: upstream sys\driver.c в дереве ПОДМЕНЁН кастомной MMIO-копией
 * (см. DRIVER_DEVLOG.md §Внимание), а сам гейтвей отсутствует.
 *
 * Ключевые решения:
 *   - Символический линк \\.\XDMA0dma — НЕ конфликтует с рабочим \\.\XDMA0.
 *   - Ко всему добавлен device interface GUID_DEVINTERFACE_XDMA (для GUID-клиентов).
 *   - Анти-BSOD (вместо прежнего «отказ при малом BAR»): драйвер ЗАГРУЖАЕТСЯ
 *     независимо от размера не-config BAR (на DFX-сборке BAR2 = 64KB MSI-X,
 *     а не DDR3-мост). Загрузку не блокируем. Опасен только ЭКСПОНИРОВАННЫЙ
 *     пассив-BAR-доступ хоста, поэтому после XDMA_DeviceOpen принудительно
 *     ставим userBarIdx = bypassBarIdx = -1 — upstream file_io.c сам отклонит
 *     \\.\XDMA0dma\user и \\.\XDMA0dma\bypass (fatal PCIe AER -> BSOD 0x124
 *     исключён), а control + h2c/c2h работают через BAR0 (config).
 *   - IOCTL GET_BAR_INFO (pre-flight) обрабатываем своим диспетчером на default
 *     queue; для control/user узлов НЕ зовём upstream EvtIoDeviceControl, т.к.
 *     тот читает GetQueueContext(file->queue) с NULL (узел не DMA) -> bugcheck.
 *
 * Сборка: /entry:FxDriverEntry (см. build.cmd), security_cookie.c отдельно.
 */

// ========================= include dependencies =================================================

#include "dma_driver.h"
#include "xdma_public.h"
#include "file_io.h"

// ========================= forward declarations =================================================

EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL EvtIoControlDispatch;

static NTSTATUS EvtCreateEngineQueues(_In_ WDFDEVICE Device);

// ========================= DriverEntry ============================================================

NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT  DriverObject,
    _In_ PUNICODE_STRING RegistryPath
)
{
    WDF_DRIVER_CONFIG config;
    WDFDRIVER driver;

    WDF_DRIVER_CONFIG_INIT(&config, EvtDriverDeviceAdd);
    config.DriverPoolTag = 'XDMA';

    // WdfDriverCreate: точка входа /entry:FxDriverEntry в build.cmd (FIX-8), т.е.
    // стаб wdfdriverentry.lib проинициализирует WdfFunctions/WdfDriverGlobals ДО
    // этого вызова. Здесь обычный WdfDriverCreate без собственной обвязки.
    return WdfDriverCreate(
        DriverObject,
        RegistryPath,
        WDF_NO_OBJECT_ATTRIBUTES,
        &config,
        &driver
    );
}

// ========================= EvtDriverDeviceAdd ====================================================

NTSTATUS
EvtDriverDeviceAdd(
    _In_ WDFDRIVER        Driver,
    _Inout_ PWDFDEVICE_INIT DeviceInit
)
{
    WDFDEVICE device;
    PDEVICE_CONTEXT devCtx;
    WDF_OBJECT_ATTRIBUTES deviceAttributes;
    WDF_PNPPOWER_EVENT_CALLBACKS pnpCallbacks;
    WDF_FILEOBJECT_CONFIG fileObjectConfig;
    WDF_IO_QUEUE_CONFIG queueConfig;
    WDFQUEUE queue;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(Driver);

    // ---- PnP / power ----
    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnpCallbacks);
    pnpCallbacks.EvtDevicePrepareHardware  = EvtDevicePrepareHardware;
    pnpCallbacks.EvtDeviceReleaseHardware  = EvtDeviceReleaseHardware;
    WdfDeviceInitSetPnpPowerEventCallbacks(DeviceInit, &pnpCallbacks);

    // ---- FileObject config: под-ноды (control/user/h2c_N/c2h_N/event_N) ----
    // upstream file_io.c предоставляет EvtDeviceFileCreate/EvtFileClose/EvtFileCleanup.
    WDF_FILEOBJECT_CONFIG_INIT(
        &fileObjectConfig,
        EvtDeviceFileCreate,   // EVT_WDF_DEVICE_FILE_CREATE  (file_io.c)
        EvtFileClose,          // EVT_WDF_FILE_CLOSE          (file_io.c)
        EvtFileCleanup);       // EVT_WDF_FILE_CLEANUP        (file_io.c)
    WdfDeviceInitSetFileObjectConfig(
        DeviceInit,
        &fileObjectConfig,
        WDF_NO_OBJECT_ATTRIBUTES);

    // Buffered/Direct I/O: BAR-read/write в file_io.c идут через
    // WdfRequestRetrieve*Memory (работает для обоих), а DMA-транзакции
    // (WdfDmaTransactionInitializeUsingRequest) требуют прямого доступа к буферу;
    // BufferedOrDirect даёт WDF сам выбрать оптимальный путь.
    WdfDeviceInitSetIoType(DeviceInit, WdfDeviceIoBufferedOrDirect);

    // ---- Create device ----
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&deviceAttributes, DEVICE_CONTEXT);
    status = WdfDeviceCreate(&DeviceInit, &deviceAttributes, &device);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    devCtx = GetDeviceContext(device);
    devCtx->bar0PhysAddr = 0;
    devCtx->bar0Length   = 0;
    // WDFQUEUE == NULL трактуем как "очередь ещё не создана" (создаём в PrepareHardware).
    RtlZeroMemory(devCtx->engineQueue, sizeof(devCtx->engineQueue));

    // ---- Device interface (для GUID-клиентов) ----
    status = WdfDeviceCreateDeviceInterface(
        device,
        &GUID_DEVINTERFACE_XDMA,
        NULL);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    // ---- Symbolic link \\.\XDMA0dma (не конфликтует с \\.\XDMA0 у MMIO-драйвера) ----
    // upsteram FileNameLUT (file_io.c:46) сопоставляет имена, возвращаемые
    // WdfFileObjectGetFileName(), т.е. при открытии \\.\XDMA0dma\control
    // fileName = "\control" -> DEVNODE_TYPE_CONTROL. Ссылки достаточно.
    UNICODE_STRING symLink;
    RtlInitUnicodeString(&symLink, L"\\DosDevices\\XDMA0dma");
    status = WdfDeviceCreateSymbolicLink(device, &symLink);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    // ---- Default queue (control/user/events + чтение/запись; forward на DMA) ----
    // EvtIoRead/EvtIoWrite/EvtIoDeviceControl определены в ПОДЛИННОМ file_io.c.
    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&queueConfig, WdfIoQueueDispatchSequential);
    queueConfig.EvtIoRead           = EvtIoRead;          // file_io.c
    queueConfig.EvtIoWrite          = EvtIoWrite;         // file_io.c
    // IOCTL-диспетчер СВОЙ (GET_BAR_INFO + страховка от NULL file->queue),
    // upstream EvtIoDeviceControl вызываем только для DMA-узлов.
    queueConfig.EvtIoDeviceControl  = EvtIoControlDispatch;

    status = WdfIoQueueCreate(device, &queueConfig, WDF_NO_OBJECT_ATTRIBUTES, &queue);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    return STATUS_SUCCESS;
}

// ========================= EvtDevicePrepareHardware ==============================================

NTSTATUS
EvtDevicePrepareHardware(
    _In_ WDFDEVICE      Device,
    _In_ WDFCMRESLIST   ResourcesRaw,
    _In_ WDFCMRESLIST   ResourcesTranslated
)
{
    PDEVICE_CONTEXT devCtx = GetDeviceContext(Device);
    NTSTATUS status;

    // Открыть и проинициализировать XDMA-стек (BAR-маппинг, DMA enabler, прерывания, engines).
    status = XDMA_DeviceOpen(Device, &devCtx->xdma, ResourcesRaw, ResourcesTranslated);
    if (!NT_SUCCESS(status)) {
        DbgPrint("XDMA_DMA: XDMA_DeviceOpen failed 0x%08x\n", status);
        return status;
    }

    // ===== Анти-BSOD: не даём хост-клиенту открыть small (MSI-X) BAR =====
    // В DFX-сборке: BAR0 = config-бар (AXI-Lite), второй memory-BAR = 64KB MSI-X
    // table (pf0_msix_cap_table_bir), а НЕ DDR3-мост. DDR3 доступен ТОЛЬКО через
    // каналы DMA (h2c/c2h). Если хост откроет узел \user или \bypass, указывающий
    // на MSI-X page, и запишет туда -> fatal PCIe AER -> BSOD 0x124.
    //
    // РЕШЕНИЕ (НЕ блокируем загрузку драйвера!): маленький MSI-X BAR сам по себе
    // не является поводом для отказа — драйвер загружается, а control и DMA-каналы
    // (h2c_0/c2h_0) работают через BAR0 (config). Опасен только ЭКСПОНИРОВАННЫЙ
    // доступ к bar[userBarIdx]/bar[bypassBarIdx].
    //
    // Механизм закрытия: upstream file_io.c EvtDeviceFileCreate САМ отказывает в
    // открытии \\.\XDMA0dma\user и \\.\XDMA0dma\bypass, если userBarIdx < 0 /
    // bypassBarIdx < 0 (file_io.c:124,131 -> STATUS_INVALID_PARAMETER). Индексы
    // читаются ИЗ XDMA_DEVICE ЛЕНИВО, в момент открытия файла, а не при маппинге.
    // Поэтому здесь, ПРАВИМ индексы после XDMA_DeviceOpen: даже если libxdma
    // IdentifyBars() вычислил bypassBarIdx на MSI-X BAR (всё равно сделает для
    // 2-resource стека: numBars - configBarIdx == 2), мы принудительно обнуляем
    // оба в -1. Тогда upstream-гейт гарантированно вернёт STATUS_INVALID_PARAMETER
    // на \user и \bypass. data race отсутствует: PrepareHardware завершается и
    // только потом устройство стартует и становится доступным приложениям.
    //
    // Диагностика: печатаем карту найденных BAR'ов и индексы до/после правки.

    for (UINT i = 0; i < devCtx->xdma.numBars; i++) {
        DbgPrint("XDMA_DMA: BAR%u length=0x%lx base=%p\n",
                 i, devCtx->xdma.barLength[i], devCtx->xdma.bar[i]);
    }
    DbgPrint("XDMA_DMA: pre-fix indices -> configBarIdx=%u userBarIdx=%d bypassBarIdx=%d\n",
             devCtx->xdma.configBarIdx,
             devCtx->xdma.userBarIdx,
             devCtx->xdma.bypassBarIdx);

    // Запрещаем host-доступ к user/bypass BAR'ам (в т.ч. MSI-X BAR2). Отказ СПЛАНИРОВАН:
    // драйвер загружается, control + h2c_0/c2h_0 работают через BAR0 (config).
    devCtx->xdma.userBarIdx = -1;
    devCtx->xdma.bypassBarIdx = -1;

    DbgPrint("XDMA_DMA: post-fix indices -> userBarIdx=%d bypassBarIdx=%d "
             "(user/bypass узлы недоступны хосту; загрузка НЕ блокируется)\n",
             devCtx->xdma.userBarIdx,
             devCtx->xdma.bypassBarIdx);

    // Pre-flight: сохраним BAR0 физический адрес/размер для GET_BAR_INFO.
    {
        ULONG n = WdfCmResourceListGetCount(ResourcesTranslated);
        for (ULONG i = 0; i < n; i++) {
            PCM_PARTIAL_RESOURCE_DESCRIPTOR r =
                WdfCmResourceListGetDescriptor(ResourcesTranslated, i);
            if (r && r->Type == CmResourceTypeMemory) {
                devCtx->bar0PhysAddr = r->u.Memory.Start.QuadPart;
                devCtx->bar0Length   = r->u.Memory.Length;
                break; // первый memory-resource = BAR0
            }
        }
    }

    // ---- Создание DMA engine queues (parallel, авто-диспатч DMA-хендлеров) ----
    status = EvtCreateEngineQueues(Device);
    if (!NT_SUCCESS(status)) {
        goto ErrClose;
    }

    return STATUS_SUCCESS;

ErrClose:
    XDMA_DeviceClose(&devCtx->xdma);
    return status;
}

// ========================= EvtDeviceReleaseHardware ==============================================

NTSTATUS
EvtDeviceReleaseHardware(
    _In_ WDFDEVICE      Device,
    _In_ WDFCMRESLIST   ResourcesTranslated
)
{
    PDEVICE_CONTEXT devCtx = GetDeviceContext(Device);

    UNREFERENCED_PARAMETER(ResourcesTranslated);

    XDMA_DeviceClose(&devCtx->xdma);
    return STATUS_SUCCESS;
}

// ========================= engine DMA queues =====================================================

// Создаёт 8 очередей (H2C_0..3, C2H_0..3) — по одной на каждый hardware-движок —
// и связывает их с QUEUE_CONTEXT.engine (нужен upstream EvtIoReadDma/
// EvtIoWriteDma/EvtIoDeviceControl, см. file_io.c).
//
// Dispatch = WdfIoQueueDispatchParallel: upstream file_io.c пересылает запросы
// H2C/C2H в эти очереди через WdfRequestForwardToIoQueue (file_io.c:335,378), а
// целевая очередь затем ДОСТАВЛЯЕТ запрос своим диспетчер-хендлерам
// (WDF-документация: "adds the request to the tail of a specified queue.
// Eventually the framework delivers the request to the driver again using the
// specified queue's dispatching method"). Эти хендлеры — EvtIoReadDma /
// EvtIoWriteDma / EvtIoDeviceControl из upstream file_io.c, что и задумано
// (file_io.c:335 comment: "completed by EvtIoReadDma later").
static NTSTATUS
EvtCreateEngineQueues(_In_ WDFDEVICE Device)
{
    PDEVICE_CONTEXT devCtx = GetDeviceContext(Device);
    NTSTATUS status = STATUS_SUCCESS;

    for (UINT dirIdx = H2C; dirIdx < XDMA_NUM_DIRECTIONS; dirIdx++) {
        for (ULONG ch = 0; ch < XDMA_MAX_NUM_CHANNELS; ch++) {
            XDMA_ENGINE *engine = &devCtx->xdma.engines[ch][dirIdx];
            WDF_OBJECT_ATTRIBUTES queueAttributes;
            WDF_IO_QUEUE_CONFIG queueConfig;

            // Очередь создаём для каждого hardware-движка. Для disabled-движка
            // узел всё равно не откроется (file_io.c:145 проверяет engine->enabled).
            WDF_IO_QUEUE_CONFIG_INIT(&queueConfig, WdfIoQueueDispatchParallel);
            queueConfig.EvtIoRead           = EvtIoReadDma;           // file_io.c
            queueConfig.EvtIoWrite          = EvtIoWriteDma;          // file_io.c
            queueConfig.EvtIoDeviceControl  = EvtIoDeviceControl;     // file_io.c

            WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&queueAttributes, QUEUE_CONTEXT);
            status = WdfIoQueueCreate(
                Device,
                &queueConfig,
                &queueAttributes,
                &devCtx->engineQueue[dirIdx][ch]);
            if (!NT_SUCCESS(status)) {
                return status;
            }

            GetQueueContext(devCtx->engineQueue[dirIdx][ch])->engine = engine;
        }
    }
    return STATUS_SUCCESS;
}

// ========================= IOCTL dispatcher (default queue) ======================================

VOID
EvtIoControlDispatch(
    _In_ WDFQUEUE  Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t   OutputBufferLength,
    _In_ size_t   InputBufferLength,
    _In_ ULONG    IoControlCode
)
{
    WDFDEVICE device = WdfIoQueueGetDevice(Queue);
    PDEVICE_CONTEXT devCtx = GetDeviceContext(device);
    NTSTATUS status = STATUS_NOT_SUPPORTED;
    size_t bytesReturned = 0;

    UNREFERENCED_PARAMETER(InputBufferLength);

    void *pBuf = NULL;
    size_t bufSize = 0;

    if (IoControlCode == IOCTL_XDMA_GET_BAR_INFO) {
        XDMA_DMA_BAR_INFO info = { 0 };

        if (OutputBufferLength < sizeof(info)) {
            status = STATUS_BUFFER_TOO_SMALL;
            goto exit;
        }

        info.Bar0PhysAddr = devCtx->bar0PhysAddr;
        info.Bar0Length   = devCtx->bar0Length;
        info.NumBars      = devCtx->xdma.numBars;
        info.UserBarIdx   = devCtx->xdma.userBarIdx;

        status = WdfRequestRetrieveOutputBuffer(
            Request, sizeof(info), &pBuf, &bufSize);
        if (!NT_SUCCESS(status)) {
            goto exit;
        }
        if (bufSize < sizeof(info)) {
            status = STATUS_BUFFER_TOO_SMALL;
            goto exit;
        }
        RtlCopyMemory(pBuf, &info, sizeof(info));
        bytesReturned = sizeof(info);
        status = STATUS_SUCCESS;
        goto exit;
    }

    // Иные IOCTL (PERF/ADDRMODE) — только для DMA-узлов, где есть file->queue.
    // Перед вызовом upstream EvtIoDeviceControl проверяем, что узел DMA:
    // для control/user узла file->queue == NULL, и GetQueueContext(NULL) внутри
    // file_io.c уронил бы систему (bugcheck).
    {
        WDFFILEOBJECT fileObject = WdfRequestGetFileObject(Request);
        PFILE_CONTEXT file = fileObject ? GetFileContext(fileObject) : NULL;

        if (file != NULL && file->queue != NULL) {
            // Узел h2c_N/c2h_N — делегируем подлинному upstream-обработчику.
            EvtIoDeviceControl(
                Queue, Request,
                OutputBufferLength,
                InputBufferLength,
                IoControlCode);
            return; // upstream-обработчик сам завершит запрос
        }
        status = STATUS_INVALID_PARAMETER; // IOCTL только на DMA-узлах
    }

exit:
    WdfRequestCompleteWithInformation(Request, status, bytesReturned);
}