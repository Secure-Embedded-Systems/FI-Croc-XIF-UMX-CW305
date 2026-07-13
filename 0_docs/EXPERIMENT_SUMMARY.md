> **Supplementary working notes.** Format names follow the paper: LOG8-SUM (`mxlog8`), LOG8-MAX (`mxlog8_logdom`). Where any number here differs from the published paper (e.g. intermediate WNS or accuracy runs), the paper and `6_analysis/reproduce.py` are authoritative.

# Fault Injection Experiment Summary

**Platform:** CROC SoC (CVE2 Ibex RV32IMC, 2-stage pipeline) + Unified MX Coprocessor via CV-X-IF  
**FPGA:** Xilinx Artix-7 XC7A35T-2FTG256 on ChipWhisperer CW305  
**Clock:** 20 MHz (CDCE906 PLL Ch1), WNS = 9.919 ns, Fmax ≈ 24.9 MHz  
**Nominal VCCINT:** 1.0 V (USB-controlled via CW305 on-board regulator)  
**State monitor:** 129-bit direct-wire readout from MX coprocessor registers into USB-readable registers via CDC flip-flops (cw305_live wrapper)

## 1. Workloads

### QNN-LLM (Quantized Neural Network Language Model)

A 2-layer transformer decoder (d_model=8, 2 attention heads, d_ffn=32, vocab=32) that performs autoregressive token generation. The prompt is fixed at [3, 7, 12, 1] with deterministic weights (seed=42). Each format variant uses the same model architecture but format-specific MX instructions (DOT4, ADD4) and quantized weights.

| Format | Comp. Cycles | Total Cycles | Golden Token | IMEM |
|--------|-------------|-------------|-------------|------|
| MXINT8 | 121,139 | 288,431 | 25 | 3,262 B |
| MXFP8-E4M3 | 223,128 | 372,914 | 14 | 2,918 B |
| MXFP8-E5M2 | 223,597 | 373,237 | 11 | 2,914 B |
| LOG8-SUM | 220,483 | 384,274 | 8 | 2,904 B |
| LOG8-MAX | 217,422 | 370,670 | 0 | 2,904 B |

MXINT8 is 1.8x faster than FP/log formats because its DOT4 requires only integer multiply-accumulate with no exponent decode or mantissa alignment. The total-vs-computation gap (150-164K cycles) is dominated by UART output at 125 kbaud.

### BitNet TinyLLM (1.58-bit Quantized Transformer)

Identical architecture to QNN (2-layer, d_model=8, 2-head, d_ffn=32, vocab=32, 4-token prompt, 4-token generation) but with independently generated ternary-style weights. Uses the same MX instructions per format. Different golden values confirm it exercises different datapath states.

| Format | Golden Token |
|--------|-------------|
| MXINT8 | 23 |
| MXFP8-E4M3 | 0 |
| MXFP8-E5M2 | 0 |
| LOG8-SUM | 10 |
| LOG8-MAX | 2 |

## 2. 129-Bit State Monitor

The cw305_live FPGA wrapper taps 10 internal MX coprocessor registers via hierarchical references and synchronizes them to the USB clock domain through 2-stage CDC flip-flops. A snapshot-freeze register (REG 0x0C) provides coherent multi-register reads.

| Field | Width | Description |
|-------|-------|-------------|
| rs1_q | 32 | Operand A register (from CVE2 via CV-X-IF) |
| rs2_q | 32 | Operand B register |
| mac_acc_q | 32 | MAC accumulator (FP32 internal) |
| se_a_q | 8 | Shared exponent A (E8M0, bias=127) |
| se_b_q | 8 | Shared exponent B |
| instr_op_q | 4 | MX operation code (DOT4=0, MUL4=1, ADD4=2, ...) |
| instr_fmt_q | 3 | Format selector (INT8=0, E4M3=1, E5M2=2, LOG8=3, LOGDOM=4) |
| inflight_q | 1 | CV-X-IF in-flight flag |
| instr_rd_q | 5 | Destination register index |
| instr_id_q | 4 | Instruction ID tag |
| **Total** | **129** | |

### How the state monitor enabled root-cause analysis

