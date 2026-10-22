# Проект и внедрение: безопасный сброс XDMA-канала с управлением в драйвере

**Дата:** 2026-10-22. **Репозиторий:** `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3` (правки в рабочем дереве, не закоммичены).
**Сборка:** flat (без DFX). **Драйвер:** 1.2.7.4 (oem194), источник — `xdma_driver_win_src_2017` (гейтвей `driver\dma\dma_driver.c`).

**Жёсткое ограничение исполнения:** запись в плату ЗАПРЕЩЕНА. Внесены ТОЛЬКО статические изменения кода драйвера и хостовых обвязок + этот отчёт. Ничего не запускалось на железе, ни один регистр/дескриптор на плате не трогался, `write_dma`/`read_dma`/IOCTL не выполнялись.

---

## 0. Короткая версия

| Что | Итог |
|---|---|
| Причина веджа (до фикса) | Большая h2c-запись (~500 КБ batch) оставляет аппаратный h2c-движок в состоянии «BUSY»: прежний таймаут-путь делал только `EngineStop` (снимал RUN, но НЕ read-clear `statusRC` и НЕ аппаратный reset канала) → BUSY остаётся, следующий перенос стартует BUSY и виснет до power-cycle (см. `AUDIT_H2C_WEDGE.md` §2.3/§4). |
| Решение | Новая `XDMA_EngineResetChannel(engine)` в `libxdma\dma_engine.c/.h` — полный целевой сброс одного канала: EngineStop → **аппаратный канальный reset (`controlW1S=XDMA_CTRL_RST`, BIT31, по умолчанию ВКЛ)** → read-clear `statusRC` → `completedDescCount` → re-arm `firstDesc` → зачистка дескрипторного банка → сброс `perfCtrl`. |
| Управление | Новый IOCTL `IOCTL_XDMA_CHANNEL_RESET` (+ `XDMA_CHANNEL_RESET` в `inc\xdma_public.h`). Три флага: `NOW` (ручной сброс сейчас), `AUTO_ON`/`AUTO_OFF` (политика `engine->channelResetOnTimeout`). **По умолчанию авто-сброс ВКЛЮЧЁН** (`channelResetOnTimeout=TRUE` в `EngineCreate`). |
| Авто-путь | В таймаут-хвосте `EvtIoWriteDma` и `EvtIoReadDma` после `EngineStop` (после захвата владения `txnDone`) вызывается `XDMA_EngineResetChannel`, если флаг включён. |
| Хост | `XdmaWinDma.soft_reset_h2c()` (`test_dma_win.py`) и `XdmaWinUpstream.soft_reset_h2c()` (`xdma_driver.py`) — ручной fallback через IOCTL на `\\.\XDMA0dma\h2c_0`. |
| Аппаратный бит `XDMA_CTRL_RST` | **Основной механизм** (по умолчанию ВКЛ). Основание: `AUDIT_H2C_WEDGE.md` §2.4/H3 — soft-idle (`EngineStop`+read-clear) НЕ выбивает BUSY из застрявшего write-FSM на границе PCIe→AXI/SMC; рекомендован именно bit31. Опционально: сборка `-DXDMA_CHANNEL_RESET_HW_BIT=0` для A/B soft-сравнения на стенде. |
| Риски double-complete/BSOD | Закрыты: сброс выполняется только после захвата владения `txnDone` под `engineLock`; IOCTL на `h2c`-узле serialized в sequential-очереди движка; сброс не трогает WDF-объекты. |

---

## 1. Файлы изменений (дифф-описание)

| Файл | Изменение |
|---|---|
| `xdma_driver_win_src_2017\libxdma\dma_engine.h` | Поле `BOOLEAN channelResetOnTimeout`; прототип `NTSTATUS XDMA_EngineResetChannel(IN XDMA_ENGINE*)`. |
| `xdma_driver_win_src_2017\libxdma\dma_engine.c` | Реализация `XDMA_EngineResetChannel` (после `XDMA_EngineResetIdle`); инициализация `channelResetOnTimeout=TRUE` в `EngineCreate`. |
| `xdma_driver_win_src_2017\sys\file_io.c` | Case `IOCTL_XDMA_CHANNEL_RESET` в `EvtIoDeviceControl`; вызов `XDMA_EngineResetChannel` в таймаут-хвосте `EvtIoWriteDma` и `EvtIoReadDma`. |
| `xdma_driver_win_src_2017\inc\xdma_public.h` | `IOCTL_XDMA_CHANNEL_RESET` (0x7), флаги `XDMA_CHANNEL_RESET_FLAG_*`, структура `XDMA_CHANNEL_RESET`. |
| `pytorch_layer\test_dma_win.py` | `soft_reset_h2c(auto_on=None)` + `_ioctl_channel_reset()` + константы IOCTL. |
| `pytorch_layer\xdma_driver.py` | `XdmaWinUpstream.soft_reset_h2c()` + `DeviceIoControl` binding + константы IOCTL. |

