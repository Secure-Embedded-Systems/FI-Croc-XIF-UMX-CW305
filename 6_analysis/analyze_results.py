# SPDX-License-Identifier: Apache-2.0
# Security Analysis of Microscaling Formats Under Fault Injection on a RISC-V Edge Platform
# Authors: Dillibabu Shanmugam, Patrick Schaumont
# Affiliation: Worcester Polytechnic Institute (WPI), USA

#!/usr/bin/env python3
"""Analyze MX glitch campaign results — 5-way vulnerability comparison.

Reads CSV files from run_mx_faults.py and produces:
  - Per-format vulnerability summary
  - Offset/width heatmaps
  - Cross-format comparison table
  - Scan chain state analysis for misclassified faults

Usage:
  python3 analyze_results.py results/

Authors: Dillibabu Shanmugam, Patrick Schaumont (WPI)
"""

import argparse
import csv
import json
import os
import sys

FORMATS = [
    "mxint8",
    "mxfp8_e4m3",
    "mxfp8_e5m2",
    "mxlog8",
    "mxlog8_logdom",
]

FORMAT_LABELS = {
    "mxint8": "MXINT8",
    "mxfp8_e4m3": "MXFP8-E4M3",
    "mxfp8_e5m2": "MXFP8-E5M2",
    "mxlog8": "MXLOG8",
    "mxlog8_logdom": "MXLOG8-logdom",
}


def load_results(results_dir, mode):
    """Load all CSV results for a given glitch mode."""
    all_data = {}
    for fmt in FORMATS:
        csv_path = os.path.join(results_dir, f"glitch_{fmt}_{mode}.csv")
        if not os.path.exists(csv_path):
            print(f"  WARNING: {csv_path} not found")
            continue

        with open(csv_path, "r") as f:
            reader = csv.DictReader(f)
            all_data[fmt] = list(reader)
        print(f"  Loaded {len(all_data[fmt])} rows for {fmt}")

    return all_data


def summarize(all_data):
    """Generate per-format vulnerability summary."""
    summary = {}
    for fmt, rows in all_data.items():
        total = len(rows)
        outcomes = {}
        for r in rows:
            o = r["outcome"]
            outcomes[o] = outcomes.get(o, 0) + 1

        misclass = outcomes.get("misclass", 0)
        crash = outcomes.get("crash", 0)
        sdc = outcomes.get("sdc", 0)
        normal = outcomes.get("normal", 0)

        summary[fmt] = {
            "total": total,
            "misclass": misclass,
            "crash": crash,
            "sdc": sdc,
            "normal": normal,
            "vuln_pct": 100.0 * misclass / max(1, total),
            "crash_pct": 100.0 * crash / max(1, total),
        }

    return summary


def print_ranking(summary, mode):
    """Print 5-way vulnerability ranking table."""
    print(f"\n{'='*70}")
    print(f"5-Way Vulnerability Ranking — {mode.title()} Glitch Campaign")
    print(f"{'='*70}")
    print(f"{'Rank':<5} {'Format':<18} {'Total':>6} {'Misclass':>9} {'Crash':>6} {'SDC':>5} {'Vuln%':>7}")
    print(f"{'-'*70}")

    ranked = sorted(summary.items(), key=lambda x: x[1]["vuln_pct"])
    for rank, (fmt, s) in enumerate(ranked, 1):
        label = FORMAT_LABELS.get(fmt, fmt)
        print(f"{rank:<5} {label:<18} {s['total']:>6} {s['misclass']:>9} "
              f"{s['crash']:>6} {s['sdc']:>5} {s['vuln_pct']:>6.1f}%")

    print(f"\nKey observations:")
    if ranked:
        best = FORMAT_LABELS.get(ranked[0][0], ranked[0][0])
        worst = FORMAT_LABELS.get(ranked[-1][0], ranked[-1][0])
        print(f"  Most resilient:    {best} ({ranked[0][1]['vuln_pct']:.1f}% misclass)")
        print(f"  Most vulnerable:   {worst} ({ranked[-1][1]['vuln_pct']:.1f}% misclass)")


def analyze_scan_data(all_data):
    """Analyze scan chain captures for misclassified faults."""
    print(f"\n{'='*70}")
    print(f"Scan Chain Analysis — Misclassified Faults")
    print(f"{'='*70}")

    for fmt, rows in all_data.items():
        misclass_rows = [r for r in rows if r["outcome"] == "misclass"]
        if not misclass_rows:
            print(f"\n  {FORMAT_LABELS.get(fmt, fmt)}: 0 misclassified faults (immune)")
            continue

        print(f"\n  {FORMAT_LABELS.get(fmt, fmt)}: {len(misclass_rows)} misclassified faults")

        # Analyze which scan chain fields were corrupted
        for r in misclass_rows[:5]:  # show first 5
            scan_fields = {k: v for k, v in r.items() if k.startswith("scan_")}
            if scan_fields:
                print(f"    offset={r['offset']:>4}, width={r['width']:>3}: "
                      f"class {r['golden_class']}→{r['faulted_class']}, "
                      f"scan: op={scan_fields.get('scan_instr_op','?')}, "
                      f"fmt={scan_fields.get('scan_instr_fmt','?')}, "
                      f"acc=0x{scan_fields.get('scan_mac_acc','?')}")


def main():
    parser = argparse.ArgumentParser(description="Analyze MX glitch campaign results")
    parser.add_argument("results_dir", help="Directory containing CSV results")
    parser.add_argument("--mode", choices=["clock", "voltage"], default="clock",
                        help="Glitch mode (default: clock)")
    args = parser.parse_args()

    if not os.path.isdir(args.results_dir):
        print(f"ERROR: {args.results_dir} is not a directory")
        sys.exit(1)

    print(f"Loading results from {args.results_dir} ({args.mode} mode)...")
    all_data = load_results(args.results_dir, args.mode)

    if not all_data:
        print("ERROR: No result files found")
        sys.exit(1)

    summary = summarize(all_data)
    print_ranking(summary, args.mode)
    analyze_scan_data(all_data)

    # Save summary JSON
    summary_path = os.path.join(args.results_dir, f"analysis_{args.mode}.json")
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"\nAnalysis saved to {summary_path}")


if __name__ == "__main__":
    main()
