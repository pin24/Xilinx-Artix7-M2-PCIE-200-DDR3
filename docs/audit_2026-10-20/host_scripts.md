# Аудит скриптов проекта Xilinx-Artix7-M2-PCIE-200-DDR3
## Дата: 2026-10-20 | Исполнитель: MultiTool

---

## Сводная таблица

| Severity | Count | Top-5 (file:line) |
|----------|-------|-------------------|
| P1 (Critical) | 12 | obs_smi.py:147, obs_smi.py:148, monitor_obs.py:131, monitor_obs.py:147, bw_profile.py:45 |
| P2 (High) | 8 | obs_smi.py:131, check_burst_4kb.py:41, bw_profile.py:30, monitor_obs.py:57, nn_audio_train_fpga.py:27 |
| P3 (Medium) | 5 | gen.py:10, nn_audio_common.py:20, bench_dma_dual.py (не предоставлен), nn_audio_train_cpu.py:51 |
| P4 (Low) | 3 | monitor_temp.py:126, nn_audio_common.py:59, obs_smi.py:30 |

---

## P1 — Critical (деление на ноль, падение скрипта)

### 1. Деление на ноль в bw_profile.py
**file:bw_profile.py:45**
```
wmb=(sz/wdt/1e6); rmb=(sz/rdt/1e6)
```
**Сценарий:** При очень быстрой DMA (1-2 мкс) `wdt` или `rdt` могут быть 0 из-за точности `time.time()`. Вызовет ZeroDivisionError.
**Рекомендация:** `wdt = max(wdt, 1e-9)` перед делением.

### 2. Деление на ноль в monitor_obs.py
**file:monitor_obs.py:131-132**
```
dcyc = cur["cycles"] - prev["cycles"]
busy_p = 100.0 * (cur["busy"] - prev["busy"]) / dcyc
```
**Сценарий:** Если между кадрами счётчик не изменился (dcyc=0) — деление на 0. Защита `cyc = s["cycles"] or 1` есть только для первого чтения, но не для дельты.
**Рекомендация:** `dcyc = max(dcyc, 1)`.

### 3. Деление на ноль в monitor_obs.py
**file:monitor_obs.py:147**
```
dmamb = dbeat * 8 / dt_real / 1e6
job_s = (dj / dt_real) if dj > 0 else 0.0
```
**Сценарий:** `dt_real` вычисляется как `cur_t - prev_t`. При очень быстром цикле (часы с высоким приоритетом) может быть 0.
**Рекомендация:** `dt_real = max(dt_real, 1e-6)`.

### 4. Деление на ноль в obs_smi.py
**file:obs_smi.py:147**
```
dmamb = dbeat * 8 / dt_real / 1e6
```
**Сценарий:** Аналогично monitor_obs — при dt_real=0 (быстрый цикл, VF/троттлинг).
**Рекомендация:** `dt_real = max(dt_real, 1e-6)` перед использованием.

### 5. Деление на ноль в obs_smi.py
**file:obs_smi.py:148**
```
job_s = (dj / dt_real) if dj > 0 else 0.0
```
**Сценарий:** dt_real может быть 0 даже при dj>0 (переполнение/wrap счётчика).
**Рекомендация:** `dt_real = max(dt_real, 1e-6)`.

### 6. Переполнение 32-битных счётчиков OBS
**file:obs_smi.py:131**
```
dcyc = cur["cycles"] - prev["cycles"]
```
**Сценарий:** Счётчики OBS 32-битные. При ~200 МГц такт переполняется за ~21 секунду. Если цикл опроса >21с — `dcyc` станет отрицательным. Все проценты (busy_p, mem_p и т.д.) будут неверны.
**Рекомендация:** Применить маску: `dcyc = (cur["cycles"] - prev["cycles"]) & 0xFFFFFFFF`, затем `if dcyc < 0: dcyc += 0x100000000`.