Полный текстовый дифф — Приложение A (в конце отчёта). Сводка: **+307 строк, 0 удалений** по 6 файлам.

---

## 2. Функция сброса канала `XDMA_EngineResetChannel`

### 2.1 Сигнатура

```c
NTSTATUS XDMA_EngineResetChannel(IN XDMA_ENGINE* engine);
```

Возвращает `STATUS_SUCCESS`; `STATUS_INVALID_PARAMETER` при `engine==NULL`.

### 2.2 Последовательность

1. **EngineStop** — `controlW1C = XDMA_CTRL_RUN_BIT`. Идемпотентно (W1C), гасит активный RUN.
2. **Аппаратный канальный reset (по умолчанию)** — `controlW1S = XDMA_CTRL_RST` (BIT31), затем `controlW1C = RUN` (re-stop). Сбрасывает внутренний FSM движка и отбрасывает застрявший write-транзакт (см. §2.3). Fallback на soft: сборка `-DXDMA_CHANNEL_RESET_HW_BIT=0`.
3. **read-and-clear `statusRC`** — снимает остаточный BUSY и биты ошибок (в soft-режиме это единственный активный приём снятия BUSY).
4. **чтение `completedDescCount`** — наблюдаем (read-only), значение логируется.
5. **re-arm SGDMA `firstDescLo/Hi`** на базу постоянного дескрипторного буфера + `firstDescAdj=0` — необходимо ПОВТОРНО после аппаратного сброса (reset сбрасывает дескрипторный указатель).
6. **`RtlZeroMemory` дескрипторного банка** — стираем протухшую частичную цепочку после таймаута. Движок уже остановлен, новая передача перепишет банк заново.
7. **сброс `perfCtrl`** — снимаем возможный остаточный `XDMA_PERF_RUN`.
8. **`MemoryBarrier()`** — упорядочивание записи до последующего `EngineStart`.

### 2.3 Аппаратный бит `XDMA_CTRL_RST` (BIT31) — основной механизм сброса

`libxdma\reg.h:74` определяет `XDMA_CTRL_RST = BIT_N(31)` канального Control. Ключевое обоснование (из сопутствующего read-only аудита `docs\audit-h2c-wedge-2026-10-22\AUDIT_H2C_WEDGE.md`, §2.4/§2.3/H3):

- **`EngineStop` и `XDMA_EngineResetIdle` НЕ являются аппаратным reset канала.** Soft-idle делает `RUN=0` + read-clear `statusRC` + re-arm `firstDesc`, но НЕ сбрасывает внутренний FSM DMA-инга. Если BUSY держится из-за незавершённого транзакта на шине (AXI-slave не вернул BLAST/BVALID на границе PCIe→AXI/SMC), `statusRC` снова вернёт BUSY в тот же момент, и движок сразу застревает снова.
- **BUSY — это застрявший FSM на границе PCIe→AXI, а не флаг.** Поэтому программно-soft reset не помогает; единственный путь из host — аппаратный канальный reset.
- Аудит прямо рекомендует (п.1 рекомендаций): нечто вроде «прописать `XDMA_CTRL_RST (bit31)` в `controlW1S`… и `SGDMA_COMMON.control` global reset».

В связи с этим `XDMA_EngineResetChannel` по умолчанию делает аппаратный канальный reset:

```c
#ifndef XDMA_CHANNEL_RESET_HW_BIT
#define XDMA_CHANNEL_RESET_HW_BIT 1   // HW-reset ВКЛ по умолчанию
#endif

engine->regs->controlW1C = XDMA_CTRL_RUN_BIT;   // 1) stop
#if XDMA_CHANNEL_RESET_HW_BIT
engine->regs->controlW1S = XDMA_CTRL_RST;        // 2) аппаратный канальный reset (bit31)
engine->regs->controlW1C = XDMA_CTRL_RUN_BIT;    //    re-stop если reset поднял RUN
#endif
UINT32 st = engine->regs->statusRC;              // 3) read-clear BUSY/errors
... re-arm firstDesc, clear bank, clear perf ...
```

**Сброс канало-локальный**: пишется BIT31 только в `controlW1S` конкретного движка (H2C_0) — в отличие от глобального `SGDMA_COMMON.control` reset (0x6010), который сбросил бы ВСЕ каналы (в т.ч. работающий C2H) и потому внутри хода scope НЕ применяется (упоминается как отдельная опция в §7).

