# 4. Fault Injection — ChipWhisperer Campaign Drivers

Python drivers that run the fault-injection campaigns on physical hardware. They
require a **ChipWhisperer CW305** (Artix-7 XC7A35T) target and, for clock
glitching, a **CW-Lite** capture board. Set `MX_PROJ` if the project root is not
the parent directory. Each format has its own bitstream and is programmed
per-trial.

## Drivers

| Script | Campaign | Observability | Needs |
|--------|----------|---------------|-------|
| `dvfs_5format_sweep.py` | QNN voltage underscaling, 5 formats | scan readout (`cw305_scan`, 129-bit) | CW305 |
| `dvfs_bitnet_5format.py` | BitNet FC1 voltage underscaling, 5 formats | live monitor (`cw305_live`) | CW305 |
| `clkglitch_qnn_5format.py` | QNN clock glitch, 5 formats | live monitor (`cw305_live`) | CW305 + CW-Lite |
| `clkglitch_bitnet_5format.py` | BitNet clock glitch, 5 formats | live monitor (`cw305_live`, `*_bitnet.bit`) | CW305 + CW-Lite |
| `sweep_scan_delay.py` | Calibration: finds the capture cycle where the MX coprocessor is active (`se_a`/`se_b` non-zero) | scan | CW305 |
| `hex2mem.py` | Utility: split a RISC-V `.hex` into IMEM/DMEM `.mem` bank init files | — | — |

Voltage campaigns sweep VCC-INT from 1.00 V down to 0.60 V (10 mV steps,
reprogram-per-trial). The scan-based QNN sweep uses `sweep_scan_delay.py` to
locate the MX-active cycle before capturing state.

## Outcome taxonomy

Each trial is classified (recorded in the `class` column of the datasets):

| Class | Meaning |
|-------|---------|
| `normal` | Correct result, matches golden. |
| `fault` | Silent data corruption (SDC): completes but wrong result. |
| `crash` | End-of-computation flag `eoc = 0` (hang / no completion). |
| `dead` | Target unresponsive. |

Shared-exponent corruption is flagged when `se_a != 127` on a faulted row
(`se_a = 127` is the neutral value).
