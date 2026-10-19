#!/usr/bin/env python
"""bench_tdot_auto.py — автономный нагрузочный тест ядра tdot_axi4 через XDMA.

Скрипт НЕ привязан к конкретной прошивке: сам читает CAPS (0x74) / CORE_PARAMS
(0x64) / MAGIC (0x68) и по ним определяет формат данных (ELEM_FMT), NUM_MAC и
ADDERS, после чего генерирует данные в ПРАВИЛЬНОМ формате и сверяет результат.

Режимы:
  python bench_tdot_auto.py                  # реальная плата (автопоиск XDMA)
  python bench_tdot_auto.py --dev \\.\XDMA0dma   # явный базовый узел
  python bench_tdot_auto.py --mock           # без железа (mock-ядро в памяти)
  python bench_tdot_auto.py --unit           # только unit-проверка паковки

Поток (для каждого формата/размера):
  1. Открыть XDMA (regs + h2c/c2h DMA).
  2. Прочитать MAGIC (== 'TDOT'), CAPS (ELEM_FMT/NUM_MAC/ADDERS/L2BURST),
     CORE_PARAMS.
  3. Сгенерировать data[i]=1.0, weights[i]=1.0 -> ожидаемый dot = n (в формате,
     который понимает ядро: fp32-raw для ELEM_FMT=1, tf48 для 0/2).
  4. Записать data/weights в DDR3 (h2c), запрограммировать адреса + N_IN,
     подать GO, поллить DONE, прочитать результат (c2h), развернуть в число.
  5. Сверить с ожидаемым (n.0), отчёт PASS/FAIL + параметры формата.
  6. Цикл нагрузки n=8/16/32/64 (в пределах NUM_MAC) × итераций, замер времени.

Формат результата ядра (сверить с rtl/integration/tdot_axi4.sv):
  ELEM_FMT=0 (legacy) : 8 байт, мл. 48 бит = tf48  (CS_WAIT wr_data {16'h0,res})
  ELEM_FMT=1 (fp32)   : 8 байт, мл. 32 бита = fp32 (CS_T2F_WAIT wr_data {32'h0,fp32})
  ELEM_FMT=2 (PACKED6): 6 байт, WSTRB=0x3F (packed6_wr, woff=0)
"""
from __future__ import annotations

import argparse
import os
import struct
import sys
import time

# UTF-8 stdout для корректного вывода кириллицы в разных консолях
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

# ---- доступ к xdma_driver (pytorch_layer на sys.path) ----
_HERE = os.path.dirname(os.path.abspath(__file__))
_PT = os.path.join(_HERE, "..", "pytorch_layer")
if _PT not in sys.path:
    sys.path.insert(0, _PT)
_TSW = os.path.join(_HERE, "..", "ternary_sw")
if _TSW not in sys.path:
    sys.path.insert(0, _TSW)

from xdma_driver import (  # noqa: E402
    TdotCore, XdmaDevice, XdmaError,
    REG_BASE, DDR3_BASE, AXI_LITE_BASE,
    _pack_tf48, _pack_tf48_packed6, _pack_fp32_raw, _unpack_tf48_bytes,
)

# tf48-биты числа 1.0 (сверить с ternary_sw/block/tfloat48.py):
#   TFloat.from_float(1.0) -> e_int=0, m_int=2^36 -> bits = 0x0010_0000_0000
TF48_ONE = 0x0010_0000_0000

# 48-битная маска RTL-конвенции [E:8][M:40]
TF48_MASK = (1 << 48) - 1
TF48_M_MASK = (1 << 40) - 1
TF48_E_SHIFT = 40

# Код ошибки tfloat48 в RTL-конвенции [E:8][M:40]: все 20 тритов мантиссы = ERR(11),
# т.е. биты [39:0] все = 1, экспонента E=0. Соответствует RTL-дешифрации err-значения.
TF48_ERR = TF48_M_MASK  # 0x0000_00FF_FFFF_FFFF

_MAGIC_TDOT = 0x54444F54  # 'TDOT'