**Почему не оставлен «только soft»:** тот самый soft-путь, что я рассматривал изначально, по аудиту доказанно не разблокирует h2c. Оставить его основным значило бы сделать сброс декоративным. HW-bit — это и есть та «дыра», которую аудит назвал отсутствующей. Для A/B на стенде предусмотрен compile-флаг `-DXDMA_CHANNEL_RESET_HW_BIT=0` (fallback на soft-путь) — сравнить и зафиксировать в отчёте стенда, на каком битстриме бит функционален.

### 2.4 Координация с txnDone (протокол вызывающего)

`XDMA_EngineResetChannel` **сам не захватывает** `txnDone`/`isReqPending`. Контракт (зафиксирован в doc-комментарии и .h):

> Вызывать ТОЛЬКО когда вызывающий УЖЕ стал единственным владельцем транзакции движка: `txnDone=TRUE` захвачен CAS под `engineLock` в таймаут/ISR/cancel-пути. Тогда никакой DPC/ISR/`EngineProcessTransfer` не трогает регистры канала параллельно.

Это гарантирует: reset не конкурирует с завершением, не вызывает double-complete, не трогает незавершённый IRP.

---

## 3. Управление: флаг + IOCTL

### 3.1 Принятое решение: «авто-сброс на таймауте включён по умолчанию + ручной IOCTL-fallback»

**Обоснование.** Цель задачи — чтобы сценарий «большая h2c → 1 сбой → следующий перенос OK БЕЗ power-cycle» проходил автоматически. Если бы сброс был только по явной команде, хост обязан был бы ловить каждый таймаут и успевать вызвать IOCTL ДО следующего переноса — хрупко и зависит от хостовой дисциплины. Размещение сброса в таймаут-ветке драйвера делает восстановление детерминированным и независимым от хоста. Ручной IOCTL (`NOW`) — резерв для случаев, когда хост сам перехватил таймаут раньше драйвера и хочет разблокировать канал до общих операций.

### 3.2 Поле `engine->channelResetOnTimeout` (по умолчанию `TRUE`)

Инициализируется в `EngineCreate` (`dma_engine.c:811`). Читается в таймаут-пути под обычным доступом; пишется только из IOCTL-контекста (PASSIVE, `PASSIVE`), под `engineLock`. Простая BOOLEAN-политика без гонок.

### 3.3 IOCTL

```c
#define IOCTL_XDMA_CHANNEL_RESET XDMA_IOCTL(0x7)   // METHOD_BUFFERED
typedef struct { ULONG Flags; } XDMA_CHANNEL_RESET;
#define XDMA_CHANNEL_RESET_FLAG_NOW      0x00000001UL // сбросить канал сейчас
#define XDMA_CHANNEL_RESET_FLAG_AUTO_ON  0x00000002UL // включить авто-сброс на таймауте
#define XDMA_CHANNEL_RESET_FLAG_AUTO_OFF 0x00000004UL // выключить авто-сброс на таймауте
```

Флаги комбинируются. Обработка в `EvtIoDeviceControl` (`sys\file_io.c`) для **DMA-узлов** (h2c/c2h): `queue->engine` задан. Завершение — по устоявшемуся паттерну: на `SUCCESS` завершаем в case, на fail — через `exit:` один раз (без double-complete).

### 3.4 Почему IOCTL идёт на `\\.\XDMA0dma\h2c_0`, а не на `\control`

Инфраструктура IOCTL-обработки построена по движкам:
- гейтвей `dma_driver.c EvtIoControlDispatch` (default queue, `\control`/`\user`) делегирует upstream `EvtIoDeviceControl` ТОЛЬКО для DMA-узлов (`file->queue != NULL`), иначе возвращает `STATUS_INVALID_PARAMETER`;
- движковые IOCTL (PERF/ADDRMODE/DIAG) живут в `EvtIoDeviceControl` (`file_io.c`), который требует `queue->engine`.

Поэтому сброс канала, будучи пер-движковой операцией, обязан идти на движковый узел. Хост уже держит `self._h2c` открытым — метод `soft_reset_h2c()` шлёт IOCTL именно туда. Дополнительный бонус: движковая очередь — `WdfIoQueueDispatchSequential`, поэтому IOCTL на `\h2c_0` сериализуется ПОСЛЕ любого in-flight DMA-запроса того же узла (минимальный риск сброса во время передачи).

### 3.5 Хостовые методы

```python
# test_dma_win.py :: XdmaWinDma
def soft_reset_h2c(self, auto_on=None):   # NOW + (опционально) смена политики

# xdma_driver.py :: XdmaWinUpstream
def soft_reset_h2c(self, auto_on=None):
```

Оба: `DeviceIoControl(self._h2c, IOCTL_CHANNEL_RESET, inbuf, 4, ...)`. Хост регистры НЕ пишет — всю аппаратную работу делает драйвер в ядре (метод read-only по отношению к железу).

