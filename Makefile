# ============================================================================
# Makefile — обёртки над Vivado/TCL-скриптами flat-сборки
# ============================================================================
# Основной поток сборки — TCL-скрипт build_flat.tcl (полный цикл BD+synth+
# impl+bitstream+экспорт артефактов), этот Makefile лишь даёт короткие цели.
# Vivado должен быть в PATH либо задан через
# VIVADO=/path/to/vivado.bat (Windows) / VIVADO=vivado (Linux).
#
# Примеры:
#   make build            # полная flat-сборка (BD+synth+impl+bitstream)
#   make proj             # только создать проект (SKIP_SYNTH=1)
#   make num_mac=16 build # собрать с NUM_MAC=16 (и NUM_MAC=16 — эквивалент)
#   make adders=4 build   # собрать с ADDERS=4 (и ADDERS=4 — эквивалент;
#                         #   нижний регистр разрешён через алиасы ниже)
#   make elem_fmt=2 build # собрать с ELEM_FMT=2 (PACKED6); 0=легаси (дефолт)
#   make bitstream        # полный цикл сборки + экспорт артефактов
#   make clean            # удалить каталог проекта и артефакты
# ============================================================================

NUM_MAC ?= 8
ADDERS  ?= 4
ELEM_FMT ?= 0
JOBS    ?= 7

# Lowercase-алиасы (2026-10-01): позволяют писать `make num_mac=32 adders=8`
# так же, как `make NUM_MAC=32 ADDERS=8`. GNU make чувствителен к регистру имён
# переменных, поэтому раньше `num_mac=...` молча игнорировался и шёл дефолт.
# Правило: если NUM_MAC/ADDERS не заданы в командной строке, они берутся из
# num_mac/adders. (Команд-строка NUM_MAC=... имеет высший приоритет и не
# перезаписывается — `:=` для неё действует только через override.)
num_mac ?= $(NUM_MAC)
adders  ?= $(ADDERS)
elem_fmt ?= $(ELEM_FMT)
jobs    ?= $(JOBS)
NUM_MAC := $(num_mac)
ADDERS  := $(adders)
ELEM_FMT := $(elem_fmt)
JOBS    := $(jobs)
JOBS    := $(jobs)

# Auto-detect Vivado on Windows
VIVADO ?= vivado
ifeq ($(OS),Windows_NT)
  ifeq ($(wildcard $(VIVADO)),)
    _VIVADO_SEARCH := $(wildcard \
      C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat \
      C:/Xilinx/Vivado/2025.2/bin/vivado.bat \
      C:/AMDDesignTools/*/Vivado/bin/vivado.bat \
      C:/Xilinx/Vivado/*/bin/vivado.bat)
    ifneq ($(strip $(_VIVADO_SEARCH)),)
      _VIVADO := $(firstword $(_VIVADO_SEARCH))
      $(info Auto-detected Vivado: $(_VIVADO))
      VIVADO := $(_VIVADO)
    else
      VIVADO := vivado.bat
      $(warning Vivado not found in common paths; set VIVADO= explicitly)
    endif
  endif
endif

BUILD_FLAT    := scripts/build_flat.tcl   # master build: BD+synth+impl+bitstream+artifacts

.PHONY: build proj bitstream clean help

help:
	@echo "Targets: build | proj | bitstream | clean"

# Полная flat-сборка (проект создаётся заново, затем synth+impl+bitstream+артефакты)
build:
	"$(VIVADO)" -mode batch -source $(BUILD_FLAT) -tclargs NUM_MAC=$(NUM_MAC) ADDERS=$(ADDERS) ELEM_FMT=$(ELEM_FMT) JOBS=$(JOBS)

# Только создать проект без синтеза
proj:
	"$(VIVADO)" -mode batch -source $(BUILD_FLAT) -tclargs SKIP_SYNTH=1

# Полный цикл сборки + экспорт артефактов (build_flat экспортирует .bit/.mcs сам)
bitstream:
	"$(VIVADO)" -mode batch -source $(BUILD_FLAT) -tclargs NUM_MAC=$(NUM_MAC) ADDERS=$(ADDERS) ELEM_FMT=$(ELEM_FMT) JOBS=$(JOBS)

clean:
ifeq ($(OS),Windows_NT)
	-if exist C:\build_flat rd /s /q C:\build_flat
	-if exist build\flat_proj rd /s /q build\flat_proj
	-if exist build\flat_proj.cache rd /s /q build\flat_proj.cache
	-if exist build\flat_proj.gen  rd /s /q build\flat_proj.gen
	-if exist build\artifacts_flat rd /s /q build\artifacts_flat
else
	rm -rf build/flat_proj build/flat_proj.cache build/flat_proj.gen \
	       build/flat_proj.hw build/flat_proj.ip_user_files build/flat_proj.sim \
	       build/flat_proj.srcs build/flat_proj.runs build/flat_proj.xpr \
	       build/artifacts_flat
endif
