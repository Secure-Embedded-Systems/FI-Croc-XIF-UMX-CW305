# SPDX-License-Identifier: Apache-2.0
# Fault Analysis of Microscaling Formats on a RISC-V SoC
# Authors: Dillibabu Shanmugam, Patrick Schaumont
# Affiliation: Worcester Polytechnic Institute (WPI), USA

#!/usr/bin/env python3
"""Generate QNN-LLM weight headers for all 5 MX formats.

Quantized Transformer Decoder (GPT-style QNN-LLM):
  vocab=32, d_model=8, n_heads=2, head_dim=4, d_ffn=32
  2 layers, ctx_len=8, 4 prompt + 4 generated tokens

All weights quantized to 8-bit MX formats. Proper re-quantization
between layers. BN (batch-norm-like affine) after attention & FFN.

Const data layout (all in IMEM as static const):
  OFF_EMB=0      embeddings: 32 vocab x 2 words = 64 words
  OFF_POS=64     position:   8 pos x 2 words = 16 words
  OFF_L0=80      layer 0:    200 words
  OFF_L1=280     layer 1:    200 words
  OFF_LM=480     LM head:    32 vocab x 2 words = 64 words
  OFF_PROMPT=544 prompt:     1 word (4 packed token IDs)
  TOTAL = 545 words = 2180 bytes

Per-layer (200 words):
  +0   W_Q    (8x8 = 16 words)
  +16  W_K    (8x8 = 16 words)
  +32  W_V    (8x8 = 16 words)
  +48  W_O    (8x8 = 16 words)
  +64  BN_attn (scale_lo, scale_hi, bias_lo, bias_hi = 4 words)
  +68  W_UP   (32x8 = 32 rows x 2 words/row = 64 words)
  +132 W_DN   (8x32 = 8 rows x 8 words/row = 64 words)
  +196 BN_ffn  (4 words)

Authors: Dillibabu Shanmugam, Patrick Schaumont (WPI)
"""

import os, math, random

# ── Architecture ──
VOCAB   = 32
DMODEL  = 8
NHEADS  = 2
HDIM    = DMODEL // NHEADS  # 4
NLAYERS = 2
DFFN    = 32
CTXLEN  = 8
PLEN    = 4
GLEN    = 4
DW      = DMODEL // 4  # 2 words per d_model vector

