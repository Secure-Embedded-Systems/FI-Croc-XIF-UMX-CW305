# SPDX-License-Identifier: Apache-2.0
# Fault Analysis of Microscaling Formats on a RISC-V SoC
# Authors: Dillibabu Shanmugam, Patrick Schaumont
# Affiliation: Worcester Polytechnic Institute (WPI), USA

# Fault Injection Artifact — Build & Run
#
# Prerequisites:
#   - riscv64-unknown-elf-gcc (RISC-V toolchain)
#   - Vivado 2020.2 (for updatemem bitstream patching)
#   - ChipWhisperer Python package (pip install chipwhisperer)
#   - CW305 + optional CW-Lite connected via USB
#
# Usage:
#   make build-firmware        Build all firmware variants (.hex)
#   make patch-bitstreams      Patch bitstreams with BitNet firmware
#   make run-dvfs-qnn          Run DVFS sweep: QNN × 5 formats (J16=0)
#   make run-dvfs-bitnet       Run DVFS sweep: BitNet × 5 formats (J16=0)
#   make run-clkglitch-qnn     Run clock glitch: QNN × 5 formats (J16=1)
#   make run-all               Run all experiments

SHELL := /bin/bash

# Numbered-repo layout: this Makefile lives in 3_firmware/
FW_DIR     := $(CURDIR)
SOC        := $(FW_DIR)/soc
REPO_DIR   := $(FW_DIR)/..
SYN_DIR    := $(REPO_DIR)/2_synthesis
FI_DIR     := $(REPO_DIR)/4_fault_injection
BIT_DIR    := $(SYN_DIR)/bitstreams/cw305_live
MMI_FILE   := $(BIT_DIR)/croc_cw305.mmi
HEX2MEM    := $(FI_DIR)/hex2mem.py
UPDATEMEM  := updatemem

RISCV_PREFIX := riscv64-unknown-elf-
RISCV_CC     := $(RISCV_PREFIX)gcc
RISCV_OBJCOPY := $(RISCV_PREFIX)objcopy
RISCV_FLAGS  := -march=rv32ic -mabi=ilp32 -mcmodel=medany -static -std=gnu99 \
                -Os -nostdlib -fno-builtin -ffreestanding
RISCV_INC    := -I $(FW_DIR)/include -I $(FW_DIR)/workloads/bitnet/weights \
                -I $(SOC)/lib/inc -I $(SOC)
LIBGCC       := $(shell $(RISCV_CC) -march=rv32ic -mabi=ilp32 -print-libgcc-file-name)

FORMATS := mxint8 mxfp8_e4m3 mxfp8_e5m2 mxlog8 mxlog8_logdom
BANK0_PROC := i_croc_soc/i_croc/gen_sram_bank[0].i_sram/i_tc_sram/gen_1_ports.i_xpm_memory_spram/xpm_memory_base_inst
BANK1_PROC := i_croc_soc/i_croc/gen_sram_bank[1].i_sram/i_tc_sram/gen_1_ports.i_xpm_memory_spram/xpm_memory_base_inst

BUILD_DIR := /tmp/fi_artifact_build

.PHONY: all build-firmware patch-bitstreams run-dvfs-qnn run-dvfs-bitnet run-clkglitch-qnn run-all clean

all: build-firmware

$(BUILD_DIR):
	mkdir -p $@

