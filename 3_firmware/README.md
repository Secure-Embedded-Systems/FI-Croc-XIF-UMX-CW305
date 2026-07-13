# 3. Firmware — SoC Runtime and MX Workloads

Bare-metal RISC-V firmware that exercises the unified MX coprocessor. Two
workloads (QNN decoder and BitNet FC1) are compiled per MX format, converted to
BRAM init images, and baked into (or patched into) the CW305 bitstreams.

## `soc/` — CROC-derived runtime

- `link.ld`, `crt0.S` — linker script and startup (from CROC upstream).
- `config.h` — SoC memory/peripheral configuration.
- `lib/inc`, `lib/src` — drivers: `uart`, `gpio`, `clint`, `obi_timer`, `soc_ctrl`, `print`, `util`.

## `include/mx.h`

Inline-assembly MX ISA intrinsics: a single custom-0 opcode (`0x0B`) with the
format in `funct7[4:2]`, covering all five formats and ops (DOT4, ADD4, MUL4,
RELU4, SET_SE, MACS, ...).

## `workloads/`

| Dir | Contents |
|-----|----------|
| `qnn/` | `qnn_llm_<fmt>.c` — 2-layer GPT-style quantized decoder (2-head attention, KV cache, LM head); `gen_weights_qnn_llm.py` generates the `weights/` headers. |
| `bitnet/` | `tiny_llm_<fmt>_fi.c` — BitNet b1.58 FC1 / tiny transformer decoder for FI campaigns; `gen_weights_llm.py` generates the `weights/` headers. |

Five per-format `.c` files each (`mxint8`, `mxfp8_e4m3`, `mxfp8_e5m2`, `mxlog8`,
`mxlog8_logdom`). The `weights/*.h` headers are generated, not hand-edited.

## Build flow

```
gen_weights_*.py  ->  weights/*.h
riscv64-unknown-elf-gcc + crt0.S + link.ld  ->  .elf  ->  .hex
hex2mem.py (../4_fault_injection)  ->  bank0/bank1 .mem
updatemem + croc_cw305.mmi         ->  firmware baked into BRAM (.bit)
```

Compile a workload against the CROC toolchain, emit a flat `.hex`, split it into
IMEM/DMEM bank images with `hex2mem.py`, then either build the bitstream with the
image as `MEMORY_INIT_FILE` or patch an existing `.bit` via `updatemem` and the
`croc_cw305.mmi` map (`../2_synthesis/bitstreams/`).
