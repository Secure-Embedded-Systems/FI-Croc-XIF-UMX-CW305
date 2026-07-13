# SPDX-License-Identifier: Apache-2.0
# Security Analysis of Microscaling Formats Under Fault Injection on a RISC-V Edge Platform
# Authors: Dillibabu Shanmugam, Patrick Schaumont
# Affiliation: Worcester Polytechnic Institute (WPI), USA

# =============================================================================
# RTL Source List for CW305 Build — CROC + Unified MX Coprocessor
# =============================================================================
# Adapted from: add_sources.genesys2.tcl
# Differences from Genesys2:
#   - Uses tc_sram_xilinx.sv (FPGA BRAM) instead of behavioral SRAM
#   - Adds MX coprocessor files (mx_pkg, mx_alu, mx_coprocessor, scan_chain)
#   - Replaces croc_xilinx.sv with croc_cw305.sv (no fan, VIO, clock wizard)
#   - No fan_ctrl.sv needed
# =============================================================================

if { [info exists ::env(CROC_ROOT)] && $::env(CROC_ROOT) ne "" } {
    set CROC "$::env(CROC_ROOT)"
} else {
    # Default: look for croc/ alongside the project root
    set CROC [file normalize "[file dirname [info script]]/../1_rtl/croc"]
}

# ---- Technology cells (FPGA-specific SRAM + clock cells) ----
add_files -norecurse -fileset [current_fileset] [list \
    $CROC/rtl/tech_cells_generic/fpga/pad_functional_xilinx.sv \
    $CROC/rtl/tech_cells_generic/fpga/tc_clk_xilinx.sv \
    $CROC/rtl/tech_cells_generic/fpga/tc_sram_xilinx.sv \
    $CROC/rtl/tech_cells_generic/tc_sram_impl.sv \
]

# ---- Common cells ----
add_files -norecurse -fileset [current_fileset] [list \
    $CROC/rtl/common_cells/binary_to_gray.sv \
]
add_files -norecurse -fileset [current_fileset] [list \
    $CROC/rtl/common_cells/cb_filter_pkg.sv \
    $CROC/rtl/common_cells/cc_onehot.sv \
    $CROC/rtl/common_cells/cdc_reset_ctrlr_pkg.sv \
    $CROC/rtl/common_cells/cf_math_pkg.sv \
    $CROC/rtl/common_cells/clk_int_div.sv \
    $CROC/rtl/common_cells/credit_counter.sv \
    $CROC/rtl/common_cells/delta_counter.sv \
    $CROC/rtl/common_cells/ecc_pkg.sv \
    $CROC/rtl/common_cells/edge_propagator_tx.sv \
    $CROC/rtl/common_cells/exp_backoff.sv \
    $CROC/rtl/common_cells/fifo_v3.sv \
    $CROC/rtl/common_cells/gray_to_binary.sv \
    $CROC/rtl/common_cells/heaviside.sv \
    $CROC/rtl/common_cells/isochronous_4phase_handshake.sv \
    $CROC/rtl/common_cells/isochronous_spill_register.sv \
    $CROC/rtl/common_cells/lfsr.sv \
    $CROC/rtl/common_cells/lfsr_16bit.sv \
    $CROC/rtl/common_cells/lfsr_8bit.sv \
    $CROC/rtl/common_cells/lossy_valid_to_stream.sv \
    $CROC/rtl/common_cells/mv_filter.sv \
    $CROC/rtl/common_cells/onehot_to_bin.sv \
    $CROC/rtl/common_cells/plru_tree.sv \
    $CROC/rtl/common_cells/passthrough_stream_fifo.sv \
    $CROC/rtl/common_cells/popcount.sv \
    $CROC/rtl/common_cells/ring_buffer.sv \
    $CROC/rtl/common_cells/rr_arb_tree.sv \
    $CROC/rtl/common_cells/rstgen_bypass.sv \
    $CROC/rtl/common_cells/serial_deglitch.sv \
    $CROC/rtl/common_cells/shift_reg.sv \
    $CROC/rtl/common_cells/shift_reg_gated.sv \
    $CROC/rtl/common_cells/spill_register_flushable.sv \
    $CROC/rtl/common_cells/stream_demux.sv \
    $CROC/rtl/common_cells/stream_filter.sv \
    $CROC/rtl/common_cells/stream_fork.sv \
    $CROC/rtl/common_cells/stream_intf.sv \
    $CROC/rtl/common_cells/stream_join_dynamic.sv \
    $CROC/rtl/common_cells/stream_mux.sv \
    $CROC/rtl/common_cells/stream_throttle.sv \
    $CROC/rtl/common_cells/sub_per_hash.sv \
    $CROC/rtl/common_cells/sync.sv \
    $CROC/rtl/common_cells/sync_wedge.sv \
    $CROC/rtl/common_cells/unread.sv \
    $CROC/rtl/common_cells/read.sv \
    $CROC/rtl/common_cells/addr_decode_dync.sv \
    $CROC/rtl/common_cells/boxcar.sv \
    $CROC/rtl/common_cells/cdc_2phase.sv \
    $CROC/rtl/common_cells/cdc_4phase.sv \
    $CROC/rtl/common_cells/clk_int_div_static.sv \
    $CROC/rtl/common_cells/trip_counter.sv \
    $CROC/rtl/common_cells/addr_decode.sv \
    $CROC/rtl/common_cells/addr_decode_napot.sv \
    $CROC/rtl/common_cells/multiaddr_decode.sv \
]
add_files -norecurse -fileset [current_fileset] [list \
    $CROC/rtl/common_cells/cb_filter.sv \
    $CROC/rtl/common_cells/cdc_fifo_2phase.sv \
    $CROC/rtl/common_cells/clk_mux_glitch_free.sv \
    $CROC/rtl/common_cells/counter.sv \
    $CROC/rtl/common_cells/ecc_decode.sv \
    $CROC/rtl/common_cells/ecc_encode.sv \
    $CROC/rtl/common_cells/edge_detect.sv \
    $CROC/rtl/common_cells/lzc.sv \
    $CROC/rtl/common_cells/max_counter.sv \
    $CROC/rtl/common_cells/rstgen.sv \
    $CROC/rtl/common_cells/spill_register.sv \
    $CROC/rtl/common_cells/stream_delay.sv \
    $CROC/rtl/common_cells/stream_fifo.sv \
    $CROC/rtl/common_cells/stream_fork_dynamic.sv \
    $CROC/rtl/common_cells/stream_join.sv \
    $CROC/rtl/common_cells/cdc_reset_ctrlr.sv \
    $CROC/rtl/common_cells/cdc_fifo_gray.sv \
    $CROC/rtl/common_cells/fall_through_register.sv \
    $CROC/rtl/common_cells/id_queue.sv \
    $CROC/rtl/common_cells/stream_to_mem.sv \
    $CROC/rtl/common_cells/stream_arbiter_flushable.sv \
    $CROC/rtl/common_cells/stream_fifo_optimal_wrap.sv \
    $CROC/rtl/common_cells/stream_register.sv \
    $CROC/rtl/common_cells/stream_xbar.sv \
    $CROC/rtl/common_cells/cdc_fifo_gray_clearable.sv \
    $CROC/rtl/common_cells/cdc_2phase_clearable.sv \
    $CROC/rtl/common_cells/mem_to_banks_detailed.sv \
    $CROC/rtl/common_cells/stream_arbiter.sv \
    $CROC/rtl/common_cells/stream_omega_net.sv \
    $CROC/rtl/common_cells/mem_to_banks.sv \
]

