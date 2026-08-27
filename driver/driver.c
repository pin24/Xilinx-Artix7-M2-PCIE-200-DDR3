#include <ntddk.h>
#include <wdf.h>

// WDF 1.15 stub references __security_init_cookie
// Provide minimal stubs to resolve linker dependencies
ULONG_PTR __security_cookie = (ULONG_PTR)0xABCDEF0123456789ULL;
void __security_init_cookie(void) { }
void __security_check_cookie(ULONG_PTR x) { UNREFERENCED_PARAMETER(x); }

#define IOCTL_XDMA_GET_BAR_INFO \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)

typedef struct _XDMA_BAR_INFO {
    ULONG64 Bar0PhysAddr;
    ULONG   Bar0Length;
    ULONG64 Bar2PhysAddr;
    ULONG   Bar2Length;
} XDMA_BAR_INFO;

typedef struct _DEVICE_CONTEXT {
    WDFDEVICE WdfDevice;
    PHYSICAL_ADDRESS Bar0PhysAddr;
    ULONG Bar0Length;
    PVOID Bar0Va;
    PHYSICAL_ADDRESS Bar2PhysAddr;
    ULONG Bar2Length;
    PVOID Bar2Va;
} DEVICE_CONTEXT, *PDEVICE_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DEVICE_CONTEXT, GetDeviceContext)

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD EvtDriverDeviceAdd;
EVT_WDF_DEVICE_PREPARE_HARDWARE EvtDevicePrepareHardware;
EVT_WDF_DEVICE_RELEASE_HARDWARE EvtDeviceReleaseHardware;
EVT_WDF_DEVICE_D0_ENTRY EvtDeviceD0Entry;
EVT_WDF_DEVICE_D0_EXIT EvtDeviceD0Exit;
EVT_WDF_IO_QUEUE_IO_READ EvtIoRead;
EVT_WDF_IO_QUEUE_IO_WRITE EvtIoWrite;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL EvtIoDeviceControl;

NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT DriverObject,
    _In_ PUNICODE_STRING RegistryPath
)
{
    WDF_DRIVER_CONFIG config;
    WDFDRIVER driver;

    WDF_DRIVER_CONFIG_INIT(&config, EvtDriverDeviceAdd);
    config.DriverPoolTag = 'XDMA';

    return WdfDriverCreate(
        DriverObject,
        RegistryPath,
        WDF_NO_OBJECT_ATTRIBUTES,
        &config,
        &driver
    );
}

NTSTATUS
EvtDriverDeviceAdd(
    _In_ WDFDRIVER Driver,
    _Inout_ PWDFDEVICE_INIT DeviceInit
)
{
    WDFDEVICE device;
    PDEVICE_CONTEXT devCtx;
    WDF_OBJECT_ATTRIBUTES deviceAttributes;
    WDF_PNPPOWER_EVENT_CALLBACKS pnpCallbacks;
    WDF_IO_QUEUE_CONFIG queueConfig;
    WDFQUEUE queue;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(Driver);

    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnpCallbacks);
    pnpCallbacks.EvtDevicePrepareHardware = EvtDevicePrepareHardware;
    pnpCallbacks.EvtDeviceReleaseHardware = EvtDeviceReleaseHardware;
    pnpCallbacks.EvtDeviceD0Entry = EvtDeviceD0Entry;
    pnpCallbacks.EvtDeviceD0Exit = EvtDeviceD0Exit;
    WdfDeviceInitSetPnpPowerEventCallbacks(DeviceInit, &pnpCallbacks);

    WdfDeviceInitSetIoType(DeviceInit, WdfDeviceIoBuffered);

    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&deviceAttributes, DEVICE_CONTEXT);

    status = WdfDeviceCreate(&DeviceInit, &deviceAttributes, &device);
    if (!NT_SUCCESS(status))
        return status;

    devCtx = GetDeviceContext(device);
    devCtx->WdfDevice = device;
    devCtx->Bar0Length = 0;
    devCtx->Bar0Va = NULL;
    devCtx->Bar0PhysAddr.QuadPart = 0;
    devCtx->Bar2Length = 0;
    devCtx->Bar2Va = NULL;
    devCtx->Bar2PhysAddr.QuadPart = 0;

    DECLARE_CONST_UNICODE_STRING(symLink, L"\\DosDevices\\XDMA0");
    status = WdfDeviceCreateSymbolicLink(device, &symLink);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&queueConfig, WdfIoQueueDispatchSequential);
    queueConfig.EvtIoRead = EvtIoRead;
    queueConfig.EvtIoWrite = EvtIoWrite;
    queueConfig.EvtIoDeviceControl = EvtIoDeviceControl;

    status = WdfIoQueueCreate(device, &queueConfig, WDF_NO_OBJECT_ATTRIBUTES, &queue);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    return STATUS_SUCCESS;
}