# ============================================================================
# Автопоиск XDMA-бэкенда (реальная плата)
# ============================================================================
def open_device(dev: str | None = None):
    """Вернуть (XdmaDevice, описание). Пробует бэкенды в порядке приоритета."""
    if dev:
        # Явный базовый узел -> пробуем per-node драйвер (control/h2c/c2h)
        try:
            from test_dma_win import XdmaWinDma
            d = XdmaWinDma(base=dev)
            return d, "XdmaWinDma(%s)" % dev
        except Exception:
            pass
        try:
            from xdma_driver import XdmaWinUpstream
            d = XdmaWinUpstream(base=dev)
            return d, "XdmaWinUpstream(%s)" % dev
        except Exception:
            pass
        from xdma_driver import XdmaWinDriver
        d = XdmaWinDriver(devpath=dev)
        return d, "XdmaWinDriver(%s)" % dev

    attempts = []
    # 1) per-node DMA драйвер (flat-сборка, DDR3 через h2c/c2h)
    try:
        from test_dma_win import XdmaWinDma
        for base in (r"\\.\XDMA0dma", r"\\.\XDMA0"):
            try:
                d = XdmaWinDma(base=base)
                return d, "XdmaWinDma(%s)" % base
            except Exception:
                continue
    except Exception:
        pass
    # 2) upstream ctypes (контроль + user + h2c/c2h)
    try:
        from xdma_driver import XdmaWinUpstream
        d = XdmaWinUpstream()
        return d, "XdmaWinUpstream(\\\\.\\XDMA0)"
    except Exception:
        pass
    # 3) Linux
    try:
        from xdma_driver import XdmaLinux
        d = XdmaLinux()
        return d, "XdmaLinux(/dev/xdma0)"
    except Exception:
        pass
    # 4) кастомный штатный драйвер (только регистры)
    try:
        from xdma_driver import XdmaWinDriver
        d = XdmaWinDriver()
        return d, "XdmaWinDriver(\\\\.\\XDMA0)"
    except Exception:
        pass
    raise XdmaError("не удалось открыть ни один XDMA-бэкенд (нет железа?)")


# ============================================================================
# Mock-бэкенд (без железа): моделирует ядро с заданным ELEM_FMT/NUM_MAC/ADDERS
# ============================================================================
class MockDevice(XdmaDevice):
    """В памяти повторяет routing XDMA + считает dot(1.0*1.0)=n.

    Читает data/weights из mock-DDR3 в формате (из CAPS), пишет результат в
    формате (из CAPS) в result offset, выставляет DONE. Позволяет проверить
    логику bench-скрипта (детект формата, упаковку, раскодировку) без платы.
    """

    def __init__(self, elem_fmt: int, num_mac: int = 32, adders: int = 4,
                 mem_size: int = 0x100000):
        self.fmt = elem_fmt
        self.mem = bytearray(mem_size)
        self.regs = {}
        # MAGIC + CORE_PARAMS + CAPS
        self.regs[REG_BASE + 0x68] = _MAGIC_TDOT
        self.regs[REG_BASE + 0x64] = ((adders & 0xFF) << 8) | (num_mac & 0xFF)
        caps = (8 << 24) | (0 << 20) | ((elem_fmt & 0x7) << 17) | (1 << 16) \
            | (0 << 12) | ((adders & 0xF) << 8) | (num_mac & 0xFF)
        self.regs[REG_BASE + 0x74] = caps
        self.busy = False

    def read(self, addr: int, length: int) -> bytes:
        if addr >= DDR3_BASE:
            o = addr - DDR3_BASE
            if o + length > len(self.mem):
                raise XdmaError("mock DDR3 read out of range")
            return bytes(self.mem[o:o + length])
        if AXI_LITE_BASE <= addr < DDR3_BASE:
            v = self.regs.get(addr, 0) & 0xFFFFFFFF
            return struct.pack("<I", v)
        raise XdmaError(f"bad mock addr 0x{addr:X}")

    def write(self, addr: int, data: bytes) -> None:
        if addr >= DDR3_BASE:
            o = addr - DDR3_BASE
            if o + len(data) > len(self.mem):
                raise XdmaError("mock DDR3 write out of range")
            self.mem[o:o + len(data)] = data
            return
        if AXI_LITE_BASE <= addr < DDR3_BASE:
            self.regs[addr] = struct.unpack("<I", data[:4].ljust(4, b"\x00"))[0]
            return
        raise XdmaError(f"bad mock addr 0x{addr:X}")

    def write_dma(self, ddr_off: int, data: bytes) -> None:
        self.write(DDR3_BASE + ddr_off, data)

    def read_dma(self, ddr_off: int, length: int) -> bytes:
        return self.read(DDR3_BASE + ddr_off, length)

    def run_task(self, data_off: int, weights_off: int, result_off: int, n: int):
        """Имитация GO->compute->DONE; пишет результат в формате ядра."""
        fmt = self.fmt
        bpe = 4 if fmt == 1 else (6 if fmt == 2 else 8)
        # читаем векторы в формате
        def read_vec(off, nelem):
            vals = []
            for i in range(nelem):
                if fmt == 1:  # fp32, 4Б/элемент -> float
                    vals.append(struct.unpack("<f", self.mem[off + i * 4:
                                                             off + i * 4 + 4])[0])
                else:         # tf48 (legacy 8Б или packed6 6Б) -> float
                    e = 8 if fmt == 0 else 6
                    bits = int.from_bytes(self.mem[off + i * e:off + i * e + 6],
                                          "little") & ((1 << 48) - 1)
                    vals.append(caps_to_float(bits, fmt))
            return vals

        d = read_vec(data_off, n)
        w = read_vec(weights_off, n)
        # эталон: dot = sum(data[i]*weights[i]); для нашего теста все 1.0 -> n
        # (численно n.0 при n<=64 точно представим в fp32/tf48)
        dot_val = float(sum(a * b for a, b in zip(d, w)))
        if fmt == 1:
            # fp32: результат std::float32 в мл. 4 байтах
            self.mem[result_off:result_off + 4] = struct.pack("<f", dot_val)
            res_bits = struct.unpack("<I", struct.pack("<f", dot_val))[0]
            self.regs[REG_BASE + 0x0C] = res_bits
            self.regs[REG_BASE + 0x10] = 0
        else:
            # tf48 (legacy 8Б или packed6 6Б): результат в мл. 6 байтах
            res_bits = _tf48_of_float(dot_val)
            packed = _pack_tf48_packed6([res_bits]) if fmt == 2 else \
                struct.pack("<Q", res_bits)[:6]
            self.mem[result_off:result_off + 6] = packed
            self.regs[REG_BASE + 0x0C] = res_bits & 0xFFFFFFFF
            self.regs[REG_BASE + 0x10] = (res_bits >> 32) & 0xFFFF
        self.regs[REG_BASE + 0x04] = 0b10  # DONE=1, BUSY=0


