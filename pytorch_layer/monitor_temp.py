#!/usr/bin/env python3
r"""Мониторинг температуры и VCCINT Artix-7 через XADC (BAR0 @ 0x4600_0000).

Канонический production-вариант: pytorch_layer/monitor_temp.py.
Эта standalone-копия имеет те же адреса/формулы + 4 добавления:
  * проверка MAGIC-регистра +0x0C ('XADC') — детект старого битстрима;
  * статус MIG через GPIO2 (mmcm_locked / init_calib_complete);
  * режим --once (один замер — для скриптов/CI, exit 3 = нет данных);
  * Windows-бэкенд — КАНОНИЧЕСКИЙ порядок рабочих скриптов
    (stress_platform.py:73-104, obs_smi.py:70-78): XdmaWinDma/
    XdmaWinUpstream с базой \\.\XDMA0dma (DMA-драйвер xdma_dma.inf),
    затем \\.\XDMA0, затем проектный XdmaWinDriver (driver.c). Без xdma_rw.exe.

Аппаратура: rtl/integration/xadc_temp.sv (u_xadc, AXI-Lite M05) +
rtl/integration/xadc_prim.sv (u_xadc_prim, DCLK=clk50=50 МГц, DRP-FSM:
DADDR 0x00 temp / 0x06 vccint, сэмпл раз в секунду).

ВНИМАНИЕ (исправлено 2026-10-22, прогон владельца): регистры хранят
ПОЛНОЕ 16-битное DRP-слово (xadc_temp.sv:145-146: {16'h0, temp_val}),
а 12-битный код сидит в битах [15:4] — xadc_prim.sv:9-11 прямо
предписывает Temp[°C] = DO[15:4] * 503.975/4096 - 273.15.
Без сдвига показания ровно в 16 раз завышены (было 4262.63 °C,
стало 10.3 °C при raw=0x9000). docs/ADDRESS_MAP.md:319-320 и
stress_platform.py:122-130 содержат ту же ошибку (сырое слово без
сдвига) — здесь сдвиг обязателен.
BUG-031 разрешён (docs/ADDRESS_MAP.md §7, актуализация 2026-09-27):
xadc_prim опрашивает XADC напрямую, минуя конфликт UTLZ-1 с MIG
(XADC_En=Off), и подаёт реальные raw_temp/raw_vccint/raw_valid.

Карта регистров (rtl/integration/xadc_temp.sv:5-8, read mux :144-151):
  +0x00  TEMP    RO  [15:0]  ПОЛНОЕ DRP-слово XADC (НЕ 12-битный код!)
  +0x04  VCCINT  RO  [15:0]  полное DRP-слово
  +0x08  VALID   RO  [0]     флаг валидности (липкий: 1 после 1-го сэмпла)
  +0x0C  MAGIC   RO  32'h58414443 ('XADC') — идентификация блока

Формулы (UG480; контракт xadc_prim.sv:9-11 — код в DO[15:4]):
  code   = drp_word >> 4 & 0xFFF
  temp_c = code * 503.975 / 4096 - 273.15
  vccint = code * 3.0     / 4096
Живой rail читается ~0x555x (1 В), ровный 0 — канал не опрашивается:
в xadc_prim.sv:11/:112 DADDR 0x06 подписан VCCINT, но по UG480 0x06 =
VCCBRAM (VCCINT = 0x01). На raw=0 это не влияет (и VCCBRAM живой
не бывает 0) — вероятна прошивка до двухканального FSM; температура
при этом валидна. Сырые слова видны в колонке raw t/v.

Резервный статус платы — MIG через GPIO2 axi_gpio_0 (docs/ADDRESS_MAP.md:74,
:333-334): база 0x4002_0000, GPIO2_DATA 0x08: bit0 = mmcm_locked,
bit1 = init_calib_complete. Это СТАТУС, а не температура.

Безопасность: скрипт только ЧИТАЕТ BAR0 (никаких AXI-Lite write, никаких
DMA) — не может дестабилизировать плату во время wedge-отладки.

Usage:
    python monitor_temp.py                       # опрос каждые 2 с
    python monitor_temp.py --interval 5 --log temps.csv
    python monitor_temp.py --once                # один замер и выход
    python monitor_temp.py --device xdma0
"""
from __future__ import annotations

import argparse
import csv
import os
import sys
import time
from datetime import datetime, timezone

# --- импорт XDMA-драйвера (как в pytorch_layer/monitor_temp.py:17) ---
try:
    from xdma_driver import (XdmaLinux, XdmaWinDriver, XdmaWinUpstream,
                             XdmaError)
