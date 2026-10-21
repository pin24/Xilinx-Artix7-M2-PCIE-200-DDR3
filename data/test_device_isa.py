#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""test_device_isa.py — тесты ISA-компилятора/интерпретатора device_isa.

Запуск: python data/test_device_isa.py  (или pytest data/test_device_isa.py)
numpy-only; pytest-совместимые assertions.

Главный тест mode="tf48" сверяет интерпретатор с RTL-симуляцией device_prog
(tb_integ1, C:\\Temp\\gigatool\\devprog_integ): та же 2-юнитовая программа, те же
вход/веса (случайный seed 71), те же 48-битные out-слова (RTL-эталон из
tb_integ1_out.hex: out0[0..1], out1[0..2]). Эталон подсчёта — dot_ref_raw
(бит-точный TFloat48-оракул rtl/integration/verify_tdot_axi4). Ожидается 0 несовпадений.
"""
import os
import sys

_D = os.path.dirname(os.path.abspath(__file__))
if _D not in sys.path:
    sys.path.insert(0, _D)

import numpy as np
import device_isa as ISA
import nn_audio_common as AC


def _rng(seed=1):
    return np.random.default_rng(seed)


# ---------------------------------------------------------------------------
# Эталон программы/данных/весов ИЗ RTL-симуляции tb_integ1 (verify_integ1.py).
# random.seed(71); N_IN=4; unit0: 4->2 (src=data, pass=1); unit1: 4->3 (src=prev, pass=2).
# Вход и веса — те же f32-значения, что легли в tb_integ1_mem.hex (декодированы
# обратно через TFloat48). Ожидаемые out-слова — из tb_integ1_out.hex (строки 1..5).
# ---------------------------------------------------------------------------
RTL_DATA = [-1.05747998, 0.720176935, -2.94912004, 2.8971467]

# (n_in=4, n_out=2): столбец j = веса выходного нейрона j (соответствует w0 строкам)
RTL_W0 = np.array([
    [1.93295109, -2.67157221],
    [2.99411869, -1.83718574],
    [-1.41989815, -2.85488558],
    [-1.80306804, 1.15042818],
], dtype=np.float32)

# (n_in=4, n_out=3): столбец j = веса выходного нейрона j (соответствует w1 строкам)
RTL_W1 = np.array([
    [-0.805981815, -1.99920177, -1.86125553],
    [1.89336979, -0.913952351, -2.10760355],
    [1.5640322, -2.81822896, 2.33041883],
    [-0.904053986, 0.889955223, -0.377770782],
], dtype=np.float32)

# RTL out-hex (та же расстановка, что в tb_integ1_out.hex): out0[0], out0[1], out1[0..2]
RTL_OUT = [0x00218146249a, 0x061564a51994,
           0x048026948844, 0x1a1012698aa2, 0x18258564620a]


def test_bits_parse_roundtrip():
    u = ISA.make_unit(2, 16, passes=3, relu=True, b_en=True, src='prev', tag=7,
                      w_reg=3, w_imm=0x10, b_reg=3, b_imm=0x20, o_reg=2, o_imm=0x40)
    b = ISA.bits(u)
    assert len(b) == ISA.UNIT_BYTES
    u2 = ISA.parse_unit(b)
    # src скомпилировался в 0/1 (data=0, prev=1)
    assert u2['src'] == ISA._SRC_PREV
    assert u2['tag'] == 7 and u2['pass'] == 3 and u2['relu'] == 1
    assert u2['w_reg'] == 3 and u2['w_imm'] == 0x10
    assert u2['b_imm'] == 0x20 and u2['o_imm'] == 0x40
    # компилятор <-> parser: повторная компиляция не меняет байты
    assert ISA.bits(u2) == b
    # программа из нескольких юнитов
    prog = ISA.compile_program([ISA.make_unit(2, 16, tag=0),
                                ISA.make_unit(16, 1, tag=1)])
    parsed = ISA.parse(prog)
    assert len(parsed) == 2
    assert ISA.compile_program(parsed) == prog


def _dot48(src, n_in, wrow):
    """Один dot-нейрон TFloat48 (эталонный вход из буфера с добором нулей)."""
    m = len(src)
    inp = src[:n_in] if m >= n_in else src + [0] * (n_in - m)
    return ISA.dot_ref_raw(inp, wrow)


def _sample_row48(x):
    """Вектор float32 -> спи-сок 48-битных TFloat48 слов."""
    return [ISA._tf_to_bits48(ISA.TFloat.from_float(float(v))) for v in x]


def test_forward_batch_tf48():
    """2-юнитовая программа == RTL device_prog бит-в-бит (mode='tf48')."""
    # 1) промежуточный юнит0 (src=data, pass=1): out0[0..1]
    prog0 = [ISA.make_unit(4, 2, passes=1, src='data', tag=0,
                           relu=False, b_en=False)]
    res0 = ISA.run_program(np.array([RTL_DATA], np.float32), prog0,
                           {0: (RTL_W0, None)}, mode="tf48")
    assert res0.shape == (1, 2)
    assert list(res0[0]) == [RTL_OUT[0], RTL_OUT[1]], \
        f"unit0 vs RTL: {[hex(x) for x in res0[0]]} != {[hex(x) for x in RTL_OUT[0:2]]}"

    # 2) полная цепочка: unit0(src=data)->unit1(src=prev, pass=2, вплоть до in-place)
    prog = [ISA.make_unit(4, 2, passes=1, src='data', tag=0,
                          relu=False, b_en=False),
            ISA.make_unit(4, 3, passes=2, src='prev', tag=1,
                          relu=False, b_en=False)]
    res = ISA.run_program(np.array([RTL_DATA], np.float32), prog,
                          {0: (RTL_W0, None), 1: (RTL_W1, None)}, mode="tf48")
    assert res.shape == (1, 3)
    assert list(res[0]) == RTL_OUT[2:5], \
        f"full chain vs RTL: {[hex(x) for x in res[0]]} != {[hex(x) for x in RTL_OUT[2:5]]}"
    # строка run_program mode='tf48' == явный dot_ref_raw через linear_pass (ту же программу)
    lp = ISA.linear_pass(np.array([RTL_DATA], np.float32), RTL_W0, mode="tf48")
    assert list(lp[0]) == [RTL_OUT[0], RTL_OUT[1]]


def test_float_mode_compat():
    """mode='float' сохраняет старую numpy-семантику (== forward_batch cpu)."""
    B, H = 64, 16
    rng = _rng(1)
    X = rng.uniform(-1, 1, (B, 2)).astype(np.float32)
    W1 = rng.normal(0, 0.5, (2, H)).astype(np.float32); b1 = np.zeros(H, np.float32)
    W2 = rng.normal(0, 0.5, (H, 1)).astype(np.float32); b2 = np.zeros(1, np.float32)
    prog = [ISA.make_unit(2, H, relu=True, src='data', tag=0),
            ISA.make_unit(H, 1, relu=False, src='prev', tag=1)]
    res = ISA.run_program(X, prog, {0: (W1, b1), 1: (W2, b2)}, mode="float")
    ref = AC.forward_batch(X, W1, b1, W2, b2, backend="cpu").ravel()
    d = np.abs(res.ravel() - ref).max()
    assert d < 1e-6, f"mode='float' vs forward_batch cpu: max diff = {d}"
    # то же через битовую программу (bytes) — компайлер/parser в интерпретаторе
    prog_bytes = ISA.compile_program(prog)
    res2 = ISA.run_program(X, prog_bytes, {0: (W1, b1), 1: (W2, b2)}, mode="float")
    assert np.abs(res2.ravel() - ref).max() < 1e-6


def _run_chain_manual(sample_row48, units, weights48):
    """Ручной эталон in-place цепочки: prev_out между юнитами, pass>1 читает свой
    буфер с по-нейронным live-обновлением (как device_prog)."""
    prev_out = None
    for u in units:
        u = ISA.normalize_unit(u)
        n_in, n_out, pas, s = int(u['n_in']), int(u['n_out']), int(u['pass']), int(u['src'])
        src0 = sample_row48 if s == ISA._SRC_DATA else (prev_out if prev_out is not None else sample_row48)
        wrows = weights48[int(u['tag'])]
        out = [0] * n_out
        for _p in range(pas):
            src = src0 if _p == 0 else out
            for j in range(n_out):
                out[j] = _dot48(src, n_in, wrows[j])
        prev_out = out
    return prev_out


def test_loop_square_layer():
    """pass>1 (in-place feed-forward) и LOOP (repeat) на tf48-эталоне."""
    B, H = 64, 16
    rng = _rng(2)
    W3 = rng.normal(0, 0.5, (H, H)).astype(np.float32)
    X3 = rng.uniform(-1, 1, (B, H)).astype(np.float32)
    wcol = ISA._tf48_weight_vectors(np.asarray(W3, np.float32))  # per-нейрон строки (n_in=H)
    xrows = [_sample_row48(X3[i]) for i in range(B)]

    # pass=N на одном юните (src=data): in-place повторы
    N = 3
    prog = [ISA.make_unit(H, H, passes=N, src='data', tag=2, relu=False, b_en=False)]
    res = ISA.run_program(X3, prog, {2: (W3, None)}, mode="tf48")
    ref = [_run_chain_manual(xrows[i], prog, {2: wcol}) for i in range(B)]
    assert (res == np.array(ref, dtype=np.int64)).all(), "pass=N in-place vs manual"

    # LOOP из args (repeat=N): каждый повтор кормит результат предыдущего шага
    prog1 = [ISA.make_unit(H, H, passes=1, relu=False, src='data', tag=2)]
    res_r = ISA.run_program(X3, prog1, {2: (W3, None)}, args={'repeat': N}, mode="tf48")
    x = xrows
    for _ in range(N):
        x = [_run_chain_manual(x[i], prog1, {2: wcol}) for i in range(B)]
    assert (res_r == np.array(x, dtype=np.int64)).all(), "repeat LOOP vs manual"


def test_completion_mailbox():
    B, H = 16, 8
    rng = _rng(3)
    X = rng.uniform(-1, 1, (B, 2)).astype(np.float32)
    W1 = rng.normal(0, 0.5, (2, H)).astype(np.float32); b1 = np.zeros(H, np.float32)
    W2 = rng.normal(0, 0.5, (H, 1)).astype(np.float32); b2 = np.zeros(1, np.float32)
    prog = [ISA.make_unit(2, H, relu=True, src='data', tag=0),
            ISA.make_unit(H, 1, relu=False, src='prev', tag=1)]
    wgt = {0: (W1, b1), 1: (W2, b2)}
    res, comp = ISA.run_program_mb(X, prog, wgt)
    # адрес completion по умолчанию — из ARG[comp_reg]=ARG4 (0x00110000)
    assert comp['addr'] == ISA.DEFAULT_ARGS[ISA.ARG_COMP]
    assert comp['word'] == ISA.STATUS_DONE
    # программируемый адрес/значение статуса
    args = {ISA.ARG_COMP: 0x00AA0000, 'status': 0xBEEF}
    res2, comp2 = ISA.run_program_mb(X, prog, wgt, args=args)
    assert comp2['addr'] == 0x00AA0000
    assert comp2['word'] == 0xBEEF


def _selftest() -> int:
    test_bits_parse_roundtrip()
    print("roundtrip: OK")
    test_forward_batch_tf48()
    print("forward_batch tf48 (vs RTL tb_integ1): OK")
    test_float_mode_compat()
    print("float mode compat (forward_batch cpu): OK")
    test_loop_square_layer()
    print("loop square layer (tf48): OK")
    test_completion_mailbox()
    print("completion mailbox: OK")
    print("ALL DEVICE-ISA TESTS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(_selftest())