// SPDX-License-Identifier: Apache-2.0
// Fault Analysis of Microscaling Formats on a RISC-V SoC
// Authors: Dillibabu Shanmugam, Patrick Schaumont
// Affiliation: Worcester Polytechnic Institute (WPI), USA

// =============================================================================
// MX Unified Coprocessor Package
// =============================================================================
//
// Defines instruction encoding, format constants, and helper functions for a
// unified MX (Microscaling) coprocessor that supports all five OCP MX element
// formats through a single CV-X-IF port on the CVE2 (Ibex) core.
//
// Instruction encoding: R-type on custom-0 opcode (0x0B)
//
//   31      25 24  20 19  15 14  12 11   7 6    0
//  +---------+------+------+------+------+-------+
//  | funct7  | rs2  | rs1  |funct3|  rd  |0001011|
//  +---------+------+------+------+------+-------+
//
//  funct7 layout:
//    [6:5] = 00        (reserved, must be zero)
//    [4:2] = format    (mx_fmt_e: which MX element encoding)
//    [1]   = 0         (reserved)
//    [0]   = group     (0 = base ops, 1 = extended ops)
//
//  Operation = {funct7[0], funct3} → 4-bit mx_op_e selector
//
// Operand conventions:
//   rs1 = 4 packed 8-bit MX elements {e3, e2, e1, e0}   (or special per op)
//   rs2 = 4 packed 8-bit MX elements {e3, e2, e1, e0}   (or special per op)
//   rd  = 32-bit result (dot product, packed elements, scalar, or mask)
//
// Shared exponent handling:
//   MX blocks use an E8M0 shared exponent (8-bit, bias 127) that scales all
//   elements in a block.  The coprocessor maintains an internal SE register
//   pair {se_b, se_a} loaded via MX_SET_SE.  Subsequent DOT4/MACS operations
//   incorporate the shared exponent scaling automatically:
//     linear_dot4 = sum(decode(a[i]) * decode(b[i])) * 2^(se_a + se_b - 254)
//
// Copyright 2026.  All rights reserved.
// =============================================================================

