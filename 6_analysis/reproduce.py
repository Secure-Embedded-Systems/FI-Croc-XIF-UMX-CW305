# SPDX-License-Identifier: Apache-2.0
# Security Analysis of Microscaling Formats Under Fault Injection on a RISC-V Edge Platform
# Authors: Dillibabu Shanmugam, Patrick Schaumont
# Affiliation: Worcester Polytechnic Institute (WPI), USA
"""
Regenerate the paper's fault-injection result tables directly from the shipped
CSV datasets in ../5_datasets. No FPGA board or Vivado is required: this script
consumes the raw campaign logs and reproduces the numbers reported in the paper.

Outputs (stdout + optional --md report):
  * Table 7  - QNN voltage-underscaling per-format outcome counts and onsets
  * Table 8  - BitNet FC1 voltage-underscaling per-format results
  * Table 10 - Fault-injection method comparison (voltage vs clock glitch)
  * Design-space fault-resilience ordering (Fig. 5 / Table 11 fault column)

Outcome taxonomy (paper Sec. 3.2), taken from the 'class' column of each CSV:
  normal | fault (silent data corruption, SDC) | crash (eoc=0) | dead
Shared-exponent (SE) corruption is detected via se_a != 127 on a faulted row.

Usage:
  python3 reproduce.py                 # print all tables
  python3 reproduce.py --md report.md  # also write a Markdown report
  python3 reproduce.py --check         # exit non-zero if any value diverges
                                       # from the paper's published numbers
"""
import argparse
import csv
import glob
import os
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.environ.get("MX_DATASETS", os.path.join(HERE, "..", "5_datasets"))

# repo file-name -> paper format name
FMT_NAME = {
    "mxfp8_e5m2": "MXFP8-E5M2",
    "mxfp8_e4m3": "MXFP8-E4M3",
    "mxint8": "MXINT8",
    "mxlog8": "LOG8-SUM",
    "mxlog8_logdom": "LOG8-MAX",
}
# paper presentation order (most to least vulnerable, Fig. 5 / Table 7)
ORDER = ["mxfp8_e5m2", "mxfp8_e4m3", "mxint8", "mxlog8", "mxlog8_logdom"]

# Published reference numbers, for --check (paper Tables 7 and 10).
# (normal, fault, crash, dead), fault_onset_V, crash_onset_V
PAPER_QNN = {
    "MXFP8-E5M2": ((57, 27, 27, 3), 0.81, 0.77),
    "MXFP8-E4M3": ((60, 24, 27, 3), 0.80, 0.77),
    "MXINT8":     ((66, 18, 27, 3), 0.78, 0.77),
    "LOG8-SUM":   ((69, 15, 27, 3), 0.68, 0.77),
    "LOG8-MAX":   ((69, 15, 27, 3), 0.68, 0.77),
}
PAPER_TABLE10 = {  # (total, crashes, silent)
    "voltage": (1140, 262, 190),
    "clock":   (900, 0, 0),
}


def load(path):
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def counts(rows):
    c = Counter(r["class"] for r in rows)
    return (c.get("normal", 0), c.get("fault", 0),
            c.get("crash", 0), c.get("dead", 0))


def highest_voltage(rows, pred):
    vs = [float(r["vccint"]) for r in rows if pred(r)]
    return max(vs) if vs else None


def qnn_table():
    rows_out = []
    for fmt in ORDER:
        rows = load(os.path.join(DATA, "dvfs_qnn", f"dvfs_{fmt}.csv"))
        n, f, cr, d = counts(rows)
        fault_onset = highest_voltage(rows, lambda r: r["class"] == "fault")
        crash_onset = highest_voltage(rows, lambda r: r["class"] == "crash")
        se_onset = highest_voltage(
            rows, lambda r: r["class"] == "fault" and r["se_a"] != "127")
        rows_out.append((FMT_NAME[fmt], (n, f, cr, d),
                         fault_onset, crash_onset, se_onset,
                         rows[0]["golden_ret"]))
    return rows_out


def bitnet_table():
    rows_out = []
    for fmt in ORDER:
        rows = load(os.path.join(DATA, "dvfs_bitnet", f"dvfs_bitnet_{fmt}.csv"))
        n, f, cr, d = counts(rows)
        se_onset = highest_voltage(
            rows, lambda r: r["class"] == "fault" and r["se_a"] != "127")
        rows_out.append((FMT_NAME[fmt], (n, f, cr, d), se_onset,
                         rows[0]["golden_ret"]))
    return rows_out