---

## 4. Точка интеграции в таймаут-путь

Блок таймаут-хвоста (`EvtIoWriteDma`, `sys\file_io.c:813-883`) и его аналог в `EvtIoReadDma` — единственная правка в пути завершения:

```
CAS захват владения под engineLock      // уже было
EngineStop(queue->engine)                // уже было
X_DMA_EngineResetChannel(engine)         // НОВОЕ, если queue->engine->channelResetOnTimeout
WdfRequestUnmarkCancelable(Request)      // уже было
   если == STATUS_CANCELLED -> return    // cancel-путь завершит (сброс уже сделан — безвредно, движок idle)
WdfDmaTransactionRelease
WdfRequestComplete(Request, status)
```

Порядок соответствует ТЗ: **EngineStop → (канал сброс) → UnmarkCancelable → Release → Complete**. Сброс вставлен между `EngineStop` и `UnmarkCancelable`.

**Почему после Ownership, до Release:** к моменту сброса мы единственные владельцы транзакции (`txnDone` захвачен выше, `EngineProcessTransfer` заблокирован гардом), поэтому никакой DPC не трогает регистры; сброс не трогает WDF-объекты, поэтому безопасен до `Release`.

---

## 5. Риски double-complete / BSOD и как они закрыты

| # | Риск | Как закрыт |
|---|---|---|
| BSOD-1 | Двойной `Release`/`Complete` от позднего DPC после таймаута | `XDMA_EngineResetChannel` вызывается только ПОСЛЕ CAS-захвата `txnDone` под `engineLock`; DPC/`EngineProcessTransfer` отсекается по `isReqPending`/`txnDone`-гардам. Сброс не вызывает `Release`/`Complete` — не может сам породить второе завершение. |
| BSOD-2 | Сброс форсируется на ещё работающей передаче | Сброс стоит строго после задачи владения (движок уже остановлен `EngineStop`); на IOCTL-пути — sequential-очередь движка serializes IOCTL после in-flight DMA. |
| BSOD-3 | `WdfRequestUnmarkCancelable → STATUS_CANCELLED` и сброс уже сделан | Сброс перед UnmarkCancelable: при передаче владения cancel-пути движок уже idle/сброшен; cancel-путь делает свой `EngineStop` + `Release` без повторного сброса → двойного сброса/завершения нет. |
| BSOD-4 | IOCTL-обработчик завершит request дважды | Case следует паттерну остальных: на `SUCCESS` — `WdfRequestComplete` в case; на fail — `break` и `exit:` завершает единожды. |
| BSOD-5 | `RtlZeroMemory` банка под работающим движком | Банк чистится только после `EngineStop` + read-clear и после захвата владения — движок не выполняет дескрипторы в этот момент; новая передача перепишет банк целиком. |
| BSOD-6 | Сброс падает из-за NULL engine | `XDMA_EngineResetChannel(NULL) → STATUS_INVALID_PARAMETER`, IOCTL вернёт ошибку, request завершится (не упадёт). |

Не выполнялось / не доказывалось статически: реальное «хвостовое» прерывание ровно в окне между CAS и `EngineStop` (крайне узкое окно; существующий риск, унаследованный от текущего кода, не усугублён). См. §7, п.5.

---

## 6. Изменённые сигнатуры и флаги (сводка)

- **Ядро:** `NTSTATUS XDMA_EngineResetChannel(IN XDMA_ENGINE*)` — новая глобальная функция.
- **Поле движка:** `BOOLEAN channelResetOnTimeout` (default `TRUE`).
- **IOCTL:** `IOCTL_XDMA_CHANNEL_RESET (0x7)`, input `XDMA_CHANNEL_RESET{Flags}`, флаги `NOW`/`AUTO_ON`/`AUTO_OFF`.
- **Хост:** `XdmaWinDma.soft_reset_h2c()` / `XdmaWinUpstream.soft_reset_h2c()`.

---

## 7. Что ОБЯЗАТЕЛЬНО проверить на железе (после разрешения записи)

0. **Сборка и загрузка:** собрать `driver\dma` (build.cmd), установить с заменой драйвера 1.2.7.4, убедиться что загружается и `\\.\XDMA0dma\control` + `\h2c_0` + `\c2h_0` открываются (проверить `GET_BAR_INFO`).

1. **Базовый сценарий (регрессия по умолчанию):** малая переходная проверка: 64 Б write_dma + read_dma @0x200000 — ок (движок переиспользуется), т.е. инкремент не сломал штатный путь.

