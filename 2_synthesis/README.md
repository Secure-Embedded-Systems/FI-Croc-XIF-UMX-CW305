# 2. Synthesis — Vivado Build for CW305

Vivado project scripts, constraints, reports, and prebuilt bitstreams for the
CROC + unified MX coprocessor on the ChipWhisperer CW305.
Tested with **Vivado 2020.2** targeting **Artix-7 XC7A35T-2FTG256**.
The source lists default to the vendored `../1_rtl/croc` and `../1_rtl/cw305`;
override the CROC location with the `CROC_ROOT` environment variable if needed.

## Build scripts

| File | Builds | Top wrapper |
|------|--------|-------------|
| `build_cw305.tcl` | Baseline | `croc_cw305` |
| `build_cw305_live.tcl` | Direct-wire live monitor | `croc_cw305_live` |
| `build_cw305_scan.tcl` | 129-bit mux-scan | `croc_cw305_scan` |

Each pairs with an `add_sources_cw305*.tcl` source list (164 files: MX RTL plus
CROC CVE2 core, PULP common cells, OBI/APB, and the CW305 USB front-end).

```bash
export CROC_ROOT=/path/to/croc
vivado -mode batch -source build_cw305_live.tcl
```

## Constraints and reports

- `constraints/cw305.xdc` — pinout and clocking (PLL `pll_clk1` on N13, glitch `tio_clkin` on N14, `usb_clk`).
- `reports/utilization_cw305_live.rpt`, `reports/timing_summary_cw305_live.rpt` — for the `cw305_live` build:

| Resource | Value |
|----------|-------|
| LUT | 11,621 |
| FF | 4,790 |
| BRAM | 2 |
| Functional-clock WNS (`pll_clk1` / `tio_clkin`) | 9.919 ns (met) |

## Bitstreams

`bitstreams/cw305_live/` and `bitstreams/cw305_scan/` hold **15** `.bit` files:

- 10 live = 5 formats × {QNN, BitNet} — BitNet variants suffixed `_bitnet`.
- 5 scan = 5 formats × QNN.

Firmware is baked into BRAM, so there is one `.bit` per (format, workload). Each
directory also ships a `croc_cw305.mmi` BRAM map for `updatemem` firmware patching.

> Bitstreams are large binaries and may be **gitignored** (see `.gitignore`);
> rebuild them from the `.tcl` scripts or fetch from release assets.
