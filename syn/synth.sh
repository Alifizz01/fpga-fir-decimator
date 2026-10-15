#!/usr/bin/env bash
# Open-source synthesis check: GHDL converts the VHDL-2008 RTL to a Verilog
# netlist, Yosys synthesises it for Lattice ECP5 and prints a utilisation report.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
ghdl synth --std=08 --out=verilog \
  rtl/regmap_pkg.vhd rtl/fir_pkg.vhd rtl/axil_regs.vhd rtl/fir_decim.vhd rtl/axi_fir_top.vhd \
  -e axi_fir_top > build/axi_fir_top.v
yosys -q -l build/yosys_ecp5.log -p "read_verilog build/axi_fir_top.v; synth_ecp5 -top axi_fir_top; tee -o build/stat_ecp5.txt stat"
cat build/stat_ecp5.txt
