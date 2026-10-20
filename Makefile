# ============================================================================
# Makefile — обёртки над Vivado/TCL-скриптами DFX-сборки
# ============================================================================
# Основной поток сборки — TCL-скрипты (build_dfx.tcl и др.), этот Makefile
# лишь даёт короткие цели. Vivado должен быть в PATH либо задан через
# VIVADO=/path/to/vivado.bat (Windows) / VIVADO=vivado (Linux).
#
# Примеры:
#   make build            # полная DFX-сборка (synth+impl+bitstream+partials)
#   make proj             # только создать проект (SKIP_SYNTH=1)
#   make num_mac=16 build # собрать с NUM_MAC=16 (и NUM_MAC=16 — эквивалент)
#   make adders=4 build   # собрать с ADDERS=4 (и ADDERS=4 — эквивалент;
#                         #   нижний регистр разрешён через алиасы ниже)
#   make artifacts        # .bin/.mcs из готового impl_1 (без пересинтеза)
#   make clean            # удалить каталог проекта и артефакты
# ============================================================================

NUM_MAC ?= 32
ADDERS  ?= 16
JOBS    ?= 7

# Lowercase-алиасы (2026-10-01): позволяют писать `make num_mac=32 adders=8`
# так же, как `make NUM_MAC=32 ADDERS=8`. GNU make чувствителен к регистру имён
# переменных, поэтому раньше `num_mac=...` молча игнорировался и шёл дефолт.
# Правило: если NUM_MAC/ADDERS не заданы в командной строке, они берутся из
# num_mac/adders. (Команд-строка NUM_MAC=... имеет высший приоритет и не
# перезаписывается — `:=` для неё действует только через override.)
num_mac ?= $(NUM_MAC)
adders  ?= $(ADDERS)
jobs    ?= $(JOBS)
flat    ?:= $(FLAT)
NUM_MAC := $(num_mac)
ADDERS  := $(adders)
JOBS    := $(jobs)
FLAT    := $(FLAT)


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

BUILD_DFX      := scripts/build_dfx.tcl
GEN_BITSTREAM  := scripts/build_dfx.tcl   # full refresh (BD+synth+impl+bitstream) = master build
GEN_BIN_MCS    := scripts/gen_bin_mcs.tcl

# Flat-сборка: `make FLAT num_mac=32 adders=16 build` (или `make FLAT build`).
# FLAT фигурирует в целях командной строки => выбираем build_flat.tcl.
ifneq ($(filter FLAT,$(MAKECMDGOALS)),)
  BUILD_SCRIPT := scripts/build_flat.tcl
else
  BUILD_SCRIPT := $(BUILD_DFX)
endif

.PHONY: build proj artifacts bitstream clean help FLAT

# no-op цель-флаг: позволяет писать `make FLAT ... build` (см. $(filter FLAT,...))
FLAT:

help:
	@echo "Targets: build | proj | artifacts | bitstream | clean (prefix FLAT for flat: make FLAT build)"

# Полная сборка (DFX по умолчанию; FLAT — если задан флаг FLAT)
build:
	"$(VIVADO)" -mode batch -source $(BUILD_SCRIPT) -tclargs NUM_MAC=$(NUM_MAC) ADDERS=$(ADDERS) JOBS=$(JOBS)

# Только создать проект без синтеза
proj:
	"$(VIVADO)" -mode batch -source $(BUILD_SCRIPT) -tclargs SKIP_SYNTH=1

# Экспорт .bin/.mcs/partial из существующего impl_1 (без пересинтеза)
artifacts:
	"$(VIVADO)" -mode batch -source $(GEN_BIN_MCS)

# Полный цикл для существующего проекта: synth+impl+bitstream+экспорт
bitstream:
	"$(VIVADO)" -mode batch -source $(GEN_BITSTREAM) -tclargs NUM_MAC=$(NUM_MAC) ADDERS=$(ADDERS) JOBS=$(JOBS)

clean:
ifeq ($(OS),Windows_NT)
	-if exist C:\build_dfx rd /s /q C:\build_dfx
	-if exist build\dfx_proj rd /s /q build\dfx_proj
	-if exist build\dfx_proj.cache rd /s /q build\dfx_proj.cache
	-if exist build\dfx_proj.gen  rd /s /q build\dfx_proj.gen
	-if exist build\artifacts_dfx rd /s /q build\artifacts_dfx
else
	rm -rf build/dfx_proj build/dfx_proj.cache build/dfx_proj.gen \
	       build/dfx_proj.hw build/dfx_proj.ip_user_files build/dfx_proj.sim \
	       build/dfx_proj.srcs build/dfx_proj.runs build/dfx_proj.xpr \
	       build/artifacts_dfx
endif