# ---- OBI interconnect ----
add_files -norecurse -fileset [current_fileset] [list \
    $CROC/rtl/obi/obi_pkg.sv \
    $CROC/rtl/obi/obi_intf.sv \
    $CROC/rtl/obi/obi_rready_converter.sv \
    $CROC/rtl/obi/apb_to_obi.sv \
    $CROC/rtl/obi/obi_to_apb.sv \
    $CROC/rtl/obi/obi_atop_resolver.sv \
    $CROC/rtl/obi/obi_cut.sv \
    $CROC/rtl/obi/obi_demux.sv \
    $CROC/rtl/obi/obi_err_sbr.sv \
    $CROC/rtl/obi/obi_mux.sv \
    $CROC/rtl/obi/obi_sram_shim.sv \
    $CROC/rtl/obi/obi_xbar.sv \
]

# ---- APB ----
add_files -norecurse -fileset [current_fileset] [list \
    $CROC/rtl/apb/apb_pkg.sv \
]

# ---- CVE2 core ----
add_files -norecurse -fileset [current_fileset] [list \
    $CROC/rtl/cve2/cve2_pkg.sv \
    $CROC/rtl/cve2/cve2_alu.sv \
    $CROC/rtl/cve2/cve2_branch_predict.sv \
    $CROC/rtl/cve2/cve2_compressed_decoder.sv \
    $CROC/rtl/cve2/cve2_controller.sv \
    $CROC/rtl/cve2/cve2_counter.sv \
    $CROC/rtl/cve2/cve2_csr.sv \
    $CROC/rtl/cve2/cve2_decoder.sv \
    $CROC/rtl/cve2/cve2_fetch_fifo.sv \
    $CROC/rtl/cve2/cve2_load_store_unit.sv \
    $CROC/rtl/cve2/cve2_multdiv_fast.sv \
    $CROC/rtl/cve2/cve2_multdiv_slow.sv \
    $CROC/rtl/cve2/cve2_pmp.sv \
    $CROC/rtl/cve2/cve2_register_file_ff.sv \
    $CROC/rtl/cve2/cve2_wb.sv \
    $CROC/rtl/cve2/cve2_cs_registers.sv \
    $CROC/rtl/cve2/cve2_ex_block.sv \
    $CROC/rtl/cve2/cve2_id_stage.sv \
    $CROC/rtl/cve2/cve2_prefetch_buffer.sv \
    $CROC/rtl/cve2/cve2_if_stage.sv \
    $CROC/rtl/cve2/cve2_core.sv \
]

