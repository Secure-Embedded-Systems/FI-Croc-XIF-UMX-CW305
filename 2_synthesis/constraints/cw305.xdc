# SPDX-License-Identifier: Apache-2.0
# Security Analysis of Microscaling Formats Under Fault Injection on a RISC-V Edge Platform
# Authors: Dillibabu Shanmugam, Patrick Schaumont
# Affiliation: Worcester Polytechnic Institute (WPI), USA

# =============================================================================
# CW305-A35T Pin Constraints — CROC + Unified MX Coprocessor
# =============================================================================
#
# Target:  XC7A35T-2FTG256
# Board:   ChipWhisperer CW305 Artix-7 FPGA target
#
# Fault injection support:
#   - Clock glitch: BUFGMUX selects PLL_CLK1 (N13) or CW HS-IO (N14) via J16
#   - Voltage glitch: SMA X3 crowbar (board-level, trigger sync via IO4/T14)
#   - EMFI: X-Y table mounting (board-level, trigger sync via IO4/T14)
#   - Power analysis: ext_clock (M16) feeds CW ADC for synchronous capture
#
# Reference: CW305-Arm-DesignStart (github.com/newaetech/CW305-Arm-DesignStart)
# Verified against: CW305 schematic Rev 09, NAE-CW305 datasheet
# =============================================================================


# ==========================
# Clocks
# ==========================

# PLL_CLK1 from CDCE906 PLL Channel 1 (configured to 20 MHz via CW Python API)
set_property -dict { PACKAGE_PIN N13  IOSTANDARD LVCMOS33 } [get_ports { pll_clk1 }]
create_clock -period 50.000 -name pll_clk1 [get_ports { pll_clk1 }]

# CW Husky HS-IO clock input (glitch clock, same nominal 20 MHz from CW CLKGEN)
# Connected via 20-pin connector HS-IO pin → CW305 tio_clkin trace
set_property -dict { PACKAGE_PIN N14  IOSTANDARD LVCMOS33 } [get_ports { tio_clkin }]
create_clock -period 50.000 -name tio_clkin [get_ports { tio_clkin }]

# SAM3U USB bus clock (96 MHz nominal, ~10 ns period)
# Pin F5 per CW305 schematic Rev 09; used by cw305_usb_reg_fe registered interface
set_property -dict { PACKAGE_PIN F5   IOSTANDARD LVCMOS33 } [get_ports { usb_clk }]
create_clock -period 10.000 -name usb_clk [get_ports { usb_clk }]

# PLL and CW clocks are physically exclusive (muxed by BUFGMUX_CTRL)
# but Vivado needs both defined for timing analysis
set_clock_groups -logically_exclusive -group [get_clocks pll_clk1] -group [get_clocks tio_clkin]

# USB clock is asynchronous to SoC and JTAG clocks
set_clock_groups -asynchronous -group [get_clocks usb_clk] -group [get_clocks pll_clk1]
set_clock_groups -asynchronous -group [get_clocks usb_clk] -group [get_clocks tio_clkin]

# SoC clock period for I/O delay calculations (matches selected clock)
set SOC_TCK 50.0

# CLINT ref_clk synchronizer: ref_clk_i is tied to soc_clk in RTL (no separate RTC).
# The 2-FF synchronizer samples the clock signal as data — inherently safe but causes
# a hold violation because the clock-as-data path arrives before the clock tree.
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *i_clint/i_sync/reg_q_reg*/D}]


# ==========================
# Reset — push-button SW4
# ==========================
set_property -dict { PACKAGE_PIN R1   IOSTANDARD LVCMOS33 } [get_ports { rst_n }]
set_false_path -from [get_ports { rst_n }]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets rst_n_IBUF]


# ==========================
# DIP Switch S2
# ==========================
# J16: Clock source select (0=PLL normal, 1=CW HS-IO glitch clock)
set_property -dict { PACKAGE_PIN J16  IOSTANDARD LVCMOS33 } [get_ports { j16_sel }]
# K16: HS-Out enable (drive ext_clock on M16 for CW ADC sync)
set_property -dict { PACKAGE_PIN K16  IOSTANDARD LVCMOS33 } [get_ports { k16_sel }]
# K15: Fetch enable (0=core halted, 1=core runs)
set_property -dict { PACKAGE_PIN K15  IOSTANDARD LVCMOS33 } [get_ports { k15_sel }]
# L14: Spare (routed to gpio_i[0])
set_property -dict { PACKAGE_PIN L14  IOSTANDARD LVCMOS33 } [get_ports { l14_sel }]

# DIP switches are static — no timing requirements
set_false_path -from [get_ports { j16_sel k16_sel k15_sel l14_sel }]


# ==========================
# LEDs
# ==========================
set_property -dict { PACKAGE_PIN T2   IOSTANDARD LVCMOS33  DRIVE 8 } [get_ports { led1 }]
set_property -dict { PACKAGE_PIN T3   IOSTANDARD LVCMOS33  DRIVE 8 } [get_ports { led2 }]
set_property -dict { PACKAGE_PIN T4   IOSTANDARD LVCMOS33  DRIVE 8 } [get_ports { led3 }]
set_false_path -to [get_ports { led1 led2 led3 }]


