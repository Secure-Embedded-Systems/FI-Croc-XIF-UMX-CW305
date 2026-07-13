# Fault Analysis of Microscaling Formats on a RISC-V SoC

Reproducibility artifact for the fault-injection study of OCP Microscaling (MX)
number formats on a CROC RISC-V SoC with a unified MX coprocessor attached over
the CV-X-IF extension interface. The design is evaluated on a ChipWhisperer
CW305 (Xilinx Artix-7) under **voltage underscaling** and **clock glitching**,
with a **129-bit state monitor** that reads the coprocessor's internal state out
over USB for causal post-fault attribution.

Five 8-bit MX-compatible formats are compared: the three OCP-standard encodings
plus two proposed log-domain variants.

## Format naming

The paper and these files use different short names for the two log-domain
formats. The mapping is:

| File / dataset name | Paper name | Reduction | Notes |
|---------------------|-----------|-----------|-------|
| `mxint8`            | MXINT8      | MUL + sum       | OCP standard, ternary-friendly |
| `mxfp8_e4m3`        | MXFP8-E4M3  | MUL + sum       | OCP standard |
| `mxfp8_e5m2`        | MXFP8-E5M2  | MUL + sum       | OCP standard, widest exponent |
| `mxlog8`            | **LOG8-SUM**| ADD + LUT + sum | proposed; linear-domain accumulate |
| `mxlog8_logdom`     | **LOG8-MAX**| ADD + max       | proposed; log-domain, max-dominated |

The mapping is verified two ways in `PROVENANCE.md`: firmware reduction
semantics and the golden return value (LOG8-MAX has golden return 0 on QNN).

## Hardware setup

- **FPGA:** Xilinx Artix-7 XC7A35T-2FTG256 on ChipWhisperer CW305
- **Clock:** 20 MHz (CDCE906 PLL); functional-clock WNS = 9.919 ns (post-route)
- **Glitch source:** ChipWhisperer CW-Lite (clock XOR via `tio_clkin`)
- **Voltage control:** CW305 on-board USB regulator (`target.vccint_set`)

| DIP switch | DVFS (J16=0) | Clock glitch (J16=1) |
|------------|--------------|----------------------|
| J16              | 0 (PLL clock)  | 1 (CW-Lite clock) |
| K16, K15, L14    | 1, 1, 1        | 1, 1, 1           |

## Repository layout

```
0_docs/            Experiment summary, per-format accuracy, results tables
1_rtl/             MX coprocessor RTL + vendored CROC SoC (self-contained)
  croc/rtl/          CROC SoC + CVE2 core + PULP common cells (third-party,
                     Apache-2.0 / Solderpad), integrated with the MX modules
                     (mx_pkg, mx_alu, mx_coprocessor, scan_chain, core_wrap,
                     and the SE-protect countermeasure variants)
  cw305/             CW305 top-level wrappers (baseline / live / scan)
2_synthesis/       Vivado build scripts, constraints, reports, bitstreams
3_firmware/        RISC-V firmware for both workloads x five formats
  soc/               link.ld, crt0.S, config, driver lib (CROC-derived)
  include/mx.h       MX ISA-extension intrinsics (five formats)
  workloads/qnn/     2-layer QNN decoder + weight generator
  workloads/bitnet/  BitNet b1.58 FC1 + weight generator
4_fault_injection/ DVFS and clock-glitch campaign drivers (ChipWhisperer)
5_datasets/        Captured campaign logs (1,140 DVFS + 900 clock-glitch)
6_analysis/        reproduce.py / reproduce.ipynb + table & figure generators
```

## Experiment matrix

|                        | Voltage underscaling | Clock glitching |
|------------------------|----------------------|-----------------|
| QNN x 5 formats        | 570 trials           | 450 trials      |
| BitNet x 5 formats     | 570 trials           | 450 trials      |
| **Total**              | **1,140**            | **900**         |

## Quick reproduction (no board required)

Regenerate the paper's result tables directly from the shipped datasets:

