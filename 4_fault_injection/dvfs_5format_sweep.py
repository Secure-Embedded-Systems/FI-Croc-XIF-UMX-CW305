# SPDX-License-Identifier: Apache-2.0
# Fault Analysis of Microscaling Formats on a RISC-V SoC
# Authors: Dillibabu Shanmugam, Patrick Schaumont
# Affiliation: Worcester Polytechnic Institute (WPI), USA

#!/usr/bin/env python3
"""DVFS 5-Format Sweep — Voltage fault injection across all MX formats.

Runs DVFS voltage sweep on all 5 MX format QNN workloads at 20 MHz.
Each format has its own bitstream. Reprogram-per-trial.

Usage:
    python3 dvfs_5format_sweep.py
"""

import chipwhisperer as cw
import struct, time, json, os, sys

PROJ = os.environ.get('MX_PROJ', os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
SCAN_DIR = f'{PROJ}/2_synthesis/bitstreams/cw305_scan'
OUTDIR = f'{PROJ}/5_datasets/results'

FORMATS = ['mxint8', 'mxfp8_e4m3', 'mxfp8_e5m2', 'mxlog8', 'mxlog8_logdom']

BITSTREAMS = {fmt: f'{SCAN_DIR}/{fmt}.bit' for fmt in FORMATS}

VOLTAGES = [1.00, 0.95, 0.90, 0.85, 0.82, 0.80, 0.78, 0.76, 0.75,
            0.74, 0.73, 0.72, 0.71, 0.70, 0.69, 0.68, 0.67, 0.66,
            0.65, 0.64, 0.63, 0.62, 0.61, 0.60]

TRIALS = 3
FREQ = 20e6


def read32(t, a):
    return struct.unpack('<I', bytes(t.fpga_read(a, 4)))[0]


def decode_scan(t):
    # cw305_scan build: the 129-bit mux-scan chain is shifted out MSB-first
    # into five contiguous USB words (0x08..0x0C) and reassembled here.
    # (The BitNet DVFS and clock-glitch drivers instead use the cw305_live
    #  direct-wire monitor with structured registers -- see README pairing.)
    fw = [read32(t, a) for a in [0x08, 0x09, 0x0A, 0x0B, 0x0C]]
    f = (fw[4] & 1) << 128 | fw[3] << 96 | fw[2] << 64 | fw[1] << 32 | fw[0]
    return {
        'rs1': (f >> 97) & 0xFFFFFFFF, 'rs2': (f >> 65) & 0xFFFFFFFF,
        'mac': (f >> 33) & 0xFFFFFFFF, 'se_a': (f >> 25) & 0xFF,
        'se_b': (f >> 17) & 0xFF, 'op': (f >> 13) & 0xF,
        'fmt': (f >> 10) & 0x7, 'inf': (f >> 9) & 1,
    }


def run_trial(target, vcc, bitstream):
    """Reprogram, set voltage, run firmware, read result + scan."""
    try:
        target.dis()
    except:
        pass
    time.sleep(0.2)

    target = cw.target(None, cw.targets.CW305, bsfile=bitstream, force=True)
    target.vccint_set(1.0)
    time.sleep(0.2)
    target.pll.pll_enable_set(True)
    target.pll.pll_outenable_set(True, 1)
    target.pll.pll_outfreq_set(FREQ, 1)
    target.pll.pll_outsource_set('PLL1', 1)
    time.sleep(0.2)

    target.vccint_set(vcc)
    time.sleep(0.3)

    target.fpga_write(0x05, [0x00])
    target.fpga_write(0x03, [0x01])
    time.sleep(0.02)
    target.fpga_write(0x03, [0x00])
    time.sleep(2.0)

    s = read32(target, 0x00)
    eoc = s & 1
    ret = s >> 1

    # Scan readout
    target.fpga_write(0x06, [0x01])
    time.sleep(0.003)
    for j in range(130):
        target.fpga_write(0x06, [0x02])
        time.sleep(0.0005)
    scan = decode_scan(target)

    magic = read32(target, 0x02)

    if s == 0xFFFFFFFF:
        cls = 'dead'
    elif eoc == 0:
        cls = 'crash'
    else:
        cls = 'normal'  # will be updated after golden comparison

    target.vccint_set(1.0)
    time.sleep(0.1)

    return target, {
        'eoc': eoc, 'ret': ret, 'magic_ok': magic == 0x434F5243,
        'class': cls, 'se_a': scan['se_a'], 'se_b': scan['se_b'],
        'mac': f"0x{scan['mac']:08X}", 'rs1': f"0x{scan['rs1']:08X}",
    }


def main():
    # Verify all bitstreams exist
    for fmt in FORMATS:
        if not os.path.exists(BITSTREAMS[fmt]):
            print(f"ERROR: Missing bitstream: {BITSTREAMS[fmt]}")
            sys.exit(1)

    all_results = {}

    for fmt in FORMATS:
        bitstream = BITSTREAMS[fmt]
        print(f'\n{"="*60}')
        print(f'  Format: {fmt}')
        print(f'{"="*60}')

        # Golden capture at 1.0V
        target = cw.target(None, cw.targets.CW305, bsfile=bitstream, force=True)
        target.vccint_set(1.0)
        time.sleep(0.3)
        target.pll.pll_enable_set(True)
        target.pll.pll_outenable_set(True, 1)
        target.pll.pll_outfreq_set(FREQ, 1)
        target.pll.pll_outsource_set('PLL1', 1)
        time.sleep(0.2)

        target.fpga_write(0x03, [0x01])
        time.sleep(0.05)
        target.fpga_write(0x03, [0x00])
        time.sleep(3.0)
        gs = read32(target, 0x00)
        golden = gs >> 1
        print(f'  Golden: ret={golden}')
        target.dis()
        time.sleep(0.2)

        results = []

        for vcc in VOLTAGES:
            trials = []
            for trial in range(TRIALS):
                target, row = run_trial(target, vcc, bitstream)
                if row['class'] != 'dead' and row['class'] != 'crash':
                    if row['ret'] == golden:
                        row['class'] = 'normal'
                    else:
                        row['class'] = 'fault'
                row['vccint'] = vcc
                row['trial'] = trial
                row['golden'] = golden
                trials.append(row)
                results.append(row)

            classes = [t['class'] for t in trials]
            rets = [t['ret'] for t in trials]
            se_as = [t['se_a'] for t in trials]
            print(f'  V={vcc:.2f}: {classes} ret={rets} se_a={se_as}')

            if all(c == 'dead' for c in classes):
                print(f'  Config destroyed at {vcc:.2f}V, stopping')
                break

        all_results[fmt] = {
            'golden': golden,
            'trials': results,
        }

        try:
            target.dis()
        except:
            pass
        time.sleep(0.3)

    # Save
    os.makedirs(OUTDIR, exist_ok=True)
    outpath = os.path.join(OUTDIR, 'dvfs_5format.json')
    with open(outpath, 'w') as fp:
        json.dump(all_results, fp, indent=2)
    print(f'\nSaved to {outpath}')

    # Summary
    print(f'\n{"="*60}')
    print(f'  5-Format DVFS Summary')
    print(f'{"="*60}')
    print(f'{"Format":<18} {"Golden":>8} {"Fault onset":>12} {"Fault ret":>10} {"se_a":>6}')
    print('-' * 56)
    for fmt in FORMATS:
        data = all_results.get(fmt, {})
        golden = data.get('golden', '?')
        trials = data.get('trials', [])
        fault_trials = [t for t in trials if t['class'] == 'fault']
        if fault_trials:
            onset = max(t['vccint'] for t in fault_trials)
            fret = fault_trials[0]['ret']
            fse = fault_trials[0]['se_a']
            print(f'{fmt:<18} {golden:>8} {onset:>10.2f}V {fret:>10} {fse:>6}')
        else:
            print(f'{fmt:<18} {golden:>8} {"none":>12} {"---":>10} {"---":>6}')


if __name__ == '__main__':
    main()
