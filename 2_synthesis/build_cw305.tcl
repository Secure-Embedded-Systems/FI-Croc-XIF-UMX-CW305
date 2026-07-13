# SPDX-License-Identifier: Apache-2.0
# Security Analysis of Microscaling Formats Under Fault Injection on a RISC-V Edge Platform
# Authors: Dillibabu Shanmugam, Patrick Schaumont
# Affiliation: Worcester Polytechnic Institute (WPI), USA

# =============================================================================
# Vivado Build Flow — CROC + MX Coprocessor for CW305-A35T
# =============================================================================
#
# Usage:
#   vivado -mode batch -source fpga/cw305/scripts/build_cw305.tcl
#
# Prerequisite:
#   make setup   (creates croc/ directory with symlinks + MX files)
#
# Output:
#   fpga/cw305/build/croc_cw305.bit  — bitstream for CW305 programming
#
# Programming via ChipWhisperer Python:
#   import chipwhisperer as cw
#   target = cw.target(scope, cw.targets.CW305, bsfile="croc_cw305.bit")
# =============================================================================

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize "${script_dir}/.."]
set croc_root [file normalize "${script_dir}/../../../croc"]

# CW305-A35T FPGA part
set fpga_part "xc7a35tftg256-2"

# Parallelism
set num_threads 4
set num_jobs 4
set_param general.maxThreads $num_threads

# Clean and create project
set build_dir "${project_root}/build"
file mkdir $build_dir
file delete -force [glob -nocomplain ${build_dir}/*]
create_project croc_cw305 $build_dir -force -part $fpga_part

# ---- Load constraints ----
import_files -fileset constrs_1 -norecurse ${project_root}/src/cw305.xdc

# ---- BRAM init files ----
# Copy .mem files to both project build dir AND synthesis run dir.
# XPM $readmem executes in croc_cw305.runs/synth_1/, not the project root.
foreach memfile [glob -nocomplain ${project_root}/src/*.mem] {
    file copy -force $memfile ${build_dir}/[file tail $memfile]
}
# Pre-create synth_1 dir and copy .mem files there too (XPM needs them here)
file mkdir ${build_dir}/croc_cw305.runs/synth_1
foreach memfile [glob -nocomplain ${project_root}/src/*.mem] {
    file copy -force $memfile ${build_dir}/croc_cw305.runs/synth_1/[file tail $memfile]
}

# ---- Load RTL sources ----
source ${project_root}/scripts/add_sources.cw305.tcl

# ---- Set top module ----
set_property top croc_cw305 [current_fileset]
update_compile_order -fileset sources_1

# ---- Synthesis properties ----
set_property XPM_LIBRARIES XPM_MEMORY [current_project]
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]

# ---- Synthesis ----
launch_runs -jobs $num_jobs synth_1
wait_on_run synth_1
open_run synth_1

# Synthesis reports
file mkdir ${build_dir}/reports.synth
report_utilization       -file ${build_dir}/reports.synth/utilization.rpt -hierarchical
report_timing_summary    -file ${build_dir}/reports.synth/timing_summary.rpt

# ---- Implementation ----
set_property strategy Performance_ExtraTimingOpt [get_runs impl_1]
launch_runs -jobs $num_jobs impl_1 -to_step write_bitstream
wait_on_run impl_1
open_run impl_1

# Implementation reports
file mkdir ${build_dir}/reports.impl
report_utilization       -file ${build_dir}/reports.impl/utilization.rpt -hierarchical
report_timing_summary    -file ${build_dir}/reports.impl/timing_summary.rpt
report_timing            -file ${build_dir}/reports.impl/timing_worst_100.rpt -max_paths 100 -nworst 100

# ---- Check timing ----
set trep [report_timing_summary -no_header -no_detailed_paths -return_string]
if { ![string match -nocase {*timing constraints are met*} $trep] } {
    puts "WARNING: Timing constraints NOT met.  Check reports."
} else {
    puts "INFO: All timing constraints met."
}

# ---- Copy bitstream ----
file mkdir ${project_root}/out
file copy -force ${build_dir}/croc_cw305.runs/impl_1/croc_cw305.bit \
    ${project_root}/out/croc_cw305.bit

puts "=== Build complete: ${project_root}/out/croc_cw305.bit ==="
