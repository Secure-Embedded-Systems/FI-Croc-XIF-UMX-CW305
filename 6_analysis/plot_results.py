# SPDX-License-Identifier: Apache-2.0
# Fault Analysis of Microscaling Formats on a RISC-V SoC
# Authors: Dillibabu Shanmugam, Patrick Schaumont
# Affiliation: Worcester Polytechnic Institute (WPI), USA

#!/usr/bin/env python3
"""Generate paper-quality figures for MX unified coprocessor fault analysis.

Reads CSV results from run_sram_faults.py / run_mx_faults.py and produces:
  1. 5-way vulnerability ranking bar chart
  2. Per-matrix vulnerability heatmap
  3. Bit-position sensitivity line plot
  4. Coprocessor vs software cycle comparison
  5. Scan chain propagation timelines (if propagation data available)
  6. Combined multi-panel figure

Usage:
  python3 plot_results.py results/
  python3 plot_results.py results/ --output figures/

Authors: Dillibabu Shanmugam, Patrick Schaumont (WPI)
"""

import argparse
import csv
import os
import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
import matplotlib.patches as mpatches
import numpy as np

# ─────────────────────────────────────────────────────────────────────
# Format configuration
# ─────────────────────────────────────────────────────────────────────

FORMATS = ["mxint8", "mxfp8_e4m3", "mxfp8_e5m2", "mxlog8", "mxlog8_logdom"]

FORMAT_LABELS = {
    "mxint8":        "MXINT8",
    "mxfp8_e4m3":   "MXFP8\nE4M3",
    "mxfp8_e5m2":   "MXFP8\nE5M2",
    "mxlog8":        "MXLOG8",
    "mxlog8_logdom": "MXLOG8\nLogdom",
}

FORMAT_LABELS_INLINE = {
    "mxint8":        "MXINT8",
    "mxfp8_e4m3":   "MXFP8-E4M3",
    "mxfp8_e5m2":   "MXFP8-E5M2",
    "mxlog8":        "MXLOG8",
    "mxlog8_logdom": "MXLOG8-Logdom",
}

FORMAT_COLORS = {
    "mxint8":        "#2196F3",   # blue
    "mxfp8_e4m3":   "#F44336",   # red
    "mxfp8_e5m2":   "#9C27B0",   # purple
    "mxlog8":        "#FF9800",   # orange
    "mxlog8_logdom": "#4CAF50",   # green
}

MATRICES = ["W_Q", "W_K", "W_V", "W_L1", "W_L2"]

# Software-only cycle counts from CAPRI1 benchmarks
SW_CYCLES = {
    "mxint8":        9010,
    "mxfp8_e4m3":   10233,
    "mxfp8_e5m2":   10111,
    "mxlog8":        9382,
    "mxlog8_logdom": 8822,
}

# Estimated HW coprocessor cycle counts (5-6x speedup)
HW_CYCLES_EST = {
    "mxint8":        1800,
    "mxfp8_e4m3":   2000,
    "mxfp8_e5m2":   2000,
    "mxlog8":        1700,
    "mxlog8_logdom": 1500,
}


# ─────────────────────────────────────────────────────────────────────
# Data loading
# ─────────────────────────────────────────────────────────────────────

def load_sram_results(results_dir):
    """Load all sram_faults_*.csv files."""
    all_data = {}
    for fmt in FORMATS:
        csv_path = os.path.join(results_dir, f"sram_faults_{fmt}.csv")
        if not os.path.exists(csv_path):
            continue
        with open(csv_path, "r") as f:
            all_data[fmt] = list(csv.DictReader(f))
        print(f"  Loaded {len(all_data[fmt])} rows for {fmt}")
    return all_data


def load_glitch_results(results_dir):
    """Load all glitch_*_clock.csv files."""
    all_data = {}
    for fmt in FORMATS:
        for mode in ["clock", "voltage"]:
            csv_path = os.path.join(results_dir, f"glitch_{fmt}_{mode}.csv")
            if not os.path.exists(csv_path):
                continue
            key = f"{fmt}_{mode}"
            with open(csv_path, "r") as f:
                all_data[key] = list(csv.DictReader(f))
            print(f"  Loaded {len(all_data[key])} rows for {key}")
    return all_data