def _tf48_of_float(v: float) -> int:
    """fp32 float -> 48-бит tf48 (для mock; через проектный эмулятор)."""
    from block.tfloat48 import TFloat
    t = TFloat.from_float(v)
    return ((t.e_int & 0xFF) << 40) | (t.m_int & ((1 << 40) - 1))


# ============================================================================
# Собственно тест
# ============================================================================
def format_name(fmt: int) -> str:
    return {0: "ELEM_FMT=0 (legacy tf48, 8Б/элемент)",
            1: "ELEM_FMT=1 (fp32, 4Б/элемент)",
            2: "ELEM_FMT=2 (PACKED6 tf48, 6Б/элемент)"}.get(fmt, f"ELEM_FMT={fmt}?")


def caps_to_float(bits: int, fmt: int) -> float:
    """Декодирует результат ядра (int tf48 либо float fp32) в число float."""
    if fmt == 1:
        # read_result вернул float; тут принимаем int-биты fp32 (mock) или float
        if isinstance(bits, float):
            return bits
        return struct.unpack("<f", struct.pack("<I", bits & 0xFFFFFFFF))[0]
    from block.tfloat48 import TFloat
    m = bits & ((1 << 40) - 1)
    e = (bits >> 40) & 0xFF
    return TFloat.from_bits((m << 8) | e).to_float()


def random_fp32_vector(n: int, seed: int) -> list:
    """Псевдослучайный float32-вектор в разумном диапазоне tf48.

    Диапазон [-4, 4): произведение/суммы n<=64 элементов не выходят за
    точный диапазон tf48 (E до +40; 4^64~10^38 < 3^40~10^19 — безопасно).
    Использует np.random с фиксированным seed для воспроизводимости.
    """
    import numpy as np
    rng = np.random.default_rng(seed)
    return rng.uniform(-4.0, 4.0, size=n).astype(np.float32).tolist()


def _dot_fp32_reference(data, weights) -> float:
    """Эталон dot в float32 (numpy) для сравнения с результатом ядра."""
    import numpy as np
    return float(np.dot(np.asarray(data, dtype=np.float32),
                        np.asarray(weights, dtype=np.float32)))


