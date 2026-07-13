> **Supplementary working notes.** Format names follow the paper: LOG8-SUM (`mxlog8`), LOG8-MAX (`mxlog8_logdom`). Where any number here differs from the published paper (e.g. intermediate WNS or accuracy runs), the paper and `6_analysis/reproduce.py` are authoritative.

# DVFS Fault Injection Results — MX Unified Coprocessor

Platform: CROC SoC (CVE2 RV32IMC + Unified MX Coprocessor via CV-X-IF) on CW305 Artix-7 XC7A35T  
Clock: 20 MHz (WNS = 2.252 ns, Fmax ≈ 20.9 MHz)  
Protocol: Reprogram-per-trial, 3 trials per voltage, 129-bit scan chain readout

---

## Table 1: DVFS Voltage Sweep — MXINT8 (with State Monitor + 3-Way Consistency)

Entire execution at fault voltage. Scan captured at cycle 100. Scan read 3× at fault voltage.

| VCCINT (V) | Return Code | eoc | se_a_q | se_b_q | mac_acc_q | rs1_q | 3-Way Consistent | Class |
|---|---|---|---|---|---|---|---|---|
| 1.00 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.99 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.98 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.97 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.96 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.95 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.94 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.93 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.92 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.91 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.90 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.89 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.88 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.87 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.86 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.85 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.84 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.83 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.82 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.81 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.80 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| 0.79 | 25 | 1 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Normal |
| **0.78** | **0** | **0** | 0 | 0 | 0x00000000 | 0x00000000 | YES | **Crash** |
| 0.77 | 0 | 0 | 255 | 255 | 0xFFFFFFFF | 0xFFFFFFFF | YES | Crash |
| 0.76 | 0 | 0 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Crash |
| 0.75 | 0 | 0 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Crash |
| 0.74 | 0 | 0 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Crash |
| 0.73 | 0 | 0 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Crash |
| 0.72 | 0 | 0 | 0 | 0 | 0x00000000 | 0x00000000 | YES | Crash |
| **0.71** | **127** | **1** | **128** | **0** | **0x8000007F** | **0x8000007F** | **YES** | **Silent Fault** |
| 0.70 | 127 | 1 | 128 | 0 | 0x8000007F | 0x8000007F | YES | Silent Fault |
| 0.69 | 127 | 1 | 128 | 0 | 0x8000007F | 0x8000007F | YES | Silent Fault |
| 0.68 | 127 | 1 | 128 | 0 | 0x8000007F | 0x8000007F | YES | Silent Fault |
| 0.67 | 127 | 1 | 128 | 0 | 0x8000007F | 0x8000007F | YES | Silent Fault |
| 0.66 | 2175 | 1 | 128 | 0 | 0x8000007F | 0x800000FF | YES | Deeper Fault |
| 0.65 | 2175 | 1 | 128 | 0 | 0x8000007F | 0x808080FF | YES | Deeper Fault |
| 0.64 | 2431 | 1 | 128 | 0 | 0x8000007F | 0x8000007F | YES | Deeper Fault |
| **0.63** | **0x7FFFFFFF** | **1** | **255** | **255** | **0xFFFFFFFF** | **0xFFFFFFFF** | **YES** | **Dead** |

---

## Table 2: 5-Format DVFS Comparison

All formats at 20 MHz, reprogram-per-trial, 3 trials per voltage (100% reproducible).

| Format | Golden ret | Crash Onset (V) | Silent Fault Onset (V) | Faulted ret | se_a_q (faulted) | Dead (≤V) |
|---|---|---|---|---|---|---|
| MXINT8 | 25 | 0.78 | 0.71 | 127 | 128 (0x80) | 0.63 |
| MXFP8-E4M3 | 14 | 0.76 | 0.71 | 127 | 128 (0x80) | 0.63 |
| MXFP8-E5M2 | 11 | 0.76 | 0.71 | 127 | 128 (0x80) | 0.63 |
| LOG8-SUM | 8 | 0.76 | 0.71 | 127 | 128 (0x80) | 0.63 |
| LOG8-MAX | 0 | 0.76 | 0.71 | 127 | 128 (0x80) | 0.63 |

