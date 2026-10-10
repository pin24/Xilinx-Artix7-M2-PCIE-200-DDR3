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

## Нагрузочный скрипт stress_platform.py (08.10) — статус
- Создан: pytorch_layer/stress_platform.py. Полная нагрузка: N DOT-потоков (tdot.dot n=16) + M DMA-потоков (loopback на разные DDR3-оффсеты) + фоновый monitor XADC (temp/VCCINT/CSI), итог+CSSV.
- Параметры: --sec --dots --dma --n --interval --csv.
- ПРОВЕДЕНЫ: диагностика (устройство OK, CORE_PARAMS 0x1010=16/16), regs/firmware PASS, loopback 512/1024/2048/1M PASS, dot 1/8/16/32 PASS (dot 32=0x041680000000 совпадает с RTL-эмуляцией - ЖЕЛЕЗО=СИМУЛЯЦИЯ).
- НАЙДЕНЫ И ИСПРАВЛЕНЫ ПРИ ОТЛАДКЕ:
  * XdmaWinDma.read/write шли через \control (config-BAR) вместо \user (AXI-Lite периферия TDOT/XADC) => WinError 1. FIX: открыли \user и читаем периферию оттуда (test_dma_win.py).
  * stress с несколькими потоками падал Access Violation (0xC0000005): XdmaWinDma использует ОДИН event на объект, потоки конкурировали -> гонка. FIX: единый глобальный lock поверх всех dev-операций (ядро всё равно сериализует канал).
  * XADC temp выдал мусор 4262C при valid=1 (BUG-031: XADC занят MIG). FIX: валидация диапазона (temp -40..125, vcc 0..2) -> инвалидировать мусор.
- ТЕХНИЧЕСКОЕ: полный stress-прогон на плате НЕ выполнялся (требует разрешения; команда: python stress_platform.py --sec 60 --dots 4 --dma 2 --csv stress.csv). Прошивка на плате = 16/16 (не 32/16).