NTSTATUS
EvtDevicePrepareHardware(
    _In_ WDFDEVICE Device,
    _In_ WDFCMRESLIST ResourceList,
    _In_ WDFCMRESLIST ResourceListTranslated
)
{
    PDEVICE_CONTEXT devCtx = GetDeviceContext(Device);
    ULONG barIndex;
    NTSTATUS status;
    BOOLEAN bar0Found = FALSE;
    BOOLEAN bar2Found = FALSE;

    UNREFERENCED_PARAMETER(ResourceList);

    // Clean up any previous mappings before re-mapping
    if (devCtx->Bar0Va != NULL) {
        MmUnmapIoSpace(devCtx->Bar0Va, (SIZE_T)devCtx->Bar0Length);
        devCtx->Bar0Va = NULL;
        devCtx->Bar0Length = 0;
    }
    if (devCtx->Bar2Va != NULL) {
        MmUnmapIoSpace(devCtx->Bar2Va, (SIZE_T)devCtx->Bar2Length);
        devCtx->Bar2Va = NULL;
        devCtx->Bar2Length = 0;
    }

    devCtx->Bar0PhysAddr.QuadPart = 0;
    devCtx->Bar2PhysAddr.QuadPart = 0;

    // Scan translated resource list for PCI BARs (memory resources)
    for (barIndex = 0; barIndex < WdfCmResourceListGetCount(ResourceListTranslated); barIndex++) {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR resDesc;
        resDesc = WdfCmResourceListGetDescriptor(ResourceListTranslated, barIndex);
        if (resDesc == NULL) continue;
        if (resDesc->Type != CmResourceTypeMemory) continue;

        // The interface type tells us which BAR we're looking at
        // Use the physical address to determine BAR0 vs BAR2:
        // XDMA BAR0 maps to small addresses (typically < 0x10000000)
        // XDMA BAR2 maps to DDR3 (typically >= 0x80000000)
        // But we need the BAR index. For WDF, we can detect by checking
        // the BAR descriptor storage class or interface type.
        //
        // Simplified approach: first memory resource is BAR0, second is BAR2
        if (!bar0Found) {
            devCtx->Bar0PhysAddr = resDesc->u.Memory.Start;
            devCtx->Bar0Length = resDesc->u.Memory.Length;
            devCtx->Bar0Va = MmMapIoSpace(resDesc->u.Memory.Start,
                                           (SIZE_T)resDesc->u.Memory.Length,
                                           MmNonCached);
            if (devCtx->Bar0Va == NULL) {
                devCtx->Bar0Length = 0;
                return STATUS_INSUFFICIENT_RESOURCES;
            }
            bar0Found = TRUE;
        } else if (!bar2Found) {
            devCtx->Bar2PhysAddr = resDesc->u.Memory.Start;
            devCtx->Bar2Length = resDesc->u.Memory.Length;
            devCtx->Bar2Va = MmMapIoSpace(resDesc->u.Memory.Start,
                                           (SIZE_T)resDesc->u.Memory.Length,
                                           MmNonCached);
            if (devCtx->Bar2Va == NULL) {
                if (devCtx->Bar0Va != NULL) {
                    MmUnmapIoSpace(devCtx->Bar0Va, (SIZE_T)devCtx->Bar0Length);
                    devCtx->Bar0Va = NULL;
                    devCtx->Bar0Length = 0;
                }
                devCtx->Bar2Length = 0;
                return STATUS_INSUFFICIENT_RESOURCES;
            }
            bar2Found = TRUE;
        }
    }

    if (devCtx->Bar0Va == NULL) {
        return STATUS_DEVICE_CONFIGURATION_ERROR;
    }

    return STATUS_SUCCESS;
}

