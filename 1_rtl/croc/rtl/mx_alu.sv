// SPDX-License-Identifier: Apache-2.0
// Fault Analysis of Microscaling Formats on a RISC-V SoC
// Authors: Dillibabu Shanmugam, Patrick Schaumont
// Affiliation: Worcester Polytechnic Institute (WPI), USA

// =============================================================================
// MX Unified ALU — 5-format datapath
// =============================================================================
//
// Supports all five OCP MX element formats through a single combinational
// datapath with format-switched lane operations and DOT product paths.
//
// Formats:  MXINT8, MXFP8-E4M3, MXFP8-E5M2, LOG8-SUM (Dally), LOG8-MAX (ours)
//
// Internal sequential state:
//   - Shared exponent register pair {se_b_q, se_a_q}  (loaded by MX_SET_SE)
//   - MAC accumulator mac_acc_q                        (updated by MX_MACS)
//
// All lane operations (ADD4/SUB4/MUL4/MIN4/MAX4/RELU4/ABS4) are
// combinational and produce results in one cycle after operand register.
// MAC accumulator follows the X-IF commit/kill protocol.
//
// Adapted from: int8_simd_alu.sv, fp8_alu.sv, log8_alu.sv
// =============================================================================

module mx_alu
  import mx_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,

  // Operands (4 packed 8-bit elements each)
  input  logic [31:0] rs1_i,
  input  logic [31:0] rs2_i,

  // Control
  input  mx_op_e      op_i,
  input  mx_fmt_e     fmt_i,
  input  logic        valid_i,
  input  logic        mac_commit_i,
  input  logic        mac_kill_i,

  // Result
  output logic [31:0] result_o,

  // Scan chain observability
  output logic [7:0]  se_a_o,
  output logic [7:0]  se_b_o,
  output logic [31:0] mac_acc_o
);

  // =========================================================================
  // Format helper flags
  // =========================================================================
  logic fmt_is_e5m2;
  logic fmt_is_log8_max;
  assign fmt_is_e5m2      = (fmt_i == MX_FMT_FP8_E5M2);
  assign fmt_is_log8_max = (fmt_i == MX_FMT_LOG8_MAX);

  // =========================================================================
  // FP8 unpacked type
  // =========================================================================
  typedef struct packed {
    logic        sign;
    logic [4:0]  exp;
    logic [3:0]  mant;   // {implicit_1, fraction_bits}
    logic        is_zero;
    logic        is_nan;
    logic        is_inf;
  } fp8_unpacked_t;

  // =========================================================================
  // FP8 unpack: byte → unpacked representation
  // =========================================================================
  function automatic fp8_unpacked_t unpack_fp8(input logic [7:0] val, input logic e5m2);
    fp8_unpacked_t u;
    logic [4:0] raw_exp;

    u.sign = val[7];

    if (e5m2) begin
      raw_exp  = val[6:2];
      u.is_zero = (raw_exp == 5'd0) && (val[1:0] == 2'd0);
      u.is_nan  = (raw_exp == 5'd31) && (val[1:0] != 2'd0);
      u.is_inf  = (raw_exp == 5'd31) && (val[1:0] == 2'd0);
      if (raw_exp == 5'd0) begin
        u.exp  = 5'd1;
        u.mant = {1'b0, 1'b0, val[1:0]};
      end else begin
        u.exp  = raw_exp;
        u.mant = {1'b0, 1'b1, val[1:0]};
      end
    end else begin
      raw_exp  = {1'b0, val[6:3]};
      u.is_zero = (val[6:3] == 4'd0) && (val[2:0] == 3'd0);
      u.is_nan  = (val[6:3] == 4'd15) && (val[2:0] == 3'd7);
      u.is_inf  = 1'b0;
      if (val[6:3] == 4'd0) begin
        u.exp  = 5'd1;
        u.mant = {1'b0, 1'b0, val[2:0]};
      end else begin
        u.exp  = raw_exp;
        u.mant = {1'b0, 1'b1, val[2:0]};
      end
    end
    return u;
  endfunction

  // =========================================================================
  // FP8 pack: sign, exponent, mantissa → byte (with overflow saturation)
  // =========================================================================
  function automatic logic [7:0] pack_fp8(
    input logic sign,
    input logic signed [7:0] exp_in,
    input logic [7:0] mant_in,
    input logic e5m2
  );
    logic [7:0] result;
    logic [4:0] exp_out;
    int emax;

    emax = e5m2 ? 31 : 15;

    if (exp_in <= 0) begin
      exp_out = 5'd0;
      if (e5m2)
        result = {sign, 5'd0, 2'd0};
      else
        result = {sign, 4'd0, 3'd0};
    end else if (exp_in >= signed'({3'b0, emax[4:0]})) begin
      if (e5m2)
        result = {sign, 5'd31, 2'd0};    // Inf
      else
        result = {sign, 4'd15, 3'd6};    // max normal (not NaN)
    end else begin
      exp_out = exp_in[4:0];
      if (e5m2)
        result = {sign, exp_out, mant_in[1:0]};
      else
        result = {sign, exp_out[3:0], mant_in[2:0]};
    end
    return result;
  endfunction

  // =========================================================================
  // FP8 add/subtract (per-lane, combinational)
  // =========================================================================
  function automatic logic [7:0] fp8_addsub(
    input logic [7:0] a_byte, input logic [7:0] b_byte,
    input logic do_sub, input logic e5m2
  );
    fp8_unpacked_t a, b;
    logic eff_b_sign, same_sign, swap;
    logic [4:0] exp_diff, exp_max;
    logic [8:0] ext_big, ext_small, work;
    logic result_sign;
    logic signed [7:0] result_exp;
    logic [7:0] result;

    a = unpack_fp8(a_byte, e5m2);
    b = unpack_fp8(b_byte, e5m2);

    if (a.is_nan || b.is_nan) return 8'hFF;

    eff_b_sign = do_sub ? ~b.sign : b.sign;

    // Inf handling (E5M2 only)
    if (a.is_inf && b.is_inf) begin
      if (a.sign != eff_b_sign) return 8'hFF;
      else return {a.sign, 5'd31, 2'd0};
    end
    if (a.is_inf) return a_byte;
    if (b.is_inf) return {eff_b_sign, b_byte[6:0]};

    // Zero handling
    if (a.is_zero && b.is_zero) return 8'd0;
    if (a.is_zero) return {eff_b_sign, b_byte[6:0]};
    if (b.is_zero) return a_byte;

    // Align exponents
    same_sign = (a.sign == eff_b_sign);
    swap = (b.exp > a.exp) || ((b.exp == a.exp) && (b.mant > a.mant));

    if (swap) begin
      exp_max  = b.exp;
      exp_diff = b.exp - a.exp;
      ext_big   = {1'b0, b.mant, 4'b0};
      ext_small = ({1'b0, a.mant, 4'b0}) >> exp_diff;
      result_sign = eff_b_sign;
    end else begin
      exp_max  = a.exp;
      exp_diff = a.exp - b.exp;
      ext_big   = {1'b0, a.mant, 4'b0};
      ext_small = ({1'b0, b.mant, 4'b0}) >> exp_diff;
      result_sign = a.sign;
    end

    result_exp = signed'({3'b0, exp_max});

    if (same_sign) begin
      work = ext_big + ext_small;
      if (e5m2) begin
        if (work[7]) begin work = work >> 1; result_exp = result_exp + 1; end
        result = pack_fp8(result_sign, result_exp, {6'b0, work[5:4]}, 1'b1);
      end else begin
        if (work[8]) begin work = work >> 1; result_exp = result_exp + 1; end
        result = pack_fp8(result_sign, result_exp, {5'b0, work[6:4]}, 1'b0);
      end
    end else begin
      work = ext_big - ext_small;
      if (work == 9'd0) return 8'd0;

      // Normalize: shift until implicit 1 at expected position
      if (e5m2) begin
        if      (!work[6] && !work[5] && !work[4] && !work[3] && !work[2])
          begin work = work << 5; result_exp = result_exp - 5; end
        else if (!work[6] && !work[5] && !work[4] && !work[3])
          begin work = work << 4; result_exp = result_exp - 4; end
        else if (!work[6] && !work[5] && !work[4])
          begin work = work << 3; result_exp = result_exp - 3; end
        else if (!work[6] && !work[5])
          begin work = work << 2; result_exp = result_exp - 2; end
        else if (!work[6])
          begin work = work << 1; result_exp = result_exp - 1; end
        result = pack_fp8(result_sign, result_exp, {6'b0, work[5:4]}, 1'b1);
      end else begin
        if      (!work[7] && !work[6] && !work[5] && !work[4] && !work[3])
          begin work = work << 5; result_exp = result_exp - 5; end
        else if (!work[7] && !work[6] && !work[5] && !work[4])
          begin work = work << 4; result_exp = result_exp - 4; end
        else if (!work[7] && !work[6] && !work[5])
          begin work = work << 3; result_exp = result_exp - 3; end
        else if (!work[7] && !work[6])
          begin work = work << 2; result_exp = result_exp - 2; end
        else if (!work[7])
          begin work = work << 1; result_exp = result_exp - 1; end
        result = pack_fp8(result_sign, result_exp, {5'b0, work[6:4]}, 1'b0);
      end
    end
    return result;
  endfunction

  // =========================================================================
  // FP8 multiply (per-lane, combinational)
  // =========================================================================
  function automatic logic [7:0] fp8_mul(
    input logic [7:0] a_byte, input logic [7:0] b_byte, input logic e5m2
  );
    fp8_unpacked_t a, b;
    logic result_sign;
    logic signed [7:0] result_exp;
    logic [7:0] mant_prod;
    int bias;

    a = unpack_fp8(a_byte, e5m2);
    b = unpack_fp8(b_byte, e5m2);
    bias = e5m2 ? 15 : 7;

    if (a.is_nan || b.is_nan) return 8'hFF;
    if (a.is_inf || b.is_inf) begin
      if (a.is_zero || b.is_zero) return 8'hFF;
      return {a.sign ^ b.sign, e5m2 ? 7'h7C : 7'h78};
    end
    if (a.is_zero || b.is_zero) return 8'd0;

    result_sign = a.sign ^ b.sign;
    result_exp = signed'({3'b0, a.exp}) + signed'({3'b0, b.exp}) - signed'(8'(bias));
    mant_prod = {4'b0, a.mant} * {4'b0, b.mant};

    if (e5m2) begin
      if (mant_prod[5]) begin
        mant_prod = mant_prod >> 1; result_exp = result_exp + 1;
      end else if (!mant_prod[4]) begin
        if      (mant_prod[3]) begin mant_prod = mant_prod << 1; result_exp = result_exp - 1; end
        else if (mant_prod[2]) begin mant_prod = mant_prod << 2; result_exp = result_exp - 2; end
        else if (mant_prod[1]) begin mant_prod = mant_prod << 3; result_exp = result_exp - 3; end
      end
      return pack_fp8(result_sign, result_exp, {6'b0, mant_prod[3:2]}, 1'b1);
    end else begin
      if (mant_prod[7]) begin
        mant_prod = mant_prod >> 1; result_exp = result_exp + 1;
      end else if (!mant_prod[6]) begin
        if      (mant_prod[5]) begin mant_prod = mant_prod << 1; result_exp = result_exp - 1; end
        else if (mant_prod[4]) begin mant_prod = mant_prod << 2; result_exp = result_exp - 2; end
        else if (mant_prod[3]) begin mant_prod = mant_prod << 3; result_exp = result_exp - 3; end
      end
      return pack_fp8(result_sign, result_exp, {5'b0, mant_prod[5:3]}, 1'b0);
    end
  endfunction

  // =========================================================================
  // FP8 → 16-bit signed fixed-point (8.8 format, for DOT product)
  // =========================================================================
  function automatic logic signed [15:0] fp8_to_fixed16(
    input logic [7:0] val, input logic e5m2
  );
    fp8_unpacked_t u;
    logic [15:0] mag;
    int shift;

    u = unpack_fp8(val, e5m2);
    if (u.is_zero || u.is_nan) return 16'sd0;
    if (u.is_inf) return u.sign ? -16'sd32767 : 16'sd32767;

    if (e5m2)
      shift = signed'({3'b0, u.exp}) - 15 - 2 + 8;
    else
      shift = signed'({3'b0, u.exp}) - 7 - 3 + 8;

    mag = {12'd0, u.mant};
    if (shift > 0 && shift < 16)
      mag = mag << shift;
    else if (shift < 0 && shift > -16)
      mag = mag >> (-shift);
    else if (shift <= -16)
      mag = 16'd0;

    return u.sign ? -$signed({1'b0, mag}) : $signed({1'b0, mag});
  endfunction

  // =========================================================================
  // FP8 signed compare: returns 1 if a > b
  // =========================================================================
  function automatic logic fp8_gt(
    input logic [7:0] a, input logic [7:0] b, input logic e5m2
  );
    fp8_unpacked_t ua, ub;
    ua = unpack_fp8(a, e5m2);
    ub = unpack_fp8(b, e5m2);

    if (ua.is_nan || ub.is_nan) return 1'b0;
    if (ua.is_zero && ub.is_zero) return 1'b0;
    if (!ua.sign && ub.sign) return 1'b1;
    if (ua.sign && !ub.sign) return 1'b0;
    if (!ua.sign) begin
      if (ua.exp > ub.exp) return 1'b1;
      if (ua.exp < ub.exp) return 1'b0;
      return (ua.mant > ub.mant);
    end else begin
      if (ua.exp < ub.exp) return 1'b1;
      if (ua.exp > ub.exp) return 1'b0;
      return (ua.mant < ub.mant);
    end
  endfunction

  // =========================================================================
  // LOG8 inline ROM LUTs (from log8_alu.sv — proven correct)
  // =========================================================================

  // log-domain addition correction: ADD_LUT[d] ≈ round(log2(1 + 2^(-d/8)) * 8)
  localparam logic [6:0] ADD_LUT [128] = '{
    7'd  8, 7'd  8, 7'd  7, 7'd  7, 7'd  6, 7'd  6, 7'd  5, 7'd  5,
    7'd  5, 7'd  4, 7'd  4, 7'd  4, 7'd  3, 7'd  3, 7'd  3, 7'd  3,
    7'd  3, 7'd  2, 7'd  2, 7'd  2, 7'd  2, 7'd  2, 7'd  2, 7'd  1,
    7'd  1, 7'd  1, 7'd  1, 7'd  1, 7'd  1, 7'd  1, 7'd  1, 7'd  1,
    7'd  1, 7'd  1, 7'd  1, 7'd  1, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0
  };

  // log-domain subtraction correction: SUB_LUT[d] ≈ round(-log2(1 - 2^(-d/8)) * 8)
  localparam logic [6:0] SUB_LUT [128] = '{
    7'd127, 7'd 29, 7'd 21, 7'd 17, 7'd 14, 7'd 12, 7'd 10, 7'd  9,
    7'd  8, 7'd  7, 7'd  6, 7'd  6, 7'd  5, 7'd  5, 7'd  4, 7'd  4,
    7'd  3, 7'd  3, 7'd  3, 7'd  2, 7'd  2, 7'd  2, 7'd  2, 7'd  2,
    7'd  2, 7'd  1, 7'd  1, 7'd  1, 7'd  1, 7'd  1, 7'd  1, 7'd  1,
    7'd  1, 7'd  1, 7'd  1, 7'd  1, 7'd  1, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0,
    7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0, 7'd  0
  };

  // log index → 16-bit linear magnitude: EXP_LUT[L] = round(2^((L-63)/8) * 256)
  localparam logic [15:0] EXP_LUT [128] = '{
    16'd    1, 16'd    1, 16'd    1, 16'd    1, 16'd    2, 16'd    2, 16'd    2, 16'd    2,
    16'd    2, 16'd    2, 16'd    3, 16'd    3, 16'd    3, 16'd    3, 16'd    4, 16'd    4,
    16'd    4, 16'd    5, 16'd    5, 16'd    6, 16'd    6, 16'd    7, 16'd    7, 16'd    8,
    16'd    9, 16'd   10, 16'd   10, 16'd   11, 16'd   12, 16'd   13, 16'd   15, 16'd   16,
    16'd   17, 16'd   19, 16'd   21, 16'd   23, 16'd   25, 16'd   27, 16'd   29, 16'd   32,
    16'd   35, 16'd   38, 16'd   41, 16'd   45, 16'd   49, 16'd   54, 16'd   59, 16'd   64,
    16'd   70, 16'd   76, 16'd   83, 16'd   91, 16'd   99, 16'd  108, 16'd  117, 16'd  128,
    16'd  140, 16'd  152, 16'd  166, 16'd  181, 16'd  197, 16'd  215, 16'd  235, 16'd  256,
    16'd  279, 16'd  304, 16'd  332, 16'd  362, 16'd  395, 16'd  431, 16'd  470, 16'd  512,
    16'd  558, 16'd  609, 16'd  664, 16'd  724, 16'd  790, 16'd  861, 16'd  939, 16'd 1024,
    16'd 1117, 16'd 1218, 16'd 1328, 16'd 1448, 16'd 1579, 16'd 1722, 16'd 1878, 16'd 2048,
    16'd 2233, 16'd 2435, 16'd 2656, 16'd 2896, 16'd 3158, 16'd 3444, 16'd 3756, 16'd 4096,
    16'd 4467, 16'd 4871, 16'd 5312, 16'd 5793, 16'd 6317, 16'd 6889, 16'd 7512, 16'd 8192,
    16'd 8933, 16'd 9742, 16'd10624, 16'd11585, 16'd12634, 16'd13777, 16'd15024, 16'd16384,
    16'd17867, 16'd19484, 16'd21247, 16'd23170, 16'd25268, 16'd27554, 16'd30048, 16'd32768,
    16'd35734, 16'd38968, 16'd42495, 16'd46341, 16'd50535, 16'd55109, 16'd60097, 16'd65535
  };

  // unsigned 8-bit → log index: LOG_LUT[v] = round(log2(v) * 8 + 63)
  localparam logic [6:0] LOG_LUT [256] = '{
    7'd  0, 7'd 63, 7'd 71, 7'd 76, 7'd 79, 7'd 82, 7'd 84, 7'd 85,
    7'd 87, 7'd 88, 7'd 90, 7'd 91, 7'd 92, 7'd 93, 7'd 93, 7'd 94,
    7'd 95, 7'd 96, 7'd 96, 7'd 97, 7'd 98, 7'd 98, 7'd 99, 7'd 99,
    7'd100, 7'd100, 7'd101, 7'd101, 7'd101, 7'd102, 7'd102, 7'd103,
    7'd103, 7'd103, 7'd104, 7'd104, 7'd104, 7'd105, 7'd105, 7'd105,
    7'd106, 7'd106, 7'd106, 7'd106, 7'd107, 7'd107, 7'd107, 7'd107,
    7'd108, 7'd108, 7'd108, 7'd108, 7'd109, 7'd109, 7'd109, 7'd109,
    7'd109, 7'd110, 7'd110, 7'd110, 7'd110, 7'd110, 7'd111, 7'd111,
    7'd111, 7'd111, 7'd111, 7'd112, 7'd112, 7'd112, 7'd112, 7'd112,
    7'd112, 7'd113, 7'd113, 7'd113, 7'd113, 7'd113, 7'd113, 7'd113,
    7'd114, 7'd114, 7'd114, 7'd114, 7'd114, 7'd114, 7'd114, 7'd115,
    7'd115, 7'd115, 7'd115, 7'd115, 7'd115, 7'd115, 7'd115, 7'd116,
    7'd116, 7'd116, 7'd116, 7'd116, 7'd116, 7'd116, 7'd116, 7'd116,
    7'd117, 7'd117, 7'd117, 7'd117, 7'd117, 7'd117, 7'd117, 7'd117,
    7'd117, 7'd118, 7'd118, 7'd118, 7'd118, 7'd118, 7'd118, 7'd118,
    7'd118, 7'd118, 7'd118, 7'd119, 7'd119, 7'd119, 7'd119, 7'd119,
    7'd119, 7'd119, 7'd119, 7'd119, 7'd119, 7'd119, 7'd120, 7'd120,
    7'd120, 7'd120, 7'd120, 7'd120, 7'd120, 7'd120, 7'd120, 7'd120,
    7'd120, 7'd120, 7'd121, 7'd121, 7'd121, 7'd121, 7'd121, 7'd121,
    7'd121, 7'd121, 7'd121, 7'd121, 7'd121, 7'd121, 7'd121, 7'd122,
    7'd122, 7'd122, 7'd122, 7'd122, 7'd122, 7'd122, 7'd122, 7'd122,
    7'd122, 7'd122, 7'd122, 7'd122, 7'd122, 7'd122, 7'd123, 7'd123,
    7'd123, 7'd123, 7'd123, 7'd123, 7'd123, 7'd123, 7'd123, 7'd123,
    7'd123, 7'd123, 7'd123, 7'd123, 7'd123, 7'd123, 7'd124, 7'd124,
    7'd124, 7'd124, 7'd124, 7'd124, 7'd124, 7'd124, 7'd124, 7'd124,
    7'd124, 7'd124, 7'd124, 7'd124, 7'd124, 7'd124, 7'd124, 7'd125,
    7'd125, 7'd125, 7'd125, 7'd125, 7'd125, 7'd125, 7'd125, 7'd125,
    7'd125, 7'd125, 7'd125, 7'd125, 7'd125, 7'd125, 7'd125, 7'd125,
    7'd125, 7'd126, 7'd126, 7'd126, 7'd126, 7'd126, 7'd126, 7'd126,
    7'd126, 7'd126, 7'd126, 7'd126, 7'd126, 7'd126, 7'd126, 7'd126,
    7'd126, 7'd126, 7'd126, 7'd126, 7'd126, 7'd126, 7'd127, 7'd127,
    7'd127, 7'd127, 7'd127, 7'd127, 7'd127, 7'd127, 7'd127, 7'd127
  };

  // =========================================================================
  // LOG8 add/subtract in log domain (combinational)
  // =========================================================================
  function automatic logic [7:0] log8_addsub(
    input logic a_s, input logic [6:0] a_l,
    input logic b_s, input logic [6:0] b_l,
    input logic do_sub
  );
    logic eff_b_sign, same_sign, a_larger;
    logic [6:0] max_log, diff, result_log;
    logic result_sign;

    eff_b_sign = do_sub ? ~b_s : b_s;

    if (a_l == 7'd0 && b_l == 7'd0) return 8'd0;
    if (a_l == 7'd0) return {eff_b_sign, b_l};
    if (b_l == 7'd0) return {a_s, a_l};

    same_sign = (a_s == eff_b_sign);
    a_larger  = (a_l >= b_l);
    max_log   = a_larger ? a_l : b_l;
    diff      = a_larger ? (a_l - b_l) : (b_l - a_l);
    result_sign = a_larger ? a_s : eff_b_sign;

    if (same_sign) begin
      // Magnitudes add
      result_log = max_log + ADD_LUT[diff];
      if ({1'b0, max_log} + {1'b0, ADD_LUT[diff]} > 8'd127)
        result_log = 7'd127;
    end else begin
      if (diff == 7'd0) return 8'd0;  // complete cancellation
      if (SUB_LUT[diff] >= max_log)
        result_log = 7'd0;
      else
        result_log = max_log - SUB_LUT[diff];
    end

    return {result_sign, result_log};
  endfunction

  // =========================================================================
  // Internal state
  // =========================================================================
  logic [7:0]        se_a_q, se_b_q;
  logic signed [31:0] mac_acc_q;
  logic               mac_pending_q;

  assign se_a_o   = se_a_q;
  assign se_b_o   = se_b_q;
  assign mac_acc_o = $unsigned(mac_acc_q);

  // =========================================================================
  // Byte extraction
  // =========================================================================
  logic [7:0] a_byte [4];
  logic [7:0] b_byte [4];

  always_comb begin
    for (int i = 0; i < 4; i++) begin
      a_byte[i] = rs1_i[i*8 +: 8];
      b_byte[i] = rs2_i[i*8 +: 8];
    end
  end

  // =========================================================================
  // Pre-computed intermediates
  // =========================================================================

  // INT8
  logic signed [7:0]  int8_a [4];
  logic signed [7:0]  int8_b [4];
  logic signed [15:0] int8_mul_full [4];

  // LOG8
  logic        lg_a_sign [4], lg_b_sign [4];
  logic [6:0]  lg_a_log  [4], lg_b_log  [4];
  logic        lg_a_zero [4], lg_b_zero [4];
  logic [7:0]  lg_mul_sum [4];
  logic [7:0]  lg_mul_biased [4];

  always_comb begin
    for (int i = 0; i < 4; i++) begin
      // INT8 decode
      int8_a[i]       = signed'(a_byte[i]);
      int8_b[i]       = signed'(b_byte[i]);
      int8_mul_full[i] = int8_a[i] * int8_b[i];

      // LOG8 decode
      lg_a_sign[i] = a_byte[i][7];
      lg_a_log[i]  = a_byte[i][6:0];
      lg_b_sign[i] = b_byte[i][7];
      lg_b_log[i]  = b_byte[i][6:0];
      lg_a_zero[i] = (lg_a_log[i] == 7'd0);
      lg_b_zero[i] = (lg_b_log[i] == 7'd0);

      // LOG8 MUL intermediate
      lg_mul_sum[i]    = {1'b0, lg_a_log[i]} + {1'b0, lg_b_log[i]};
      lg_mul_biased[i] = (lg_mul_sum[i] <= 8'(LOG8_BIAS)) ? 8'd0
                        : lg_mul_sum[i] - 8'(LOG8_BIAS);
      if (lg_mul_biased[i] > 8'd127) lg_mul_biased[i] = 8'd127;
    end
  end

  // =========================================================================
  // Per-lane computation (format × operation switch)
  // =========================================================================
  logic [7:0] lane_result [4];

  always_comb begin
    for (int i = 0; i < 4; i++) begin
      lane_result[i] = 8'd0;

      case (fmt_i)
        // ---------------------------------------------------------------
        // MXINT8: signed 8-bit integer lane ops
        // ---------------------------------------------------------------
        MX_FMT_INT8: begin
          case (op_i)
            MX_OP_ADD4:  lane_result[i] = int8_a[i] + int8_b[i];
            MX_OP_SUB4:  lane_result[i] = int8_a[i] - int8_b[i];
            MX_OP_MUL4:  lane_result[i] = int8_mul_full[i][7:0];
            MX_OP_RELU4: lane_result[i] = a_byte[i][7] ? 8'd0 : a_byte[i];
            MX_OP_ABS4:  lane_result[i] = (int8_a[i] == -8'sd128) ? 8'd127
                                         : (int8_a[i] < 0) ? 8'(-int8_a[i])
                                         : a_byte[i];
            MX_OP_MIN4:  lane_result[i] = (int8_a[i] < int8_b[i]) ? a_byte[i] : b_byte[i];
            MX_OP_MAX4:  lane_result[i] = (int8_a[i] > int8_b[i]) ? a_byte[i] : b_byte[i];
            default:     lane_result[i] = 8'd0;
          endcase
        end

        // ---------------------------------------------------------------
        // MXFP8-E4M3 / MXFP8-E5M2: FP8 lane ops
        // ---------------------------------------------------------------
        MX_FMT_FP8_E4M3, MX_FMT_FP8_E5M2: begin
          case (op_i)
            MX_OP_ADD4:  lane_result[i] = fp8_addsub(a_byte[i], b_byte[i], 1'b0, fmt_is_e5m2);
            MX_OP_SUB4:  lane_result[i] = fp8_addsub(a_byte[i], b_byte[i], 1'b1, fmt_is_e5m2);
            MX_OP_MUL4:  lane_result[i] = fp8_mul(a_byte[i], b_byte[i], fmt_is_e5m2);
            MX_OP_RELU4: lane_result[i] = a_byte[i][7] ? 8'd0 : a_byte[i];
            MX_OP_ABS4:  lane_result[i] = {1'b0, a_byte[i][6:0]};
            MX_OP_MIN4:  lane_result[i] = fp8_gt(a_byte[i], b_byte[i], fmt_is_e5m2)
                                           ? b_byte[i] : a_byte[i];
            MX_OP_MAX4:  lane_result[i] = fp8_gt(a_byte[i], b_byte[i], fmt_is_e5m2)
                                           ? a_byte[i] : b_byte[i];
            default:     lane_result[i] = 8'd0;
          endcase
        end

        // ---------------------------------------------------------------
        // LOG8-SUM / LOG8-MAX: LOG8 lane ops (same encoding for both)
        // ---------------------------------------------------------------
        default: begin
          case (op_i)
            MX_OP_ADD4: lane_result[i] = log8_addsub(
              lg_a_sign[i], lg_a_log[i], lg_b_sign[i], lg_b_log[i], 1'b0);
            MX_OP_SUB4: lane_result[i] = log8_addsub(
              lg_a_sign[i], lg_a_log[i], lg_b_sign[i], lg_b_log[i], 1'b1);
            MX_OP_MUL4: begin
              if (lg_a_zero[i] || lg_b_zero[i] || lg_mul_biased[i] == 8'd0)
                lane_result[i] = 8'd0;
              else
                lane_result[i] = {lg_a_sign[i] ^ lg_b_sign[i], lg_mul_biased[i][6:0]};
            end
            MX_OP_RELU4: lane_result[i] = a_byte[i][7] ? 8'd0 : a_byte[i];
            MX_OP_ABS4:  lane_result[i] = {1'b0, a_byte[i][6:0]};
            MX_OP_MIN4: begin
              if (lg_a_zero[i] && lg_b_zero[i])
                lane_result[i] = 8'd0;
              else if (lg_a_sign[i] && !lg_b_sign[i])
                lane_result[i] = a_byte[i];
              else if (!lg_a_sign[i] && lg_b_sign[i])
                lane_result[i] = b_byte[i];
              else if (!lg_a_sign[i])
                lane_result[i] = (lg_a_log[i] <= lg_b_log[i]) ? a_byte[i] : b_byte[i];
              else
                lane_result[i] = (lg_a_log[i] >= lg_b_log[i]) ? a_byte[i] : b_byte[i];
            end
            MX_OP_MAX4: begin
              if (lg_a_zero[i] && lg_b_zero[i])
                lane_result[i] = 8'd0;
              else if (!lg_a_sign[i] && lg_b_sign[i])
                lane_result[i] = a_byte[i];
              else if (lg_a_sign[i] && !lg_b_sign[i])
                lane_result[i] = b_byte[i];
              else if (!lg_a_sign[i])
                lane_result[i] = (lg_a_log[i] >= lg_b_log[i]) ? a_byte[i] : b_byte[i];
              else
                lane_result[i] = (lg_a_log[i] <= lg_b_log[i]) ? a_byte[i] : b_byte[i];
            end
            default: lane_result[i] = 8'd0;
          endcase
        end
      endcase
    end
  end

  // =========================================================================
  // Packed lane result
  // =========================================================================
  logic [31:0] packed_lanes;
  assign packed_lanes = {lane_result[3], lane_result[2], lane_result[1], lane_result[0]};

  // =========================================================================
  // DOT product — INT8
  // =========================================================================
  logic signed [31:0] int8_dot;

  always_comb begin
    int8_dot = 32'sd0;
    for (int i = 0; i < 4; i++)
      int8_dot = int8_dot + 32'(int8_mul_full[i]);
  end

  // =========================================================================
  // DOT product — FP8 (multiply in FP8, convert products to fixed16, sum)
  // =========================================================================
  logic signed [15:0] fp8_dot_prod [4];
  logic signed [31:0] fp8_dot;

  always_comb begin
    fp8_dot = 32'sd0;
    for (int i = 0; i < 4; i++) begin
      fp8_dot_prod[i] = fp8_to_fixed16(
        fp8_mul(a_byte[i], b_byte[i], fmt_is_e5m2), fmt_is_e5m2);
      fp8_dot = fp8_dot + 32'($signed(fp8_dot_prod[i]));
    end
  end

  // =========================================================================
  // DOT product — LOG8 linear (decode to linear via EXP_LUT, sign, sum)
  // =========================================================================
  logic [8:0]         lg_dot_raw_idx [4];
  logic [15:0]        lg_dot_linear  [4];
  logic               lg_dot_sign    [4];
  logic signed [17:0] lg_dot_signed  [4];
  logic signed [31:0] log8_dot;

  always_comb begin
    log8_dot = 32'sd0;
    for (int i = 0; i < 4; i++) begin
      lg_dot_sign[i]   = lg_a_sign[i] ^ lg_b_sign[i];
      lg_dot_linear[i] = 16'd0;
      lg_dot_signed[i] = 18'sd0;
      lg_dot_raw_idx[i] = {2'b0, lg_a_log[i]} + {2'b0, lg_b_log[i]} - 9'(LOG8_BIAS);

      if (!lg_a_zero[i] && !lg_b_zero[i]) begin
        if (lg_dot_raw_idx[i] > 9'd0 && lg_dot_raw_idx[i] <= 9'd127)
          lg_dot_linear[i] = EXP_LUT[lg_dot_raw_idx[i][6:0]];
        else if (lg_dot_raw_idx[i] > 9'd127)
          lg_dot_linear[i] = 16'd65535;

        lg_dot_signed[i] = lg_dot_sign[i]
          ? -$signed({2'b0, lg_dot_linear[i]})
          :  $signed({2'b0, lg_dot_linear[i]});
      end

      log8_dot = log8_dot + 32'($signed(lg_dot_signed[i]));
    end
  end

  // =========================================================================
  // DOT product — LOG8-LD (products in log domain, MAX-reduction tree)
  // =========================================================================
  // Stage 1: Log-addition — 4 parallel 7-bit adders compute products
  //          prod[i] = a_log[i] + b_log[i] - BIAS  (already in lg_mul_biased)
  // Stage 2: Max-reduction — binary comparator tree selects the largest
  //          product by unsigned magnitude (sign preserved from winner)
  //
  // This matches the ISLPED LOG8-LD architecture: ADD+MAX (Table 1, Fig 1c).
  // Faults on non-winning terms are absorbed by the comparator and do not
  // alter the output — the structural basis of fault containment.
  // =========================================================================
  logic [7:0] logdom_prod [4];
  logic [7:0] logdom_max01, logdom_max23;
  logic [7:0] logdom_dot;

  // Unsigned-magnitude comparator for LOG8-LD max-reduction
  function automatic logic [7:0] log8_max(
    input logic [7:0] a, input logic [7:0] b
  );
    // Both zero → zero
    if (a[6:0] == 7'd0 && b[6:0] == 7'd0) return 8'd0;
    // One zero → return the other
    if (a[6:0] == 7'd0) return b;
    if (b[6:0] == 7'd0) return a;
    // Compare unsigned magnitudes; return the larger
    return (a[6:0] >= b[6:0]) ? a : b;
  endfunction

  always_comb begin
    // Stage 1: compute products in log domain
    for (int i = 0; i < 4; i++) begin
      if (lg_a_zero[i] || lg_b_zero[i])
        logdom_prod[i] = 8'd0;
      else if (lg_mul_biased[i] == 8'd0)
        logdom_prod[i] = 8'd0;
      else
        logdom_prod[i] = {lg_a_sign[i] ^ lg_b_sign[i], lg_mul_biased[i][6:0]};
    end

    // Stage 2: binary comparator tree (max-reduction, depth = ceil(log2(4)) = 2)
    logdom_max01 = log8_max(logdom_prod[0], logdom_prod[1]);
    logdom_max23 = log8_max(logdom_prod[2], logdom_prod[3]);
    logdom_dot   = log8_max(logdom_max01,   logdom_max23);
  end

  // =========================================================================
  // DOT format mux — select raw DOT result by format
  // =========================================================================
  logic signed [31:0] raw_dot;

  always_comb begin
    case (fmt_i)
      MX_FMT_INT8:                raw_dot = int8_dot;
      MX_FMT_FP8_E4M3,
      MX_FMT_FP8_E5M2:            raw_dot = fp8_dot;
      MX_FMT_LOG8_SUM:                raw_dot = log8_dot;
      default:                     raw_dot = 32'sd0; // LOG8-MAX uses logdom_dot via max-reduction
    endcase
  end

  // =========================================================================
  // Shared exponent scaling (barrel shifter for non-LOG8-MAX DOT/MACS)
  // =========================================================================
  //   scaled_dot = raw_dot * 2^(se_a + se_b - 254)
  //   For SE = {127,127}: shift = 0 (neutral)

  logic signed [9:0]  se_shift;
  logic signed [31:0] se_scaled_dot;

  always_comb begin
    se_shift = $signed({2'b0, se_a_q}) + $signed({2'b0, se_b_q}) - 10'sd254;

    if (se_shift == 10'sd0) begin
      se_scaled_dot = raw_dot;
    end else if (se_shift > 10'sd0) begin
      if (se_shift > 10'sd31) begin
        // Overflow: saturate
        se_scaled_dot = (raw_dot > 0) ? 32'sh7FFF_FFFF
                      : (raw_dot < 0) ? 32'sh8000_0000
                      : 32'sd0;
      end else begin
        se_scaled_dot = raw_dot <<< se_shift[4:0];
        // Detect overflow: if sign changed, saturate
        if (raw_dot > 0 && se_scaled_dot <= 0 && raw_dot != 0)
          se_scaled_dot = 32'sh7FFF_FFFF;
        else if (raw_dot < 0 && se_scaled_dot >= 0)
          se_scaled_dot = 32'sh8000_0000;
      end
    end else begin
      // Right shift (se_shift < 0)
      if ((-se_shift) > 10'sd31)
        se_scaled_dot = (raw_dot >= 0) ? 32'sd0 : -32'sd1;
      else
        se_scaled_dot = raw_dot >>> (-se_shift[4:0]);
    end
  end

  // Logdomain SE offset: add (se_a + se_b - 254) * SCALE to log index
  logic [7:0] logdom_se_dot;

  always_comb begin
    logic signed [15:0] log_offset;
    logic signed [15:0] adjusted;

    logdom_se_dot = logdom_dot;
    log_offset    = $signed(se_shift) * 16'sd8;
    adjusted      = $signed({9'd0, logdom_dot[6:0]}) + log_offset;

    if (se_shift != 10'sd0 && logdom_dot[6:0] != 7'd0) begin
      if (adjusted > 16'sd127)
        logdom_se_dot = {logdom_dot[7], 7'd127};
      else if (adjusted <= 16'sd0)
        logdom_se_dot = 8'd0;
      else
        logdom_se_dot = {logdom_dot[7], adjusted[6:0]};
    end
  end

  // Final DOT result (used by DOT4 and MACS)
  logic [31:0] dot_result;
  assign dot_result = fmt_is_log8_max ? {24'd0, logdom_se_dot} : $unsigned(se_scaled_dot);

  // =========================================================================
  // Shared exponent registers
  // =========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      se_a_q <= 8'd127;  // neutral SE (2^0 scaling)
      se_b_q <= 8'd127;
    end else if (valid_i && op_i == MX_OP_SET_SE) begin
      se_a_q <= rs1_i[7:0];
      se_b_q <= rs1_i[15:8];
    end
  end

  // =========================================================================
  // MAC accumulator
  // =========================================================================
  logic signed [31:0] mac_result_linear;
  logic signed [32:0] mac_sum_wide;
  logic [7:0]         mac_result_logdom;
  logic [31:0]        mac_result;

  // Linear MAC: acc + se_scaled_dot with saturation
  always_comb begin
    mac_sum_wide = {se_scaled_dot[31], se_scaled_dot} + {mac_acc_q[31], mac_acc_q};
    if (mac_sum_wide > 33'sh0_7FFF_FFFF)
      mac_result_linear = 32'sh7FFF_FFFF;
    else if (mac_sum_wide < -33'sh0_8000_0000)
      mac_result_linear = 32'sh8000_0000;
    else
      mac_result_linear = mac_sum_wide[31:0];
  end

  // LOG8-LD MAC: max-reduce new dot into accumulator
  // acc = max(acc, new_dot) — non-winning terms are discarded
  always_comb begin
    mac_result_logdom = log8_max({mac_acc_q[7], mac_acc_q[6:0]}, logdom_se_dot);
  end

  // Select MAC result by format
  assign mac_result = fmt_is_log8_max ? {24'd0, mac_result_logdom}
                                   : $unsigned(mac_result_linear);

  // MAC accumulator register with commit/kill protocol
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mac_acc_q     <= 32'sd0;
      mac_pending_q <= 1'b0;
    end else begin
      if (valid_i && op_i == MX_OP_MACC) begin
        // Clear: immediate, unconditional
        mac_acc_q     <= 32'sd0;
        mac_pending_q <= 1'b0;
      end else if (mac_pending_q && mac_commit_i) begin
        mac_acc_q     <= $signed(mac_result);
        mac_pending_q <= 1'b0;
      end else if (mac_pending_q && mac_kill_i) begin
        mac_pending_q <= 1'b0;
      end else if (valid_i && op_i == MX_OP_MACS) begin
        mac_pending_q <= 1'b1;
      end
    end
  end

  // =========================================================================
  // DECODE: element rs1[7:0] + SE rs2[7:0] → 32-bit linear
  // =========================================================================
  logic [31:0] decode_result;

  always_comb begin
    decode_result = 32'd0;

    case (fmt_i)
      MX_FMT_INT8: begin
        // INT8: sign-extend, then shift by (SE - 127)
        logic signed [31:0] int_val;
        logic signed [8:0] dec_shift;
        int_val   = $signed({{24{rs1_i[7]}}, rs1_i[7:0]});
        dec_shift = $signed({1'b0, rs2_i[7:0]}) - 9'sd127;
        if (dec_shift > 9'sd0 && dec_shift < 9'sd32)
          decode_result = $unsigned(int_val <<< dec_shift[4:0]);
        else if (dec_shift < 9'sd0 && (-dec_shift) < 9'sd32)
          decode_result = $unsigned(int_val >>> (-dec_shift[4:0]));
        else if (dec_shift == 9'sd0)
          decode_result = $unsigned(int_val);
      end

      MX_FMT_FP8_E4M3, MX_FMT_FP8_E5M2: begin
        // FP8: decode to fixed16, then shift by (SE - 127)
        logic signed [15:0] fp_val;
        logic signed [31:0] fp_wide;
        logic signed [8:0] dec_shift;
        fp_val    = fp8_to_fixed16(rs1_i[7:0], fmt_is_e5m2);
        fp_wide   = {{16{fp_val[15]}}, fp_val};
        dec_shift = $signed({1'b0, rs2_i[7:0]}) - 9'sd127;
        if (dec_shift > 9'sd0 && dec_shift < 9'sd32)
          decode_result = $unsigned(fp_wide <<< dec_shift[4:0]);
        else if (dec_shift < 9'sd0 && (-dec_shift) < 9'sd32)
          decode_result = $unsigned(fp_wide >>> (-dec_shift[4:0]));
        else if (dec_shift == 9'sd0)
          decode_result = $unsigned(fp_wide);
      end

      default: begin
        // LOG8-SUM / LOG8-MAX: EXP_LUT, apply sign, then shift by (SE - 127)
        logic [15:0] lg_val;
        logic signed [31:0] lg_signed;
        logic signed [8:0] dec_shift;
        if (lg_a_log[0] == 7'd0)
          lg_val = 16'd0;
        else
          lg_val = EXP_LUT[lg_a_log[0]];
        lg_signed = lg_a_sign[0] ? -$signed({16'd0, lg_val}) : $signed({16'd0, lg_val});
        dec_shift = $signed({1'b0, rs2_i[7:0]}) - 9'sd127;
        if (dec_shift > 9'sd0 && dec_shift < 9'sd32)
          decode_result = $unsigned(lg_signed <<< dec_shift[4:0]);
        else if (dec_shift < 9'sd0 && (-dec_shift) < 9'sd32)
          decode_result = $unsigned(lg_signed >>> (-dec_shift[4:0]));
        else if (dec_shift == 9'sd0)
          decode_result = $unsigned(lg_signed);
      end
    endcase
  end

  // =========================================================================
  // CVT_LIN: element rs1[7:0] → 32-bit linear (no SE)
  // =========================================================================
  logic [31:0] cvt_lin_result;

  always_comb begin
    case (fmt_i)
      MX_FMT_INT8:
        cvt_lin_result = $unsigned($signed({{24{rs1_i[7]}}, rs1_i[7:0]}));

      MX_FMT_FP8_E4M3, MX_FMT_FP8_E5M2: begin
        logic signed [15:0] fp_cvt;
        fp_cvt = fp8_to_fixed16(rs1_i[7:0], fmt_is_e5m2);
        cvt_lin_result = $unsigned({{16{fp_cvt[15]}}, fp_cvt});
      end

      default: begin
        // LOG8-SUM / LOG8-MAX
        logic [15:0] lg_cvt;
        if (rs1_i[6:0] == 7'd0)
          lg_cvt = 16'd0;
        else
          lg_cvt = EXP_LUT[rs1_i[6:0]];
        cvt_lin_result = rs1_i[7]
          ? $unsigned(-$signed({16'd0, lg_cvt}))
          : {16'd0, lg_cvt};
      end
    endcase
  end

  // =========================================================================
  // CVT_ENC: unsigned byte rs1[7:0] → element byte rd[7:0]
  // =========================================================================
  logic [31:0] cvt_enc_result;

  always_comb begin
    case (fmt_i)
      MX_FMT_INT8:
        // Identity: input byte is already INT8 element
        cvt_enc_result = {24'd0, rs1_i[7:0]};

      MX_FMT_FP8_E4M3, MX_FMT_FP8_E5M2: begin
        // Convert unsigned 8-bit integer to FP8
        logic [7:0] cvt_input;
        logic signed [7:0] cvt_exp;
        logic [3:0] cvt_mant;
        logic [7:0] cvt_byte;
        cvt_input = rs1_i[7:0];
        cvt_exp   = 8'sd0;
        cvt_mant  = 4'd0;
        cvt_byte  = 8'd0;

        if (cvt_input != 8'd0) begin
          if      (cvt_input[7]) begin cvt_exp = (fmt_is_e5m2 ? 8'sd22 : 8'sd14); cvt_mant = cvt_input[6:3]; end
          else if (cvt_input[6]) begin cvt_exp = (fmt_is_e5m2 ? 8'sd21 : 8'sd13); cvt_mant = cvt_input[5:2]; end
          else if (cvt_input[5]) begin cvt_exp = (fmt_is_e5m2 ? 8'sd20 : 8'sd12); cvt_mant = cvt_input[4:1]; end
          else if (cvt_input[4]) begin cvt_exp = (fmt_is_e5m2 ? 8'sd19 : 8'sd11); cvt_mant = cvt_input[3:0]; end
          else if (cvt_input[3]) begin cvt_exp = (fmt_is_e5m2 ? 8'sd18 : 8'sd10); cvt_mant = {cvt_input[2:0], 1'b0}; end
          else if (cvt_input[2]) begin cvt_exp = (fmt_is_e5m2 ? 8'sd17 : 8'sd9);  cvt_mant = {cvt_input[1:0], 2'b0}; end
          else if (cvt_input[1]) begin cvt_exp = (fmt_is_e5m2 ? 8'sd16 : 8'sd8);  cvt_mant = {cvt_input[0], 3'b0}; end
          else                   begin cvt_exp = (fmt_is_e5m2 ? 8'sd15 : 8'sd7);  cvt_mant = 4'd0; end

          if (fmt_is_e5m2)
            cvt_byte = pack_fp8(1'b0, cvt_exp, {5'b0, cvt_mant[3:2], 1'b0}, 1'b1);
          else
            cvt_byte = pack_fp8(1'b0, cvt_exp, {4'b0, cvt_mant[3:1], 1'b0}, 1'b0);
        end
        cvt_enc_result = {24'd0, cvt_byte};
      end

      default: begin
        // LOG8: LOG_LUT[unsigned_byte] → log index
        cvt_enc_result = {24'd0, 1'b0, LOG_LUT[rs1_i[7:0]]};
      end
    endcase
  end

  // =========================================================================
  // CMP4: 4-bit comparison mask (a[i] > b[i])
  // =========================================================================
  logic [3:0] cmp_mask;

  always_comb begin
    for (int i = 0; i < 4; i++) begin
      case (fmt_i)
        MX_FMT_INT8:
          cmp_mask[i] = (int8_a[i] > int8_b[i]);

        MX_FMT_FP8_E4M3, MX_FMT_FP8_E5M2:
          cmp_mask[i] = fp8_gt(a_byte[i], b_byte[i], fmt_is_e5m2);

        default: begin
          // LOG8 signed compare
          if (lg_a_zero[i] && lg_b_zero[i])
            cmp_mask[i] = 1'b0;
          else if (!lg_a_sign[i] && lg_b_sign[i])
            cmp_mask[i] = 1'b1;
          else if (lg_a_sign[i] && !lg_b_sign[i])
            cmp_mask[i] = 1'b0;
          else if (!lg_a_sign[i])
            cmp_mask[i] = (lg_a_log[i] > lg_b_log[i]);
          else
            cmp_mask[i] = (lg_a_log[i] < lg_b_log[i]);
        end
      endcase
    end
  end

  // =========================================================================
  // Output mux
  // =========================================================================
  always_comb begin
    case (op_i)
      MX_OP_DOT4:    result_o = dot_result;
      MX_OP_MACS:    result_o = mac_result;
      MX_OP_MACC:    result_o = 32'd0;
      MX_OP_MACC_RD: result_o = $unsigned(mac_acc_q);
      MX_OP_SET_SE:  result_o = {16'd0, rs1_i[15:0]};
      MX_OP_DECODE:  result_o = decode_result;
      MX_OP_CVT_LIN: result_o = cvt_lin_result;
      MX_OP_CVT_ENC: result_o = cvt_enc_result;
      MX_OP_CMP4:    result_o = {28'd0, cmp_mask};
      default:        result_o = packed_lanes;  // ADD4/SUB4/MUL4/RELU4/ABS4/MIN4/MAX4
    endcase
  end

endmodule