# ==========================
# UART — 20-pin connector
# ==========================
# IO1 (P16): UART TX — FPGA output → CW host (scope.read() in Python)
set_property -dict { PACKAGE_PIN P16  IOSTANDARD LVCMOS33 } [get_ports { uart_tx_o }]
# IO2 (R16): UART RX — CW host → FPGA input (scope.write() in Python)
set_property -dict { PACKAGE_PIN R16  IOSTANDARD LVCMOS33 } [get_ports { uart_rx_i }]

set_input_delay  -clock pll_clk1 -min [expr { $SOC_TCK * 0.10 }] [get_ports { uart_rx_i }]
set_input_delay  -clock pll_clk1 -max [expr { $SOC_TCK * 0.35 }] [get_ports { uart_rx_i }]
set_output_delay -clock pll_clk1 -min [expr { $SOC_TCK * 0.10 }] [get_ports { uart_tx_o }]
set_output_delay -clock pll_clk1 -max [expr { $SOC_TCK * 0.35 }] [get_ports { uart_tx_o }]


# ==========================
# Trigger — 20-pin connector IO4
# ==========================
# IO4 (T14): Trigger output → CW Husky capture hardware
# Python: scope.trigger.triggers = "tio4"
# This synchronizes glitch insertion, power capture, and EMFI timing.
set_property -dict { PACKAGE_PIN T14  IOSTANDARD LVCMOS33 } [get_ports { trig_out }]
set_output_delay -clock pll_clk1 -min [expr { $SOC_TCK * 0.10 }] [get_ports { trig_out }]
set_output_delay -clock pll_clk1 -max [expr { $SOC_TCK * 0.35 }] [get_ports { trig_out }]


# ==========================
# ADC sampling clock — ext_clock output
# ==========================
# M16: SoC clock output for CW Husky ADC synchronous sampling
# Python: scope.clock.adc_src = "extclk_x1"  (or "extclk_x4" for 4x oversampling)
# Gated by K16 DIP switch in RTL (0=quiet, 1=drive clock)
# This is a forwarded clock, not synchronous data — CW ADC handles alignment.
set_property -dict { PACKAGE_PIN M16  IOSTANDARD LVCMOS33 } [get_ports { ext_clock }]
set_false_path -to [get_ports { ext_clock }]


# ==========================
# JTAG — JP3 header
# ==========================
set_property -dict { PACKAGE_PIN A13  IOSTANDARD LVCMOS33 } [get_ports { jtag_tck_i }]
set_property -dict { PACKAGE_PIN B12  IOSTANDARD LVCMOS33 } [get_ports { jtag_tdi_i }]
set_property -dict { PACKAGE_PIN C11  IOSTANDARD LVCMOS33 } [get_ports { jtag_tdo_o }]
set_property -dict { PACKAGE_PIN B15  IOSTANDARD LVCMOS33 } [get_ports { jtag_tms_i }]
set_property -dict { PACKAGE_PIN C14  IOSTANDARD LVCMOS33  PULLUP TRUE } [get_ports { jtag_trst_ni }]

# JTAG clock is asynchronous to SoC clock
create_clock -period 100.000 -name jtag_tck [get_ports { jtag_tck_i }]
set_clock_groups -asynchronous -group [get_clocks pll_clk1] -group [get_clocks jtag_tck]
set_clock_groups -asynchronous -group [get_clocks tio_clkin] -group [get_clocks jtag_tck]

set_input_delay  -clock jtag_tck -min 5.0  [get_ports { jtag_tdi_i jtag_tms_i }]
set_input_delay  -clock jtag_tck -max 20.0 [get_ports { jtag_tdi_i jtag_tms_i }]
set_output_delay -clock jtag_tck -min 5.0  [get_ports { jtag_tdo_o }]
set_output_delay -clock jtag_tck -max 20.0 [get_ports { jtag_tdo_o }]
set_false_path -from [get_ports { jtag_trst_ni }]

# JTAG TCK is NOT on a clock-capable pin — suppress Vivado DRC
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets jtag_tck_i]


# ==========================
# Scan chain — JP3 header
# ==========================
# MX coprocessor 129-bit scan chain for observability during fault campaigns.
# ChipWhisperer Python drives these via scope.io GPIO or an external controller.
# Protocol: capture(1clk) → shift(129 clks, read scan_out MSB-first) → idle
set_property -dict { PACKAGE_PIN A12  IOSTANDARD LVCMOS33 } [get_ports { scan_en_i }]
set_property -dict { PACKAGE_PIN A14  IOSTANDARD LVCMOS33 } [get_ports { scan_capture_i }]
set_property -dict { PACKAGE_PIN B14  IOSTANDARD LVCMOS33 } [get_ports { scan_in_i }]
set_property -dict { PACKAGE_PIN C13  IOSTANDARD LVCMOS33 } [get_ports { scan_out_o }]