except ImportError:
    _here = os.path.dirname(os.path.abspath(__file__))
    for _cand in (os.path.join(_here, "pytorch_layer"),
                  os.path.abspath(os.path.join(_here, "..", "pytorch_layer"))):
        if os.path.isfile(os.path.join(_cand, "xdma_driver.py")):
            sys.path.insert(0, _cand)
            from xdma_driver import (XdmaLinux, XdmaWinDriver,
                                     XdmaWinUpstream, XdmaError)
            break
    else:
        sys.exit("monitor_temp: не найден xdma_driver.py — положите скрипт "
                 "рядом с pytorch_layer/ или внутрь неё.")


# --- адреса (docs/ADDRESS_MAP.md §2/§7) ---
XADC_BASE: int = 0x4600_0000   # u_xadc (AXI-Lite M05), xadc_temp.sv
REG_TEMP: int = 0x00           # [15:0] полное DRP-слово temp (xadc_temp.sv:5)
REG_VCCINT: int = 0x04         # [15:0] полное DRP-слово vcc  (xadc_temp.sv:6)
REG_VALID: int = 0x08          # [0]    valid, липкий  (xadc_temp.sv:7)
REG_MAGIC: int = 0x0C          # 32'h58414443 'XADC'   (xadc_temp.sv:8)
MAGIC_XADC: int = 0x5841_4443

GPIO_BASE: int = 0x4002_0000   # axi_gpio_0 (M00), docs/ADDRESS_MAP.md:74
GPIO2_DATA: int = 0x08         # ch2: bit0 mmcm_locked, bit1 init_calib_complete

# --- формулы и пороги (UG480; контракт DO[15:4] — xadc_prim.sv:9-11;
#     docs/ADDRESS_MAP.md:319-320 НЕ учитывают сдвиг, см. докстринг) ---
TEMP_SCALE: float = 503.975
TEMP_OFFSET: float = 273.15
VCCINT_SCALE: float = 3.0
ADC_RANGE: float = 4096.0
WARN_TEMP: float = 85.0        # WARNING-порог, °C
CRIT_TEMP: float = 100.0       # CRITICAL-порог, °C


def _open_windows_device(dev_base: str | None = None):
    r"""Открыть плату на Windows в КАНОНИЧЕСКОМ порядке рабочих скриптов
    (копия приоритета stress_platform.py:73-104; obs_smi.py:70-78):

      1. XdmaWinDma(base=\\.\XDMA0dma)   — DMA-драйвер (staged xdma_dma.inf,
         символ. линк XDMA0dma; требует только \\control, read сам уходит
         в \\user с фолбэком, test_dma_win.py:134-141/:191-195)
      2. XdmaWinDma(base=\\.\XDMA0)
      3. XdmaWinUpstream(base=\\.\XDMA0dma)
      4. XdmaWinUpstream(base=\\.\XDMA0)
      5. XdmaWinDriver()                 — проектный driver.c, \\.\XDMA0 (FIX-1)

    При явном dev_base — только он. xdma_rw.exe НЕ используется.
    Возвращает (dev, подпись_бэкенда); все неудачи — XdmaError со списком.
    """
    attempts: list[str] = []

    def _try(fn, label):
        try:
            return fn(), label
        except (XdmaError, OSError) as e:
            attempts.append(f"{label}: {e}")
            return None

    bases = [dev_base] if dev_base else [r"\\.\XDMA0dma", r"\\.\XDMA0"]
    try:
        from test_dma_win import XdmaWinDma          # лениво: тяжёлый модуль
        for b in bases:
            r = _try(lambda b=b: XdmaWinDma(base=b), f"XdmaWinDma({b})")
            if r:
                return r
    except ImportError:
        attempts.append("XdmaWinDma: test_dma_win недоступен")
    for b in bases:
        r = _try(lambda b=b: XdmaWinUpstream(base=b), f"XdmaWinUpstream({b})")
        if r:
            return r
    if not dev_base or dev_base == r"\\.\XDMA0":
        r = _try(lambda: XdmaWinDriver(), r"XdmaWinDriver(\\.\XDMA0)")
        if r:
            return r
    raise XdmaError(
        "Windows: ни один бэкенд не открыл плату (ожидаемые узлы: "
        r"\\.\XDMA0dma или \\.\XDMA0). Попытки:\n  "
        + "\n  ".join(attempts))