Without the state monitor, a DVFS fault at 0.79V on BitNet MXINT8 produces ret=19 instead of golden=23. This could be corruption anywhere in the 150K-instruction execution. The state monitor reveals se_a=127 (correct neutral exponent), meaning the MX coprocessor computed correctly and the fault is in the CVE2 CPU pipeline or the CV-X-IF response path. At 0.67V, se_a=255 (all bits set), pinpointing the fault to the MX shared exponent register. Without internal observability, these two distinct mechanisms would appear as a single "wrong answer" failure mode.

## 3. Reprogram-Per-Trial Protocol

Each trial follows: (1) reprogram FPGA from bitstream via USB, (2) set VCCINT to 1.0V, (3) configure PLL to 20 MHz, (4) lower VCCINT to test voltage, (5) assert/release soft reset, (6) wait for end-of-computation, (7) read core_status and 5 state-monitor registers, (8) restore VCCINT to 1.0V, (9) disconnect.

Reprogramming per trial ensures every fault observation starts from a clean FPGA configuration. This distinguishes transient computation faults (which disappear on reprogram) from persistent FPGA configuration corruption (which survives soft reset but not reprogram). All faults reported here are transient — they reproduce deterministically at the same voltage but vanish at nominal voltage after reprogram.

Three trials per voltage level confirm reproducibility. Across 1,140 DVFS trials, the classification (normal/fault/crash/dead) was consistent across all 3 trials at every voltage for every format, with the sole exception of transition voltages (0.77V, 0.68V) where stochastic effects produce mixed classes.

## 4. DVFS Results — QNN Workload (5 Formats, 570 Trials)

Voltage sweep: 1.00V to 0.60V, 10 mV steps, 3 trials per voltage. J16=0 (PLL clock).

| Format | Golden | CPU-Fault Onset | Crash Onset | SE-Fault Onset | Dead |
|--------|--------|----------------|-------------|----------------|------|
| MXFP8-E5M2 | 11 | **0.81V** | 0.77V | 0.67V | 0.63V |
| MXFP8-E4M3 | 14 | **0.80V** | 0.77V | 0.67V | 0.63V |
| MXINT8 | 25 | **0.78V** | 0.77V | 0.67V | 0.63V |
| LOG8-SUM | 8 | 0.68V | 0.77V | 0.67V | 0.63V |
| LOG8-MAX | 0 | 0.68V | 0.77V | 0.67V | 0.63V |

**Susceptible voltage range for silent data corruption (SDC):** 0.68V–0.81V, format-dependent.  
**Format vulnerability ordering:** FP8-E5M2 > FP8-E4M3 > MXINT8 > LOG8-SUM ≈ LOG8-MAX.

This ordering correlates with combinational logic depth. The three OCP-standard formats (MXINT8, MXFP8-E4M3, MXFP8-E5M2) have progressively longer critical paths: FP8 requires exponent decode, mantissa alignment, and normalization stages. Our two proposed logarithmic formats (LOG8-SUM, LOG8-MAX) use shift-and-add arithmetic, which has the shortest critical path and consequently the highest fault resilience — a security-aware argument for extending the MX specification with log-domain formats.

## 5. DVFS Results — BitNet Workload (5 Formats, 570 Trials)

Same protocol. Different workload confirms the fault mechanism is hardware-structural, not workload-dependent.

| Format | Golden | CPU-Fault Onset | Crash Onset | SE-Fault Onset | Dead |
|--------|--------|----------------|-------------|----------------|------|
| MXINT8 | 23 | **0.79V** (ret=19, then 16) | 0.77V | 0.67V | 0.63V |
| LOG8-SUM | 10 | **0.78V** (ret=8) | 0.77V | 0.67V | 0.63V |
| LOG8-MAX | 2 | **0.78V** (ret=0) | 0.76V | 0.67V | 0.63V |
| MXFP8-E4M3 | 0 | masked (golden=0) | 0.77V | 0.67V | 0.63V |
| MXFP8-E5M2 | 0 | masked (golden=0) | 0.77V | 0.67V | 0.63V |

BitNet MXINT8 uniquely shows two progressive CPU-path SDC values (23→19→16→crash) before the SE corruption zone, suggesting the CPU ALU fails gracefully across a 20 mV window. E4M3 and E5M2 have golden=0, which makes CPU-path SDC invisible because the faulted ret=0 matches the crash signature (eoc=0, ret=0). The eoc flag distinguishes them: normal has eoc=1, crash has eoc=0.

## 6. Clock Glitch Results — QNN Workload (5 Formats, 450 Trials)