package mx_pkg;

  // ==========================================================================
  // Opcode
  // ==========================================================================
  localparam logic [6:0] MX_OPCODE = 7'b000_1011;  // custom-0 = 0x0B

  // ==========================================================================
  // MX Format Select  (funct7[4:2])
  // ==========================================================================
  //
  //  Format          Element Layout       Decode Formula                          Reduction
  //  ──────────────  ───────────────────  ─────────────────────────────────────  ──────────
  //  MXINT8          1S.7I (signed int)   e * 2^(se - 127)                      MUL + ADD
  //  MXFP8-E4M3     1S.4E.3M (float)     (1 + M/8) * 2^(se - 127 + E - 7)     MUL + ADD
  //  MXFP8-E5M2     1S.5E.2M (float)     (1 + M/4) * 2^(se - 127 + E - 15)    MUL + ADD
  //  LOG8-SUM        1S.4FI.3FE (log)     LUT[FE] * 2^(se - 127 + FI)          ADD + SUM (Dally)
  //  LOG8-MAX        1S.4FI.3FE (log)     same as LOG8-SUM                      ADD + MAX (ours)
  //
  //  LOG8-SUM: Dally's Log4.3 pipeline — products via 7-bit addition in log
  //            domain, then EXP_LUT converts to linear, then linear summation.
  //  LOG8-MAX: Same Log4.3 element encoding, but replaces the LUT-based
  //            summation pipeline with a binary comparator tree (pure max).
  //            Non-winning terms are discarded — fault containment property.

  typedef enum logic [2:0] {
    MX_FMT_INT8     = 3'b000,
    MX_FMT_FP8_E4M3 = 3'b001,
    MX_FMT_FP8_E5M2 = 3'b010,
    MX_FMT_LOG8_SUM  = 3'b011,   // Dally's Log4.3: ADD + linear SUM via EXP_LUT
    MX_FMT_LOG8_MAX  = 3'b100    // Our variant:    ADD + MAX via comparator tree
  } mx_fmt_e;

  localparam int unsigned MX_NUM_FORMATS = 5;

  // ==========================================================================
  // funct7 field helpers
  // ==========================================================================
  //
  //  funct7 = { 2'b00, format[2:0], 1'b0, group }
  //
  //  Example funct7 values:
  //    MXINT8       base: 7'b00_000_0_0 = 0x00
  //    MXINT8       ext:  7'b00_000_0_1 = 0x01
  //    MXFP8-E4M3   base: 7'b00_001_0_0 = 0x04
  //    MXFP8-E4M3   ext:  7'b00_001_0_1 = 0x05
  //    MXFP8-E5M2   base: 7'b00_010_0_0 = 0x08
  //    MXFP8-E5M2   ext:  7'b00_010_0_1 = 0x09
  //    MXLOG8        base: 7'b00_011_0_0 = 0x0C
  //    MXLOG8        ext:  7'b00_011_0_1 = 0x0D
  //    MXLOG8-logdom base: 7'b00_100_0_0 = 0x10
  //    MXLOG8-logdom ext:  7'b00_100_0_1 = 0x11

  // Extract format from funct7
  function automatic mx_fmt_e get_format(input logic [6:0] funct7);
    return mx_fmt_e'(funct7[4:2]);
  endfunction

  // Extract operation group bit from funct7
  function automatic logic get_group(input logic [6:0] funct7);
    return funct7[0];
  endfunction

  // Check funct7 reserved bits are zero
  function automatic logic funct7_reserved_ok(input logic [6:0] funct7);
    return (funct7[6:5] == 2'b00) && (funct7[1] == 1'b0);
  endfunction

  // ==========================================================================
  // Operation Select  ({funct7[0], funct3} → 4-bit enum)
  // ==========================================================================

  typedef enum logic [3:0] {
    // ---- Base operations (funct7[0] = 0) ----
    MX_OP_DOT4    = 4'b0_000,  // dot(rs1, rs2) using pre-set SE pair → rd (32-bit)
    MX_OP_MUL4    = 4'b0_001,  // 4 element-wise multiplies → rd (4 packed results)
    MX_OP_ADD4    = 4'b0_010,  // 4 element-wise adds → rd (4 packed results)
    MX_OP_SUB4    = 4'b0_011,  // 4 element-wise subs → rd (4 packed results)
    MX_OP_RELU4   = 4'b0_100,  // 4 element-wise ReLU → rd (4 packed results)
    MX_OP_ABS4    = 4'b0_101,  // 4 element-wise abs → rd (4 packed results)
    MX_OP_MIN4    = 4'b0_110,  // 4 element-wise min → rd (4 packed results)
    MX_OP_MAX4    = 4'b0_111,  // 4 element-wise max → rd (4 packed results)

    // ---- Extended operations (funct7[0] = 1) ----
    MX_OP_MACS    = 4'b1_000,  // acc += dot4(rs1, rs2, se_a, se_b) → rd = acc
    MX_OP_MACC    = 4'b1_001,  // clear acc, rd = 0
    MX_OP_SET_SE  = 4'b1_010,  // se_a ← rs1[7:0], se_b ← rs1[15:8], rd = {se_b, se_a}
    MX_OP_DECODE  = 4'b1_011,  // decode rs1[7:0] with se = rs2[7:0] → rd (32-bit linear)
    MX_OP_CVT_LIN = 4'b1_100,  // element rs1[7:0] → 32-bit linear (no SE scaling)
    MX_OP_CVT_ENC = 4'b1_101,  // linear rs1[15:0] → element byte in rd[7:0]
    MX_OP_CMP4    = 4'b1_110,  // compare 4 element pairs → rd[3:0] mask (a[i] > b[i])
    MX_OP_MACC_RD = 4'b1_111   // read acc → rd = acc (no clear)
  } mx_op_e;

  // ==========================================================================
  // MX Block Constants
  // ==========================================================================

  // E8M0 shared exponent
  localparam int unsigned MX_SE_BIAS      = 127;  // shared exponent bias
  localparam int unsigned MX_SE_BITS      = 8;    // shared exponent width

  // SIMD lane count (4 elements per block, 4 lanes)
  localparam int unsigned MX_LANES        = 4;

  // Combined SE scaling for dot product: 2^(se_a + se_b - 2*MX_SE_BIAS)
  localparam int unsigned MX_SE_DOT_BIAS  = 2 * MX_SE_BIAS;  // 254

  // ==========================================================================
  // MXINT8 Constants
  // ==========================================================================
  // Element: 1S.7I  (signed 8-bit integer, two's complement)
  // Decode:  value = element * 2^(shared_exp - 127)
  // Range:   [-128, +127] * 2^(se-127)

  // ==========================================================================
  // MXFP8-E4M3 Constants
  // ==========================================================================
  // Element: 1S.4E.3M  (IEEE-like FP8, no infinity)
  // Decode:  (1 + M/8) * 2^(E - 7)  scaled by  2^(se - 127)
  // NaN:     E=15, M=7 (0xFF)
  // Max:     ±448

  localparam int unsigned E4M3_EXP_BITS   = 4;
  localparam int unsigned E4M3_MANT_BITS  = 3;
  localparam int unsigned E4M3_BIAS       = 7;
  localparam int unsigned E4M3_EMAX       = 15;

  // ==========================================================================
  // MXFP8-E5M2 Constants
  // ==========================================================================
  // Element: 1S.5E.2M  (IEEE-like FP8, has infinity)
  // Decode:  (1 + M/4) * 2^(E - 15)  scaled by  2^(se - 127)
  // Inf:     E=31, M=0
  // NaN:     E=31, M!=0
  // Max:     ±57344

  localparam int unsigned E5M2_EXP_BITS   = 5;
  localparam int unsigned E5M2_MANT_BITS  = 2;
  localparam int unsigned E5M2_BIAS       = 15;
  localparam int unsigned E5M2_EMAX       = 31;

  // ==========================================================================
  // LOG8-SUM / LOG8-MAX Constants (Dally's Log4.3 encoding)
  // ==========================================================================
  // Element: 1S.4FI.3FE  (logarithmic, LUT-based fractional decode)
  // Decode:  LUT[FE] * 2^(FI)  scaled by  2^(se - 127)
  //   where FI = element[6:3] (4-bit integer part)
  //         FE = element[2:0] (3-bit fractional part)
  //         S  = element[7]   (sign)
  //         element[6:0] = 0 → zero
  //
  // LOG8 LUT (3-bit fractional → fixed-point multiplier):
  //   FE=0: 1.000  (2^0.000)
  //   FE=1: 1.091  (2^0.125)
  //   FE=2: 1.189  (2^0.250)
  //   FE=3: 1.297  (2^0.375)
  //   FE=4: 1.414  (2^0.500)
  //   FE=5: 1.542  (2^0.625)
  //   FE=6: 1.682  (2^0.750)
  //   FE=7: 1.834  (2^0.875)
  //
  // LOG8-SUM: products via log addition, then EXP_LUT to linear, then sum (Dally)
  // LOG8-MAX: products via log addition, then binary comparator tree (pure max)

  localparam int unsigned LOG8_INT_BITS   = 4;   // FI field width
  localparam int unsigned LOG8_FRAC_BITS  = 3;   // FE field width
  localparam int unsigned LOG8_BIAS       = 63;  // log index bias
  localparam int unsigned LOG8_SCALE      = 8;   // log index scale factor
  localparam int unsigned LOG8_LUT_DEPTH  = 8;   // 2^LOG8_FRAC_BITS entries

  // 3-bit fractional decode LUT: FE → 8.8 fixed-point multiplier
  // LUT[i] = round(2^(i/8) * 256)
  localparam logic [15:0] LOG8_FRAC_LUT [8] = '{
    16'd256,   // FE=0: 2^(0/8) = 1.000 * 256
    16'd279,   // FE=1: 2^(1/8) = 1.091 * 256
    16'd304,   // FE=2: 2^(2/8) = 1.189 * 256
    16'd332,   // FE=3: 2^(3/8) = 1.297 * 256
    16'd362,   // FE=4: 2^(4/8) = 1.414 * 256
    16'd395,   // FE=5: 2^(5/8) = 1.542 * 256
    16'd431,   // FE=6: 2^(6/8) = 1.682 * 256
    16'd470    // FE=7: 2^(7/8) = 1.834 * 256
  };

  // Log-domain addition LUT (used for LOG8 lane-wise ADD4/SUB4 operations)
  // log_add_lut[d] = round(log2(1 + 2^(-d/8)) * 8)   for d = 0..31
  // Note: LOG8-MAX DOT4/MACS uses pure max, not this LUT
  localparam logic [4:0] LOG8_ADD_LUT [32] = '{
    5'd8,  5'd7,  5'd6,  5'd6,  5'd5,  5'd5,  5'd4,  5'd4,   // d=0..7
    5'd4,  5'd3,  5'd3,  5'd3,  5'd2,  5'd2,  5'd2,  5'd2,   // d=8..15
    5'd2,  5'd1,  5'd1,  5'd1,  5'd1,  5'd1,  5'd1,  5'd1,   // d=16..23
    5'd0,  5'd0,  5'd0,  5'd0,  5'd0,  5'd0,  5'd0,  5'd0    // d=24..31
  };

  // Log-domain subtraction LUT
  // log_sub_lut[d] = round(-log2(1 - 2^(-d/8)) * 8)  for d = 1..31
  // Index 0 = cancellation (result is zero)
  localparam logic [6:0] LOG8_SUB_LUT [32] = '{
    7'd127, 7'd29,  7'd21,  7'd17,  7'd14,  7'd12,  7'd10,  7'd9,    // d=0..7
    7'd8,   7'd7,   7'd6,   7'd6,   7'd5,   7'd5,   7'd4,   7'd4,    // d=8..15
    7'd3,   7'd3,   7'd3,   7'd2,   7'd2,   7'd2,   7'd2,   7'd2,    // d=16..23
    7'd1,   7'd1,   7'd1,   7'd1,   7'd1,   7'd1,   7'd1,   7'd1     // d=24..31
  };

  // ==========================================================================
  // Saturating 32-bit boundaries (MAC accumulator)
  // ==========================================================================
  localparam logic signed [32:0] INT32_MAX =  33'sh0_7FFF_FFFF;
  localparam logic signed [32:0] INT32_MIN = -33'sh1_0000_0000;

  // ==========================================================================
  // Scan chain parameters
  // ==========================================================================
  // Width of the coprocessor scan chain (all observable FFs)
  //   rs1_q(32) + rs2_q(32) + mac_acc_q(32) + se_a_q(8) + se_b_q(8)
  //   + instr_op_q(4) + fmt_q(3) + inflight_q(1) + rd_q(5) + id_q(4)
  // Total = 129 bits
  localparam int unsigned MX_SCAN_WIDTH = 129;

  // ==========================================================================
  // Format classification helpers
  // ==========================================================================

  function automatic logic is_valid_format(input logic [2:0] fmt);
    return (fmt <= 3'(MX_FMT_LOG8_MAX));
  endfunction

  function automatic logic is_int_format(input logic [2:0] fmt);
    return (fmt == 3'(MX_FMT_INT8));
  endfunction

  function automatic logic is_fp_format(input logic [2:0] fmt);
    return (fmt == 3'(MX_FMT_FP8_E4M3)) || (fmt == 3'(MX_FMT_FP8_E5M2));
  endfunction

  function automatic logic is_e5m2(input logic [2:0] fmt);
    return (fmt == 3'(MX_FMT_FP8_E5M2));
  endfunction

  function automatic logic is_log_format(input logic [2:0] fmt);
    return (fmt == 3'(MX_FMT_LOG8_SUM)) || (fmt == 3'(MX_FMT_LOG8_MAX));
  endfunction

  function automatic logic is_log8_max(input logic [2:0] fmt);
    return (fmt == 3'(MX_FMT_LOG8_MAX));
  endfunction

  // ==========================================================================
  // Operation classification helpers
  // ==========================================================================

  // Does this operation produce a 32-bit scalar result (vs 4 packed bytes)?
  function automatic logic is_scalar_result(input mx_op_e op);
    return (op == MX_OP_DOT4)    || (op == MX_OP_MACS)    ||
           (op == MX_OP_MACC)    || (op == MX_OP_SET_SE)   ||
           (op == MX_OP_DECODE)  || (op == MX_OP_CVT_LIN)  ||
           (op == MX_OP_CVT_ENC) || (op == MX_OP_MACC_RD);
  endfunction

  // Does this operation need rs2?
  function automatic logic needs_rs2(input mx_op_e op);
    return (op == MX_OP_DOT4)  || (op == MX_OP_MUL4) ||
           (op == MX_OP_ADD4)  || (op == MX_OP_SUB4) ||
           (op == MX_OP_MIN4)  || (op == MX_OP_MAX4) ||
           (op == MX_OP_MACS)  || (op == MX_OP_CMP4) ||
           (op == MX_OP_DECODE);
  endfunction

  // Does this operation use the internal SE register pair?
  function automatic logic uses_se(input mx_op_e op);
    return (op == MX_OP_DOT4) || (op == MX_OP_MACS);
  endfunction

  // Does this operation read/modify the MAC accumulator?
  function automatic logic is_mac_op(input mx_op_e op);
    return (op == MX_OP_MACS) || (op == MX_OP_MACC) || (op == MX_OP_MACC_RD);
  endfunction

endpackage