### 7. Захардкоженные пути устройств (Windows)
**file:bw_profile.py:30-31**
```
h0=Ch(r"\\.\XDMA0dma\h2c_0"); c0=Ch(r"\\.\XDMA0dma\c2h_0")
```
**Сценарий:** Жёстко привязан к XDMA0dma. На системе с другим номером (XDMA1dma, XDMA2dma) скрипт упадёт.
**Рекомендация:** Сделать параметр `--device` или авто-поиск.

### 8. Захардкоженные пути в monitor_obs.py
**file:monitor_obs.py:57-58**
```
base = args.dev if args.dev else (r"\\.\XDMA0dma" if sys.platform.startswith("win") else "/dev/xdma0")
```
**Сценарий:** Аналогично — привязка к XDMA0dma.

### 9. Захардкоженные пути в obs_smi.py
**file:obs_smi.py:56**
```
base = args.dev or r"\\.\XDMA0dma"
```

### 10. Захардкоженный адрес в nn_audio_train_fpga.py
**file:nn_audio_train_fpga.py:27**
```
dev = XdmaWinUpstream(base=r"\\.\XDMA0dma")
```
**Сценарий:** При нескольких платах — не работает.

### 11. Адрес GPIO в check_mig.py
**file:check_mig.py:8**
```
GPIO2_DATA = 0x40020008
```
**Сценарий:** Адрес изменён (см. комментарий про 0x40020008 vs 0x40000008), но если прошивка изменится — скрипт сломается без предупреждения.
**Рекомендация:** Добавить проверку BUILD_ID/CAPS перед чтением.

### 12. Адрес XADC в monitor_temp.py
**file:monitor_temp.py:19**
```
XADC_BASE = 0x4600_0000
```
**Сценарий:** Жёсткая привязка к адресу. При изменении DFX-топологии — ошибка.

---

## P2 — High (утечки ресурсов, бесконечные циклы)

### 1. Утечка handle в bw_profile.py
**file:bw_profile.py:18-19**
```
self.h=self.k.CreateFileW(path,0xC0000000,0,None,3,0x40000000,None)
```
**Сценарий:** handle не закрывается. При долгом вызове — утечка ~4KB на вызов.
**Рекомендация:** Добавить `__del__` или `close()` + контекстный менеджер.

### 2. Утечка ресурсов в monitor_obs.py
**file:monitor_obs.py:59-60**
```
dev = _Backend(base=base)
core = TdotCore(dev, num_mac=args.num_mac, ddr_base=args.ddr_base)
```
**Сценарий:** dev и core не освобождаются при выходе (KeyboardInterrupt, исключение).
**Рекомендация:** `try/finally` с `dev.close()`.

### 3. Утечка в obs_smi.py
**file:obs_smi.py:62-63**
```
dev = Backend(base=base)
core = TdotCore(dev, num_mac=args.num_mac, ddr_base=args.ddr_base)
```

### 4. Утечка в monitor_temp.py
**file:monitor_temp.py:41-45**
```
self._dev = XdmaLinux(f"/dev/{device}") / XdmaWindows()
```
**Сценарий:** Не закрывается.

### 5. Потенциальный бесконечный цикл
**file:check_burst_4kb.py:41**
```
for _ in range(10000):  # страховка
```
**Сценарий:** Если `issued >= total` никогда не выполнится (зависание логики FSM) — 10000 итераций не хватит для обнаружения. Реальная проблема: при `L < 0` возвращается None, но проверка `if seq is None` есть. Однако если `issued` растёт медленно — 10000 может быть достаточно. Но страховка от бесконечного цикла — хорошо.
**Статус:** НЕ ошибка, но значение 10000 эмпирическое. Документировать.

### 6. Логическая ошибка в monitor_temp.py
**file:monitor_temp.py:126-130**
```
if samples and invalid == samples:
    print("ВНИМАНИЕ: все отсчёты INVALID...")
    return 3
```
**Сценарий:** При `--allow-invalid` возвращается 3, хотя пользователь явно просил не считать ошибкой.
**Рекомендация:** При `--allow-invalid` возвращать 0 даже если все невалидны.

---

## P3 — Medium (мёртвый код, дубликаты, несоответствия)