CW-Lite clock glitch via clock_xor on tio_clkin (J16=1). Width sweep w=-5 to -24, ext_offset sweep 50-500, 3 trials per width.

| Format | Trials | Faults | Crashes | Result |
|--------|--------|--------|---------|--------|
| MXINT8 | 90 | 0 | 0 | All normal |
| MXFP8-E4M3 | 90 | 0 | 0 | All normal |
| MXFP8-E5M2 | 90 | 0 | 0 | All normal |
| LOG8-SUM | 90 | 0 | 0 | All normal |
| LOG8-MAX | 90 | 0 | 0 | All normal |

**Zero SDC across all 450 trials.** The CW-Lite glitch module uses integer-step width resolution, which jumps from "no effect" directly past the exploitable window to "would crash the FPGA" with no intermediate sweet spot. The design has 9.919 ns positive slack at 20 MHz, meaning a glitch would need to remove more than 9.9 ns from a single clock period to cause a timing violation. The CW-Lite's coarsest single-cycle glitch (~2 ns step) cannot achieve this. A higher-resolution glitch source (e.g., CW-Husky with sub-ns control) or a higher clock frequency (to reduce slack) would be needed.

## 7. Two Distinct Fault Mechanisms

### Mechanism 1: CPU-path SDC (0.78V–0.81V)

The return value changes but the MX coprocessor state monitor shows all registers correct (se_a=127, se_b=127, normal op/fmt fields). The fault occurs after the MX computation result leaves the coprocessor through the CV-X-IF response interface and enters the CVE2 register file, ALU, or memory subsystem. This affects the final argmax token selection or the scalar accumulation logic in the CPU.

### Mechanism 2: MX shared-exponent corruption (0.67V–0.68V)

The se_a register flips from 127 (neutral, 2^0 scaling) toward 255 (2^128 scaling). The progression is gradual: 107→128→192→253→255 across 0.71V–0.67V. Once se_a reaches 255, every DOT4 output overflows, clip8() saturates to 127, and the argmax selects token 127 regardless of weights or format. This produces the same faulted ret=127 across all 5 formats on both workloads — a format-independent, workload-independent fault signature.

### Crash zone (0.72V–0.76V)

Between the two SDC zones lies a crash zone where the CPU halts (eoc=0). This is where the CPU core itself fails to complete execution. The MX coprocessor may still function (se_a transitions from correct to corrupted through this range), but the CPU cannot execute the surrounding control flow.

## 8. Format Accuracy on QNN-LLM Benchmark

All 5 formats produce valid, deterministic token predictions on the 2-layer transformer benchmark. The different golden values reflect quantization-induced differences in the argmax output, not accuracy failures.

| Format | Tokens Generated | Autoregressive Pattern | Notes |
|--------|-----------------|----------------------|-------|
| MXINT8 | 25, 19, 19, 19 | Converges after 1st token | Fastest (121K cycles) |
| MXFP8-E4M3 | 14, 14, 14, 14 | Stable repetition | Standard FP8 |
| MXFP8-E5M2 | 11, 11, 11, 11 | Stable repetition | Wide-range FP8 |
| LOG8-SUM | 8, 20, 30, 30 | Diverse then converges | Linear-domain log |
| LOG8-MAX | 7, 7, 7, 7 | Stable repetition | Native log-domain |

LOG8-SUM produces the most diverse token sequence (8, 20, 30, 30), which is a positive indicator: the format's quantization characteristics lead to different attention distributions rather than collapsing to a single repeated token. LOG8-MAX generates a stable sequence (7, 7, 7, 7) with the lowest cycle count among non-integer formats (217K vs 220-223K), reflecting the efficiency of keeping computations in log-domain without repeated linear conversion.

## 9. Experimental Volume

| Experiment | Workload | Formats | Method | Trials | Datasets |
|-----------|----------|---------|--------|--------|----------|
| DVFS voltage sweep | QNN | 5 | VCCINT underscaling | 570 | dvfs_{format}.csv |
| DVFS voltage sweep | BitNet | 5 | VCCINT underscaling | 570 | dvfs_bitnet_{format}.csv |
| Clock glitch | QNN | 5 | CW-Lite clock_xor | 450 | clkglitch_{format}_qnn.csv |
| **Total** | | | | **1,590** | |

All datasets include per-trial state-monitor fields (se_a, se_b, mac_acc, rs1, rs2, op, fmt_hw, inflight, rd, id) for post-hoc analysis and ML classification.