def auto_test(dev: XdmaDevice, mode: str = "auto",
              reset_done_before_go: bool = True):
    """Основной прогон: детект формата + dot-проверка + цикл нагрузки.

    mode="ones" — данные 1.0/1.0, ожидаемый dot=n (штатный самопроверочный).
    mode="fp32" — случайные float32-векторы, хост конвертирует fp32->tf48
                  для ELEM_FMT=0/2 (или шлёт raw fp32 для =1); ожидаемый
                  dot считается numpy в fp32 и сравнивается с декодированным
                  результатом ядра (tf48 ~31 бит -> допустимая погрешность).
    mode="auto" — "ones" для форматов 0/2, "fp32" для 1 (если когда-либо).
    """
    core = TdotCore(dev)  # авто-детект CAPS/CORE_PARAMS
    assert core.magic == _MAGIC_TDOT, ("MAGIC != 'TDOT' (0x%08X): это не ядро "
                                       "tdot_axi4?" % (core.magic or 0))

    fmt = core.elem_fmt
    num_mac = core.num_mac
    adders = core.core_params["adders"] if core.core_params else 0
    caps = core.caps or {}
    print("=== авто-детект прошивки ===")
    print("  MAGIC       = 0x%08X ('TDOT' OK)" % core.magic)
    print("  CORE_PARAMS = NUM_MAC=%d ADDERS=%d" % (num_mac, adders))
    print("  CAPS        = %s" % caps)
    print("  FORMAT      = %s" % format_name(fmt))

    if fmt not in (0, 1, 2):
        raise XdmaError(f"неизвестный ELEM_FMT={fmt} (CAPS 0x74 [19:17])")

    if mode == "auto":
        # fmt=1 (fp32 в ядре) пока нереализуем на чипе; если появится — fp32-вход
        mode = "fp32" if fmt == 1 else "ones"
    if mode not in ("ones", "fp32"):
        raise ValueError(f"неизвестный режим входа: {mode}")

    # офсеты в DDR3 (в стороне; result достаточно 8-байт на все форматы)
    DATA_OFF, WG_OFF, RES_OFF = 0x0, 0x1000, 0x2000

    sizes = [8, 16, 32, 64]
    sizes = [s for s in sizes if s <= num_mac] or [num_mac]  # в пределах NUM_MAC
    iters = args.iters

    print("\n=== dot-проверка и нагрузка по n из %s (по %d итер.), вход=%s ==="
          % (sizes, iters, mode))
    all_pass = True
    max_err = 0.0   # макс. |got - expected| (fp32)
    max_rel = 0.0   # макс. |got - expected|/|expected| (fp32)
    for n in sizes:
        for it in range(iters):
            # генерируем входные данные в правильном формате
            if mode == "fp32":
                data = random_fp32_vector(n, seed=1000 * n + it)
                weights = random_fp32_vector(n, seed=200000 + 1000 * n + it)
                expected = _dot_fp32_reference(data, weights)
            else:
                data = [1.0] * n
                weights = [1.0] * n
                expected = float(n)  # dot(1,1)*n = n

            t0 = time.monotonic()
            res = _run_single(core, fmt, data, weights, n,
                              DATA_OFF, WG_OFF, RES_OFF)
            dt = time.monotonic() - t0
            got = res if isinstance(res, float) else caps_to_float(res, fmt)
            rawbits = int(res) if not isinstance(res, float) else 0

            err = abs(got - expected)
            rel = err / (abs(expected) + 1e-12)
            max_err = max(max_err, err)
            max_rel = max(max_rel, rel)
            # tf48 даёт ~31 значащий бит против 24 у fp32 -> относительный
            # запас 1e-3 (и абсолютный флор) достаточно строг для конверсии.
            ok = err <= max(1e-3, abs(expected) * 1e-3)
            all_pass &= ok
            print("  n=%3d it=%d -> got=%.6f exp=%.6f  err=%.3e rel=%.2e "
                  "raw=0x%012X  %6.2f ms  %s"
                  % (n, it, got, expected, err, rel, rawbits, dt * 1e3,
                     "PASS" if ok else "FAIL"))

    print("  [сводка] max_abs_err=%.3e max_rel_err=%.2e" % (max_err, max_rel))
    print("\n=== ИТОГ: %s ===" % ("PASS" if all_pass else "FAIL"))
    return 0 if all_pass else 1


