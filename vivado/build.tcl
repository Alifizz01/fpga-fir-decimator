# Vivado non-project-mode build, out-of-context (no pin assignment).
# Usage (from repo root):  vivado -mode batch -source vivado/build.tcl
# Optional part override:  vivado -mode batch -source vivado/build.tcl -tclargs xc7a35tcpg236-1
set part [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xc7a35tcpg236-1"}]
set root [file normalize [file dirname [info script]]/..]
set out  $root/build/vivado
file mkdir $out

read_vhdl -vhdl2008 [list \
  $root/rtl/regmap_pkg.vhd $root/rtl/fir_pkg.vhd $root/rtl/axil_regs.vhd \
  $root/rtl/fir_decim.vhd $root/rtl/axi_fir_top.vhd]
read_xdc -mode out_of_context $root/vivado/axi_fir_top.xdc

synth_design -top axi_fir_top -part $part -mode out_of_context
report_utilization -file $out/post_synth_util.rpt
opt_design
place_design
route_design
report_utilization    -file $out/post_route_util.rpt
report_timing_summary -file $out/post_route_timing.rpt
puts "Reports written to $out"
