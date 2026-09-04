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
#   make num_mac=16 build # собрать с NUM_MAC=16
#   make artifacts        # .bin/.mcs из готового impl_1 (без пересинтеза)
#   make clean            # удалить каталог проекта и артефакты
# ============================================================================

NUM_MAC ?= 32
JOBS    ?= 8

VIVADO ?= vivado
ifeq ($(OS),Windows_NT)
  VIVADO ?= vivado.bat
endif

BUILD_DFX      := scripts/build_dfx.tcl
GEN_BITSTREAM  := scripts/gen_bitstream.tcl
GEN_BIN_MCS    := scripts/gen_bin_mcs.tcl

.PHONY: build proj artifacts bitstream clean help

help:
	@echo "Targets: build | proj | artifacts | bitstream | clean"

# Полная сборка DFX (проект создаётся заново, затем synth+impl+bitstream)
build:
	"$(VIVADO)" -mode batch -source $(BUILD_DFX) -tclargs NUM_MAC=$(NUM_MAC) JOBS=$(JOBS)

# Только создать проект без синтеза
proj:
	"$(VIVADO)" -mode batch -source $(BUILD_DFX) -tclargs SKIP_SYNTH=1

# Экспорт .bin/.mcs/partial из существующего impl_1 (без пересинтеза)
artifacts:
	"$(VIVADO)" -mode batch -source $(GEN_BIN_MCS)

# Полный цикл для существующего проекта: synth+impl+bitstream+экспорт
bitstream:
	"$(VIVADO)" -mode batch -source $(GEN_BITSTREAM)

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
