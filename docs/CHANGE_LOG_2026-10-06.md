# CHANGE LOG — 2026-10-06 (тесты прошивки 0e5cb12 + драйвер v1.1.29)

Сессия: тестирование на возвращённой стабильной прошивке **0e5cb12** (SW_CRC 937831e9)
с драйвером **v1.1.29** (numDescriptors-безусловно + prefetch off + апертурная проверка).
Продолжение BUG-054 (WHEA 0x124/ROF).

Каталог: `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3`; прошивка собрана в worktree `C:\A7_M2\_fw_0e5cb12`.

---

## 1. Результаты стенда

| Тест | Результат | Примечание |
|---|---|---|
| loopback 512 | ✅ PASS | |
| loopback 1024 | ✅ PASS | IOCTL_XDMA_DIAG_GET: progDmaCalls=1 (единый пакет) |
| loopback 2048 | ✅ PASS | |
| loopback 1 MiB | ✅ PASS | c2h чтение DDR3 стабильно |
| WHEA/AER/BugCheck за тесты | **нет** | миндампы только старые (05.10 21:46/22:38); 0x124 НЕ повторялся |
| dot 4 (DDR3) | ❌ TDOT DONE timeout | STATUS=0x1 (BUSY), DONE не приходит |
| dot_bram 4 | ❌ TDOT DONE timeout | STATUS=0x1 (BUSY) |

## 2. Выводы
- Причина серии 0x124/ROF на Root Port, поддерживаемая дефектным завершением в драйвере
  (numDescriptors под poll=0 → мгновенный SUCCESS → зависший C2H → ROF) и/или размещением,
  **устранена на практических тестах**: loopback до 1MiB проходит без WHEA/ROF.
- DMA-механика (h2c/c2h) на 0e5cb12 + v1.1.29 полностью работоспособна.
- Открытая отдельная задача: **ядро TDOT не завершает dot** (DONE timeout, BUSY). Это не DMA,
  это проблема read-мастера tdot_axi4 / пути M_AXI_TDOT (ранее CORE_RES=0). Требует отдельной
  отладки ядра (ILA на M_AXI_TDOT arvalid/rvalid, анализ FSM застревания).

## 3. Следующий шаг
- Отдельно разобрать ядро TDOT (dot/dot_bram DONE timeout): ILA/анализ read-мастера и пути данных.
- Логи: ERROR_HISTORY.md (BUG-054 статус), DIAG, worklog.md.