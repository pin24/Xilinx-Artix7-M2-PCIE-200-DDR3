/*
 * driver.h — upstream-контракт, требуемый подлинным sys\file_io.c.
 *
 * file_io.c (genuine upstream) использует:
 *   DeviceContext* ctx = GetDeviceContext(device);   // file_io.c:96
 *   ctx->xdma;                                       // file_io.c:97
 *   ctx->engineQueue[dir][index];                    // file_io.c:157
 *
 * В оригинальном дереве этот файл был ПУСТ (0 байт), а контракт задавал
 * головной (подлинный) driver.c, которого в этом репозитории НЕТ
 * (он здесь подменён кастомной MMIO-копией — см. DRIVER_DEVLOG.md §5).
 *
 * Контракт определён в driver\dma\dma_driver.h (тип DEVICE_CONTEXT +
 * аксессор GetDeviceContext + поле engineQueue[XDMA_NUM_DIRECTIONS]
 * [XDMA_MAX_NUM_CHANNELS]). Здесь просто подключаем его. build.cmd
 * добавляет /I driver\dma, чтобы <dma_driver.h> резолвился.
 *
 * WDF_DECLARE_CONTEXT_TYPE_WITH_NAME расширяется в COMDAT (__declspec
 * (selectany) + FORCEINLINE), поэтому дублирующее объявление в соседних
 * translation units (dma_driver.h / driver.h) не даёт коллизий при линковке.
 */
#pragma once

#include <dma_driver.h>