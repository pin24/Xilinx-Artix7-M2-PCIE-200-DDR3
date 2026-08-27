"""Тесты TFloat40: конвертация и арифметика.

Запуск:  python -m pytest tests/ -v
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from ternary.tfloat40 import TFloat
from ternary import arith


def approx(v, ref, tol=1e-4):
    if ref == 0.0:
        return abs(v) < tol
    return abs(v - ref) / max(abs(ref), 1e-30) < tol


def test_convert_exact():
    for v in [1.0, -1.0, 3.0, -3.0, 9.0, 27.0, 0.0, 100.0, -100.0]:
        assert TFloat.from_float(v).to_float() == v, f"{v}"


def test_convert_fraction():
    for v in [0.5, -0.5, 0.3333333333, 1.5, 2.5, 0.1, 0.001]:
        got = TFloat.from_float(v).to_float()
        assert approx(got, v, 1e-4), f"{v} -> {got}"


def test_add():
    a, b = TFloat.from_float(1.5), TFloat.from_float(2.0)
    assert approx(arith.add(a, b).to_float(), 3.5)
    assert approx(arith.add(TFloat.from_float(1), TFloat.from_float(1)).to_float(), 2.0)


def test_sub():
    a, b = TFloat.from_float(1.5), TFloat.from_float(2.0)
    assert approx(arith.sub(a, b).to_float(), -0.5)
    assert approx(arith.sub(b, a).to_float(), 0.5)


def test_mul():
    for x, y in [(1.5, 2.0), (2.0, 3.0), (0.5, 0.5), (-1.5, 2.0), (100.0, 0.01)]:
        r = arith.mul(TFloat.from_float(x), TFloat.from_float(y)).to_float()
        assert approx(r, x * y), f"{x}*{y}={r}"


def test_div():
    for x, y in [(1.5, 2.0), (6.0, 2.0), (1.0, 3.0), (1.0, 10.0), (-3.0, 2.0)]:
        r = arith.div(TFloat.from_float(x), TFloat.from_float(y)).to_float()
        assert approx(r, x / y), f"{x}/{y}={r}"


def test_neg():
    a = TFloat.from_float(1.5)
    assert approx(arith.neg(a).to_float(), -1.5)


def test_error_flag():
    # деление на ноль -> TFloatError
    import pytest
    with pytest.raises(Exception):
        arith.div(TFloat.from_float(1.0), TFloat.from_float(0.0))


def test_bits_roundtrip():
    for v in [1.0, -1.0, 3.0, 0.5, 0.1, 100.0, -0.001, 1234.5678]:
        t = TFloat.from_float(v)
        bits = t.to_bits()
        assert 0 <= bits < (1 << 40)
        t2 = TFloat.from_bits(bits)
        assert approx(t2.to_float(), v, 1e-4)


def test_zero():
    z = TFloat.from_float(0.0)
    assert z.is_zero()
    assert z.to_float() == 0.0
    assert approx(arith.add(z, TFloat.from_float(5.0)).to_float(), 5.0)