# Per-layer word counts
W_PROJ    = DMODEL * DW              # 16 words per projection (8 rows x 2 words)
W_BN      = 4                        # scale_lo, scale_hi, bias_lo, bias_hi
W_FFN_UP  = DFFN * DW                # 64 words (32 rows x 2 words)
W_FFN_DN  = DMODEL * (DFFN // 4)     # 64 words (8 rows x 8 groups)
WLAYER    = W_PROJ*4 + W_BN + W_FFN_UP + W_FFN_DN + W_BN  # 200

OFF_EMB    = 0
OFF_POS    = VOCAB * DW                          # 64
OFF_L0     = OFF_POS + CTXLEN * DW               # 80
OFF_L1     = OFF_L0 + WLAYER                     # 280
OFF_LM     = OFF_L1 + WLAYER                     # 480
OFF_PROMPT = OFF_LM + VOCAB * DW                 # 544
TOTAL      = OFF_PROMPT + 1                      # 545 words

# Layer-relative offsets
LR_WQ   = 0
LR_WK   = W_PROJ        # 16
LR_WV   = W_PROJ * 2    # 32
LR_WO   = W_PROJ * 3    # 48
LR_BNA  = W_PROJ * 4    # 64
LR_WUP  = LR_BNA + W_BN # 68
LR_WDN  = LR_WUP + W_FFN_UP  # 132
LR_BNF  = LR_WDN + W_FFN_DN  # 196

PROMPT = [3, 7, 12, 1]

# ── Weight generation (deterministic) ──
random.seed(42)

# Token embeddings: 32 x 8, range [-4, +4]
emb = [[random.randint(-4, 4) for _ in range(DMODEL)] for _ in range(VOCAB)]

# Sinusoidal position encoding: 8 x 8, quantized to [-6, +6]
pos = []
for p in range(CTXLEN):
    row = []
    for d in range(DMODEL):
        angle = p / (100.0 ** ((d // 2 * 2) / DMODEL))
        val = math.sin(angle) if d % 2 == 0 else math.cos(angle)
        row.append(int(round(val * 6)))
    pos.append(row)

# Per-layer weights
layers = []
for _ in range(NLAYERS):
    L = {}
    for name in ['wq', 'wk', 'wv', 'wo']:
        L[name] = [[random.choice([-2,-1,-1,0,0,1,1,2])
                     for _ in range(DMODEL)] for _ in range(DMODEL)]
    # BN attn: scale near 1, small bias
    L['bn_a_s'] = [random.choice([1, 1, 1, 2]) for _ in range(DMODEL)]
    L['bn_a_b'] = [random.choice([-1, 0, 0, 0, 1]) for _ in range(DMODEL)]
    # FFN up: 32 x 8
    L['wup'] = [[random.choice([-2,-1,-1,0,0,1,1,2])
                  for _ in range(DMODEL)] for _ in range(DFFN)]
    # FFN down: 8 x 32
    L['wdn'] = [[random.choice([-2,-1,-1,0,0,1,1,2])
                  for _ in range(DFFN)] for _ in range(DMODEL)]
    # BN ffn
    L['bn_f_s'] = [random.choice([1, 1, 1, 2]) for _ in range(DMODEL)]
    L['bn_f_b'] = [random.choice([-1, 0, 0, 0, 1]) for _ in range(DMODEL)]
    layers.append(L)

# LM head: 32 x 8, range [-3, +3]
lm_head = [[random.choice([-3,-2,-1,0,1,2,3])
             for _ in range(DMODEL)] for _ in range(VOCAB)]


# ── Encoding ──

def encode_int8(v):
    v = int(round(v))
    return max(-128, min(127, v)) & 0xFF

def encode_fp8_e4m3(val):
    if val == 0: return 0x00
    s = int(val < 0); val = abs(val)
    if val >= 448: return (s << 7) | 0x7E
    if val < 2**-6 / 8: return s << 7
    if val < 2**-6:
        m = max(1, min(7, int(round(val / 2**-6 * 8))))
        return (s << 7) | m
    e = int(math.floor(math.log2(val)))
    eb = max(1, min(15, e + 7))
    m = int(round((val / 2.0**(eb-7) - 1.0) * 8))
    if m > 7: m = 0; eb += 1
    if eb > 15: return (s << 7) | 0x7E
    return (s << 7) | (eb << 3) | max(0, m)

def encode_fp8_e5m2(val):
    if val == 0: return 0x00
    s = int(val < 0); val = abs(val)
    if val >= 57344: return (s << 7) | 0x7B
    if val < 2**-14 / 4: return s << 7
    if val < 2**-14:
        m = max(1, min(3, int(round(val / 2**-14 * 4))))
        return (s << 7) | m
    e = int(math.floor(math.log2(val)))
    eb = max(1, min(30, e + 15))
    m = int(round((val / 2.0**(eb-15) - 1.0) * 4))
    if m > 3: m = 0; eb += 1
    if eb > 30: return (s << 7) | 0x7B
    return (s << 7) | (eb << 2) | max(0, m)

def encode_log8(val):
    if val == 0: return 0x00
    s = int(val < 0); val = abs(val)
    idx = max(1, min(127, int(round(math.log2(val) * 8 + 63))))
    return (s << 7) | idx

def pk4(b0, b1, b2, b3):
    return (b0&0xFF)|((b1&0xFF)<<8)|((b2&0xFF)<<16)|((b3&0xFF)<<24)


# ── Header generation ──

def gen_header(fmt, enc):
    o = []
    o.append("// Auto-generated by gen_weights_qnn_llm.py")
    o.append("// QNN-LLM: Quantized 2-layer transformer decoder")
    o.append("// Format: %s | d_model=8, 2-head, d_ffn=32, vocab=32" % fmt)
    o.append("// DO NOT EDIT")
    o.append("")
    g = "WEIGHTS_%s_QNN_LLM_H" % fmt.upper()
    o.append("#ifndef %s" % g)
    o.append("#define %s" % g)
    o.append("#include <stdint.h>")
    o.append("")

    # Constants
    o.append("#define QNN_VOCAB   %d" % VOCAB)
    o.append("#define QNN_DMODEL  %d" % DMODEL)
    o.append("#define QNN_NHEADS  %d" % NHEADS)
    o.append("#define QNN_HDIM    %d" % HDIM)
    o.append("#define QNN_NLAYERS %d" % NLAYERS)
    o.append("#define QNN_DFFN    %d" % DFFN)
    o.append("#define QNN_CTXLEN  %d" % CTXLEN)
    o.append("#define QNN_PLEN    %d" % PLEN)
    o.append("#define QNN_GLEN    %d" % GLEN)
    o.append("#define QNN_DW      %d  // words per d_model vector" % DW)
    o.append("")

    # Offsets
    o.append("// Flat weight array offsets (word index)")
    o.append("#define QW_EMB    %d" % OFF_EMB)
    o.append("#define QW_POS    %d" % OFF_POS)
    o.append("#define QW_L(l)   (%d + (l) * %d)" % (OFF_L0, WLAYER))
    o.append("#define QW_LM     %d" % OFF_LM)
    o.append("#define QW_PROMPT %d" % OFF_PROMPT)
    o.append("#define QW_TOTAL  %d" % TOTAL)
    o.append("")
    o.append("// Per-layer relative offsets")
    o.append("#define QL_WQ   %d" % LR_WQ)
    o.append("#define QL_WK   %d" % LR_WK)
    o.append("#define QL_WV   %d" % LR_WV)
    o.append("#define QL_WO   %d" % LR_WO)
    o.append("#define QL_BNA  %d" % LR_BNA)
    o.append("#define QL_WUP  %d" % LR_WUP)
    o.append("#define QL_WDN  %d" % LR_WDN)
    o.append("#define QL_BNF  %d" % LR_BNF)
    o.append("")

    # Build flat word array
    words = []

    # Embeddings: 32 x 2 words
    for t in range(VOCAB):
        for g in range(DW):
            words.append(pk4(*[enc(emb[t][g*4+d]) for d in range(4)]))

    # Position encoding: 8 x 2 words
    for p in range(CTXLEN):
        for g in range(DW):
            words.append(pk4(*[enc(pos[p][g*4+d]) for d in range(4)]))

    # Layers
    for l in range(NLAYERS):
        L = layers[l]
        # W_Q, W_K, W_V, W_O
        for proj in ['wq', 'wk', 'wv', 'wo']:
            for r in range(DMODEL):
                for g in range(DW):
                    words.append(pk4(*[enc(L[proj][r][g*4+d]) for d in range(4)]))
        # BN attn: scale_lo, scale_hi, bias_lo, bias_hi
        for g in range(DW):
            words.append(pk4(*[enc(L['bn_a_s'][g*4+d]) for d in range(4)]))
        for g in range(DW):
            words.append(pk4(*[enc(L['bn_a_b'][g*4+d]) for d in range(4)]))
        # W_FFN_UP: 32 x 2 words
        for r in range(DFFN):
            for g in range(DW):
                words.append(pk4(*[enc(L['wup'][r][g*4+d]) for d in range(4)]))
        # W_FFN_DOWN: 8 x 8 words (8 outputs x 32/4 groups)
        for r in range(DMODEL):
            for g in range(DFFN // 4):
                words.append(pk4(*[enc(L['wdn'][r][g*4+d]) for d in range(4)]))
        # BN ffn
        for g in range(DW):
            words.append(pk4(*[enc(L['bn_f_s'][g*4+d]) for d in range(4)]))
        for g in range(DW):
            words.append(pk4(*[enc(L['bn_f_b'][g*4+d]) for d in range(4)]))

    # LM head: 32 x 2 words
    for t in range(VOCAB):
        for g in range(DW):
            words.append(pk4(*[enc(lm_head[t][g*4+d]) for d in range(4)]))

    # Prompt: 4 token IDs packed
    words.append(pk4(PROMPT[0], PROMPT[1], PROMPT[2], PROMPT[3]))

    assert len(words) == TOTAL, "Expected %d, got %d" % (TOTAL, len(words))

    # Emit array
    o.append("// Weights: %d words = %d bytes (all in IMEM as const)" % (TOTAL, TOTAL*4))
    o.append("static const uint32_t qw_%s[%d] = {" % (fmt, TOTAL))

    sec = {OFF_EMB: "Embeddings (%d words)" % (VOCAB*DW),
           OFF_POS: "Position Encoding (%d words)" % (CTXLEN*DW),
           OFF_L0: "Layer 0 (%d words)" % WLAYER,
           OFF_L1: "Layer 1 (%d words)" % WLAYER,
           OFF_LM: "LM Head (%d words)" % (VOCAB*DW),
           OFF_PROMPT: "Prompt (1 word)"}

    for i, w in enumerate(words):
        if i in sec:
            o.append("    // --- %s ---" % sec[i])
        o.append("    0x%08X%s" % (w, "," if i < len(words)-1 else ""))
    o.append("};")
    o.append("")
    o.append("#endif // %s" % g)
    o.append("")
    return "\n".join(o)


# ── Main ──

FORMATS = {
    "mxint8":       encode_int8,
    "mxfp8_e4m3":   encode_fp8_e4m3,
    "mxfp8_e5m2":   encode_fp8_e5m2,
    "mxlog8":       encode_log8,
    "mxlog8_logdom": encode_log8,
}

if __name__ == "__main__":
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "weights")
    os.makedirs(out, exist_ok=True)

    print("QNN-LLM Weight Generator")
    print("  Architecture: %d-layer transformer, d=%d, %d-head, ffn=%d, vocab=%d" %
          (NLAYERS, DMODEL, NHEADS, DFFN, VOCAB))
    print("  Const data: %d words = %d bytes (IMEM)" % (TOTAL, TOTAL*4))
    print("  Fault targets: %d bits/format, %d total" % (TOTAL*32, TOTAL*32*5))
    print()

    for fmt, enc in FORMATS.items():
        path = os.path.join(out, "weights_%s_qnn_llm.h" % fmt)
        with open(path, "w") as f:
            f.write(gen_header(fmt, enc))
        print("  %s" % os.path.basename(path))

    print("\nDone. %d headers, %d bytes/format." % (len(FORMATS), TOTAL*4))
