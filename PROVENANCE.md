# Provenance: how the RTL, firmware, and scripts produce the results

This document traces every published number back to the code and data in this
repository, so a reviewer can confirm that the shipped artifacts are the ones
that generated the paper's tables and figures. The hardware campaigns were run
on a physical ChipWhisperer CW305 board; the **data-to-table** half of the
chain can be re-executed on any machine with `python3` and no board.

## The chain

```
MX coprocessor internal state (rs1, rs2, mac_acc, se_a, se_b, op, fmt, inf, rd, id)
        |
        +-- 1_rtl/cw305/croc_cw305_live.sv  direct-wire -> structured USB regs
        |        (0x08=rs1, 0x09=rs2, 0x0A=mac, 0x0B={se_a,se_b,op,fmt,inf,rd,id})
        |        used by: BitNet DVFS, clock-glitch (QNN+BitNet)
        |
        +-- 1_rtl/mx/scan_chain.sv + croc_cw305_scan.sv  129-bit shift, MSB-first
                 word: {rs1[31:0], rs2[31:0], mac_acc[31:0], se_a[7:0], se_b[7:0],
                        op[3:0], fmt[2:0], inflight, rd[4:0], id[3:0]}
                 dumped into contiguous USB words 0x08..0x0C
                 used by: QNN DVFS sweep
        v
4_fault_injection/*.py   decode + classify each trial:
        |                normal | fault (SDC) | crash | dead
        v
5_datasets/dvfs_qnn/*.csv  dvfs_bitnet/*.csv  clock_glitch/*.csv
        v
6_analysis/reproduce.py    aggregates -> Tables 7, 8, 10 and Fig. 5 ordering
```

Both readouts expose the identical 10 logical fields; they differ only in the
register layout, so the CSV columns are the same regardless of which build
produced a given file.

## Bit-exact link: RTL packing == script unpacking

**Scan build** (`scan_chain.sv` + `croc_cw305_scan.sv`, QNN DVFS). The 129-bit
word is packed MSB-first; `dvfs_5format_sweep.py:decode_scan()` reassembles five
USB words (0x08..0x0C) and unpacks at exactly the same offsets:

| Field | RTL bit range | `decode_scan` expression |
|-------|---------------|--------------------------|
| rs1     | [128:97] | `(f >> 97) & 0xFFFFFFFF` |
| rs2     | [96:65]  | `(f >> 65) & 0xFFFFFFFF` |
| mac_acc | [64:33]  | `(f >> 33) & 0xFFFFFFFF` |
| se_a    | [32:25]  | `(f >> 25) & 0xFF`       |
| se_b    | [24:17]  | `(f >> 17) & 0xFF`       |
| op      | [16:13]  | `(f >> 13) & 0xF`        |
| fmt     | [12:10]  | `(f >> 10) & 0x7`        |
| inflight| [9]      | `(f >> 9)  & 1`          |
| rd      | [8:4]    | (present in word)        |
| id      | [3:0]    | (present in word)        |

**Live build** (`croc_cw305_live.sv`, BitNet DVFS + clock glitch). Structured
registers; the drivers read them directly:

| Field | USB register | script expression |
|-------|--------------|-------------------|
| rs1     | 0x08 | `read32(0x08)`          |
| rs2     | 0x09 | `read32(0x09)`          |
| mac_acc | 0x0A | `read32(0x0A)`          |
| se_a    | 0x0B[7:0]   | `ctrl & 0xFF`        |
| se_b    | 0x0B[15:8]  | `(ctrl >> 8) & 0xFF`|
| op      | 0x0B[19:16] | `(ctrl >> 16) & 0xF`|
| fmt     | 0x0B[21:19] | `(ctrl >> 19) & 0x7`|
| inflight| 0x0B[22]    | `(ctrl >> 22) & 1`  |

These fields become the `rs1, rs2, mac_acc, se_a, se_b, op, fmt_hw, inflight`
columns of every dataset CSV. `se_a = 127` is the neutral shared exponent;
`se_a != 127` on a faulted row is the shared-exponent (SE) corruption signature.

## Classification link: script == analysis

`dvfs_5format_sweep.py` assigns each trial a `class`:
`dead` (USB reads 0xFFFFFFFF), `crash` (`eoc == 0`), else `normal`/`fault`
by comparing `ret` to the golden value measured at nominal 1.0 V.
`reproduce.py` consumes exactly this `class` column plus `se_a`, so the paper's
outcome counts are a pure re-aggregation of the campaign logs.

## Reproduced values (see `6_analysis/expected/reproduced_tables.md`)

Running `python3 6_analysis/reproduce.py --check` regenerates and verifies:

* **Table 7 (QNN):** MXFP8-E5M2 57/27/27/3 onset 0.81 V; MXFP8-E4M3 60/24/27/3
  0.80 V; MXINT8 66/18/27/3 0.78 V; LOG8-SUM 69/15/27/3 0.68 V;
  LOG8-MAX 69/15/27/3 0.68 V. Crash 0.77 V, SE onset 0.68 V for all.
* **Table 8 (BitNet):** SE corruption universal; MXFP8-E4M3/E5M2 golden return
  0 masks CPU-path SDC.
* **Table 10:** voltage underscaling 1,140 trials -> 262 crashes (23.0 %),
  190 silent faults (16.7 %); clock glitching 900 trials -> 0 crashes, 0 SDC.

All values match the paper exactly (`--check` exits 0).

## What needs the physical board

Regenerating the CSVs from scratch requires the CW305 + CW-Lite hardware, the
per-format/per-workload bitstreams (`2_synthesis/bitstreams/`, or rebuilt from
`2_synthesis/*.tcl`), and `4_fault_injection/*.py`. The datasets in
`5_datasets/` are the captured output of those runs.
