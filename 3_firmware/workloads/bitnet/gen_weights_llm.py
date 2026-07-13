# SPDX-License-Identifier: Apache-2.0
# Fault Analysis of Microscaling Formats on a RISC-V SoC
# Authors: Dillibabu Shanmugam, Patrick Schaumont
# Affiliation: Worcester Polytechnic Institute (WPI), USA

#!/usr/bin/env python3
"""Generate MX weight headers for TinyLLM v2 across all 5 formats.

Architecture: 2-layer transformer decoder (GPT/LLaMA-style)
  - Vocab=32, d_model=8, n_heads=2, head_dim=4, d_ffn=32, ctx_len=8
  - Pre-norm (RMSNorm), sinusoidal position encoding, KV cache
  - Autoregressive: 4 prompt tokens -> 4 generated tokens

Weight layout (flat array, all uint32_t words):
  [0..63]     token embeddings: 32 vocab x 8 dim = 64 words
  [64..79]    position table:   8 pos x 8 dim = 16 words
  [80..287]   layer 0:          208 words
  [288..495]  layer 1:          208 words
  [496..559]  LM head:          32 vocab x 8 dim = 64 words
  Total: 560 words = 2240 bytes

Per-layer layout (208 words):
  [+0..+1]    RMSNorm_attn gamma (8 elements = 2 words)
  [+2..+17]   W_Q  (8x8 = 16 words)
  [+18..+33]  W_K  (8x8 = 16 words)
  [+34..+49]  W_V  (8x8 = 16 words)
  [+50..+65]  W_O  (8x8 = 16 words)
  [+66..+67]  RMSNorm_ffn gamma (2 words)
  [+68..+131] W_FFN_UP  (32 rows x 8 cols = 64 words)
  [+132..+195] W_FFN_DOWN (8 outputs x 32 inputs = 64 words)
  [+196..+207] unused padding (12 words) → total 208

Actually recomputing: let me be precise.
  RMSNorm_attn: 2 words
  W_Q: 16 words (8 output rows, each row = 2 words for 8 elements)
  W_K: 16
  W_V: 16
  W_O: 16
  RMSNorm_ffn: 2
  W_up: 64 words (32 output rows, each = 2 words)
  W_down: 64 words (8 output rows, each needs 8 words for 32 inputs)
  Layer total: 2+16+16+16+16+2+64+64 = 196 words

Grand total: 64 + 16 + 2*196 + 64 = 536 words = 2144 bytes

Authors: Dillibabu Shanmugam, Patrick Schaumont (WPI)
"""

import os, sys, math, random

# ── Architecture ──
VOCAB_SIZE  = 32
D_MODEL     = 8
N_HEADS     = 2
HEAD_DIM    = D_MODEL // N_HEADS  # 4
N_LAYERS    = 2
D_FFN       = 32
CTX_LEN     = 8
PROMPT_LEN  = 4
GEN_LEN     = 4