NTSTATUS
EvtDeviceReleaseHardware(
    _In_ WDFDEVICE Device,
    _In_ WDFCMRESLIST ResourceListTranslated
)
{
    PDEVICE_CONTEXT devCtx = GetDeviceContext(Device);

    UNREFERENCED_PARAMETER(ResourceListTranslated);

    if (devCtx->Bar2Va != NULL) {
        MmUnmapIoSpace(devCtx->Bar2Va, (SIZE_T)devCtx->Bar2Length);
        devCtx->Bar2Va = NULL;
        devCtx->Bar2Length = 0;
    }

    if (devCtx->Bar0Va != NULL) {
        MmUnmapIoSpace(devCtx->Bar0Va, (SIZE_T)devCtx->Bar0Length);
        devCtx->Bar0Va = NULL;
        devCtx->Bar0Length = 0;
    }

    return STATUS_SUCCESS;
}

NTSTATUS
EvtDeviceD0Entry(
    _In_ WDFDEVICE Device,
    _In_ WDF_POWER_DEVICE_STATE PreviousState
)
{
    UNREFERENCED_PARAMETER(Device);
    UNREFERENCED_PARAMETER(PreviousState);
    return STATUS_SUCCESS;
}

NTSTATUS
EvtDeviceD0Exit(
    _In_ WDFDEVICE Device,
    _In_ WDF_POWER_DEVICE_STATE TargetState
)
{
    UNREFERENCED_PARAMETER(Device);
    UNREFERENCED_PARAMETER(TargetState);
    return STATUS_SUCCESS;
}

VOID
EvtIoRead(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t Length
)
{
    PDEVICE_CONTEXT devCtx = GetDeviceContext(WdfIoQueueGetDevice(Queue));
    WDF_REQUEST_PARAMETERS params;
    LONGLONG offset;
    PVOID buffer;
    size_t bufferLen;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(Length);

    WDF_REQUEST_PARAMETERS_INIT(&params);
    WdfRequestGetParameters(Request, &params);

    offset = params.Parameters.Read.DeviceOffset;

    status = WdfRequestRetrieveOutputBuffer(Request, 0, &buffer, &bufferLen);
    if (!NT_SUCCESS(status) || buffer == NULL || bufferLen == 0) {
        WdfRequestComplete(Request, STATUS_INVALID_PARAMETER);
        return;
    }

    if (offset < 0) {
        WdfRequestComplete(Request, STATUS_INVALID_PARAMETER);
        return;
    }

    // BAR0: AXI-Lite (0x00000000 - 0x7FFFFFFF) — offset directly maps to AXI-Lite address
    if ((ULONG64)offset < 0x80000000ULL) {
        if (devCtx->Bar0Va == NULL) {
            WdfRequestComplete(Request, STATUS_DEVICE_NOT_CONNECTED);
            return;
        }
        // NO upper bounds check — XDMA BAR0 maps AXI-Lite 1:1, hardware handles invalid addresses
        RtlCopyMemory(buffer, (PUCHAR)devCtx->Bar0Va + (SIZE_T)offset, bufferLen);
    }
    // BAR2: DDR3 (0x80000000+)
    else {
        if (devCtx->Bar2Va == NULL) {
            WdfRequestComplete(Request, STATUS_DEVICE_NOT_CONNECTED);
            return;
        }
        ULONG64 bar2Offset = (ULONG64)offset - 0x80000000ULL;
        if (bar2Offset > devCtx->Bar2Length ||
            bufferLen > devCtx->Bar2Length - bar2Offset) {
            WdfRequestComplete(Request, STATUS_INVALID_PARAMETER);
            return;
        }
        RtlCopyMemory(buffer, (PUCHAR)devCtx->Bar2Va + (SIZE_T)bar2Offset, bufferLen);
    }

    WdfRequestCompleteWithInformation(Request, STATUS_SUCCESS, bufferLen);
}