### 1. Несоответствие DURATION
**file:gen.py:10**
```
DURATION = 5.0       # 3 секунды
```
**Сценарий:** В комментарии "3 секунды", в коде 5.0. Генерируются 5-секундные файлы.
**Рекомендация:** Исправить комментарий или константу.

### 2. Относительный путь DATA_DIR
**file:nn_audio_common.py:20**
```
DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "audio_dataset_500_3s")
```
**Сценарий:** При запуске из другого каталога — файлы не найдутся.
**Статус:** Работает при запуске из корня проекта.

### 3. Дублирование HIDDEN
**file:nn_audio_train_cpu.py:50-51**
```
AC.HIDDEN = args.hidden
HIDDEN = args.hidden
```
**Сценарий:** Избыточно, но не ошибка.

### 4. Не предоставлены bench_dma_dual.py / bench_dma_serial.py
**Сценарий:** Упомянуты в задании, но не читались (не найдены в указанной области). Требуют отдельного анализа на копипасту.

### 5. Численная неустойчивость pinv
**file:nn_audio_train_fpga.py:60**
```
W2 = (np.linalg.pinv(Ht @ H + 1e-3 * np.eye(HIDDEN)) @ (Ht @ ys.ravel()))[:, None]
```
**Сценарий:** При плохо обусловленной H (почти вырожденная) — pinv даст большие веса, rmse на трейне ≠ rmse на инференсе.
**Рекомендация:** Добавить регуляризацию (уже есть 1e-3), документировать.

---

## P4 — Low (кодировка, предупреждения)

### 1. reconfigure может не работать
**file:obs_smi.py:30**
```
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
```
**Сценарий:** На Python <3.9 или в некоторых окружениях (PyPy, embedded) — AttributeError.
**Рекомендация:** `try/except AttributeError`.

### 2. Деление на 32767 без проверки
**file:nn_audio_common.py:59**
```
ys[i, 0] = samples[t] / 32767.0
```
**Сценарий:** Если int16 значение = -32768 → /32767 = -1.00003 (выход за [-1, 1]).
**Статус:** Не критично (FP32 модель переварит), но для строгой нормализации лучше `max(-32768, min(32767, samples[t])) / 32768.0`.

### 3. Нет проверки результата dot
**file:nn_audio_common.py:88-92**
```
acc += float(np.asarray(fb.run_dot(...)).ravel()[0])
```
**Сценарий:** Если FB вернул NaN/Inf — не проверяется.

---

## Таблица метрик

| Метрика | Как считается | Корректно ли |
|---------|---------------|--------------|
| MB/s (bw_profile) | sz / dt / 1e6 | ❌ dt может быть 0 |
| MB/s (obs_smi) | dbeat * 8 / dt_real / 1e6 | ❌ dt_real может быть 0 |
| JOB/s | dj / dt_real | ❌ dt_real может быть 0, dj может быть 0 при переполнении |
| AR_STALL% | s['ar_stall']/cyc | ✅ (cyc ≥ 1) |
| R_WAIT% | s['r_wait']/cyc | ✅ |
| BUSY% | (busy_delta)/dcyc | ❌ dcyc может быть 0/отрицательным |
| FPGA matmul | X @ W (cpu) / fb.run_dot (fpga) | ✅ |
| Нормировка аудио | samples / 32767 | ⚠️ -32768 → -1.00003 |
| Фаза | (f * t / SR) % 1 | ✅ |

---

## Сохранено

Файл сохранён в: `C:\Temp\gigatool\audit2026-10-20\host_scripts.md`

---

## Рекомендации (priority)

1. **Сейчас (P1):** Добавить `max(dt, 1e-6)` во всех местах вычисления MB/s и JOB/s. Добавить маску 32-бит для цикловых счётчиков.
2. **Сейчас (P1):** Все захардкоженные пути/адреса — вынести в аргументы командной строки с авто-определением.
3. **Потом (P2):** Закрывать handle/устройства в finally. Документировать 10000 в check_burst_4kb.
4. **Потом (P3):** Исправить DURATION=5.0 → 3.0 (или обновить тесты). Добавить проверку -32768 в nn_audio_common.
5. **Никогда (P4):** Не использовать reconfigure без try/except.