# Per-layer word counts
W_NORM    = D_MODEL // 4           # 2 words (8 elements / 4 per word)
W_PROJ    = D_MODEL * (D_MODEL//4) # 16 words (8 rows x 2 words/row)
W_FFN_UP  = D_FFN * (D_MODEL//4)   # 64 words (32 rows x 2 words/row)
W_FFN_DN  = D_MODEL * (D_FFN//4)   # 64 words (8 rows x 8 words/row)
WORDS_LAYER = W_NORM + W_PROJ*4 + W_NORM + W_FFN_UP + W_FFN_DN  # 196

WORDS_EMB  = VOCAB_SIZE * (D_MODEL // 4)  # 64
WORDS_POS  = CTX_LEN * (D_MODEL // 4)     # 16
WORDS_LM   = VOCAB_SIZE * (D_MODEL // 4)  # 64
TOTAL_WORDS = WORDS_EMB + WORDS_POS + N_LAYERS * WORDS_LAYER + WORDS_LM

# Offsets
OFF_EMB = 0
OFF_POS = WORDS_EMB
OFF_LAYERS = OFF_POS + WORDS_POS
OFF_LM = OFF_LAYERS + N_LAYERS * WORDS_LAYER

# Per-layer offsets (relative)
LO_NORM_A = 0
LO_WQ     = LO_NORM_A + W_NORM
LO_WK     = LO_WQ + W_PROJ
LO_WV     = LO_WK + W_PROJ
LO_WO     = LO_WV + W_PROJ
LO_NORM_F = LO_WO + W_PROJ
LO_WUP    = LO_NORM_F + W_NORM
LO_WDN    = LO_WUP + W_FFN_UP

PROMPT = [3, 7, 12, 1]

# ── Weight generation ──
random.seed(42)

# Token embeddings: 32 x 8, range [-4, +4]
emb_fp = [[random.randint(-4, 4) for _ in range(D_MODEL)]
           for _ in range(VOCAB_SIZE)]

# Sinusoidal position table: 8 x 8
# pos_enc[pos][d] = sin(pos / 10000^(d/d_model)) for even d
#                   cos(pos / 10000^((d-1)/d_model)) for odd d
# Quantized to int8 range [-127, +127]
pos_fp = []
for pos in range(CTX_LEN):
    row = []
    for d in range(D_MODEL):
        angle = pos / (10000.0 ** ((d // 2 * 2) / D_MODEL))
        if d % 2 == 0:
            val = math.sin(angle)
        else:
            val = math.cos(angle)
        row.append(int(round(val * 8)))  # scale to small int range
    pos_fp.append(row)

# RMSNorm gamma: initialized to 1 (encoded per format)
gamma_fp = [1] * D_MODEL

# Per-layer weights
layers_fp = []
for l in range(N_LAYERS):
    layer = {}
    # Attention projections: 8x8, range [-2, +2]
    for name in ['wq', 'wk', 'wv', 'wo']:
        layer[name] = [[random.choice([-2,-1,-1,0,0,1,1,2])
                         for _ in range(D_MODEL)]
                        for _ in range(D_MODEL)]
    # FFN up: 32 x 8, range [-2, +2]
    layer['wup'] = [[random.choice([-2,-1,-1,0,0,1,1,2])
                      for _ in range(D_MODEL)]
                     for _ in range(D_FFN)]
    # FFN down: 8 x 32, range [-2, +2]
    layer['wdn'] = [[random.choice([-2,-1,-1,0,0,1,1,2])
                      for _ in range(D_FFN)]
                     for _ in range(D_MODEL)]
    layers_fp.append(layer)

# LM head: 32 x 8, range [-3, +3]
lm_head_fp = [[random.choice([-3,-2,-1,0,1,2,3])
                for _ in range(D_MODEL)]
               for _ in range(VOCAB_SIZE)]


# ── Encoding functions ──

def encode_int8(val):
    v = int(round(val))
    return max(-128, min(127, v)) & 0xFF

def encode_fp8_e4m3(val):
    if val == 0: return 0x00
    sign = 0
    if val < 0: sign = 1; val = -val
    if val >= 448: return (sign << 7) | 0x7E
    if val < 2**(-6) * (1/8): return sign << 7
    if val < 2**(-6):
        m = max(1, min(7, int(round(val / (2**(-6)) * 8))))
        return (sign << 7) | m
    e = int(math.floor(math.log2(val)))
    eb = max(1, min(15, e + 7))
    frac = val / (2.0 ** (eb - 7)) - 1.0
    m = int(round(frac * 8))
    if m > 7: m = 0; eb += 1
    if eb > 15: return (sign << 7) | 0x7E
    if m < 0: m = 0
    return (sign << 7) | (eb << 3) | m

def encode_fp8_e5m2(val):
    if val == 0: return 0x00
    sign = 0
    if val < 0: sign = 1; val = -val
    if val >= 57344: return (sign << 7) | 0x7B
    if val < 2**(-14) * (1/4): return sign << 7
    if val < 2**(-14):
        m = max(1, min(3, int(round(val / (2**(-14)) * 4))))
        return (sign << 7) | m
    e = int(math.floor(math.log2(val)))
    eb = max(1, min(30, e + 15))
    frac = val / (2.0 ** (eb - 15)) - 1.0
    m = int(round(frac * 4))
    if m > 3: m = 0; eb += 1
    if eb > 30: return (sign << 7) | 0x7B
    if m < 0: m = 0
    return (sign << 7) | (eb << 2) | m

def encode_log8(val):
    if val == 0: return 0x00
    sign = 0
    if val < 0: sign = 1; val = -val
    log_idx = math.log2(val) * 8 + 63
    log_idx = max(1, min(127, int(round(log_idx))))
    return (sign << 7) | log_idx

def pack4(b0, b1, b2, b3):
    return (b0&0xFF) | ((b1&0xFF)<<8) | ((b2&0xFF)<<16) | ((b3&0xFF)<<24)


# ── Header generation ──

def gen_header(fmt_name, encoder):
    lines = []
    lines.append("// Auto-generated by gen_weights_llm.py")
    lines.append("// TinyLLM v2: 2-layer transformer decoder, d_model=8, 2-head")
    lines.append("// Format: %s (unified MX coprocessor)" % fmt_name)
    lines.append("// DO NOT EDIT")
    lines.append("")
    guard = "WEIGHTS_%s_LLM_H" % fmt_name.upper()
    lines.append("#ifndef %s" % guard)
    lines.append("#define %s" % guard)
    lines.append("")
    lines.append("#include <stdint.h>")
    lines.append("")

    # Architecture constants
    lines.append("// Architecture")
    lines.append("#define LLM_VOCAB      %d" % VOCAB_SIZE)
    lines.append("#define LLM_DMODEL     %d" % D_MODEL)
    lines.append("#define LLM_NHEADS     %d" % N_HEADS)
    lines.append("#define LLM_HDIM       %d" % HEAD_DIM)
    lines.append("#define LLM_NLAYERS    %d" % N_LAYERS)
    lines.append("#define LLM_DFFN       %d" % D_FFN)
    lines.append("#define LLM_CTXLEN     %d" % CTX_LEN)
    lines.append("#define LLM_PROMPTLEN  %d" % PROMPT_LEN)
    lines.append("#define LLM_GENLEN     %d" % GEN_LEN)
    lines.append("#define LLM_DWORDS     %d  // words per d_model vector" % (D_MODEL // 4))
    lines.append("")

    # Offsets
    lines.append("// Flat weight array offsets (word indices)")
    lines.append("#define LLM_OFF_EMB    %d" % OFF_EMB)
    lines.append("#define LLM_OFF_POS    %d" % OFF_POS)
    lines.append("#define LLM_OFF_LM     %d" % OFF_LM)
    lines.append("#define LLM_WLAYER     %d  // words per layer" % WORDS_LAYER)
    lines.append("#define LLM_OFF_L(l)   (%d + (l) * %d)" % (OFF_LAYERS, WORDS_LAYER))
    lines.append("")
    lines.append("// Per-layer relative offsets")
    lines.append("#define LO_NORMA  %d" % LO_NORM_A)
    lines.append("#define LO_WQ     %d" % LO_WQ)
    lines.append("#define LO_WK     %d" % LO_WK)
    lines.append("#define LO_WV     %d" % LO_WV)
    lines.append("#define LO_WO     %d" % LO_WO)
    lines.append("#define LO_NORMF  %d" % LO_NORM_F)
    lines.append("#define LO_WUP    %d" % LO_WUP)
    lines.append("#define LO_WDN    %d" % LO_WDN)
    lines.append("")

    # Prompt
    lines.append("static const uint8_t llm_prompt[%d] = {%s};" %
                 (PROMPT_LEN, ", ".join(str(p) for p in PROMPT)))
    lines.append("")

    # Build flat weight array
    words = []

    # Embeddings
    for t in range(VOCAB_SIZE):
        for g in range(D_MODEL // 4):
            bs = [encoder(emb_fp[t][g*4+d]) for d in range(4)]
            words.append(pack4(*bs))

    # Position table
    for p in range(CTX_LEN):
        for g in range(D_MODEL // 4):
            bs = [encoder(pos_fp[p][g*4+d]) for d in range(4)]
            words.append(pack4(*bs))

    # Layers
    for l in range(N_LAYERS):
        layer = layers_fp[l]
        # RMSNorm attn gamma
        for g in range(D_MODEL // 4):
            bs = [encoder(gamma_fp[g*4+d]) for d in range(4)]
            words.append(pack4(*bs))
        # W_Q, W_K, W_V, W_O: each 8x8 = 16 words
        for proj in ['wq', 'wk', 'wv', 'wo']:
            for r in range(D_MODEL):
                for g in range(D_MODEL // 4):
                    bs = [encoder(layer[proj][r][g*4+d]) for d in range(4)]
                    words.append(pack4(*bs))
        # RMSNorm ffn gamma
        for g in range(D_MODEL // 4):
            bs = [encoder(gamma_fp[g*4+d]) for d in range(4)]
            words.append(pack4(*bs))
        # W_FFN_UP: 32x8 = 64 words
        for r in range(D_FFN):
            for g in range(D_MODEL // 4):
                bs = [encoder(layer['wup'][r][g*4+d]) for d in range(4)]
                words.append(pack4(*bs))
        # W_FFN_DOWN: 8x32 = 64 words
        for r in range(D_MODEL):
            for g in range(D_FFN // 4):
                bs = [encoder(layer['wdn'][r][g*4+d]) for d in range(4)]
                words.append(pack4(*bs))

    # LM head
    for t in range(VOCAB_SIZE):
        for g in range(D_MODEL // 4):
            bs = [encoder(lm_head_fp[t][g*4+d]) for d in range(4)]
            words.append(pack4(*bs))

    assert len(words) == TOTAL_WORDS, \
        "Expected %d words, got %d" % (TOTAL_WORDS, len(words))

    # Emit
    lines.append("// All weights: %d words = %d bytes" % (TOTAL_WORDS, TOTAL_WORDS*4))
    lines.append("static const uint32_t llm_w_%s[%d] = {" % (fmt_name, TOTAL_WORDS))

    # Section markers
    sections = {
        0: "Token Embeddings (%d words)" % WORDS_EMB,
        OFF_POS: "Position Table (%d words)" % WORDS_POS,
        OFF_LM: "LM Head (%d words)" % WORDS_LM,
    }
    for l in range(N_LAYERS):
        sections[OFF_LAYERS + l*WORDS_LAYER] = "Layer %d (%d words)" % (l, WORDS_LAYER)

    for i, w in enumerate(words):
        if i in sections:
            lines.append("    // --- %s ---" % sections[i])
        comma = "," if i < len(words) - 1 else ""
        lines.append("    0x%08X%s" % (w, comma))
    lines.append("};")
    lines.append("")
    lines.append("#endif // %s" % guard)
    lines.append("")
    return "\n".join(lines)


# ── Main ──

FORMATS = {
    "mxint8":       encode_int8,
    "mxfp8_e4m3":   encode_fp8_e4m3,
    "mxfp8_e5m2":   encode_fp8_e5m2,
    "mxlog8":       encode_log8,
    "mxlog8_logdom": encode_log8,
}

if __name__ == "__main__":
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "weights")
    os.makedirs(out_dir, exist_ok=True)

    print("TinyLLM v2 Weight Generator")
    print("  d_model=%d, n_heads=%d, n_layers=%d, d_ffn=%d" %
          (D_MODEL, N_HEADS, N_LAYERS, D_FFN))
    print("  Total: %d words = %d bytes" % (TOTAL_WORDS, TOTAL_WORDS*4))
    print("  IMEM estimate: ~3KB code")
    print("  DMEM: %dB weights + %dB KV cache + ~512B scratch/stack" %
          (TOTAL_WORDS*4, N_LAYERS * CTX_LEN * D_MODEL * 2))
    print("  Fault targets: %d bits/format, %d total" %
          (TOTAL_WORDS*32, TOTAL_WORDS*32*len(FORMATS)))
    print()

    for fmt_name, encoder in FORMATS.items():
        path = os.path.join(out_dir, "weights_%s_llm.h" % fmt_name)
        content = gen_header(fmt_name, encoder)
        with open(path, "w") as f:
            f.write(content)
        print("  Generated: weights_%s_llm.h" % fmt_name)

    print("\nDone. %d headers." % len(FORMATS))