def _tf48_to_bits(t) -> int:
    """TFloat48 -> 48-битное целое в RTL-конвенции [E:8][M:40].

    Поле экспоненты E в бит[47:40], мантисса M в бит[39:0]
    (совпадает с to_bits48 в verify и fpga_backend._to_bits48).
    """
    return ((t.e_int & 0xFF) << TF48_E_SHIFT) | (t.m_int & TF48_M_MASK)


def fp32_to_tf48_list(arr) -> list:
    """list of float32 -> list of 48-бит tf48 (RTL-конвенция [E:8][M:40]).

    Host-конверсия fp32 -> tf48 ДЛЯ ядра без встроенной fp32-конверсии
    (ELEM_FMT=0/2; ELEM_FMT=1 нереализуем на xc7a200t). Каждое fp32-значение
    кодируется через блоковый эмулятор TFloat.from_float.

    Спецслучаи (обрабатываются здесь, как на хосте):
      inf / -inf / nan  -> 0            (биты 0x0)
      субнормальное / underflow -> 0    (выход < 3^-40 -> ноль)
      overflow (|v| > 3^40 диапазон) -> TF48_ERR  (все триты мантиссы = ERR)
      прочие нормальные   -> 48-бит [E:8][M:40]
    """
    from block.tfloat48 import TFloat, TFloatError
    out = []
    for v in arr:
        try:
            t = TFloat.from_float(float(v))
        except TFloatError:
            # overflow: экспонента вне диапазона [-40, +40]
            out.append(TF48_ERR)
            continue
        # from_float уже вернул 0 (err=False) для +/-inf/nan? нет:
        # для inf/nan он ставит err=True, но to_bits48 даёт нулевые поля.
        # Требование host: inf/nan/subnormal/underflow -> 0, overflow -> ERR.
        if t.err:
            # inf / nan: кодируем как 0, а не ERR (как делает host-конвертер)
            out.append(0)
            continue
        out.append(_tf48_to_bits(t))
    return out


def _floats_to_tf48_bits(vals) -> list:
    """Список float -> список 48-бит tf48 (для ELEM_FMT=0/2)."""
    return fp32_to_tf48_list(vals)


def _run_single(core: TdotCore, fmt: int, data, weights, n: int,
                data_off: int, wg_off: int, res_off: int):
    """Записать данные, запрограммировать, GO, дождаться DONE, прочитать."""
    # для ELEM_FMT=0/2 ядро ждёт tf48-биты, для ELEM_FMT=1 — raw fp32
    is_fp32 = (fmt == 1)
    data_in = data if is_fp32 else _floats_to_tf48_bits(data)
    wgt_in = weights if is_fp32 else _floats_to_tf48_bits(weights)

    if isinstance(core.dev, MockDevice):
        # mock: пишем данные, программируем адреса, запускаем имитацию
        core.write_input(data_off, data_in, elem_fmt=fmt, as_fp32=is_fp32)
        core.write_input(wg_off, wgt_in, elem_fmt=fmt, as_fp32=is_fp32)
        core.set_addrs(data_off, wg_off, res_off)
        core.set_n(n)
        core.start()                       # в mock ставит GO в regs
        core.dev.run_task(data_off, wg_off, res_off, n)  # имитация ядра
        return core.read_result(res_off, elem_fmt=fmt)

    # реальная плата
    if is_fp32:
        return core.dot_fp32(data, weights, data_addr=data_off,
                             weights_addr=wg_off, result_addr=res_off)
    core.write_input(data_off, data_in, elem_fmt=fmt, as_fp32=False)
    core.write_input(wg_off, wgt_in, elem_fmt=fmt, as_fp32=False)
    core.set_addrs(data_off, wg_off, res_off)
    core.set_n(n)
    core.start()
    core.wait_done()
    return core.read_result(res_off, elem_fmt=fmt)


