# SPDX-License-Identifier: Apache-2.0
# Security Analysis of Microscaling Formats Under Fault Injection on a RISC-V Edge Platform
# Authors: Dillibabu Shanmugam, Patrick Schaumont
# Affiliation: Worcester Polytechnic Institute (WPI), USA

#!/usr/bin/env python3
"""Sweep scan_delay to find clock cycles where MX instructions are active.

Captures 129-bit scan chain at each cycle after trigger (no glitch).
Identifies cycles where se_a/se_b are non-zero (= MX coprocessor in use).

Usage:
    python3 sweep_scan_delay.py
"""

import chipwhisperer as cw
import struct, time, json

import os
BITSTREAM = os.environ.get('MX_SCAN_BIT', os.path.join(os.path.dirname(__file__), '..', '2_synthesis', 'bitstreams', 'cw305_scan', 'mxint8.bit'))

scope = cw.scope()
target = cw.target(scope, cw.targets.CW305, bsfile=BITSTREAM, force=True)
target.pll.pll_outfreq_set(20e6, 1)
time.sleep(0.2)

scope.clock.clkgen_freq = 20e6
scope.io.hs2 = 'glitch'
scope.glitch.clk_src = 'clkgen'
scope.glitch.output = 'clock_xor'
scope.glitch.trigger_src = 'ext_single'
scope.trigger.triggers = 'tio4'
scope.adc.timeout = 2.0
scope.adc.samples = 100

def read32(addr):
    return struct.unpack('<I', bytes(target.fpga_read(addr, 4)))[0]

def write16(addr, val):
    target.fpga_write(addr, [val & 0xFF, (val >> 8) & 0xFF])

def decode_scan():
    fw = [read32(a) for a in [0x08, 0x09, 0x0A, 0x0B, 0x0C]]
    full = (fw[4] & 1) << 128 | fw[3] << 96 | fw[2] << 64 | fw[1] << 32 | fw[0]
    return {
        'rs1': (full >> 97) & 0xFFFFFFFF,
        'rs2': (full >> 65) & 0xFFFFFFFF,
        'mac': (full >> 33) & 0xFFFFFFFF,
        'se_a': (full >> 25) & 0xFF,
        'se_b': (full >> 17) & 0xFF,
        'op': (full >> 13) & 0xF,
        'fmt': (full >> 10) & 0x7,
        'inf': (full >> 9) & 1,
        'rd': (full >> 4) & 0x1F,
        'id': full & 0xF,
        'raw': full,
    }

# Sweep scan_delay from 1 to 500 (no glitch, just capture state)
print("Sweeping scan_delay to find MX-active cycles...")
print(f"{'delay':>6} {'se_a':>5} {'se_b':>5} {'rs1':>10} {'rs2':>10} {'mac':>10} {'op':>3} {'inf':>3}")
print("-" * 60)

active_cycles = []

for delay in range(1, 500):
    write16(0x0D, delay)

    target.fpga_write(0x05, [0x00])
    target.fpga_write(0x03, [0x01])
    time.sleep(0.01)
    target.fpga_write(0x03, [0x00])
    time.sleep(0.001)

    # No glitch — ext_offset far away
    scope.glitch.width = -8
    scope.glitch.offset = -30
    scope.glitch.ext_offset = 50000
    scope.glitch.repeat = 1

    scope.arm()
    target.fpga_write(0x05, [0x01])
    scope.capture()
    target.fpga_write(0x05, [0x00])

    time.sleep(0.5)

    # Check auto_done
    status7 = target.fpga_read(0x07, 2)
    auto_done = (status7[0] >> 1) & 1
    count = status7[1]

    d = decode_scan()

    if d['se_a'] != 0 or d['se_b'] != 0 or d['inf'] != 0 or d['mac'] != 0:
        print(f"{delay:6d} {d['se_a']:5d} {d['se_b']:5d} 0x{d['rs1']:08X} 0x{d['rs2']:08X} 0x{d['mac']:08X} {d['op']:3d} {d['inf']:3d}")
        active_cycles.append(delay)

if active_cycles:
    print(f"\nMX-active cycles: {active_cycles}")
    print(f"Range: {min(active_cycles)} to {max(active_cycles)}")
    print(f"Use these scan_delay values for FI + scan capture")
else:
    print("\nNo MX-active cycles found in range 1-500")

scope.dis()
target.dis()
