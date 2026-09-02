# third_party/m2-artix7-accelerator-card

Встроенные HDL-файлы из репозитория [rigoorozco/m2-artix7-accelerator-card](https://github.com/rigoorozco/m2-artix7-accelerator-card) (ветка `develop`).

## Источник

- **Upstream**: https://github.com/rigoorozco/m2-artix7-accelerator-card
- **Branch**: develop
- **Commit на момент встраивания**: HEAD (2026-09-03)
- **License**: см. upstream LICENSE

## Что включено

```
third_party/m2-artix7-accelerator-card/
└── hdl/
    ├── common/
    │   ├── up_axi.v                    — ADI-style AXI-Lite slave wrapper
    │   └── datamover_ctrl.v             — control + status registers for DataMover
    ├── datamover_mm2s_ctrl/
    │   └── axi_datamover_mm2s_ctrl.v    — MM2S DataMover control wrapper
    └── datamover_s2mm_ctrl/
        └── axi_datamover_s2mm_ctrl.v    — S2MM DataMover control wrapper
```

## Использование в проекте

Эти файлы используются **только в DFX partition** (`dfx_block_designs/default.tcl` и `dfx_block_designs/test.tcl`) как референс-реализация DataMover loopback для проверки DFX-функциональности. При замене DFX partition на троичное ядро (`tdot_axi4` + `compute_dot_par_raw`) эти файлы не нужны.

## Использование в build_dfx.tcl

```tcl
# Шаг 2a: добавление HDL-файлов DFX partition
set HDL_DIR "${ROOT}/third_party/m2-artix7-accelerator-card/hdl"
add_files -norecurse \
    ${HDL_DIR}/common/up_axi.v \
    ${HDL_DIR}/common/datamover_ctrl.v \
    ${HDL_DIR}/datamover_mm2s_ctrl/axi_datamover_mm2s_ctrl.v \
    ${HDL_DIR}/datamover_s2mm_ctrl/axi_datamover_s2mm_ctrl.v
```

## Альтернатива: git submodule

Если предпочитаете submodule вместо встраивания:

```bash
git submodule add https://github.com/rigoorozco/m2-artix7-accelerator-card.git third_party/m2-artix7-accelerator-card
cd third_party/m2-artix7-accelerator-card
git checkout develop
cd ../..
git commit -m "Add m2-artix7-accelerator-card as submodule"
```

Затем в `build_dfx.tcl`:
```tcl
set HDL_DIR "${ROOT}/third_party/m2-artix7-accelerator-card/hdl"
```

Но тогда `git clone --recursive` требуется для клонирования проекта.

## Почему встроено, а не submodule

1. **Простота клонирования** — `git clone` без `--recursive`
2. **Стабильность** — файлы не изменятся без явного коммита в этом репо
3. **Контроль версий** — явная фиксация версии, не зависит от upstream
4. **Офлайн-сборка** — не нужен интернет для `git submodule update`

Встроено только 4 .v файла (~1.5K строк), что пренебрежимо мало по сравнению с основным RTL.
