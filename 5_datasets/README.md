# 5. Datasets — Raw Fault-Injection Campaign Logs

CSV and JSON logs from the hardware campaigns. These are the inputs the analysis
in `../6_analysis` consumes; no board is needed to reproduce the paper tables
from them. **2,040 trials** total: 1,140 voltage (570 QNN + 570 BitNet) + 900
clock glitch (450 + 450).

## Layout

| Path | Contents | Trials |
|------|----------|-------:|
| `dvfs_qnn/` | QNN voltage underscaling; 5 per-format files (114 rows each) + `dvfs_all_formats.csv` | 570 |
| `dvfs_bitnet/` | BitNet FC1 voltage underscaling; 5 per-format files + `dvfs_bitnet_all_formats.csv` | 570 |
| `clock_glitch/` | Clock-glitch campaigns; 10 files (5 formats × {QNN, BitNet}), 90 rows each | 900 |
| `results/` | Raw JSON campaign logs and configs (sweeps, boundaries, summaries) | — |

Format file names map to paper names: `mxint8`=MXINT8, `mxfp8_e4m3`=MXFP8-E4M3,
`mxfp8_e5m2`=MXFP8-E5M2, `mxlog8`=**LOG8-SUM**, `mxlog8_logdom`=**LOG8-MAX**.

## CSV columns

| Column | Meaning |
|--------|---------|
| `format` | MX format (file-name form). |
| `vccint` | Core voltage for the trial (V). |
| `trial` | Repeat index at that operating point. |
| `eoc` | End-of-computation flag (`0` = crash/hang). |
| `ret` | Observed return value. |
| `golden_ret` | Reference (fault-free) return value. |
| `class` | Outcome: `normal` / `fault` / `crash` / `dead`. |
| `xor` | `ret XOR golden_ret`. |
| `bits_diff` | Hamming distance between `ret` and `golden_ret`. |
| `se_a`, `se_b` | Captured shared-exponent registers (`127` = neutral). |
| `mac_acc` | MAC accumulator snapshot. |
| `rs1`, `rs2` | Captured MX operands. |
| `op` | MX operation selector. |
| `fmt_hw` | Format as seen by hardware. |
| `inflight` | In-flight / pipeline-busy flag. |
| `rd`, `id` | Destination register and instruction id. |

`se_a = 127` is neutral; `se_a != 127` on a faulted row indicates
shared-exponent (SE) corruption.
