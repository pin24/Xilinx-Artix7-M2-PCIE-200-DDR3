# Стендовые тесты 08.10 (плата в PCIe, прошивка уже залита)

## ШАГ 1 - Диагностика (08.10)
- Устройство: XDMA DMA Subsystem Status=OK.
- test_dma firmware: TDOT MAGIC=0x54444F54 OK; CORE_PARAMS=0x00001010 -> NUM_MAC=16, ADDERS=16 (ТЕКУЩАЯ ПРОШИВКА = 16/16, НЕ наша 32/16).
- test_dma regs: TDOT_STATUS=0x0(BUSY=0,DONE=0), TDOT_N_IN=16, RES=0/0, GPIO_DATA=0x00 (MIG-калибровка/маmmcm не видно -> проверить loopback).
- СТАТУС перед тестом записи: BUSY=0, DONE=0, GPIO=0.
## ШАГ 2 - loopback 512 (test_dma): PASS (512 байт идентичны) - DMA h2c/c2h и DDR3 работают.
## СТАТУС: BUSY=0 DONE=0.

## ШАГ 3 - loopback 1024: PASS (1024 байт идентичны)
## ШАГ 4 - dot 8: PASS - DONE после ~5ms (STATUS=0x02), result(48)=0x014800000000 (8x1.0 path работает). Ядро считает.
## ИТОГ стенда (проживаемая прошивка): DMA h2c/c2h OK, DDR3 OK, tdot dot OK. Конфигурация прошитой прошивки = 16/16 (CORE_PARAMS 0x1010) - НЕ 32/16.
## Расширенные тесты (продолжение)
## ШАГ 5 - loopback 2048: PASS
## ШАГ 6 - loopback 1048576 (1MB): PASS - DMA конвейра больших посылок работает
## ШАГ 7 - dot 1: PASS result=0x001000000000 (совпадает с симуляцией=1.0)
## ШАГ 8 - dot 16: PASS result=0x066900000000 (16.0 path)
## ШАГ 9 - dot 32: PASS result=0x041680000000 (канонический 'сумма 32', совпадает с RTL-эмуляцией tb_tdot) - ЖЕЛЕЗО=СИМУЛЯЦИЯ
