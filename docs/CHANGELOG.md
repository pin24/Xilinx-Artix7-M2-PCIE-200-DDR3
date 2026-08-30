# Changelog — XDMA DDR3 Driver

## [1.1.0] — 2026-08-28
### Fixed
- **Vivado BD: XDMA IP subcore (pcie2_ip) повреждён**: `reset_target` + `generate_target` уничтожил лицензионный компонент. 
  - Tcl-скрипт `rebuild_xdma_ip.tcl` не работает на повреждённом BD (get_property падает на disconnected gpio_0).
  - **Решение**: Vivado GUI → удалить xdma_0 → добавить новый XDMA 4.1 (BAR0=128MB, pciebar2axibar=0x40000000) → Run Connection Automation → проверить адреса → make_wrapper.
- **Reference repo**: https://github.com/rigoorozco/m2-artix7-accelerator-card — подтверждена идентичность настроек XDMA, GTP lane reversal, MIG DDR3.

## [1.0.1] — 2026-08-27
### Fixed
- **RTL: icap_ctrl.sv — stale address bug**: write-decode использовал `awaddr_q` (зарегистрированный, non-blocking) вместо `S_AXI_AWADDR` → DATA не записывалась. Заменены все `awaddr_q` на `S_AXI_AWADDR` в write-decode.
- **RTL: xdma_ddr3_core_top.sv — width mismatch**: `s_axil_awaddr`/`araddr` 8 бит (несовместимо с BD 32 бит) → исправлено на `[31:0]`.
- **RTL: xdma_ddr3_core_top.sv — missing drivers**: не объявлены `s_axil_bresp`, `s_axil_rresp`, `icap_rresp` → добавлены `logic [1:0]`.
- **RTL: icap_ctrl.sv — implicit declaration**: `icap_cs`, `icap_rw`, `icap_data` использовались в instantiation ICAPE2 до объявления → перенесены выше.
- **build_all.tcl — GTP placement conflict**: stale checkpoint из предыдущего impl конфликтовал с новым LOC XDC. Удаление `runs/synth_1` и `runs/impl_1` диска перед сборкой.
- **build_all.tcl — IP core destruction**: `reset_target` + `generate_target` уничтожал XDMA IP subcore (pcie2_ip). Убраны — только `make_wrapper`.

### Known Issue
- **XDMA IP subcore (pcie2_ip) повреждён**: `reset_target` + `generate_target` в предыдущей версии скрипта уничтожил лицензионный компонент. Восстановление: открыть проект в Vivado GUI, удалить XDMA IP из BD, пересоздать из IP Catalog с BAR0=128MB.

## [1.0.0] — 2026-08-26

### Fixed
- BSOD `system_thread_exception_not_handled` при загрузке драйвера
  - Причина: `__security_cookie` константа (0xABCDEF) + `__security_init_cookie` no-op → WDF падает при FxDriverEntry (GS epilog mismatch)
  - Исправление: `__security_init_cookie` заполняет cookie через `KeQueryPerformanceCounter`
- RTL bug: запись GO (0x00) затирала N_IN через биты [16:8] в tdot_axi4.sv
  - Исправление: удалена строка `n_in_reg <= S_AXI_WDATA[16:8]` из ветки 4'd0
- XADC адрес: 0x45000000 → 0x46000000 (согласно BD, addr_map)
- USB handle: `\\.\XDMA0\control` → `\\.\XDMA0` (симлинк в драйвере)
- GPIO_TRI: 0xFF (input) → 0x00 (output)
- Use-after-return при таймауте OVERLAPPED: добавлен `CancelIo` после таймаута
- Integer overflow в `bar2Offset + bufferLen`: двойная проверка `bar2Offset > bar2Len || bufferLen > bar2Len - bar2Offset`
- `WdfObjectDelete(device)` → double-free: удалён явный вызов (WDF управляет сам)
- `MmUnmapIoSpace(NULL)`: добавлен guard `if (ptr != NULL)` в `PrepareHardware`
- `DriverPoolTag='MDX'` (3 символа) → `'XDMA'` (4 символа)
- `WdfDeviceInitSetIoType` не задан: добавлен `WdfDeviceIoBuffered` до `WdfDeviceCreate`
- Повторный `PrepareHardware` без очистки: добавлен cleanup в начале (unmap + close)
- `sc create` без пробела после `=`: исправлен синтаксис `type= kernel`
- `libcntpr.lib` не нужен, `BufferOverflowK.lib` конфликтует: удалены лишние линковки
- Неинициализированные `Bar0PhysAddr`/`Bar2PhysAddr`: инициализация нулями при объявлении
- `WdfPciDeviceGetBar` → `ResourceListTranslated`: исправлен метод получения BAR (транслированные ресурсы)

### Added
- KMDF драйвер с SAFE INIT (никаких чтений из BAR'ов при инициализации — только `MmMapIoSpace` в `EvtDevicePrepareHardware`)
- BAR0+BAR2 архитектура: BAR0 (AXI-Lite, 1:1 mapping), BAR2 (DDR3, граница 0x80000000)
- Bounds check для BAR0 (совместим с 128MB BAR сканированием)
- `IOCTL_XDMA_GET_BAR_INFO` — получение информации о BAR'ах из user-mode
- `test_xdma.exe`: 5 тестов (GPIO, TDOT_REGS, XADC, TDOT_PROTO, ICAP)
- `build.cmd`: полный цикл сборки (cl + link + sign + генерация .cat/.cer)
- `emulate_test.py`: интеграционная эмуляция FPGA (FpgaEmulator) + драйвер (6 тестов)
- `edge_cases.py`: тестирование граничных случаев (нулевые буферы, адреса вне диапазона)
- Безопасное копирование через `RtlCopyMemory` (вместо `READ_REGISTER` — не зависает при неотвечающем FPGA)

### Changed
- `build.cmd`: добавлена генерация .cat и .cer (WDKTestCert Pin)
- `build_all.tcl`: добавлен `open_bd_design` перед `set_property`
- Схема адресации: барьер 0x80000000 между AXI-Lite и DDR3 пространствами (вместо проверки `Bar0Length`)
- `driver.c`: все операции с BAR переведены на `ResourceListTranslated` вместо `WdfPciDeviceGetBar`
- `test_xdma.c`: все тесты переведены на OVERLAPPED I/O с корректной обработкой таймаутов