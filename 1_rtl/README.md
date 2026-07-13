# 1_rtl — RTL sources

Self-contained RTL for the CROC RISC-V SoC with the unified MX coprocessor and
the 129-bit state monitor. Everything needed to synthesize is vendored here; no
external fetch is required.

```
croc/rtl/   CROC SoC + CVE2 core + PULP common cells (third-party) plus the
            integrated MX modules, exactly as used to build the paper bitstreams
cw305/      CW305 FPGA top-level wrappers
```

## MX coprocessor modules (authored, in `croc/rtl/`)

| File | Purpose |
|------|---------|
| `mx_pkg.sv` | Format enums (5 MX formats), E8M0 shared-exponent types, opcodes. |
| `mx_alu.sv` | Unified MX ALU / block-scaled MAC datapath for all five formats. |
| `mx_coprocessor.sv` | CV-X-IF handler: decodes custom-0, selects format/op, drives `mx_alu`. |
| `scan_chain.sv` | 129-bit mux-scan chain (MSB-first) for internal-state readout. |
| `core_wrap.sv` | Core wrapper integrating the coprocessor into the CVE2 pipeline. |
| `mx_alu_se_protect.sv` | SE-integrity countermeasure ALU (shadow shared-exponent regs). |
| `mx_coprocessor_se_protect.sv` | Coprocessor wired to the SE-protect ALU. |

These files carry the authors' header. All other files under `croc/rtl/`
(CVE2, common cells, OBI/APB, riscv-dbg, tech cells) are third-party and retain
their upstream Apache-2.0 / Solderpad headers — see `../NOTICE`.

## CW305 wrappers (`cw305/`)

| File | Purpose |
|------|---------|
| `croc_cw305.sv` | Baseline CW305 top level (no monitor). |
| `croc_cw305_live.sv` | Direct-wire 129-bit state monitor to USB registers (0x08-0x0B). |
| `croc_cw305_scan.sv` | Scan-chain readout: shifts the 129-bit word out over one pin. |
| `cw305_usb_reg_fe.sv` | CW305 USB register front-end. |

## Building

The Vivado source lists in `../2_synthesis/add_sources_cw305_*.tcl` reference
`1_rtl/croc` (override with the `CROC_ROOT` env var) and `1_rtl/cw305`. See
`../2_synthesis/README.md`.
