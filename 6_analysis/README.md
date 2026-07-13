# 6. Analysis — Reproduce the Paper Tables

Scripts that regenerate the paper's fault-injection results directly from the
CSV datasets in `../5_datasets`. No FPGA board or Vivado is required.

## Reproduce

`reproduce.py` regenerates **Table 7** (QNN voltage underscaling), **Table 8**
(BitNet FC1 voltage underscaling), **Table 10** (voltage vs. clock-glitch method
comparison), and the **Fig. 5** fault-resilience ordering.

```bash
# Print all tables
python3 6_analysis/reproduce.py

# Verify against the paper's published numbers (exits 0 on match, non-zero on divergence)
python3 6_analysis/reproduce.py --check

# Also write a Markdown report
python3 6_analysis/reproduce.py --md report.md
```

Override the dataset location with the `MX_DATASETS` environment variable.

## Files

| File | Purpose |
|------|---------|
| `reproduce.py` | Regenerates Tables 7/8/10 + Fig. 5; `--check` verifies, `--md` writes a report. |
| `reproduce.ipynb` | Notebook version of the same reproduction. |
| `generate_tables.py` | Builds the formatted result tables. |
| `plot_results.py` | Renders the figures (e.g. Fig. 5). |
| `analyze_results.py` | Lower-level per-format outcome/SE aggregation. |
| `expected/reproduced_tables.md` | Golden output checked in for comparison. |

The outcome taxonomy (`normal` / `fault` (SDC) / `crash` (`eoc=0`) / `dead`) is
read from the `class` column; SE corruption is detected via `se_a != 127` on a
faulted row. Format file names map to paper names as in `../5_datasets`
(`mxlog8`=LOG8-SUM, `mxlog8_logdom`=LOG8-MAX).