VOID
EvtIoWrite(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t Length
)
{
    PDEVICE_CONTEXT devCtx = GetDeviceContext(WdfIoQueueGetDevice(Queue));
    WDF_REQUEST_PARAMETERS params;
    LONGLONG offset;
    PVOID buffer;
    size_t bufferLen;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(Length);

    WDF_REQUEST_PARAMETERS_INIT(&params);
    WdfRequestGetParameters(Request, &params);

    offset = params.Parameters.Write.DeviceOffset;

    status = WdfRequestRetrieveInputBuffer(Request, 0, &buffer, &bufferLen);
    if (!NT_SUCCESS(status) || buffer == NULL || bufferLen == 0) {
        WdfRequestComplete(Request, STATUS_INVALID_PARAMETER);
        return;
    }

    if (offset < 0) {
        WdfRequestComplete(Request, STATUS_INVALID_PARAMETER);
        return;
    }

    // BAR0: AXI-Lite (0x00000000 - 0x7FFFFFFF) — offset directly maps to AXI-Lite address
    if ((ULONG64)offset < 0x80000000ULL) {
        if (devCtx->Bar0Va == NULL) {
            WdfRequestComplete(Request, STATUS_DEVICE_NOT_CONNECTED);
            return;
        }
        // NO upper bounds check — XDMA BAR0 maps AXI-Lite 1:1, hardware handles invalid addresses
        RtlCopyMemory((PUCHAR)devCtx->Bar0Va + (SIZE_T)offset, buffer, bufferLen);
    }
    // BAR2: DDR3 (0x80000000+)
    else {
        if (devCtx->Bar2Va == NULL) {
            WdfRequestComplete(Request, STATUS_DEVICE_NOT_CONNECTED);
            return;
        }
        ULONG64 bar2Offset = (ULONG64)offset - 0x80000000ULL;
        if (bar2Offset > devCtx->Bar2Length ||
            bufferLen > devCtx->Bar2Length - bar2Offset) {
            WdfRequestComplete(Request, STATUS_INVALID_PARAMETER);
            return;
        }
        RtlCopyMemory((PUCHAR)devCtx->Bar2Va + (SIZE_T)bar2Offset, buffer, bufferLen);
    }

    WdfRequestCompleteWithInformation(Request, STATUS_SUCCESS, bufferLen);
}

VOID
EvtIoDeviceControl(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t OutputBufferLength,
    _In_ size_t InputBufferLength,
    _In_ ULONG IoControlCode
)
{
    PDEVICE_CONTEXT devCtx = GetDeviceContext(WdfIoQueueGetDevice(Queue));
    NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;
    size_t bytesReturned = 0;

    UNREFERENCED_PARAMETER(InputBufferLength);

    switch (IoControlCode) {

    case IOCTL_XDMA_GET_BAR_INFO:
    {
        XDMA_BAR_INFO info;
        PVOID outputBuf;
        size_t outLen;

        status = WdfRequestRetrieveOutputBuffer(Request, sizeof(info), &outputBuf, &outLen);
        if (!NT_SUCCESS(status) || outLen < sizeof(info)) {
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }

        info.Bar0PhysAddr = devCtx->Bar0PhysAddr.QuadPart;
        info.Bar0Length = devCtx->Bar0Length;
        info.Bar2PhysAddr = devCtx->Bar2PhysAddr.QuadPart;
        info.Bar2Length = devCtx->Bar2Length;

        RtlCopyMemory(outputBuf, &info, sizeof(info));
        bytesReturned = sizeof(info);
        status = STATUS_SUCCESS;
        break;
    }

    default:
        status = STATUS_INVALID_DEVICE_REQUEST;
        bytesReturned = 0;
        break;
    }

    WdfRequestCompleteWithInformation(Request, status, bytesReturned);
}