**Observation:** All 5 formats produce identical fault signature (ret=127, se_a=128) at the same voltage (0.71V). The SE register is format-independent shared hardware — the fault is architectural, not format-specific.

---

## Table 3: MXINT8 Deeper Fault Values

| VCCINT (V) | Return Code | XOR vs Golden | Bits Different |
|---|---|---|---|
| 0.71–0.67 | 127 | 102 (0x66) | 7 |
| 0.66–0.65 | 2175 | 2164 (0x874) | 6 |
| 0.64 | 2431 | 2420 (0x974) | 7 |

## Table 4: MXFP8-E4M3 Deeper Fault Values

| VCCINT (V) | Return Code | XOR vs Golden | Bits Different |
|---|---|---|---|
| 0.71–0.67 | 127 | 113 (0x71) | 5 |
| 0.66 | 2175 | 2161 (0x871) | 6 |
| 0.65 | 3199 | 3185 (0xC71) | 7 |
| 0.64 | 3711 | 3697 (0xE71) | 8 |

---

## Table 5: Frequency Sweep (MXINT8)

Design Fmax = 20.9 MHz (WNS = 2.252 ns). Frequencies >20 MHz violate timing closure.

| Frequency (MHz) | Normal (≥V) | Crash Onset (V) | Fault Onset (V) | Faulted ret | Dead (≤V) |
|---|---|---|---|---|---|
| 20 | 0.80 | 0.78 | 0.71 | 127 | 0.63 |
| 25 | 0.80 | 0.78 | 0.71 | 127 | 0.63 |
| 30 | 0.80 | 0.78 | 0.71 | 127 | 0.63 |
| 35 | 0.80 | 0.78 | 0.71 | 127 | 0.63 |

**Observation:** Identical fault boundaries across all frequencies. The fault is voltage-threshold determined, not timing-margin determined. The FPGA logic gates produce incorrect outputs below 0.71V regardless of clock period.

---

## Table 6: Voltage Zone Classification

| Zone | VCCINT Range | CPU (CVE2) | MX Coprocessor | Detection | Attacker Value |
|---|---|---|---|---|---|
| Normal | ≥ 0.80V | Correct | Correct | N/A | None |
| CPU Crash | 0.78–0.72V | Pipeline halt (eoc=0) | No computation (no issue) | Detectable (timeout) | Denial of service |
| **Silent Fault** | **0.71–0.64V** | **Barely functional** | **SE corrupted (se_a=128)** | **Undetectable** | **Data corruption** |
| Dead | ≤ 0.63V | Non-functional | Non-functional | Board-level | Board destruction |

---

## Table 7: Scan Chain Diagnosis (Golden vs Faulted at 0.71V)

| Scan Field | Width | Golden (1.0V) | Faulted (0.71V) | Corrupted? |
|---|---|---|---|---|
| se_a_q | 8 bit | 0 (post-exec) | **128 (0x80)** | **YES — bit 7: 0→1** |
| se_b_q | 8 bit | 0 | 0 | No |
| mac_acc_q | 32 bit | 0x00000000 | **0x8000007F** | **YES — overflow from SE** |
| rs1_q | 32 bit | 0x00000000 | **0x8000007F** | YES — propagated |
| rs2_q | 32 bit | 0x00000000 | 0x00000000 | No |
| instr_op_q | 4 bit | 0 | 0 | No |
| instr_fmt_q | 3 bit | 0 | 0 | No |
| inflight_q | 1 bit | 0 | 0 | No |
| instr_rd_q | 5 bit | 0 | 0 | No |
| instr_id_q | 4 bit | 0 | 0 | No |

**Interpretation:** Only se_a_q is independently corrupted. mac_acc_q and rs1_q are consequences of the SE corruption (2× scaling → overflow). All other registers are unaffected.

---

## Table 8: Fault Propagation Chain