def unit_packing() -> int:
    """Без железа: проверить три формат-пакера + результат-раскодировку."""
    ok = True
    bits = [TF48_ONE, 0x002000000000, 0x003000000000, 0x001000000000]
    leg = _pack_tf48(bits)
    p6 = _pack_tf48_packed6(bits)
    # легаси: 8 байт/элемент, мл. 48 бит
    for i, b in enumerate(bits):
        assert int.from_bytes(leg[i*8:i*8+6], "little") == b
        assert _unpack_tf48_bytes(leg, i*8) == b
    # packed6: 6 байт/элемент, тот же байтовый поток (E в 6-м байте)
    assert len(p6) == 6 * len(bits)
    for i, b in enumerate(bits):
        assert _unpack_tf48_bytes(p6, i*6) == b
    # fp32: 4 байта, 2 на 64-бит слово, little-endian
    f = _pack_fp32_raw([1.0, 2.0, 3.0])
    assert len(f) == 12
    assert struct.unpack("<f", f[0:4])[0] == 1.0
    assert struct.unpack("<f", f[4:8])[0] == 2.0
    assert struct.unpack("<f", f[8:12])[0] == 3.0

    # ---- host-конверсия fp32 -> tf48 (fp32_to_tf48_list) ----
    # 1.0 -> точный tf48-бит
    assert fp32_to_tf48_list([1.0]) == [TF48_ONE]
    # константа 1.0 в RTL-конвенции [E:8][M:40] = 0x0010_0000_0000
    # -1.0 -> знак в мантиссе
    neg_one = fp32_to_tf48_list([-1.0])[0]
    assert neg_one != 0 and (neg_one & TF48_M_MASK) != 0
    # спецслучаи: inf/nan/subnormal/underflow -> 0; overflow -> TF48_ERR
    assert fp32_to_tf48_list([float("inf"), float("-inf"), float("nan")]) \
        == [0, 0, 0]
    assert fp32_to_tf48_list([1e-45]) == [0]            # субнормал -> 0
    assert fp32_to_tf48_list([1e-300]) == [0]           # underflow -> 0
    assert fp32_to_tf48_list([3.0 ** 41]) == [TF48_ERR]  # overflow -> ERR
    # roundtrip fp32 -> tf48-биты -> fp32 (через caps_to_float) в допустимой
    # погрешности (~7 знаков для tf48 против ~7 у fp32)
    import random as _rnd
    _rnd.seed(7)
    for _ in range(64):
        v = float(_rnd.uniform(-256.0, 256.0))
        b = fp32_to_tf48_list([v])[0]
        back = caps_to_float(b, 0)
        if v == 0.0:
            assert back == 0.0
        else:
            rel = abs(back - v) / abs(v)
            assert rel < 1e-6, "fp32->tf48 roundtrip too large: %g->%g (%.2e)" \
                               % (v, back, rel)

    print("unit(packing): legacy 8B/packed6 6B/fp32 4B roundtrip + "
          "fp32->tf48 host-конверсия — OK")
    return 0 if ok else 1


def main(argv=None) -> int:
    global args
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dev", default=None, help="базовый XDMA-узел (\\\\.\\XDMA0dma)")
    ap.add_argument("--mock", action="store_true",
                    help="прогон против mock-ядра без железа")
    ap.add_argument("--fmt", type=int, default=None,
                    help="при --mock: ELEM_FMT для mock (0/1/2)")
    ap.add_argument("--num-mac", type=int, default=32, help="при --mock: NUM_MAC")
    ap.add_argument("--adders", type=int, default=4, help="при --mock: ADDERS")
    ap.add_argument("--iters", type=int, default=3, help="итераций на размер n")
    ap.add_argument("--input", default="auto", choices=("auto", "ones", "fp32"),
                    help="входные данные: auto (ones для 0/2, fp32 для 1), "
                         "ones (1.0-векторы) или fp32 (случайные float32; "
                         "хост конвертирует fp32->tf48 для ELEM_FMT=0/2)")
    ap.add_argument("--unit", action="store_true",
                    help="только unit-проверка паковки (без железа)")
    args = ap.parse_args(argv)

    if args.unit:
        return unit_packing()

    if args.mock:
        fmt = args.fmt if args.fmt is not None else 0
        dev = MockDevice(elem_fmt=fmt, num_mac=args.num_mac, adders=args.adders)
        print("mock-режим: формат = %s, вход = %s"
              % (format_name(fmt), args.input))
        return auto_test(dev, mode=args.input)

    try:
        dev, desc = open_device(args.dev)
    except XdmaError as e:
        print("ОШИБКА: %s\nПодсказка: для проверки без железа запустите "
              "`bench_tdot_auto.py --mock` (или `--unit`)." % e)
        return 2
    print("устройство: %s" % desc)
    return auto_test(dev, mode=args.input)


if __name__ == "__main__":
    sys.exit(main())