# ---- UART ----
add_files -norecurse -fileset [current_fileset] [list \
    $CROC/rtl/obi_uart/obi_uart_pkg.sv \
    $CROC/rtl/obi_uart/obi_uart_baudgen.sv \
    $CROC/rtl/obi_uart/obi_uart_interrupts.sv \
    $CROC/rtl/obi_uart/obi_uart_modem.sv \
    $CROC/rtl/obi_uart/obi_uart_rx.sv \
    $CROC/rtl/obi_uart/obi_uart_tx.sv \
    $CROC/rtl/obi_uart/obi_uart_register.sv \
    $CROC/rtl/obi_uart/obi_uart.sv \
]

# ---- Debug module ----
add_files -norecurse -fileset [current_fileset] [list \
    $CROC/rtl/riscv-dbg/dm_pkg.sv \
    $CROC/rtl/riscv-dbg/debug_rom/debug_rom.sv \
    $CROC/rtl/riscv-dbg/debug_rom/debug_rom_one_scratch.sv \
    $CROC/rtl/riscv-dbg/dm_csrs.sv \
    $CROC/rtl/riscv-dbg/dm_mem.sv \
    $CROC/rtl/riscv-dbg/dmi_cdc.sv \
]
add_files -norecurse -fileset [current_fileset] [list \
    $CROC/rtl/riscv-dbg/dmi_jtag_tap.sv \
]
add_files -norecurse -fileset [current_fileset] [list \
    $CROC/rtl/riscv-dbg/dm_sba.sv \
    $CROC/rtl/riscv-dbg/dm_top.sv \
    $CROC/rtl/riscv-dbg/dmi_jtag.sv \
    $CROC/rtl/riscv-dbg/dm_obi_top.sv \
]

# ---- CROC SoC packages and peripherals ----
add_files -norecurse -fileset [current_fileset] [list \
    $CROC/rtl/croc_pkg.sv \
    $CROC/rtl/user_pkg.sv \
    $CROC/rtl/soc_ctrl/soc_ctrl_regs_pkg.sv \
    $CROC/rtl/gpio/gpio_reg_pkg.sv \
    $CROC/rtl/clint/clint_reg_pkg.sv \
    $CROC/rtl/obi_timer/obi_timer_reg_pkg.sv \
]

# ---- MX Unified Coprocessor (replaces original core_wrap) ----
add_files -norecurse -fileset [current_fileset] [list \
    $CROC/rtl/mx_pkg.sv \
    $CROC/rtl/mx_alu.sv \
    $CROC/rtl/mx_coprocessor.sv \
    $CROC/rtl/scan_chain.sv \
    $CROC/rtl/core_wrap.sv \
]

# ---- CROC SoC top levels ----
add_files -norecurse -fileset [current_fileset] [list \
    $CROC/rtl/soc_ctrl/soc_ctrl_regs.sv \
    $CROC/rtl/gpio/gpio_reg_top.sv \
    $CROC/rtl/gpio/gpio.sv \
    $CROC/rtl/clint/clint.sv \
    $CROC/rtl/obi_timer/obi_timer.sv \
    $CROC/rtl/croc_domain.sv \
    $CROC/rtl/user_domain.sv \
    $CROC/rtl/croc_soc.sv \
]

# ---- CW305 FPGA top wrapper + USB register front-end ----
set CW305_DIR [file normalize "[file dirname [info script]]/../1_rtl/cw305"]
add_files -norecurse -fileset [current_fileset] [list \
    ${CW305_DIR}/croc_cw305_live.sv \
    ${CW305_DIR}/cw305_usb_reg_fe.sv \
]

# ---- Include directories ----
set inc_dirs [list \
    $CROC/rtl/apb/include \
    $CROC/rtl/common_cells/include \
    $CROC/rtl/cve2/include \
    $CROC/rtl/obi/include \
]
set_property include_dirs $inc_dirs [current_fileset]
set_property include_dirs $inc_dirs [current_fileset -simset]

# ---- Verilog defines ----
set vlog_defs [list \
    TARGET_FPGA \
    TARGET_CW305 \
    TARGET_SYNTHESIS \
    TARGET_VIVADO \
    TARGET_XILINX \
    COMMON_CELLS_ASSERTS_OFF=1 \
]
set_property verilog_define $vlog_defs [current_fileset]
set_property verilog_define $vlog_defs [current_fileset -simset]