build-firmware: | $(BUILD_DIR)
	@echo "=== Compiling CRT0 and library ==="
	$(RISCV_CC) $(RISCV_FLAGS) $(RISCV_INC) -c $(SOC)/crt0.S -o $(BUILD_DIR)/crt0.o
	$(RISCV_CC) $(RISCV_FLAGS) $(RISCV_INC) -c $(SOC)/lib/src/uart.c -o $(BUILD_DIR)/uart.o
	$(RISCV_CC) $(RISCV_FLAGS) $(RISCV_INC) -c $(SOC)/lib/src/print.c -o $(BUILD_DIR)/print.o
	$(RISCV_CC) $(RISCV_FLAGS) $(RISCV_INC) -c $(SOC)/lib/src/gpio.c -o $(BUILD_DIR)/gpio.o
	@for fmt in $(FORMATS); do \
		echo "=== Building BitNet $$fmt ===" ; \
		$(RISCV_CC) $(RISCV_FLAGS) $(RISCV_INC) -c \
			$(FW_DIR)/workloads/bitnet/tiny_llm_$${fmt}_fi.c -o $(BUILD_DIR)/tiny_llm_$${fmt}.o ; \
		$(RISCV_CC) -o $(BUILD_DIR)/tiny_llm_$${fmt}.elf \
			$(BUILD_DIR)/tiny_llm_$${fmt}.o $(BUILD_DIR)/crt0.o \
			$(BUILD_DIR)/uart.o $(BUILD_DIR)/print.o $(BUILD_DIR)/gpio.o \
			-static -nostartfiles -nostdlib -march=rv32ic -mabi=ilp32 \
			-T $(SOC)/link.ld $(LIBGCC) ; \
		$(RISCV_OBJCOPY) -O verilog $(BUILD_DIR)/tiny_llm_$${fmt}.elf \
			$(BUILD_DIR)/tiny_llm_$${fmt}.hex ; \
		python3 $(HEX2MEM) $(BUILD_DIR)/tiny_llm_$${fmt}.hex \
			$(BUILD_DIR)/bank0_$${fmt}.mem $(BUILD_DIR)/bank1_$${fmt}.mem ; \
	done
	@echo "=== All firmware built ==="

patch-bitstreams: build-firmware
	@for fmt in $(FORMATS); do \
		echo "=== Patching $$fmt ===" ; \
		echo "@00000000" > $(BUILD_DIR)/bank0_$${fmt}_xpm.mem ; \
		cat $(BUILD_DIR)/bank0_$${fmt}.mem >> $(BUILD_DIR)/bank0_$${fmt}_xpm.mem ; \
		echo "@00000000" > $(BUILD_DIR)/bank1_$${fmt}_xpm.mem ; \
		cat $(BUILD_DIR)/bank1_$${fmt}.mem >> $(BUILD_DIR)/bank1_$${fmt}_xpm.mem ; \
		$(UPDATEMEM) -force -meminfo $(MMI_FILE) \
			-data $(BUILD_DIR)/bank0_$${fmt}_xpm.mem \
			-bit $(BIT_DIR)/$${fmt}.bit \
			-proc "$(BANK0_PROC)" \
			-out $(BUILD_DIR)/$${fmt}_bank0.bit 2>/dev/null ; \
		$(UPDATEMEM) -force -meminfo $(MMI_FILE) \
			-data $(BUILD_DIR)/bank1_$${fmt}_xpm.mem \
			-bit $(BUILD_DIR)/$${fmt}_bank0.bit \
			-proc "$(BANK1_PROC)" \
			-out $(BIT_DIR)/$${fmt}_bitnet.bit 2>/dev/null ; \
		echo "  -> $(BIT_DIR)/$${fmt}_bitnet.bit" ; \
	done
	@echo "=== All bitstreams patched ==="

run-dvfs-qnn:
	@echo "Ensure J16=0 (PLL clock)"
	python3 $(FI_DIR)/dvfs_5format_sweep.py

run-dvfs-bitnet: patch-bitstreams
	@echo "Ensure J16=0 (PLL clock)"
	python3 $(FI_DIR)/dvfs_bitnet_5format.py

run-clkglitch-qnn:
	@echo "Ensure J16=1 (CW-Lite clock)"
	python3 $(FI_DIR)/clkglitch_qnn_5format.py

run-all: run-dvfs-qnn run-dvfs-bitnet run-clkglitch-qnn
	@echo "=== All experiments complete ==="

clean:
	rm -rf $(BUILD_DIR)
