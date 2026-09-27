/*
 * dma_driver.h — автономный DMA-драйвер XDMA (gateway), переиспользующий
 * upstream-стек из xdma_driver_win_src_2017.
 *
 * Эта шапка определяет ДВЕ вещи:
 *   1. Глобальный тип контекста устройства (DeviceContext) + аксессор
 *      GetDeviceContext — это KONTRAKT, которого требует upstream sys\file_io.c
 *      (см. file_io.c:96 `GetDeviceContext(device)` и file_io.c:157
 *      `ctx->engineQueue[dir][index]`). sys\driver.h в этом дереве — ПУСТОЙ
 *      (0 байт), поэтому contract определен здесь.
 *   2. Прототипы точки входа и PnP/Power-обработчиков этого гейтвея.
 *
 * ВАЖНО (отклонение от буквального ТЗ): в спецификации было предложено имя
 * `DEVICE_CONTEXT` + аксессор `XdmaGetContext`, но upstream`ный file_io.c
 * жёстко использует `DeviceContext`, `GetDeviceContext(...)` и
 * `ctx->engineQueue[dir][index]`. Чтобы скомпилировать file_io.c «как есть»
 * (что требует ТЗ), тип и аксессор названы именно DeviceContext /
 * GetDeviceContext. Всё остальное из ТЗ (включения, прототипы) соблюдено.
 */

#pragma once

// ===== include dependencies =================================================
#include <ntddk.h>
#include <wdf.h>
#include <ntintsafe.h>

#include "xdma.h"      // libxdma\xdma.h -> включая PXDMA_DEVICE, XDMA_DeviceOpen/Close
#include "device.h"    // libxdma\device.h -> XDMA_DEVICE

// ===== device context (required by upstream file_io.c) ======================
// Имя типа ДОЛЖНО быть `DeviceContext` (camelCase): upstream file_io.c:96
// пишет `DeviceContext* ctx = GetDeviceContext(device);`. Спецификация ТЗ
// предлагала DEVICE_CONTEXT, но оно не скомпилировало бы файл_io.c «как есть».
typedef struct _DEVICE_CONTEXT {
    XDMA_DEVICE xdma;                     // весь самостоятельный DMA-стек XDMA
    WDFQUEUE engineQueue[XDMA_NUM_DIRECTIONS][XDMA_MAX_NUM_CHANNELS];
    ULONG64 bar0PhysAddr;                 // pre-flight (GET_BAR_INFO)
    ULONG   bar0Length;
} DEVICE_CONTEXT, DeviceContext, *PDEVICE_CONTEXT, *PDeviceContext;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DEVICE_CONTEXT, GetDeviceContext)

// ===== driver entry / PnP callbacks =========================================
DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD      EvtDriverDeviceAdd;
EVT_WDF_DEVICE_PREPARE_HARDWARE EvtDevicePrepareHardware;
EVT_WDF_DEVICE_RELEASE_HARDWARE EvtDeviceReleaseHardware;

// ===== optional pre-flight IOCTL (GET_BAR_INFO) ==============================
#define IOCTL_XDMA_GET_BAR_INFO \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)

#pragma pack(push, 8)
typedef struct _XDMA_DMA_BAR_INFO {
    ULONG64 Bar0PhysAddr;
    ULONG   Bar0Length;
    ULONG   NumBars;
    LONG    UserBarIdx;
} XDMA_DMA_BAR_INFO;
#pragma pack(pop)