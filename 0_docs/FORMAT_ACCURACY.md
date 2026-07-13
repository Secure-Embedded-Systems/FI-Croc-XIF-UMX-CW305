> **Supplementary working notes.** Format names follow the paper: LOG8-SUM (`mxlog8`), LOG8-MAX (`mxlog8_logdom`). Where any number here differs from the published paper (e.g. intermediate WNS or accuracy runs), the paper and `6_analysis/reproduce.py` are authoritative.

# MX Format Accuracy Comparison

## QNN-LLM Benchmark (RTL-Verified via xsim)

2-layer quantized transformer decoder: vocab=32, d_model=8, 2 heads, d_ffn=32. Prompt: [3, 7, 12, 1]. Weights: deterministic (seed=42). Autoregressive generation of 4 tokens.

| Format | Token 0 | Token 1 | Token 2 | Token 3 | Pattern | Comp. Cycles |
|--------|---------|---------|---------|---------|---------|-------------|
| MXINT8 | 25 | 19 | 19 | 19 | Converge | 121,139 |
| MXFP8-E4M3 | 14 | 14 | 14 | 14 | Stable | 223,128 |
| MXFP8-E5M2 | 11 | 11 | 11 | 11 | Stable | 223,597 |
| LOG8-SUM | 8 | 20 | 30 | 30 | Diverse | 220,483 |
| LOG8-MAX | 7 | 7 | 7 | 7 | Stable | 217,422 |

All 5 formats produce valid, non-degenerate predictions. Different golden tokens reflect quantization-induced differences in how each format rounds intermediate values during attention and FFN computation. This is expected behavior, not an accuracy failure.

## BitNet TinyLLM Benchmark (FPGA-Verified at 1.0V)

Same architecture, independently generated ternary-style weights.

| Format | Golden Token | Valid | Notes |
|--------|-------------|-------|-------|
| MXINT8 | 23 | Yes | Distinct from QNN (23 vs 25) |
| MXFP8-E4M3 | 0 | Yes | Token 0 is a valid vocabulary entry |
| MXFP8-E5M2 | 0 | Yes | Same as E4M3 (weight rounding similarity) |
| LOG8-SUM | 10 | Yes | Distinct prediction |
| LOG8-MAX | 2 | Yes | Distinct prediction |

## Key Points for Reviewer Response

1. **All 5 formats produce valid inference output.** The log-domain formats (LOG8-SUM, LOG8-MAX) are not "formats that don't work." They produce deterministic, non-degenerate token predictions on the same benchmark as INT8 and FP8.

2. **LOG8-SUM and LOG8-MAX are proposed formats, not OCP standard.** The OCP Microscaling specification (v1.0, September 2023) defines three element formats: MXINT8, MXFP8-E4M3, and MXFP8-E5M2. We propose two additional logarithmic formats (LOG8-SUM in linear domain, LOG8-MAX in native log domain) and implement all five in a unified coprocessor. The accuracy table demonstrates these proposed formats produce valid inference output on the same benchmark.

3. **Format-dependent fault vulnerability strengthens the proposal.** Beyond functional correctness, the proposed LOG8 formats show a concrete security advantage: they survive DVFS attack down to 0.68V while OCP-standard FP8 formats fault at 0.80-0.81V. This 130 mV resilience gap is a direct consequence of shorter combinational logic paths in shift-and-add arithmetic versus floating-point exponent decode and mantissa alignment. This is a novel security-aware argument for adopting log-domain formats in safety-critical edge AI.

4. **LOG8-SUM produces the most diverse autoregressive sequence** (8, 20, 30, 30), suggesting its quantization characteristics lead to richer attention distributions compared to formats that collapse to repeated tokens (E4M3: 14, 14, 14, 14).

## Format Accuracy vs. Fault Resilience

| Format | Accuracy | Fault Onset | Resilience | LUT Cost |
|--------|----------|-------------|------------|----------|
| MXINT8 | Valid (25) | 0.78V | Medium | Lowest |
| MXFP8-E4M3 | Valid (14) | 0.80V | Low | Medium |
| MXFP8-E5M2 | Valid (11) | 0.81V | Lowest | Medium |
| LOG8-SUM | Valid (8) | 0.68V | High | Medium |
| LOG8-MAX | Valid (7/0) | 0.68V | Highest | Medium |

The tradeoff: the three OCP-standard formats (MXINT8, MXFP8-E4M3, MXFP8-E5M2) offer wider dynamic range but are more vulnerable to DVFS attack. Our proposed LOG8 formats trade dynamic range for fault resilience (shorter combinational paths in shift-and-add vs. floating-point arithmetic). This is a novel security-aware design argument for extending the MX specification with logarithmic formats in safety-critical edge AI accelerators.
