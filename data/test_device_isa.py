#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""test_device_isa.py — тесты ISA-компилятора/интерпретатора device_isa.

Запуск: python data/test_device_isa.py  (или pytest data/test_device_isa.py)
numpy-only; pytest-совместимые assertions.
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


def test_forward_batch_cpu():
    B, H = 64, 16
    rng = _rng(1)
    X = rng.uniform(-1, 1, (B, 2)).astype(np.float32)
    W1 = rng.normal(0, 0.5, (2, H)).astype(np.float32); b1 = np.zeros(H, np.float32)
    W2 = rng.normal(0, 0.5, (H, 1)).astype(np.float32); b2 = np.zeros(1, np.float32)
    prog = [ISA.make_unit(2, H, relu=True, src='data', tag=0),
            ISA.make_unit(H, 1, relu=False, src='prev', tag=1)]
    res = ISA.run_program(X, prog, {0: (W1, b1), 1: (W2, b2)})
    ref = AC.forward_batch(X, W1, b1, W2, b2, backend="cpu").ravel()
    d = np.abs(res.ravel() - ref).max()
    assert d < 1e-6, f"vs forward_batch cpu: max diff = {d}"
    # то же через битовую программу (bytes) — компайлер/parser в интерпретаторе
    prog_bytes = ISA.compile_program(prog)
    res2 = ISA.run_program(X, prog_bytes, {0: (W1, b1), 1: (W2, b2)})
    assert np.abs(res2.ravel() - ref).max() < 1e-6


def test_loop_square_layer():
    B, H = 64, 16
    rng = _rng(2)
    W3 = rng.normal(0, 0.5, (H, H)).astype(np.float32); b3 = np.zeros(H, np.float32)
    X3 = rng.uniform(-1, 1, (B, H)).astype(np.float32)
    N = 3
    prog = [ISA.make_unit(H, H, passes=N, relu=True, src='data', tag=2)]
    res = ISA.run_program(X3, prog, {2: (W3, b3)})
    s = X3
    for _ in range(N):
        s = ISA.linear_pass(s, W3, b3, True)
    assert np.abs(res - s).max() < 1e-6
    # LOOP из args (repeat) прогоняет цепочку ещё N_out раз (рекуррентно)
    prog1 = [ISA.make_unit(H, H, passes=1, relu=False, src='data', tag=2)]
    res_r = ISA.run_program(X3, prog1, {2: (W3, b3)}, args={'repeat': N})
    rr = X3
    for _ in range(N):
        rr = ISA.linear_pass(rr, W3, b3, False)
    assert np.abs(res_r - rr).max() < 1e-6


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
    test_forward_batch_cpu()
    print("forward_batch cpu: OK")
    test_loop_square_layer()
    print("loop square layer: OK")
    test_completion_mailbox()
    print("completion mailbox: OK")
    print("ALL DEVICE-ISA TESTS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(_selftest())