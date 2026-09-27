# DMA Test Suite — новый DMA-драйвер (W1)

Набор тестов для **нового DMA-драйвера** (симлинк `\\.\XDMA0dma`), который
проверяет DMA-каналы `h2c_0`/`c2h_0` и доступ к AXI-Lite регистрам через
`\control`. В DFX-сборке DDR3 доступна **только** через DMA-каналы
(без `\user`; BAR2 занят таблицей MSI-X) — см. `docs\ADDRESS_MAP.md` §1.2.

> **Важно:** эти тесты НЕ трогают легаси MMIO-драйвер `\\.\XDMA0`
> (`driver\driver.c`, `driver\test_xdma.c`) — они работают только с
> `\\.\XDMA0dma`.

---

## 1. Сначала драйвер, потом тест

Драйвер, тест и оборудование должны быть в строгом порядке:

1. **Собери и установи драйвер** (`\\.\XDMA0dma`) — этим занимается другой
   контекст (W1); использовать его доводку, в этой ветке — только запускать
   тесты. Сборка легаси-драйвера — `driver\build.cmd` (для справки, инсталляция
   — `driver\install.cmd`). **Тест бесполезен без инсталлированного драйвера**.
2. Прошей карту рабочим DFX-битстримом (DDR3 доступна через хост только по DMA).
3. Загрузи ПЛИС, убедись, что устройство перечисляется и создаёт узлы
   `\\.\XDMA0dma\control`, `\\.\XDMA0dma\h2c_0`, `\\.\XDMA0dma\c2h_0`.
4. Только после этого собирай и запускай тест.

---

## 2. Сборка теста

Тест `test_dma.c` — это **user-mode** программа (не драйвер). Компилируется
средствами WDK/VS2015, как user-mode часть `driver\build.cmd`.

```bat
cd /d C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\driver
build_test_dma.cmd
```

Результат: `build\test_dma.exe`.

Флаги компиляции: `cl /W4 /O2 /MT /D_WIN64 /DAMD64` + user-mode include/lib
(нормальный `kernel32.lib`, никаких `/kernel`). Сборка **не** требует прав
администратора (в отличие от сборки драйвера).

---

## 3. Порядок прогона

Стендовый сценарий — `driver\VERIFY_DMA.cmd` (запускается вручную, **не
автоматически**). Порядок безопасного наращивания:

| Шаг | Команда | Что проверяет | Ожидание |
|---|---|---|---|
| 1 | `test_dma.exe regs` | readback регистров через `\control` | `TDOT_STATUS`, `GPIO_DATA` читаются, без ошибок I/O |
| 2 | `test_dma.exe loopback 4` | LCG-паттерн 4 Б: h2c write → c2h read, байт-сверка | `loopback 4 bytes: PASS` |
| 3 | `test_dma.exe loopback 1024` | то же, 1 КБ | `PASS` |
| 4 | `test_dma.exe loopback 1048576` | то же, 1 МиБ | `PASS` |
| 5 *(опц.)* | `test_dma.exe loopback 8388608` | то же, 8 МиБ (максимум) | `PASS` |
| 6 | `test_dma.exe ioctl` | `PERF_START/GET/STOP` + `ADDRMODE_GET` на `c2h_0` | `dataCycleCount > 0`, `ADDRMODE == 0` |
| 7 | `test_dma.exe align` | намеренно невыровненные размер/offset | отказ API или приемлемый прогон, **без падения/BSOD** |
| 8 | `test_dma.exe dot 8` | канонический TDOT-путь: DMA данных + регистры + GO + DONE + чтение `result` | `DONE`, печатает 48-бит результат |

Python-версия (pytest / CLI):

```bat
cd /d C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\pytorch_layer
python test_dma_win.py --smoke   # безопасный минимум: regs + loopback 4
python test_dma_win.py --full    # всё: regs, loopback 4/1K/1M, ioctl, align, dot
# либо pytest test_dma_win.py -v
```

---

## 4. Ожидаемые результаты

- **regs**: `TDOT_STATUS`, `TDOT_N_IN`, `TDOT_RES0/RES1`, `GPIO_DATA` читаются
  без `WinError`; значения 32-бит. `DONE=0` если ядро только что сброшено.
- **loopback**: записанный LCG-буфер полностью совпадает с прочитанным
  (посимвольно). Размеры: 4, 1024, 1048576, (8388608) — каждый по отдельному
  запуску. Чанки ≤ 1 МиБ, суммарный трансфер ≤ 8 МиБ.
- **ioctl**: `dataCycleCount > 0` (был реальный DMA), `ADDRMODE == 0`.
- **align**: нарушение кратности 4 не вызывает аварии процесса и не роняет
  систему — драйвер либо отклоняет запрос (WinError), либо прогоняет как есть.
- **dot**: `result` — 48-битное слово; числовое значение проверяй декодером
  `ternary_sw\block\tfloat48.py` / `fpga_backend._bits_to_float`. Для N пар
  `1.0*1.0` ожидается эквивалент N.

---

## 5. Контракт адресации (свод значений)

| Узел | Действие | Offset |
|---|---|---|
| `\\.\XDMA0dma\control` | чтение/запись регистра | `axi_addr - 0x40000000` |
| `\\.\XDMA0dma\h2c_0` | DMA-запись в DDR3 | `raw_ddr3_offset` (без `+0x80000000`) |
| `\\.\XDMA0dma\c2h_0` | DMA-чтение из DDR3 | `raw_ddr3_offset` |

Минимальное выравнивание трансфера — 4 байта (безопасно 8), максимум на
транзакцию — `XDMA_MAX_TRANSFER_SIZE` = 8 МиБ, хостовый чанк — 1 МиБ.
IOCTL-коды на `c2h_0`: `GET_VERSION=0x0`, `PERF_START=0x1`, `PERF_STOP=0x2`,
`PERF_GET=0x3`, `ADDRMODE_GET=0x4`, `ADDRMODE_SET=0x5`; `PERF_GET` возвращает
`XDMA_PERF_DATA{clockCycleCount, dataCycleCount, pendingCount}` (Verified:
`xdma_driver_win_src_2017\inc\xdma_public.h`).

---

## 6. Диагностика

- `ERROR: cannot open \\.\XDMA0dma\control (GLE=2/3/...` — драйвер не установлен
  или именование иное; проверь `driver\VERIFY_DMA.cmd` загруженность и
  соответствие `base` в `pytorch_layer\test_dma_win.py`.
- Таймаут `dot`/`loopback` — проверь, что ПЛИС загружена, DDR3 отвечает,
  MIG `init_calib_complete` (статус через GPIO2/DMA).
- Ненулевой `ADDRMODE` — драйвер в неправильном режиме адресации; обычно 0.