| Stage | Value | Explanation |
|---|---|---|
| SE register | 127 → **128** | Bit 7 flipped (0→1) due to voltage-threshold violation |
| Scale factor | 2^0 = 1 → 2^1 = **2** | E8M0 bias=127: scale = 2^(se_a - 127) |
| Dot product | correct → **2× correct** | All 32 elements scaled by 2× |
| MAC accumulator | normal → **0x8000007F** | Overflow from doubled partial products |
| clip8() output | correct → **127** | Positive overflow saturates to max int8 |
| Token prediction | index 25 → **index 127** | Highest saturated logit wins |
| XOR distance | — | 102 (0x66) = 7 bits different |

---

## Table 9: Clock Glitch vs DVFS Comparison

| Metric | Clock Glitch (CW-Lite) | DVFS (USB Voltage) |
|---|---|---|
| Equipment | CW-Lite + 20-pin cable | USB only (no glitch HW) |
| Total trials | 3,065 | 360 (5 formats × 72) |
| Transient crashes | 282 (9.2%) | ~72 (20%) |
| **Silent faults** | **0 (0%)** | **>100 (>28%)** |
| Reproducibility | Crashes sporadic | **100% deterministic** |
| Scan chain correlation | No (zeros after eoc) | **Yes (se_a=128)** |
| SE corruption observed | No | **Yes** |
| Format-independent | Not tested | **Yes (all 5 formats)** |

**Why DVFS succeeds where clock glitch fails:** DVFS stresses every clock cycle continuously. Clock glitch affects one cycle — must hit the exact cycle of an MX instruction with sub-ns precision, which CW-Lite's integer width resolution cannot achieve.

---

## Table 10: Transient Verification

| Test | Method | Result |
|---|---|---|
| Jump test | Program at 1.0V, jump directly to 0.70V (skip crash zone) | ret=127 — fault confirmed |
| Reprogram test | Reprogram independently at 0.71V, 0.70V, 0.69V, 0.68V | ret=127 at all — confirmed |
| Restore test | Restore to 1.0V after fault, run again without reprogram | ret=25 — no persistent damage |
| 3-way scan | Read scan 3× at fault voltage | Identical all 3 reads — consistent |

**Conclusion:** Faults are transient computation errors, not persistent FPGA configuration corruption.

---

## Table 11: 129-Bit Scan Chain Register Map

| Field | Bits | Width | Description |
|---|---|---|---|
| rs1_q | [128:97] | 32 | Operand A latch (from CVE2 register file) |
| rs2_q | [96:65] | 32 | Operand B latch (from CVE2 register file) |
| mac_acc_q | [64:33] | 32 | FP32 MAC accumulator |
| se_a_q | [32:25] | 8 | Shared exponent A (E8M0, bias=127) |
| se_b_q | [24:17] | 8 | Shared exponent B (E8M0, bias=127) |
| instr_op_q | [16:13] | 4 | MX operation code |
| instr_fmt_q | [12:10] | 3 | MX format selector (0=INT8, 1=E4M3, 2=E5M2, 3=LOG8-S, 4=LOG8-M) |
| inflight_q | [9] | 1 | CV-X-IF instruction in-flight flag |
| instr_rd_q | [8:4] | 5 | Destination register index |
| instr_id_q | [3:0] | 4 | CV-X-IF instruction ID tag |
| **Total** | **[128:0]** | **129** | |

---

## Table 12: CW305 Hardware Configuration

| Parameter | Value |
|---|---|
| FPGA | Xilinx Artix-7 XC7A35T-2FTG256 |
| Board | ChipWhisperer CW305 |
| SoC | CROC (CVE2 Ibex RV32IMC + MX Coprocessor) |
| Clock | 20 MHz (CDCE906 PLL Ch1) |
| VCCINT nominal | 1.0V |
| WNS | 2.252 ns (Fmax ≈ 20.9 MHz) |
| DIP J16 | 0 (PLL clock for DVFS) |
| DIP K16 | 1 (ext_clock output) |
| DIP K15 | 1 (fetch enable) |
| DIP L14 | 1 (spare) |
| Voltage control | USB API: target.vccint_set() |
| Scan readout | USB REG 0x06 (ctrl), REG 0x08-0x0C (data) |
| Trigger | USB REG 0x05 (for clock glitch sync) |

---

*Data collected April 9–13, 2026. All results verified with reprogram-per-trial protocol.*