class TempMonitor:
    r"""Read-only монитор: XADC (temp/vccint) + MIG-статус (GPIO2).

    Windows: селекция бэкендов как в рабочих скриптах — XdmaWinDma /
    XdmaWinUpstream с базой \\.\XDMA0dma (узлы \\control/\\user/
    \\h2c_0/\\c2h_0; read принимает ПОЛНЫЙ AXI-адрес, offset считает сам,
    test_dma_win.py:191-195), фолбэк — проектный XdmaWinDriver (driver.c,
    \\.\XDMA0, FIX-1). xdma_rw.exe НЕ используется.
    Linux: XdmaLinux (/dev/xdma0_control|user, xdma_driver.py:109-162).
    """

    def __init__(self, device: str = "xdma0", dev=None,
                 dev_base: str | None = None):
        if dev is not None:                 # переиспользование открытого dev
            self._dev = dev
        elif sys.platform == "win32":
            self._dev, self.backend = _open_windows_device(dev_base)
        else:
            self._dev = XdmaLinux(f"/dev/{device}")
            self.backend = f"XdmaLinux(/dev/{device})"

    # ---- низкоуровневые read-only чтения ----
    def _rd32(self, addr: int) -> int:
        return int.from_bytes(self._dev.read(addr, 4), "little")

    def read_magic(self) -> int:
        return self._rd32(XADC_BASE + REG_MAGIC) & 0xFFFF_FFFF

    def magic_ok(self) -> bool:
        return self.read_magic() == MAGIC_XADC

    def read_valid(self) -> bool:
        return bool(self._rd32(XADC_BASE + REG_VALID) & 0x1)

    @staticmethod
    def _drp_code(word16: int) -> int:
        """12-битный код XADC из полного DRP-слова (DO[15:4], xadc_prim.sv:9-10).

        Без сдвига показания ровно в 16 раз завышены (прогон 2026-10-22:
        raw=0x9000 -> 4262.63 C вместо 10.3 C)."""
        return (word16 >> 4) & 0x0FFF

    def read_raw_words(self) -> tuple[int, int]:
        """Сырые 16-битные DRP-слова TEMP/VCCINT как есть (диагностика)."""
        return (self._rd32(XADC_BASE + REG_TEMP) & 0xFFFF,
                self._rd32(XADC_BASE + REG_VCCINT) & 0xFFFF)

    def read_temperature(self) -> float:
        w = self._rd32(XADC_BASE + REG_TEMP) & 0xFFFF
        return self._drp_code(w) * TEMP_SCALE / ADC_RANGE - TEMP_OFFSET

    def read_vccint(self) -> float:
        w = self._rd32(XADC_BASE + REG_VCCINT) & 0xFFFF
        return self._drp_code(w) * VCCINT_SCALE / ADC_RANGE

    def read_mig_status(self) -> tuple[bool, bool]:
        """GPIO2_DATA -> (mmcm_locked, init_calib_complete)."""
        v = self._rd32(GPIO_BASE + GPIO2_DATA)
        return bool(v & 0x1), bool(v & 0x2)

    # ---- один замер ----
    def snapshot(self) -> dict:
        ok = self.magic_ok()
        valid = self.read_valid() if ok else False   # при чужом блоке не читаем
        s: dict = {"magic_ok": ok, "valid": valid}
        if valid:
            s["temp_raw"], s["vcc_raw"] = self.read_raw_words()
            s["temp_c"] = (self._drp_code(s["temp_raw"]) * TEMP_SCALE
                           / ADC_RANGE - TEMP_OFFSET)
            s["vccint_v"] = self._drp_code(s["vcc_raw"]) * VCCINT_SCALE / ADC_RANGE
        s["mmcm_locked"], s["init_calib_complete"] = self.read_mig_status()
        return s

    # ---- цикл опроса ----
    def poll_loop(self, interval: float = 2.0,
                  csv_path: str | None = None) -> int:
        fout = writer = None
        if csv_path:
            fout = open(csv_path, "w", newline="", encoding="utf-8")
            writer = csv.writer(fout)
            writer.writerow(["timestamp_utc", "temp_c", "vccint_v",
                             "temp_raw", "vcc_raw", "valid",
                             "mmcm_locked", "init_calib_complete", "warning"])

        header = (f"{'timestamp UTC':<20} {'Temp, C':>8} {'VCCINT, V':>9} "
                  f"{'raw t/v':>15} {'valid':>5} {'lock/cal':>8}  warning")
        print(header)
        print("-" * len(header))

        samples = bad = 0
        while True:
            ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
            try:
                s = self.snapshot()
                err = ""
            except (XdmaError, OSError) as e:
                s = {"magic_ok": False, "valid": False, "temp_raw": 0,
                     "vcc_raw": 0, "mmcm_locked": False,
                     "init_calib_complete": False}
                err = f"ошибка чтения: {e}"

            samples += 1
            lock, cal = int(s["mmcm_locked"]), int(s["init_calib_complete"])
            rt, rv = s["temp_raw"], s["vcc_raw"]

            warn = ""
            if err:
                warn = err
            elif not s["magic_ok"]:
                warn = ("XADC-блок не опознан (MAGIC != 0x58414443) — "
                        "старый битстрим без xadc_prim?")
            elif not s["valid"]:
                warn = "INVALID (raw_valid=0)"
            elif s["temp_c"] >= CRIT_TEMP:
                warn = "*** CRITICAL ***"
            elif s["temp_c"] >= WARN_TEMP:
                warn = "WARNING"
            if s["valid"] and rv == 0 and not err:
                hint = "VCCINT raw=0 (канал не читается)"
                warn = f"{warn}; {hint}" if warn else hint

            if not (s["magic_ok"] and s["valid"]):
                bad += 1

            if s["valid"]:
                row = (f"{ts:<20} {s['temp_c']:>8.2f} {s['vccint_v']:>9.3f} "
                       f"{rt:#06x}/{rv:#06x} {'1':>5} {lock}/{cal:<6}  {warn}")
            else:
                row = (f"{ts:<20} {'--':>8} {'--':>9} "
                       f"{rt:#06x}/{rv:#06x} {'0':>5} {lock}/{cal:<6}  {warn}")
            print(row, flush=True)

            if writer:
                writer.writerow([
                    ts,
                    f"{s['temp_c']:.2f}" if s["valid"] else "",
                    f"{s['vccint_v']:.3f}" if s["valid"] else "",
                    f"{rt:#06x}" if s["valid"] else "",
                    f"{rv:#06x}" if s["valid"] else "",
                    int(s["valid"]), lock, cal, warn])
                fout.flush()

            try:
                time.sleep(interval)
            except KeyboardInterrupt:
                break

        if fout:
            fout.close()
        print("\nMonitor stopped.")
        if samples and bad == samples:
            print("ВНИМАНИЕ: все отсчёты невалидны — XADC недоступен "
                  "(старый битстрим без xadc_prim / легаси-карта адресов?). "
                  "См. docs/ADDRESS_MAP.md §7.", file=sys.stderr)
            return 3
        return 0