def load_propagation_timelines(results_dir):
    """Load timeline_*.csv files if available."""
    timelines = {}
    for fmt in FORMATS:
        csv_path = os.path.join(results_dir, f"timeline_{fmt}.csv")
        if not os.path.exists(csv_path):
            continue
        with open(csv_path, "r") as f:
            timelines[fmt] = list(csv.DictReader(f))
        print(f"  Loaded timeline for {fmt}: {len(timelines[fmt])} cycles")
    return timelines


# ─────────────────────────────────────────────────────────────────────
# Figure 1: 5-Way Vulnerability Ranking Bar Chart
# ─────────────────────────────────────────────────────────────────────

def plot_vulnerability_ranking(all_data, output_dir):
    """Bar chart of misclassification rate per format, sorted by vulnerability."""
    fig, ax = plt.subplots(figsize=(10, 6))

    summaries = {}
    for fmt, rows in all_data.items():
        total = len(rows)
        misclass = sum(1 for r in rows if r["outcome"] == "misclass")
        crash = sum(1 for r in rows if r["outcome"] == "crash")
        vuln_pct = 100.0 * misclass / max(1, total)
        crash_pct = 100.0 * crash / max(1, total)
        summaries[fmt] = {"total": total, "misclass": misclass,
                          "crash": crash, "vuln_pct": vuln_pct,
                          "crash_pct": crash_pct}

    # Sort by vulnerability (ascending = most resilient first)
    ranked = sorted(summaries.items(), key=lambda x: x[1]["vuln_pct"])

    labels = [FORMAT_LABELS.get(fmt, fmt) for fmt, _ in ranked]
    vuln_pcts = [s["vuln_pct"] for _, s in ranked]
    crash_pcts = [s["crash_pct"] for _, s in ranked]
    colors = [FORMAT_COLORS.get(fmt, "#999") for fmt, _ in ranked]

    x = np.arange(len(labels))
    width = 0.35

    bars_v = ax.bar(x - width/2, vuln_pcts, width, label="Misclassified",
                    color=colors, edgecolor="black", linewidth=0.5)
    bars_c = ax.bar(x + width/2, crash_pcts, width, label="Crash",
                    color=[c + "80" for c in colors],  # alpha via hex
                    edgecolor="black", linewidth=0.5, hatch="//")

    # Add value labels
    for bar, pct in zip(bars_v, vuln_pcts):
        if pct > 0:
            ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.2,
                    f"{pct:.1f}%", ha="center", va="bottom", fontsize=9,
                    fontweight="bold")

    ax.set_xlabel("MX Format", fontsize=12)
    ax.set_ylabel("Fault Rate (%)", fontsize=12)
    ax.set_title("5-Way SRAM Fault Vulnerability Ranking\n"
                 "(Single-Bit Weight Faults, Unified MX Coprocessor)",
                 fontsize=13, fontweight="bold")
    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontsize=10)
    ax.legend(loc="upper left", fontsize=10)
    ax.grid(axis="y", alpha=0.3)
    ax.set_ylim(0, max(vuln_pcts + crash_pcts) * 1.3 + 1)

    fig.tight_layout()
    path = os.path.join(output_dir, "vulnerability_ranking.png")
    fig.savefig(path, dpi=200, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved {path}")
    return summaries


# ─────────────────────────────────────────────────────────────────────
# Figure 2: Per-Matrix Vulnerability Heatmap
# ─────────────────────────────────────────────────────────────────────

def plot_per_matrix_heatmap(all_data, output_dir):
    """Heatmap: format (rows) × matrix (cols) → misclass count."""
    fig, ax = plt.subplots(figsize=(10, 6))

    fmt_order = [f for f in FORMATS if f in all_data]
    mat_order = MATRICES

    # Build matrix
    data = np.zeros((len(fmt_order), len(mat_order)))
    for i, fmt in enumerate(fmt_order):
        rows = all_data[fmt]
        for j, mat in enumerate(mat_order):
            mat_rows = [r for r in rows if r["matrix"] == mat]
            misclass = sum(1 for r in mat_rows if r["outcome"] == "misclass")
            total = len(mat_rows)
            data[i, j] = 100.0 * misclass / max(1, total)

    im = ax.imshow(data, cmap="YlOrRd", aspect="auto", vmin=0)
    cbar = fig.colorbar(im, ax=ax)
    cbar.set_label("Misclassification Rate (%)", fontsize=11)

    # Labels
    ax.set_xticks(np.arange(len(mat_order)))
    ax.set_xticklabels(mat_order, fontsize=11)
    ax.set_yticks(np.arange(len(fmt_order)))
    ax.set_yticklabels([FORMAT_LABELS_INLINE.get(f, f) for f in fmt_order],
                       fontsize=11)

    # Annotate cells
    for i in range(len(fmt_order)):
        for j in range(len(mat_order)):
            val = data[i, j]
            color = "white" if val > data.max() * 0.6 else "black"
            ax.text(j, i, f"{val:.1f}%", ha="center", va="center",
                    fontsize=10, color=color, fontweight="bold")

    ax.set_title("Per-Matrix Vulnerability Heatmap\n"
                 "(% of faults causing misclassification per weight matrix)",
                 fontsize=13, fontweight="bold")

    fig.tight_layout()
    path = os.path.join(output_dir, "per_matrix_heatmap.png")
    fig.savefig(path, dpi=200, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved {path}")


# ─────────────────────────────────────────────────────────────────────
# Figure 3: Bit-Position Sensitivity
# ─────────────────────────────────────────────────────────────────────

def plot_bit_sensitivity(all_data, output_dir):
    """Line plot: misclass rate by bit position (0-7) within each byte."""
    fig, ax = plt.subplots(figsize=(10, 6))

    for fmt in FORMATS:
        if fmt not in all_data:
            continue
        rows = all_data[fmt]
        bit_counts = defaultdict(int)
        bit_totals = defaultdict(int)
        for r in rows:
            bit = int(r["bit_in_byte"])
            bit_totals[bit] += 1
            if r["outcome"] == "misclass":
                bit_counts[bit] += 1

        bits = sorted(bit_totals.keys())
        rates = [100.0 * bit_counts[b] / max(1, bit_totals[b]) for b in bits]

        ax.plot(bits, rates, "o-", label=FORMAT_LABELS_INLINE.get(fmt, fmt),
                color=FORMAT_COLORS.get(fmt, "#999"), linewidth=2, markersize=6)

    ax.set_xlabel("Bit Position Within Byte (0=LSB, 7=MSB)", fontsize=12)
    ax.set_ylabel("Misclassification Rate (%)", fontsize=12)
    ax.set_title("Bit-Position Sensitivity\n"
                 "(vulnerability by bit position within weight byte)",
                 fontsize=13, fontweight="bold")
    ax.set_xticks(range(8))
    ax.legend(loc="upper left", fontsize=10)
    ax.grid(True, alpha=0.3)

    fig.tight_layout()
    path = os.path.join(output_dir, "bit_sensitivity.png")
    fig.savefig(path, dpi=200, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved {path}")


# ─────────────────────────────────────────────────────────────────────
# Figure 4: Coprocessor vs Software Cycle Comparison
# ─────────────────────────────────────────────────────────────────────

def plot_cycle_comparison(all_data, output_dir):
    """Grouped bar chart: SW cycles vs HW coprocessor cycles (estimated)."""
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 6))

    fmt_order = [f for f in FORMATS if f in all_data or f in SW_CYCLES]
    labels = [FORMAT_LABELS.get(f, f) for f in fmt_order]
    x = np.arange(len(fmt_order))
    width = 0.35

    # Panel 1: Cycle counts
    sw = [SW_CYCLES.get(f, 0) for f in fmt_order]
    hw = [HW_CYCLES_EST.get(f, 0) for f in fmt_order]
    colors = [FORMAT_COLORS.get(f, "#999") for f in fmt_order]

    ax1.bar(x - width/2, sw, width, label="Software-Only",
            color=[c + "60" for c in colors], edgecolor="black", linewidth=0.5)
    ax1.bar(x + width/2, hw, width, label="HW Coprocessor (est.)",
            color=colors, edgecolor="black", linewidth=0.5)

    # Speedup annotation
    for i, (s, h) in enumerate(zip(sw, hw)):
        if h > 0:
            speedup = s / h
            ax1.text(i + width/2, h + 200, f"{speedup:.1f}x",
                     ha="center", va="bottom", fontsize=9, fontweight="bold")

    ax1.set_xlabel("MX Format", fontsize=12)
    ax1.set_ylabel("Cycle Count", fontsize=12)
    ax1.set_title("Attention Workload: SW vs HW Cycles", fontsize=13,
                  fontweight="bold")
    ax1.set_xticks(x)
    ax1.set_xticklabels(labels, fontsize=9)
    ax1.legend(fontsize=10)
    ax1.grid(axis="y", alpha=0.3)

    # Panel 2: Vulnerability vs speedup scatter
    vuln_pcts = []
    speedups = []
    scatter_colors = []
    scatter_labels = []
    for fmt in fmt_order:
        if fmt in all_data:
            rows = all_data[fmt]
            total = len(rows)
            misclass = sum(1 for r in rows if r["outcome"] == "misclass")
            vuln_pcts.append(100.0 * misclass / max(1, total))
        else:
            vuln_pcts.append(0)
        s = SW_CYCLES.get(fmt, 1)
        h = HW_CYCLES_EST.get(fmt, 1)
        speedups.append(s / h if h > 0 else 0)
        scatter_colors.append(FORMAT_COLORS.get(fmt, "#999"))
        scatter_labels.append(FORMAT_LABELS_INLINE.get(fmt, fmt))

    for i, (sp, vp, c, lab) in enumerate(zip(speedups, vuln_pcts,
                                              scatter_colors, scatter_labels)):
        ax2.scatter(sp, vp, s=200, c=c, edgecolors="black", linewidth=1, zorder=5)
        ax2.annotate(lab, (sp, vp), textcoords="offset points",
                     xytext=(8, 5), fontsize=9)

    ax2.set_xlabel("Speedup (SW/HW)", fontsize=12)
    ax2.set_ylabel("Vulnerability (%)", fontsize=12)
    ax2.set_title("Speedup vs Fault Resilience", fontsize=13,
                  fontweight="bold")
    ax2.grid(True, alpha=0.3)

    fig.tight_layout()
    path = os.path.join(output_dir, "cycle_comparison.png")
    fig.savefig(path, dpi=200, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved {path}")


# ─────────────────────────────────────────────────────────────────────
# Figure 5: Propagation Timelines (if data available)
# ─────────────────────────────────────────────────────────────────────

def plot_propagation_timelines(timelines, output_dir):
    """3-panel: mean HD, max HD, num diverged over time."""
    if not timelines:
        print("  Skipping propagation timelines (no data)")
        return

    fig, axes = plt.subplots(3, 1, figsize=(14, 14), sharex=False)

    panels = [
        ("mean_hamming", "Mean Hamming Distance", "Mean HD"),
        ("max_hamming", "Max Hamming Distance", "Max HD"),
        ("num_diverged", "Faults Still Diverged", "Count"),
    ]

    for ax, (col, title, ylabel) in zip(axes, panels):
        for fmt in FORMATS:
            if fmt not in timelines:
                continue
            rows = timelines[fmt]
            cycles = [int(r["cycle"]) for r in rows]
            values = [float(r[col]) for r in rows]
            ax.plot(cycles, values,
                    label=FORMAT_LABELS_INLINE.get(fmt, fmt),
                    color=FORMAT_COLORS.get(fmt, "#999"),
                    linewidth=1.5)

        ax.set_title(title, fontsize=12, fontweight="bold")
        ax.set_ylabel(ylabel, fontsize=11)
        ax.legend(loc="upper left", fontsize=9)
        ax.grid(True, alpha=0.3)

    axes[-1].set_xlabel("Cycle", fontsize=11)

    fig.suptitle("Scan Chain Fault Propagation Timelines\n"
                 "(Hamming distance: faulted vs golden scan chain)",
                 fontsize=14, fontweight="bold", y=0.98)
    fig.tight_layout(rect=[0, 0, 1, 0.96])
    path = os.path.join(output_dir, "propagation_timelines.png")
    fig.savefig(path, dpi=200, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved {path}")


# ─────────────────────────────────────────────────────────────────────
# Figure 6: Combined Multi-Panel Figure
# ─────────────────────────────────────────────────────────────────────

def plot_combined(all_data, output_dir):
    """Combined 2×2 figure for paper: ranking, heatmap, bits, cycles."""
    fig = plt.figure(figsize=(16, 14))
    gs = gridspec.GridSpec(2, 2, figure=fig, hspace=0.35, wspace=0.30)

    # (a) Vulnerability ranking
    ax_a = fig.add_subplot(gs[0, 0])
    summaries = {}
    for fmt, rows in all_data.items():
        total = len(rows)
        misclass = sum(1 for r in rows if r["outcome"] == "misclass")
        summaries[fmt] = 100.0 * misclass / max(1, total)

    ranked = sorted(summaries.items(), key=lambda x: x[1])
    labels_a = [FORMAT_LABELS.get(f, f) for f, _ in ranked]
    pcts_a = [v for _, v in ranked]
    colors_a = [FORMAT_COLORS.get(f, "#999") for f, _ in ranked]

    bars = ax_a.barh(range(len(labels_a)), pcts_a, color=colors_a,
                     edgecolor="black", linewidth=0.5)
    ax_a.set_yticks(range(len(labels_a)))
    ax_a.set_yticklabels(labels_a, fontsize=10)
    ax_a.set_xlabel("Misclassification Rate (%)", fontsize=10)
    ax_a.set_title("(a) Vulnerability Ranking", fontsize=11, fontweight="bold")
    ax_a.grid(axis="x", alpha=0.3)
    for bar, pct in zip(bars, pcts_a):
        if pct > 0:
            ax_a.text(bar.get_width() + 0.1, bar.get_y() + bar.get_height()/2,
                      f"{pct:.1f}%", va="center", fontsize=9, fontweight="bold")

    # (b) Per-matrix heatmap
    ax_b = fig.add_subplot(gs[0, 1])
    fmt_order = [f for f in FORMATS if f in all_data]
    data_hm = np.zeros((len(fmt_order), len(MATRICES)))
    for i, fmt in enumerate(fmt_order):
        rows = all_data[fmt]
        for j, mat in enumerate(MATRICES):
            mat_rows = [r for r in rows if r["matrix"] == mat]
            mc = sum(1 for r in mat_rows if r["outcome"] == "misclass")
            data_hm[i, j] = 100.0 * mc / max(1, len(mat_rows))

    im = ax_b.imshow(data_hm, cmap="YlOrRd", aspect="auto", vmin=0)
    fig.colorbar(im, ax=ax_b, shrink=0.8, label="Vuln %")
    ax_b.set_xticks(np.arange(len(MATRICES)))
    ax_b.set_xticklabels(MATRICES, fontsize=10)
    ax_b.set_yticks(np.arange(len(fmt_order)))
    ax_b.set_yticklabels([FORMAT_LABELS_INLINE.get(f, f) for f in fmt_order],
                         fontsize=9)
    for i in range(len(fmt_order)):
        for j in range(len(MATRICES)):
            val = data_hm[i, j]
            color = "white" if val > data_hm.max() * 0.6 else "black"
            ax_b.text(j, i, f"{val:.1f}", ha="center", va="center",
                      fontsize=9, color=color, fontweight="bold")
    ax_b.set_title("(b) Per-Matrix Vulnerability", fontsize=11,
                   fontweight="bold")

    # (c) Bit sensitivity
    ax_c = fig.add_subplot(gs[1, 0])
    for fmt in FORMATS:
        if fmt not in all_data:
            continue
        rows = all_data[fmt]
        bit_counts = defaultdict(int)
        bit_totals = defaultdict(int)
        for r in rows:
            bit = int(r["bit_in_byte"])
            bit_totals[bit] += 1
            if r["outcome"] == "misclass":
                bit_counts[bit] += 1
        bits = sorted(bit_totals.keys())
        rates = [100.0 * bit_counts[b] / max(1, bit_totals[b]) for b in bits]
        ax_c.plot(bits, rates, "o-", label=FORMAT_LABELS_INLINE.get(fmt, fmt),
                  color=FORMAT_COLORS.get(fmt, "#999"), linewidth=1.5,
                  markersize=5)

    ax_c.set_xlabel("Bit Position (0=LSB)", fontsize=10)
    ax_c.set_ylabel("Misclass Rate (%)", fontsize=10)
    ax_c.set_title("(c) Bit-Position Sensitivity", fontsize=11,
                   fontweight="bold")
    ax_c.set_xticks(range(8))
    ax_c.legend(fontsize=8, loc="upper left")
    ax_c.grid(True, alpha=0.3)

    # (d) SW vs HW cycles
    ax_d = fig.add_subplot(gs[1, 1])
    fmt_order_d = [f for f in FORMATS]
    labels_d = [FORMAT_LABELS.get(f, f) for f in fmt_order_d]
    x_d = np.arange(len(fmt_order_d))
    w = 0.35
    sw = [SW_CYCLES.get(f, 0) for f in fmt_order_d]
    hw = [HW_CYCLES_EST.get(f, 0) for f in fmt_order_d]
    colors_d = [FORMAT_COLORS.get(f, "#999") for f in fmt_order_d]

    ax_d.bar(x_d - w/2, sw, w, label="SW-only", color=[c + "60" for c in colors_d],
             edgecolor="black", linewidth=0.5)
    ax_d.bar(x_d + w/2, hw, w, label="HW coproc (est.)", color=colors_d,
             edgecolor="black", linewidth=0.5)
    for i, (s, h) in enumerate(zip(sw, hw)):
        if h > 0:
            ax_d.text(i + w/2, h + 150, f"{s/h:.1f}x", ha="center",
                      va="bottom", fontsize=8, fontweight="bold")
    ax_d.set_xticks(x_d)
    ax_d.set_xticklabels(labels_d, fontsize=8)
    ax_d.set_ylabel("Cycles", fontsize=10)
    ax_d.set_title("(d) SW vs HW Cycle Counts", fontsize=11,
                   fontweight="bold")
    ax_d.legend(fontsize=9)
    ax_d.grid(axis="y", alpha=0.3)

    fig.suptitle("MX Unified Coprocessor — Fault Vulnerability Analysis",
                 fontsize=15, fontweight="bold", y=0.99)
    path = os.path.join(output_dir, "combined_analysis.png")
    fig.savefig(path, dpi=200, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved {path}")


# ─────────────────────────────────────────────────────────────────────
# Figure 7: Per-Matrix Box Plots
# ─────────────────────────────────────────────────────────────────────

def plot_per_matrix_boxplots(all_data, output_dir):
    """Box plots of faulted cycle count per matrix, grouped by format."""
    fig, axes = plt.subplots(1, 2, figsize=(16, 7))

    # Panel 1: Faulted cycle distributions per matrix
    ax1 = axes[0]
    positions = []
    box_data = []
    box_colors = []
    tick_positions = []
    tick_labels = []

    pos = 0
    for fmt in FORMATS:
        if fmt not in all_data:
            continue
        rows = all_data[fmt]
        for mat in MATRICES:
            mat_rows = [r for r in rows if r["matrix"] == mat
                        and r["outcome"] == "misclass"]
            if mat_rows:
                cycles = [int(r["faulted_cycles"]) for r in mat_rows
                          if int(r.get("faulted_cycles", 0)) > 0]
                if cycles:
                    box_data.append(cycles)
                    positions.append(pos)
                    box_colors.append(FORMAT_COLORS.get(fmt, "#999"))
            pos += 1
        tick_positions.append(pos - len(MATRICES) / 2)
        tick_labels.append(FORMAT_LABELS_INLINE.get(fmt, fmt))
        pos += 1  # gap

    if box_data:
        bp = ax1.boxplot(box_data, positions=positions[:len(box_data)],
                         widths=0.7, patch_artist=True)
        for patch, color in zip(bp["boxes"], box_colors[:len(box_data)]):
            patch.set_facecolor(color)
            patch.set_alpha(0.6)
        ax1.set_title("(a) Faulted Cycle Count\n(misclassified faults only)",
                      fontsize=11, fontweight="bold")
        ax1.set_ylabel("Cycles", fontsize=10)
        ax1.grid(axis="y", alpha=0.3)

    # Panel 2: Misclass count per matrix
    ax2 = axes[1]
    x = np.arange(len(MATRICES))
    bar_width = 0.15
    for i, fmt in enumerate(FORMATS):
        if fmt not in all_data:
            continue
        rows = all_data[fmt]
        counts = []
        for mat in MATRICES:
            mc = sum(1 for r in rows if r["matrix"] == mat
                     and r["outcome"] == "misclass")
            counts.append(mc)
        offset = (i - len(FORMATS)/2 + 0.5) * bar_width
        ax2.bar(x + offset, counts, bar_width,
                label=FORMAT_LABELS_INLINE.get(fmt, fmt),
                color=FORMAT_COLORS.get(fmt, "#999"),
                edgecolor="black", linewidth=0.5)

    ax2.set_xticks(x)
    ax2.set_xticklabels(MATRICES, fontsize=10)
    ax2.set_ylabel("Misclass Count", fontsize=10)
    ax2.set_title("(b) Misclassification Count by Weight Matrix",
                  fontsize=11, fontweight="bold")
    ax2.legend(fontsize=8, loc="upper left")
    ax2.grid(axis="y", alpha=0.3)

    fig.tight_layout()
    path = os.path.join(output_dir, "per_matrix_boxplots.png")
    fig.savefig(path, dpi=200, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved {path}")


# ─────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Generate paper figures for MX fault analysis")
    parser.add_argument("results_dir", help="Directory containing CSV results")
    parser.add_argument("--output", default=None,
                        help="Output directory for figures (default: results_dir/figures)")
    args = parser.parse_args()

    if not os.path.isdir(args.results_dir):
        print(f"ERROR: {args.results_dir} is not a directory")
        sys.exit(1)

    output_dir = args.output or os.path.join(args.results_dir, "figures")
    os.makedirs(output_dir, exist_ok=True)

    # Load SRAM fault results
    print("Loading SRAM fault results...")
    sram_data = load_sram_results(args.results_dir)

    if not sram_data:
        print("No SRAM fault results found. Checking for glitch results...")
        sram_data = load_glitch_results(args.results_dir)

    if not sram_data:
        print("ERROR: No result files found")
        sys.exit(1)

    # Load propagation data (optional)
    print("\nLoading propagation timelines...")
    timelines = load_propagation_timelines(args.results_dir)

    # Generate figures
    print("\nGenerating figures...")
    plot_vulnerability_ranking(sram_data, output_dir)
    plot_per_matrix_heatmap(sram_data, output_dir)
    plot_bit_sensitivity(sram_data, output_dir)
    plot_cycle_comparison(sram_data, output_dir)
    plot_per_matrix_boxplots(sram_data, output_dir)
    plot_propagation_timelines(timelines, output_dir)
    plot_combined(sram_data, output_dir)

    print(f"\nAll figures saved to {output_dir}")


if __name__ == "__main__":
    main()
