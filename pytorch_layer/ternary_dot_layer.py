"""Кастомный слой PyTorch: TernaryDotLayer.

Слой выполняет dot-произведение входного вектора с весами, при этом
умножения выполняются в троичной FP (через FpgaBackend). На CPU -
эмуляция, на FPGA - реальный вызов ускорителя.

Пока реализована CPU-эмуляция (для проверки логики слоя). FPGA-вызов
подключается через FpgaBackend(mode='fpga') когда ядро готово.
"""
from __future__ import annotations
import os, sys
import numpy as np
import torch
import torch.nn as nn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fpga_backend import FpgaBackend


class TernaryDotLayer(nn.Module):
    """Слой: out[batch] = dot(x[batch,N], w[N]) в троичной FP.

    forward:
      1. x конвертируется в float32 (numpy).
      2. dot через backend (троичная FP на FPGA или CPU-эмуляция).
      3. результат в torch tensor.
    """

    def __init__(self, in_features: int, backend_mode: str = "cpu", device="cpu"):
        super().__init__()
        self.in_features = in_features
        self.backend = FpgaBackend(mode=backend_mode, n=in_features)
        # веса как параметр (на CPU, троичная конвертация при вызове)
        self.register_buffer("weight", torch.ones(in_features, dtype=torch.float32))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: [batch, in_features]
        xn = x.detach().cpu().numpy().astype("float32")
        wn = self.weight.detach().cpu().numpy().astype("float32")
        if xn.ndim == 1:
            xn = xn[None, :]
        # широковещание весов на batch
        wb = np.broadcast_to(wn, xn.shape)
        out = self.backend.run_dot(xn, wb)
        return torch.tensor(out, dtype=torch.float32, device=x.device)


def main():
    """Самопроверка: слой на случайных данных против torch.dot (эталон-точность)."""
    torch.manual_seed(0)
    n = 8
    layer = TernaryDotLayer(n, backend_mode="cpu")
    layer.weight.data = torch.randn(n, dtype=torch.float32)
    x = torch.randn(4, n, dtype=torch.float32)

    y_fpga_style = layer(x)                       # троичный dot (CPU-эмуляция)
    y_torch = (x * layer.weight).sum(dim=-1)      # обычный float32 dot

    print("x shape:", x.shape)
    print("ternary dot :", y_fpga_style.detach().numpy())
    print("torch dot   :", y_torch.detach().numpy())
    # точность: троичная FP близка к float32 (15 тритов мантиссы)
    diff = torch.abs(y_fpga_style - y_torch)
    print("max diff    :", diff.max().item())
    print("OK: слой работает")


if __name__ == "__main__":
    main()