set_input_delay  -clock pll_clk1 -min [expr { $SOC_TCK * 0.10 }] [get_ports { scan_en_i scan_capture_i scan_in_i }]
set_input_delay  -clock pll_clk1 -max [expr { $SOC_TCK * 0.35 }] [get_ports { scan_en_i scan_capture_i scan_in_i }]
set_output_delay -clock pll_clk1 -min [expr { $SOC_TCK * 0.10 }] [get_ports { scan_out_o }]
set_output_delay -clock pll_clk1 -max [expr { $SOC_TCK * 0.35 }] [get_ports { scan_out_o }]


# ==========================
# SAM3U USB parallel bus — on-board register interface
# ==========================
# Data bus — bidirectional (FPGA drives during read, SAM3U drives during write)
set_property -dict { PACKAGE_PIN A7   IOSTANDARD LVCMOS33 } [get_ports { usb_data[0] }]
set_property -dict { PACKAGE_PIN B6   IOSTANDARD LVCMOS33 } [get_ports { usb_data[1] }]
set_property -dict { PACKAGE_PIN D3   IOSTANDARD LVCMOS33 } [get_ports { usb_data[2] }]
set_property -dict { PACKAGE_PIN E3   IOSTANDARD LVCMOS33 } [get_ports { usb_data[3] }]
set_property -dict { PACKAGE_PIN F3   IOSTANDARD LVCMOS33 } [get_ports { usb_data[4] }]
set_property -dict { PACKAGE_PIN B5   IOSTANDARD LVCMOS33 } [get_ports { usb_data[5] }]
set_property -dict { PACKAGE_PIN K1   IOSTANDARD LVCMOS33 } [get_ports { usb_data[6] }]
set_property -dict { PACKAGE_PIN K2   IOSTANDARD LVCMOS33 } [get_ports { usb_data[7] }]

# Address bus (from SAM3U → FPGA, active during fpga_read/fpga_write)
set_property -dict { PACKAGE_PIN F4   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[0] }]
set_property -dict { PACKAGE_PIN G5   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[1] }]
set_property -dict { PACKAGE_PIN J1   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[2] }]
set_property -dict { PACKAGE_PIN H1   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[3] }]
set_property -dict { PACKAGE_PIN H2   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[4] }]
set_property -dict { PACKAGE_PIN G1   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[5] }]
set_property -dict { PACKAGE_PIN G2   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[6] }]
set_property -dict { PACKAGE_PIN F2   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[7] }]
set_property -dict { PACKAGE_PIN E1   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[8] }]
set_property -dict { PACKAGE_PIN E2   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[9] }]
set_property -dict { PACKAGE_PIN D1   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[10] }]
set_property -dict { PACKAGE_PIN C1   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[11] }]
set_property -dict { PACKAGE_PIN K3   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[12] }]
set_property -dict { PACKAGE_PIN L2   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[13] }]
set_property -dict { PACKAGE_PIN J3   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[14] }]
set_property -dict { PACKAGE_PIN B2   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[15] }]
set_property -dict { PACKAGE_PIN C7   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[16] }]
set_property -dict { PACKAGE_PIN C6   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[17] }]
set_property -dict { PACKAGE_PIN D6   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[18] }]
set_property -dict { PACKAGE_PIN C4   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[19] }]
set_property -dict { PACKAGE_PIN D5   IOSTANDARD LVCMOS33 } [get_ports { usb_addr[20] }]

# Control signals
set_property -dict { PACKAGE_PIN A4   IOSTANDARD LVCMOS33 } [get_ports { usb_rdn }]
set_property -dict { PACKAGE_PIN C2   IOSTANDARD LVCMOS33 } [get_ports { usb_wrn }]
set_property -dict { PACKAGE_PIN A3   IOSTANDARD LVCMOS33 } [get_ports { usb_cen }]
set_property -dict { PACKAGE_PIN A2   IOSTANDARD LVCMOS33 } [get_ports { usb_alen }]

# USB bus timing (synchronous to usb_clk)
set_input_delay  -clock usb_clk -add_delay 2.000 [get_ports { usb_addr[*] }]
set_input_delay  -clock usb_clk -add_delay 2.000 [get_ports { usb_data[*] }]
set_input_delay  -clock usb_clk -add_delay 2.000 [get_ports { usb_cen usb_rdn usb_wrn }]
# USB data output: SAM3U reads via nRD/nWR handshake, not clock-edge-synchronized.
# IBUF+BUFG (4.6ns) + OBUFT (3.3ns) = 7.9ns overhead exceeds 10ns usb_clk period;
# no register-to-pad path can physically close at 96 MHz on 7-series.
# Internal USB registers are correctly clocked; pad output is handshake-timed.
set_false_path -to [get_ports { usb_data[*] }]
# usb_alen is unused but still constrained
set_false_path -from [get_ports { usb_alen }]


# ==========================
# Bitstream configuration
# ==========================
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH   1       [current_design]
set_property BITSTREAM.CONFIG.CONFIGFALLBACK ENABLE  [current_design]
set_property CONFIG_VOLTAGE                  3.3     [current_design]
set_property CFGBVS                          VCCO    [current_design]