```bash
python3 6_analysis/reproduce.py            # print Tables 7, 8, 10 + Fig. 5 order
python3 6_analysis/reproduce.py --check    # verify every value against the paper
python3 6_analysis/reproduce.py --md out.md  # also write a Markdown report
```

`--check` exits 0 only if the reproduced outcome counts, onset voltages, and
aggregate fault rates match the published numbers. The golden reference output
is committed at `6_analysis/expected/reproduced_tables.md`. See `PROVENANCE.md`
for the full RTL -> script -> dataset -> table chain.

## Full reproduction on hardware

Requires a CW305 board, a CW-Lite, Vivado (tested with 2020.2), and a RISC-V GCC
toolchain (`riscv64-unknown-elf-gcc`).

The CROC SoC and CVE2 core are already vendored under `1_rtl/croc/` (no fetch
needed), so the design builds self-contained:

```bash
# 1. Build a per-format bitstream with the 129-bit state monitor
vivado -mode batch -source 2_synthesis/build_cw305_live.tcl

# 2. Build firmware and patch it into BRAM, then run a campaign
make -C 3_firmware
python3 4_fault_injection/dvfs_5format_sweep.py       # DVFS, QNN x 5 formats
python3 4_fault_injection/clkglitch_qnn_5format.py    # clock glitch, QNN x 5
```

Each per-format/per-workload bitstream bakes its firmware into block RAM, which
is why `2_synthesis/bitstreams/` holds one `.bit` per (format, workload); the
DVFS driver reprograms the board with the matching bitstream at each step.

### Two observability builds (both used)

The same 129-bit internal state is read out two ways, for two purposes:

| Build | Readout | Purpose | Used by |
|-------|---------|---------|---------|
| `cw305_live` | Direct-wire registers (0x08-0x0B), instant, zero added cycles | Non-intrusive FPGA bring-up monitor; trustworthy under fault (does not perturb timing) | BitNet DVFS, both clock-glitch campaigns, SE root-cause |
| `cw305_scan` | 129-bit mux-scan chain shifted MSB-first over one serial pin (~130 cycles) | Silicon-realistic DFT path: same state observable with a single pad, as a taped-out ASIC would | QNN DVFS sweep |

Script/build pairing: `dvfs_5format_sweep.py` (QNN) uses the **scan** decode and
pairs with `cw305_scan`; `dvfs_bitnet_5format.py`, `clkglitch_qnn_5format.py`,
and `clkglitch_bitnet_5format.py` use the **live** structured-register decode and
pair with `cw305_live`. The two decoders extract identical logical fields.

## AI-assisted development

For functional verification and automation, AI-generated scripts were adopted:
testbench scaffolding and golden-reference cross-checks on the verification
side, and campaign orchestration, dataset post-processing, and table/figure
generation on the automation side. The RTL architecture, experimental design,
and analysis are the authors' own and were reviewed by them.

## Citation

Shanmugam, D. and Schaumont, P. (2026). Fault Analysis of Microscaling Formats
on a RISC-V SoC. Proceedings of the Great Lakes Symposium on VLSI 2026
(GLSVLSI '26). ACM. https://doi.org/10.1145/3787109.3815291.

```bibtex
@inproceedings{Shanmugam2026MXFault,
  author    = {Dillibabu Shanmugam and Patrick Schaumont},
  title     = {Fault Analysis of Microscaling Formats on a {RISC-V} {SoC}},
  booktitle = {Proceedings of the Great Lakes Symposium on VLSI 2026 (GLSVLSI)},
  year      = {2026},
  doi       = {10.1145/3787109.3815291}
}
```

## License

Apache-2.0 (see [LICENSE](LICENSE)). The CROC linker
(`3_firmware/soc/link.ld`) and crt0 (`3_firmware/soc/crt0.S`) are derivative
works of the CROC platform from ETH Zurich and University of Bologna under the
same license.

## Acknowledgements

This research was supported in part by the National Science Foundation under
Grant No. 2219810.