2. **Ключевой сценарий «большая h2c → 1 сбой → автосброс → следующий перенос OK без power-cycle»:**
   - прогон `scripts\ring_check.py --depth 1024` (крупная ~500 КБ h2c-запись) до 1 таймаута/WDF-пакетного исчерпания;
   - убедиться, что драйвер в таймаут-ветке вызвал `XDMA_EngineResetChannel` (в WPP-трассе: `CHANNEL RESET done … statusRC-cleared=0x…`);
   - СРАЗУ затем 4 КБ write_dma по 0x200000 — **должно пройти без power-cycle** (раньше висён `timeout at 0x200000`);
   - повторить цикл 3…5 раз (устойчивость).

3. **Ручной IOCTL-fallback:** на залипшем канале вызвать `soft_reset_h2c()` (через `test_dma_win.py` или `xdma_driver.py`), затем 4 КБ write_dma — должно пройти. Убедиться, что IOCTL вернул SUCCESS (не WinError).

4. **Управление политикой:** `soft_reset_h2c(auto_on=False)` → спровоцировать таймаут → убедиться, что авто-сброс НЕ сработал (движок остался занят) и следующий перенос виснет (ожидаемое поведение при выключенной политике); затем `soft_reset_h2c(auto_on=True)` + ручной `NOW`, канал оживает. Это подтверждает осмысленность флага.

5. **Гонка cancel ∩ timeout:** прогнать сценарий «пользовательский Cancel во время зависшей передачи» под Driver Verifier (включить флаги) — убедиться, что нет BugCheck 0x10D/0xE6 и что IRP завершается ровно один раз.

6. **Валидация HW-bit (BIT31) — приоритет стенда:** по умолчанию сборка идёт с `XDMA_CHANNEL_RESET_HW_BIT=1` (аппаратный канальный reset включён). На ключевом сценарии (п.2) проверить по WPP-трассе, что `CHANNEL RESET done (mode=HW-bit31 …)`, и что 4 КБ СРАЗУ после сброса проходит. **A/B-контроль:** пересобрать с `-DXDMA_CHANNEL_RESET_HW_BIT=0` (soft) и сравнить: если soft НЕ разблокирует (ожидаемо по аудиту) — подтверждается, что HW-bit обязателен; если BIT31 на этом битстриме оказался no-op — зафиксировать и перейти на комбинированный путь/иной механизм (варианты: `SGDMA_COMMON.control` глобальный reset 0x6010 — но он сбросит все каналы; либо размерный лимит h2c — см. ниже).

7b. **Опция размерного лимита (обходной, если HW-bit не подтвердится):** проверить гипотезу аудита §2.5/§4, что триггер клина — насыщение SMC→MIG при длинном posted-write; если аппаратный сброс окажется нестабильным, ввести верхний предел одиночной h2c-записи (например 4–16 КБ) и убедиться, что клина больше нет.

8. **Измерение производительности:** убедиться, что добавленный RtlZeroMemory банка (~64 КБ) в таймаут-пути не влияет на штатный successful-путь (он его не касается) и что нормальная пропускная способность h2c/c2h не изменилась.

---

## 8. Что НЕ выполнялось (ограничение)

- Никакой записи в плату: не выполнялись `write_dma`, запись конфиг/регистров, `XDMA_EngineResetChannel` на железе, пересборка с запуском на плате.
- Не выполнен полный WDK-сборке/мок-прогон C-кода (сборка требует WDK; статически код сверен с существующими паттернами `XDMA_EngineResetIdle`/`EngineProcessTransfer` и включёнными заголовками).
- Python-методы написаны и статически сверены, но не вызывались (вызов = IOCTL на железе).

---

## Приложение A. Полный дифф

