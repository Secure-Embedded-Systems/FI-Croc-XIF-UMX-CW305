// SPDX-License-Identifier: Apache-2.0
// Fault Analysis of Microscaling Formats on a RISC-V SoC
// Authors: Dillibabu Shanmugam, Patrick Schaumont
// Affiliation: Worcester Polytechnic Institute (WPI), USA

// =============================================================================
// Parameterized Mux-Scan Chain
// =============================================================================
//
// A configurable-width scan chain for observing internal coprocessor state.
// Supports two modes:
//
//   1. Capture (scan_capture_i = 1): Parallel-load data_i into the shift
//      register on the next rising clock edge.
//
//   2. Shift (scan_en_i = 1): Shift the register by one bit per clock cycle,
//      feeding scan_in_i into bit 0, and presenting the MSB on scan_out_o.
//
// Typical usage sequence (from external controller / ChipWhisperer):
//   a) Assert scan_capture_i for 1 clock → snapshot coprocessor state
//   b) Deassert scan_capture_i, assert scan_en_i
//   c) Clock WIDTH times, reading scan_out_o each cycle (MSB first)
//   d) Deassert scan_en_i
//
// Priority: capture > shift > hold.  If both capture and shift are asserted,
// capture wins (parallel load takes priority).
//
// For the MX coprocessor the default WIDTH is 129 bits:
//   {rs1_q[31:0], rs2_q[31:0], mac_acc_q[31:0], se_a_q[7:0], se_b_q[7:0],
//    instr_op_q[3:0], instr_fmt_q[2:0], instr_inflight_q, instr_rd_q[4:0],
//    instr_id_q[3:0]}
//
// Shift-out order: MSB first (rs1_q[31] is the first bit shifted out,
// instr_id_q[0] is the last).  This matches the CAPRI1 convention used
// in the existing ObF scan chain infrastructure.
//
// Area: WIDTH flip-flops + WIDTH 2:1 mux (capture vs shift).
//       For 129 bits ≈ 130 FFs + 130 LUT2s on Artix-7.
// =============================================================================

module scan_chain #(
  parameter int unsigned WIDTH = 129
)(
  input  logic             clk_i,
  input  logic             rst_ni,

  // Scan control
  input  logic             scan_en_i,       // 1 = shift mode
  input  logic             scan_capture_i,  // 1 = parallel capture (priority)
  input  logic             scan_in_i,       // serial data in (enters at bit 0)
  output logic             scan_out_o,      // serial data out (from MSB)

  // Parallel data to capture
  input  logic [WIDTH-1:0] data_i
);

  // =========================================================================
  // Shift register
  // =========================================================================
  logic [WIDTH-1:0] shift_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      shift_q <= '0;
    end else if (scan_capture_i) begin
      // Parallel capture: snapshot data_i
      shift_q <= data_i;
    end else if (scan_en_i) begin
      // Shift left: MSB out, scan_in enters at LSB
      shift_q <= {shift_q[WIDTH-2:0], scan_in_i};
    end
    // else: hold
  end

  // =========================================================================
  // Output: MSB of shift register
  // =========================================================================
  assign scan_out_o = shift_q[WIDTH-1];

endmodule
