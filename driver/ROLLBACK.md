# ROLLBACK.md — план отката драйвера XDMA

> Актуальная версия: **v1.1.4.0** (пакет `oem10.inf`, сервис `XDMA`, бинарник
> `C:\Windows\System32\drivers\XDMA.sys`). Обновлено 2026-09-11.

## 0. Быстрый откат исходников (до правок аудита 2026-09-11)

- Снапшот: `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\_backup_20260911_215624\`
- Правки в git (11 файлов): `git -C <корень> diff`; откат одного файла:
  `git -C <корень> checkout -- driver/driver.c`
- Полный откат драйвера к состоянию до аудита (v1.1.3.0):

      pnputil /delete-driver oem10.inf /uninstall /force
      del C:\Windows\System32\drivers\XDMA.sys
      (затем скопировать файлы из _backup_.../driver и пересобрать build.cmd)

## 1. Полное удаление драйвера из системы

    sc stop XDMA
    sc delete XDMA
    pnputil /delete-driver oem10.inf /uninstall /force
    del C:\Windows\System32\drivers\XDMA.sys

Проверка: `pnputil /enum-drivers` — нет `xdma.inf`; `sc query XDMA` — ошибка 1060;
диспетчер устройств → «Системные устройства» → плата без драйвера.
(Всё это делает `uninstall.cmd` — с исправлением FIX-14 для RU-локали.)

## 2. Возврат к старой сборке (воспроизведение бага 0x1000007E)

1. В `build.cmd` вернуть `/entry:FxDriverEntry` → `/entry:DriverEntry`
   (или `git checkout <старый коммит> -- build.cmd`).
2. `build.cmd` → пересобрать.
3. Установить (pnputil или sc). ОЖИДАЕМЫЙ РЕЗУЛЬТАТ: BSOD 0x1000007E при
   `sc start XDMA` (`XDMA+0x1067`, `call [rax+0x3A0]`, rax=0).

## 3. Вывод из BSOD-цикла (если PnP сам стартует сервис при загрузке)

WinRE → Командная строка:

    reg load HKLM\Tmp C:\Windows\System32\config\SYSTEM
    reg add "HKLM\Tmp\ControlSet001\Services\XDMA" /v Start /t REG_DWORD /d 4 /f
    reg unload HKLM\Tmp

(`Start=4` = отключена). После загрузки — п.1.

## 4. Тестовый стенд

`build\test_xdma.exe [all|gpio|tdot|xadc|proto|icap|ddr3]`.
На DFX-сборке `ddr3` и `xadc` печатают **SKIP** (так и должно быть).
`icap`/`proto` запускать по одному только на актуальном битстриме.