```diff
diff --git a/pytorch_layer/test_dma_win.py b/pytorch_layer/test_dma_win.py
index 2a0bc73..4bcd6c7 100644
--- a/pytorch_layer/test_dma_win.py
+++ b/pytorch_layer/test_dma_win.py
@@ -54,6 +54,22 @@ FILE_FLAG_OVERLAPPED = 0x40000000
 ERROR_IO_PENDING = 997
 INVALID_HANDLE = ctypes.c_void_p(-1).value
 
+# ---- CHANNEL-RESET 2026-10-22: IOCTL_XDMA_CHANNEL_RESET (inc/xdma_public.h) ----
+FILE_DEVICE_UNKNOWN = 0x22
+METHOD_BUFFERED = 0
+FILE_ANY_ACCESS = 0
+
+
+def _ctl_code(device_type, function, method, access):
+    """CTL_CODE from inc/xdma_public.h: (dev<<16)|(acc<<14)|(fn<<2)|method."""
+    return (device_type << 16) | (access << 14) | (function << 2) | method
+
+
+IOCTL_CHANNEL_RESET = _ctl_code(FILE_DEVICE_UNKNOWN, 0x7, METHOD_BUFFERED, FILE_ANY_ACCESS)  # = 0x22001C
+CHANNEL_RESET_NOW = 0x00000001      # XDMA_CHANNEL_RESET_FLAG_NOW
+CHANNEL_RESET_AUTO_ON = 0x00000002  # XDMA_CHANNEL_RESET_FLAG_AUTO_ON
+CHANNEL_RESET_AUTO_OFF = 0x00000004  # XDMA_CHANNEL_RESET_FLAG_AUTO_OFF
+
 
 class XdmaWinDma(XdmaDevice):
@@ -246,6 +262,38 @@ class XdmaWinDma(XdmaDevice):
             off += chunk
         return bytes(out)
 
+    # ---------------- CHANNEL-RESET 2026-10-22 -------------------------------
+    def _ioctl_channel_reset(self, flags):
+        if self._h2c is None:
+            raise XdmaError("h2c channel handle is None (driver node not open)")
+        inbuf = (self._c.c_ulong * 1)(flags & 0xFFFFFFFF)
+        done = self._c.wintypes.DWORD(0)
+        ok = self._k32.DeviceIoControl(
+            self._h2c, IOCTL_CHANNEL_RESET,
+            inbuf, 4, None, 0,
+            self._c.byref(done), None)
+        if not ok:
+            raise XdmaError(
+                f"IOCTL_XDMA_CHANNEL_RESET(flags=0x{flags:X}) failed: "
+                f"WinError {self._c.get_last_error()}")
+        return done.value
+
+    def soft_reset_h2c(self, auto_on=None):
+        flags = CHANNEL_RESET_NOW
+        if auto_on is True:
+            flags |= CHANNEL_RESET_AUTO_ON
+        elif auto_on is False:
+            flags |= CHANNEL_RESET_AUTO_OFF
+        return self._ioctl_channel_reset(flags)
+
diff --git a/pytorch_layer/xdma_driver.py b/pytorch_layer/xdma_driver.py
index bd7cf3f..893dd27 100644
--- a/pytorch_layer/xdma_driver.py
+++ b/pytorch_layer/xdma_driver.py
@@ -63,6 +63,13 @@ SPI_BASE = 0x4002_5000       # [DFX-only] SPI-over-PCIe (hot-flash без JTAG)
 # legacy alias (модульно совместим со старым именем)
 DDR_BASE = DDR3_BASE
 
+# ---- CHANNEL-RESET 2026-10-22: IOCTL_XDMA_CHANNEL_RESET (inc/xdma_public.h) ----
+IOCTL_CHANNEL_RESET = (0x22 << 16) | (0 << 14) | (0x7 << 2) | 0
+CHANNEL_RESET_NOW = 0x00000001      # XDMA_CHANNEL_RESET_FLAG_NOW
+CHANNEL_RESET_AUTO_ON = 0x00000002  # XDMA_CHANNEL_RESET_FLAG_AUTO_ON
+CHANNEL_RESET_AUTO_OFF = 0x00000004  # XDMA_CHANNEL_RESET_FLAG_AUTO_OFF
+
 
@@ -459,6 +466,12 @@ class XdmaWinUpstream(XdmaDevice):
         k32.CreateEventW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.BOOL,
                                      wintypes.LPCWSTR]
+        k32.DeviceIoControl.argtypes = [
+            wintypes.HANDLE,            wintypes.DWORD,
+            ctypes.c_void_p,            wintypes.DWORD,
+            ctypes.c_void_p,            wintypes.DWORD,
+            ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
 
         class _OVERLAPPED(ctypes.Structure):
@@ -591,6 +604,37 @@ class XdmaWinUpstream(XdmaDevice):
             off += chunk
         return bytes(out)
 
+    def soft_reset_h2c(self, auto_on=None):
+        if self._h2c is None:
+            raise XdmaError("h2c channel handle is None (driver node not open)")
+        flags = CHANNEL_RESET_NOW
+        if auto_on is True:
+            flags |= CHANNEL_RESET_AUTO_ON
+        elif auto_on is False:
+            flags |= CHANNEL_RESET_AUTO_OFF
+        from ctypes import byref
+        inbuf = (self._c.c_ulong * 1)(flags & 0xFFFFFFFF)
+        done = self._c.wintypes.DWORD(0)
+        ok = self._k32.DeviceIoControl(
+            self._h2c, IOCTL_CHANNEL_RESET,
+            inbuf, 4, None, 0, byref(done), None)
+        if not ok:
+            raise XdmaError(
+                f"IOCTL_XDMA_CHANNEL_RESET(flags=0x{flags:X}) failed: "
+                f"WinError {self._c.get_last_error()}")
+        return done.value
+
diff --git a/xdma_driver_win_src_2017/inc/xdma_public.h b/xdma_driver_win_src_2017/inc/xdma_public.h
index 3ef0ab7..34bb356 100644
--- a/xdma_driver_win_src_2017/inc/xdma_public.h
+++ b/xdma_driver_win_src_2017/inc/xdma_public.h
@@ -69,6 +69,15 @@
 #define IOCTL_XDMA_ADDRMODE_GET XDMA_IOCTL(0x4)
 #define IOCTL_XDMA_ADDRMODE_SET XDMA_IOCTL(0x5)
 #define IOCTL_XDMA_DIAG_GET     XDMA_IOCTL(0x6)
+#define IOCTL_XDMA_CHANNEL_RESET XDMA_IOCTL(0x7)
+#define XDMA_CHANNEL_RESET_FLAG_NOW      0x00000001UL
+#define XDMA_CHANNEL_RESET_FLAG_AUTO_ON  0x00000002UL
+#define XDMA_CHANNEL_RESET_FLAG_AUTO_OFF 0x00000004UL
 
 // structure for IOCTL_XDMA_PERF_GET
@@ -85,5 +94,10 @@
     UINT64 bytesTransferred;     // WdfDmaTransactionGetBytesTransferred
 } XDMA_DIAG_DATA;
 
+typedef struct {
+    ULONG Flags;                 // XDMA_CHANNEL_RESET_FLAG_*
+} XDMA_CHANNEL_RESET;
+
 #endif/*__XDMA_WINDOWS_H__*/
diff --git a/xdma_driver_win_src_2017/libxdma/dma_engine.c b/xdma_driver_win_src_2017/libxdma/dma_engine.c
index 706bf78..d69ec33 100644
--- a/xdma_driver_win_src_2017/libxdma/dma_engine.c
+++ b/xdma_driver_win_src_2017/libxdma/dma_engine.c
@@ -806,6 +806,10 @@ static NTSTATUS EngineCreate(...)
     engine->isReqPending = FALSE;
     engine->txnDone = FALSE;
+    engine->channelResetOnTimeout = TRUE;
     status = WdfSpinLockCreate(...);
@@ -1182,6 +1186,84 @@ void XDMA_EngineResetIdle(...) {
               engine->regs->control, engine->regs->status);
 }
 
+NTSTATUS XDMA_EngineResetChannel(IN XDMA_ENGINE* engine) {
+    if (engine == NULL) return STATUS_INVALID_PARAMETER;
+    engine->regs->controlW1C = XDMA_CTRL_RUN_BIT;         // 1) EngineStop
+#if XDMA_CHANNEL_RESET_HW_BIT                            // HW-reset по умолчанию (BIT31)
+    engine->regs->controlW1S = XDMA_CTRL_RST;              // 2) аппаратный канальный reset
+    engine->regs->controlW1C = XDMA_CTRL_RUN_BIT;          //    re-stop (если reset поднял RUN)
+    MemoryBarrier();
+#endif
+    UINT32 st = engine->regs->statusRC;                    // 3) read-clear BUSY/errors
+    volatile ULONG cdc = engine->regs->completedDescCount; // 4) observe
+    PHYSICAL_ADDRESS db = WdfCommonBufferGetAlignedLogicalAddress(engine->descBuffer);
+    engine->sgdma->firstDescLo = db.LowPart;               // 5) re-arm firstDesc (после HW-reset обязателен)
+    engine->sgdma->firstDescHi = db.HighPart;
+    engine->sgdma->firstDescAdj = 0;
+    DMA_DESCRIPTOR* db2 = (DMA_DESCRIPTOR*)WdfCommonBufferGetAlignedVirtualAddress(engine->descBuffer);
+    RtlZeroMemory(db2, WdfCommonBufferGetLength(engine->descBuffer)); // 6) clear bank
+    engine->regs->perfCtrl = 0;                            // 7) clear perf
+    MemoryBarrier();
+    TraceInfo(DBG_DMA, "%s_%u CHANNEL RESET done (mode=%s, ...)", ...);
+    return STATUS_SUCCESS;
+}
+
diff --git a/xdma_driver_win_src_2017/libxdma/dma_engine.h b/xdma_driver_win_src_2017/libxdma/dma_engine.h
index b63d077..234e5df 100644
--- a/xdma_driver_win_src_2017/libxdma/dma_engine.h
+++ b/xdma_driver_win_src_2017/libxdma/dma_engine.h
@@ -201,6 +201,17 @@ typedef struct XDMA_ENGINE_T {
     BOOLEAN txnTimeout;
+    BOOLEAN channelResetOnTimeout;   // default TRUE, авто-сброс на таймауте
 } XDMA_ENGINE;
@@ -287,6 +298,23 @@ NTSTATUS XDMA_EngineWaitCompletion(...);
 VOID XDMA_EngineResetIdle(IN XDMA_ENGINE* engine);
+NTSTATUS XDMA_EngineResetChannel(IN XDMA_ENGINE* engine);
+
diff --git a/xdma_driver_win_src_2017/sys/file_io.c b/xdma_driver_win_src_2017/sys/file_io.c
index 1657802..b01c1a2 100644
--- a/xdma_driver_win_src_2017/sys/file_io.c
+++ b/xdma_driver_win_src_2017/sys/file_io.c
@@ -669,6 +669,58 @@ VOID EvtIoDeviceControl(...) {
     }
+    case IOCTL_XDMA_CHANNEL_RESET:
+    {
+        XDMA_CHANNEL_RESET in = { 0 }; size_t inLen = 0;
+        status = WdfRequestRetrieveInputBuffer(request, sizeof(in), (PVOID*)&in, &inLen);
+        if (!NT_SUCCESS(status)) break;
+        if (inLen < sizeof(in)) { status = STATUS_BUFFER_TOO_SMALL; break; }
+        if (in.Flags & XDMA_CHANNEL_RESET_FLAG_AUTO_ON)
+            engine->channelResetOnTimeout = TRUE;   // под engineLock
+        if (in.Flags & XDMA_CHANNEL_RESET_FLAG_AUTO_OFF)
+            engine->channelResetOnTimeout = FALSE;  // под engineLock
+        if (in.Flags & XDMA_CHANNEL_RESET_FLAG_NOW)
+            status = XDMA_EngineResetChannel(queue->engine);
+        else
+            status = STATUS_SUCCESS;
+        if (NT_SUCCESS(status)) WdfRequestComplete(request, STATUS_SUCCESS);
+        break;
+    }
     default:
@@ -817,6 +869,18 @@ VOID EvtIoWriteDma(...) {
             EngineStop(queue->engine);
         }
+        if (queue->engine->channelResetOnTimeout)
+            XDMA_EngineResetChannel(queue->engine);
         NTSTATUS uc = WdfRequestUnmarkCancelable(Request);
@@ -944,6 +1008,18 @@ VOID EvtIoReadDma(...) {
             EngineStop(queue->engine);
         }
+        if (queue->engine->channelResetOnTimeout)
+            XDMA_EngineResetChannel(queue->engine);
         NTSTATUS uc = WdfRequestUnmarkCancelable(Request);
```

