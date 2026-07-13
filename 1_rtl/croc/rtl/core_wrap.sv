// SPDX-License-Identifier: Apache-2.0
// Fault Analysis of Microscaling Formats on a RISC-V SoC
// Authors: Dillibabu Shanmugam, Patrick Schaumont
// Affiliation: Worcester Polytechnic Institute (WPI), USA

// =============================================================================
// Core Wrapper — CVE2 + Unified MX Coprocessor (direct X-IF, no mux)
// =============================================================================
//
// Instantiates the CVE2 (Ibex) core with XInterface enabled and wires it
// directly to the unified MX coprocessor.  No cvxif_mux is needed because
// the unified design handles all 5 MX formats through a single X-IF port
// using format selection in funct7[4:2].
//
// Compared to the 3-coprocessor version (multi-format-coprocessor/rtl/
// core_wrap.sv, 265 lines), this is significantly simpler: no mux, no
// per-format wire bundles — just CVE2 ↔ mx_coprocessor direct connection.
//
// Adapted from: multi-format-coprocessor/rtl/core_wrap.sv
// =============================================================================

module core_wrap
  import croc_pkg::*;
#()
(
  input  logic clk_i,
  input  logic rst_ni,
  input  logic ref_clk_i,
  input  logic test_enable_i,

  // Interrupts
  input  logic [15:0] irqs_i,
  input  logic timer_irq_i,
  input  logic software_irq_i,

  // Boot
  input  logic [31:0] boot_addr_i,

  // Instruction memory interface (OBI)
  output logic        instr_req_o,
  input  logic        instr_gnt_i,
  input  logic        instr_rvalid_i,
  output logic [31:0] instr_addr_o,
  input  logic [31:0] instr_rdata_i,
  input  logic        instr_err_i,

  // Data memory interface (OBI)
  output logic        data_req_o,
  input  logic        data_gnt_i,
  input  logic        data_rvalid_i,
  output logic        data_we_o,
  output logic [3:0]  data_be_o,
  output logic [31:0] data_addr_o,
  output logic [31:0] data_wdata_o,
  input  logic [31:0] data_rdata_i,
  input  logic        data_err_i,

  // Debug
  input  logic        debug_req_i,
  input  logic        fetch_enable_i,
  output logic        core_busy_o,

  // Scan chain interface (from MX coprocessor, directly to FPGA pins)
  input  logic        scan_en_i,
  input  logic        scan_capture_i,
  input  logic        scan_in_i,
  output logic        scan_out_o
);

  // =========================================================================
  // Debug module addresses
  // =========================================================================
  localparam bit [31:0] DebugAddrOffset       = get_periph_start_addr(PeriphDebug);
  localparam bit [31:0] DebugHaltAddress      = DebugAddrOffset + dm::HaltAddress[31:0];
  localparam bit [31:0] DebugExceptionAddress = DebugAddrOffset + dm::ExceptionAddress[31:0];

  // Lowest 8 bits of boot address are ignored internally by CVE2
  logic [31:0] ibex_boot_addr;
  assign ibex_boot_addr = boot_addr_i & 32'hFFFFFF00;

  // =========================================================================
  // CV-X-IF wires (single set — direct CVE2 ↔ mx_coprocessor)
  // =========================================================================
  logic                        x_issue_valid;
  logic                        x_issue_ready;
  cve2_pkg::x_issue_req_t      x_issue_req;
  cve2_pkg::x_issue_resp_t     x_issue_resp;
  cve2_pkg::x_register_t       x_register;
  logic                        x_commit_valid;
  cve2_pkg::x_commit_t         x_commit;
  logic                        x_result_valid;
  logic                        x_result_ready;
  cve2_pkg::x_result_t         x_result;

  // =========================================================================
  // CVE2 core (RV32IMC, 2-stage pipeline, X-IF enabled)
  // =========================================================================
`ifdef TRACE_EXECUTION
  cve2_core_tracing #(
`else
  cve2_core #(
`endif
    .PMPEnable        ( 1'b0                ),
    .PMPGranularity   ( 0                   ),
    .PMPNumRegions    ( 4                   ),
    .MHPMCounterNum   ( 0                   ),
    .MHPMCounterWidth ( 40                  ),
    .RV32E            ( 0                   ),
    .RV32M            ( cve2_pkg::RV32MSlow ),
    .RV32B            ( cve2_pkg::RV32BNone ),
    .DbgTriggerEn     ( 1'b1                ),
    .DbgHwBreakNum    ( 1                   ),
    .XInterface       ( 1'b1                )
  ) i_ibex (
    .clk_i,
    .rst_ni,
    .test_en_i        ( test_enable_i       ),
    .hart_id_i        ( 32'd0               ),
    .boot_addr_i      ( ibex_boot_addr      ),
    .instr_req_o,
    .instr_gnt_i,
    .instr_rdata_i,
    .instr_rvalid_i,
    .instr_addr_o,
    .instr_err_i,
    .data_req_o,
    .data_gnt_i,
    .data_rvalid_i,
    .data_we_o,
    .data_be_o,
    .data_addr_o,
    .data_wdata_o,
    .data_rdata_i,
    .data_err_i,
    // ---- X-IF: direct to MX coprocessor (no mux) ----
    .x_issue_valid_o     ( x_issue_valid  ),
    .x_issue_ready_i     ( x_issue_ready  ),
    .x_issue_req_o       ( x_issue_req    ),
    .x_issue_resp_i      ( x_issue_resp   ),
    .x_register_o        ( x_register     ),
    .x_commit_valid_o    ( x_commit_valid ),
    .x_commit_o          ( x_commit       ),
    .x_result_valid_i    ( x_result_valid ),
    .x_result_ready_o    ( x_result_ready ),
    .x_result_i          ( x_result       ),
    // ---- Interrupts ----
    .irq_software_i      ( software_irq_i ),
    .irq_timer_i         ( timer_irq_i    ),
    .irq_external_i      ( 1'b0           ),
    .irq_fast_i          ( irqs_i         ),
    .irq_nm_i            ( 1'b0           ),
    .irq_pending_o       ( ),
    // ---- Debug ----
    .debug_req_i,
    .debug_halted_o      ( ),
    .dm_halt_addr_i      ( DebugHaltAddress      ),
    .dm_exception_addr_i ( DebugExceptionAddress ),
    .crash_dump_o        ( ),
    .fetch_enable_i,
    .core_busy_o
  );

  // =========================================================================
  // Unified MX Coprocessor (single instance, all 5 formats)
  // =========================================================================
  mx_coprocessor i_mx (
    .clk_i,
    .rst_ni,

    .x_issue_valid_i  ( x_issue_valid  ),
    .x_issue_ready_o  ( x_issue_ready  ),
    .x_issue_req_i    ( x_issue_req    ),
    .x_issue_resp_o   ( x_issue_resp   ),
    .x_register_i     ( x_register     ),
    .x_commit_valid_i ( x_commit_valid ),
    .x_commit_i       ( x_commit       ),
    .x_result_valid_o ( x_result_valid ),
    .x_result_ready_i ( x_result_ready ),
    .x_result_o       ( x_result       ),

    .scan_en_i        ( scan_en_i      ),
    .scan_capture_i   ( scan_capture_i ),
    .scan_in_i        ( scan_in_i      ),
    .scan_out_o       ( scan_out_o     )
  );

endmodule