def method_comparison():
    volt = []
    for sub in ("dvfs_qnn", "dvfs_bitnet"):
        for path in sorted(glob.glob(os.path.join(DATA, sub, "dvfs_*.csv"))):
            if "all_formats" in path:
                continue
            volt += load(path)
    clk = []
    for path in sorted(glob.glob(os.path.join(DATA, "clock_glitch", "clkglitch_*.csv"))):
        clk += load(path)
    cv, cc = Counter(r["class"] for r in volt), Counter(r["class"] for r in clk)
    return {
        "voltage": (len(volt), cv.get("crash", 0), cv.get("fault", 0), cv.get("dead", 0)),
        "clock":   (len(clk), cc.get("crash", 0), cc.get("fault", 0), cc.get("dead", 0)),
    }


def fmt_onset(v):
    return f"{v:.2f} V" if v is not None else "-"


def render(md=False):
    lines = []
    p = lines.append

    p("## Table 7 - QNN voltage underscaling (570 experiments, 5 formats)")
    p("")
    p("| Format | Normal | Faults | Crashes | Dead | Fault onset | Crash | SE onset |")
    p("|--------|-------:|-------:|--------:|-----:|:-----------:|:-----:|:--------:|")
    for name, (n, f, cr, d), fo, cro, seo, _ in qnn_table():
        p(f"| {name} | {n} | {f} | {cr} | {d} | {fmt_onset(fo)} | {fmt_onset(cro)} | {fmt_onset(seo)} |")
    p("")

    p("## Table 8 - BitNet FC1 voltage underscaling (570 experiments, 5 formats)")
    p("")
    p("| Format | Normal | Faults | Crashes | Dead | SE onset | Golden ret |")
    p("|--------|-------:|-------:|--------:|-----:|:--------:|-----------:|")
    for name, (n, f, cr, d), seo, gret in bitnet_table():
        note = "  (golden=0 masks CPU SDC)" if gret == "0" else ""
        p(f"| {name} | {n} | {f} | {cr} | {d} | {fmt_onset(seo)} | {gret}{note} |")
    p("")

    p("## Table 10 - Fault-injection method comparison")
    p("")
    p("| Metric | Voltage underscaling | Clock glitching |")
    p("|--------|---------------------:|----------------:|")
    mc = method_comparison()
    vt, vcr, vf, vd = mc["voltage"]
    ct, ccr, cf, cd = mc["clock"]
    p(f"| Total experiments | {vt} | {ct} |")
    p(f"| Crashes | {vcr} ({100*vcr/vt:.1f} %) | {ccr} ({100*ccr/ct:.1f} %) |")
    p(f"| Silent faults (SDC) | {vf} ({100*vf/vt:.1f} %) | {cf} ({100*cf/ct:.1f} %) |")
    p(f"| Dead | {vd} | {cd} |")
    p("")

    p("## Fault-resilience ordering (Fig. 5): fewest silent faults wins")
    p("")
    ranked = sorted(qnn_table(), key=lambda r: r[1][1])  # by fault count
    for name, (_, f, _, _), fo, _, _, _ in ranked:
        p(f"  {name:12} silent faults = {f:2d}   fault onset = {fmt_onset(fo)}")
    out = "\n".join(lines)
    print(out)
    if md:
        with open(md, "w") as fh:
            fh.write("# Reproduced fault-injection results\n\n")
            fh.write("Generated by `reproduce.py` from `5_datasets/` (no board required).\n\n")
            fh.write(out + "\n")
        print(f"\n[written] {md}")


def check():
    ok = True
    for name, cnt, fo, cro, seo, _ in qnn_table():
        exp_cnt, exp_fo, exp_cro = PAPER_QNN[name]
        if cnt != exp_cnt:
            ok = False
            print(f"MISMATCH {name} counts: got {cnt} expected {exp_cnt}")
        if fo != exp_fo:
            ok = False
            print(f"MISMATCH {name} fault onset: got {fo} expected {exp_fo}")
        if cro != exp_cro:
            ok = False
            print(f"MISMATCH {name} crash onset: got {cro} expected {exp_cro}")
    mc = method_comparison()
    for k, (et, ecr, ef) in PAPER_TABLE10.items():
        t, cr, f, _ = mc[k]
        if (t, cr, f) != (et, ecr, ef):
            ok = False
            print(f"MISMATCH Table 10 {k}: got total={t} crash={cr} silent={f} "
                  f"expected total={et} crash={ecr} silent={ef}")
    print("CHECK PASSED: all reproduced values match the paper."
          if ok else "CHECK FAILED: see mismatches above.")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="Reproduce MX FI tables from datasets")
    ap.add_argument("--md", metavar="FILE", help="also write a Markdown report")
    ap.add_argument("--check", action="store_true",
                    help="verify reproduced values against the paper; exit 1 on mismatch")
    args = ap.parse_args()
    if not os.path.isdir(DATA):
        sys.exit(f"datasets not found at {DATA} (set MX_DATASETS)")
    if args.check:
        sys.exit(check())
    render(md=args.md)


if __name__ == "__main__":
    main()
