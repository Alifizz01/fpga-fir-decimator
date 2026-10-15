"""Build the RTL with GHDL and run the cocotb tests:  python tb/run.py"""
import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_results, get_runner

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / "rtl" / f for f in
           ("regmap_pkg.vhd", "fir_pkg.vhd", "axil_regs.vhd", "fir_decim.vhd", "axi_fir_top.vhd")]

if __name__ == "__main__":
    os.environ["PYTHONPATH"] = os.pathsep.join([str(ROOT / "tb"), os.environ.get("PYTHONPATH", "")])
    runner = get_runner("ghdl")
    runner.build(sources=SOURCES, hdl_toplevel="axi_fir_top", build_args=["--std=08"],
                 build_dir=ROOT / "sim_build", always=True)
    results = runner.test(hdl_toplevel="axi_fir_top", test_module="test_axi_fir",
                          build_dir=ROOT / "sim_build", test_args=["--std=08"])
    total, failed = get_results(results)
    print(f"TOTAL={total} FAILED={failed}")
    sys.exit(1 if failed else 0)