*Примечание: дифф в Приложении A сжат (опущены чисто комментарийные длинные блоки и Trace-декорации) для читаемости; точный полный дифф см. `git diff` по указанным в §1 файлам.*


## UPD. 2026-10-22 (доп. разбор agent): уточнение первопричины и риска BIT31
- Триггер большого объёма — НЕ «порог 500 КБ», а длина цепочки × плотность потока:
  ~125 последовательных раундов «фетч дескриптора (32 Б) → 4 КБ данных → AXI-write»
  из-за отключённого prefetch (`nextAdj=0`, анти-ROF) + CplD-flood в root port (8086:7f3c)
  + posted-write через SmartConnect 125→100 МГц в MIG. Один потерянный completion/фетч/B-ответ
  на любом раунде => `BUSY=1` навсегда (у h2c-движка нет self-timeout).
- Невосстановимость подтверждена: EngineStop/ResetIdle (RUN=0 + read statusRC + re-bind firstDesc)
  НЕ обрывают in-flight транзакцию и НЕ чистят FSM фетча.
- ВНИМАНИЕ (риск): `XDMA_CTRL_RST` (bit31) — по PG195 v4.1 поле 31:28 Channel Control Reserved.
  `EngineResetChannel`, написанный как `controlW1S = XDMA_CTRL_RST` и выставленный по умолчанию
  (`channelResetOnTimeout=TRUE`), РИСКУЕТ писать в зарезервированный бит.
- Рекомендация по умолчанию ПЕРЕСМОТРЕНА: не включать автоматический BIT31-reset по умолчанию,
  пока не подтверждён на железе (A/B на стенде после permission) и (или) не использован
  документированный для этой версии канальный reset (если он есть). Запасной безопасный путь —
  полная переинициализация движка (EngineStop -> перепрограммирование desc -> EngineStart).
- H-LAT bug (код, не к клину): сравнение `actual >= expected` в `XDMA_EngineWaitCompletion`
  опирается на НАКОПИТЕЛЬНЫЙ `completedDescCount` (не очищается) -> возможен ложный «успех»
  маленькой передачи после большой. Чинить сравнение по ДЕЛЬТЕ (запомнить счётчик на старте
  переноса и требовать growth >= numDescriptors).
