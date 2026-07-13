// SPDX-License-Identifier: Apache-2.0
// Fault Analysis of Microscaling Formats on a RISC-V SoC
// Authors: Dillibabu Shanmugam, Patrick Schaumont
// Affiliation: Worcester Polytechnic Institute (WPI), USA

// =============================================================================
// MX Coprocessor — SE-Protected Variant
// =============================================================================
//
// Drop-in replacement for mx_coprocessor.sv that uses mx_alu_se_protect
// instead of mx_alu.  Adds se_fault_o to the scan chain (bit 129 → 130 bits).
//
// Original mx_coprocessor.sv and mx_alu.sv are UNTOUCHED.
// =============================================================================

module mx_coprocessor_se_protect
  import mx_pkg::*;
  import cve2_pkg::*;
(
  input  logic clk_i,
  input  logic rst_ni,

  // ---- CV-X-IF Issue Interface ----
  input  logic                    x_issue_valid_i,
  output logic                    x_issue_ready_o,
  input  cve2_pkg::x_issue_req_t  x_issue_req_i,
  output cve2_pkg::x_issue_resp_t x_issue_resp_o,

  // ---- CV-X-IF Register Interface ----
  input  cve2_pkg::x_register_t   x_register_i,

  // ---- CV-X-IF Commit Interface ----
  input  logic                    x_commit_valid_i,
  input  cve2_pkg::x_commit_t     x_commit_i,

  // ---- CV-X-IF Result Interface ----
  output logic                    x_result_valid_o,
  input  logic                    x_result_ready_i,
  output cve2_pkg::x_result_t     x_result_o,

  // ---- Scan chain interface (130 bits: original 129 + se_fault) ----
  input  logic        scan_en_i,
  input  logic        scan_capture_i,
  input  logic        scan_in_i,
  output logic        scan_out_o,

  // ---- SE fault detection output ----
  output logic        se_fault_o
);

  // =========================================================================
  // Instruction decode (identical to mx_coprocessor.sv)
  // =========================================================================
  logic [31:0] instr;
  logic [6:0]  opcode;
  logic [2:0]  funct3;
  logic [6:0]  funct7;
  logic [4:0]  rd;

  assign instr  = x_issue_req_i.instr;
  assign opcode = instr[6:0];
  assign funct3 = instr[14:12];
  assign funct7 = instr[31:25];
  assign rd     = instr[11:7];

  logic is_our_opcode, is_valid_encoding, is_our_instr;
  assign is_our_opcode     = (opcode == MX_OPCODE);
  assign is_valid_encoding = funct7_reserved_ok(funct7)
                           && is_valid_format(funct7[4:2]);
  assign is_our_instr      = is_our_opcode && is_valid_encoding;

  mx_fmt_e decoded_fmt;
  mx_op_e  decoded_op;
  assign decoded_fmt = get_format(funct7);
  assign decoded_op  = mx_op_e'({funct7[0], funct3});

  logic op_needs_rs1, op_needs_rs2;
  assign op_needs_rs1 = is_our_instr && (decoded_op != MX_OP_MACC)
                                      && (decoded_op != MX_OP_MACC_RD);
  assign op_needs_rs2 = is_our_instr && needs_rs2(decoded_op);

  // =========================================================================
  // Issue response
  // =========================================================================
  logic instr_accepted;
  assign instr_accepted = x_issue_valid_i && is_our_instr;

  logic instr_inflight_q;

  always_comb begin
    x_issue_resp_o.accept        = 1'b0;
    x_issue_resp_o.writeback     = 1'b0;
    x_issue_resp_o.register_read = 2'b00;
    x_issue_ready_o              = 1'b1;

    if (x_issue_valid_i && is_our_instr) begin
      x_issue_resp_o.accept        = 1'b1;
      x_issue_resp_o.writeback     = 1'b1;
      x_issue_resp_o.register_read = {op_needs_rs2, op_needs_rs1};
    end else if (instr_inflight_q) begin
      x_issue_resp_o.writeback     = 1'b1;
    end
  end

  // =========================================================================
  // Pipeline state
  // =========================================================================
  logic [3:0]  instr_id_q;
  logic [4:0]  instr_rd_q;
  mx_op_e      instr_op_q;
  mx_fmt_e     instr_fmt_q;
  logic [31:0] rs1_q, rs2_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      instr_inflight_q <= 1'b0;
      instr_id_q       <= 4'd0;
      instr_rd_q       <= 5'd0;
      instr_op_q       <= MX_OP_DOT4;
      instr_fmt_q      <= MX_FMT_INT8;
      rs1_q            <= 32'd0;
      rs2_q            <= 32'd0;
    end else begin
      if (instr_accepted) begin
        instr_inflight_q <= 1'b1;
        instr_id_q       <= x_issue_req_i.id;
        instr_rd_q       <= rd;
        instr_op_q       <= decoded_op;
        instr_fmt_q      <= decoded_fmt;
        rs1_q            <= x_register_i.rs[0];
        rs2_q            <= x_register_i.rs[1];
      end else if (instr_inflight_q && x_result_ready_i) begin
        instr_inflight_q <= 1'b0;
      end
    end
  end

  // =========================================================================
  // MAC commit/kill
  // =========================================================================
  logic mac_commit, mac_kill;
  assign mac_commit = x_commit_valid_i && !x_commit_i.commit_kill
                    && instr_inflight_q && (instr_op_q == MX_OP_MACS);
  assign mac_kill   = x_commit_valid_i &&  x_commit_i.commit_kill
                    && instr_inflight_q && (instr_op_q == MX_OP_MACS);

  // =========================================================================
  // SE-Protected ALU
  // =========================================================================
  logic [31:0] alu_result;
  logic [7:0]  se_a, se_b;
  logic [31:0] mac_acc;
  logic        se_fault;

  mx_alu_se_protect #(
    .SE_PROTECT_MODE ( 0 )  // detect-only (shadow compare)
  ) i_alu (
    .clk_i,
    .rst_ni,
    .rs1_i        ( rs1_q          ),
    .rs2_i        ( rs2_q          ),
    .op_i         ( instr_op_q     ),
    .fmt_i        ( instr_fmt_q    ),
    .valid_i      ( instr_accepted ),
    .mac_commit_i ( mac_commit     ),
    .mac_kill_i   ( mac_kill       ),
    .result_o     ( alu_result     ),
    .se_a_o       ( se_a           ),
    .se_b_o       ( se_b           ),
    .mac_acc_o    ( mac_acc        ),
    .se_fault_o   ( se_fault       )
  );

  assign se_fault_o = se_fault;

  // =========================================================================
  // Scan chain: 130 bits (original 129 + se_fault flag)
  // =========================================================================
  localparam int unsigned PROTECTED_SCAN_WIDTH = MX_SCAN_WIDTH + 1;  // 130

  logic [PROTECTED_SCAN_WIDTH-1:0] scan_data;

  assign scan_data = { se_fault,                       // [129] — NEW
                       rs1_q,                          // [128:97]
                       rs2_q,                          // [96:65]
                       mac_acc,                        // [64:33]
                       se_a,                           // [32:25]
                       se_b,                           // [24:17]
                       4'(instr_op_q),                 // [16:13]
                       3'(instr_fmt_q),                // [12:10]
                       instr_inflight_q,               // [9]
                       instr_rd_q,                     // [8:4]
                       instr_id_q };                   // [3:0]

  scan_chain #(
    .WIDTH ( PROTECTED_SCAN_WIDTH )
  ) i_scan (
    .clk_i,
    .rst_ni,
    .scan_en_i,
    .scan_capture_i,
    .scan_in_i,
    .scan_out_o,
    .data_i  ( scan_data )
  );

  // =========================================================================
  // Result interface
  // =========================================================================
  always_comb begin
    x_result_valid_o  = instr_inflight_q;
    x_result_o.hartid = '0;
    x_result_o.id     = instr_id_q;
    x_result_o.data   = alu_result;
    x_result_o.rd     = instr_rd_q;
    x_result_o.we     = 1'b1;
  end

endmodule