def main() -> None:
    p = argparse.ArgumentParser(
        description="Мониторинг температуры/VCCINT Artix-7 через XADC "
                    "(0x46000000, read-only).")
    p.add_argument("--interval", type=float, default=2.0,
                   help="интервал опроса в секундах (по умолчанию 2)")
    p.add_argument("--log", metavar="FILE", default=None,
                   help="CSV-файл для лога")
    p.add_argument("--device", default="xdma0",
                   help="имя XDMA-устройства для Linux (по умолчанию xdma0)")
    p.add_argument("--dev", default=None, metavar="BASE",
                   help=r"явный базовый узел Windows, напр. \\.\XDMA0dma "
                        "(по умолчанию — авто-перебор)")
    p.add_argument("--once", action="store_true",
                   help="один замер и выход (код 3 = XADC недоступен)")
    args = p.parse_args()

    try:
        mon = TempMonitor(device=args.device, dev_base=args.dev)
    except XdmaError as e:
        print(f"Ошибка XDMA: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"Бэкенд: {mon.backend}")

    if not args.once:
        # Preflight: одно чтение ДО входа в цикл — иначе ошибка доступа
        # будет печататься каждые interval секунд вместо одного явного
        # сообщения (урок запуска 2026-10-22, WinError 2 в цикле).
        try:
            mon.snapshot()
        except (XdmaError, OSError) as e:
            print(f"Preflight-чтение не удалось: {e}", file=sys.stderr)
            sys.exit(1)

    if args.once:
        try:
            s = mon.snapshot()
        except (XdmaError, OSError) as e:
            print(f"Ошибка чтения: {e}", file=sys.stderr)
            sys.exit(1)
        ok = s["magic_ok"] and s["valid"]
        line = (f"temp={s['temp_c']:.2f} C  vccint={s['vccint_v']:.3f} V  "
                f"raw=0x{s['temp_raw']:04X}/0x{s['vcc_raw']:04X}  "
                if ok else
                f"XADC недоступен: magic_ok={s['magic_ok']} valid={s['valid']}  ")
        print(line + f"mmcm_locked={int(s['mmcm_locked'])} "
                     f"init_calib_complete={int(s['init_calib_complete'])}",
              file=sys.stdout if ok else sys.stderr)
        sys.exit(0 if ok else 3)

    try:
        rc = mon.poll_loop(interval=args.interval, csv_path=args.log)
    except KeyboardInterrupt:
        rc = 0
    except XdmaError as e:
        print(f"Ошибка XDMA: {e}", file=sys.stderr)
        sys.exit(1)
    sys.exit(rc)


if __name__ == "__main__":
    main()
