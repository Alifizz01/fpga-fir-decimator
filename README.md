# axi-fir-decimator

A small FPGA DSP block in VHDL-2008: a 32-tap FIR decimator with an AXI4-Stream
data path and an AXI4-Lite register interface, verified bit-exact against a
Python/NumPy golden model with cocotb and GHDL.

I built it as a learning project to practise AXI interfaces, fixed-point DSP on
FPGA, register maps and a vendor build flow. It is a personal project and is not
affiliated with any employer.

## Architecture

```
            AXI4-Lite (32-bit)                     aclk (single clock domain)
                  |
          +-------v--------+   enable, soft_rst, R, h[0..31]
          |   axil_regs    |------------------------------+
          | (register map) |<--------- overflow, count, busy
          +----------------+                              |
                                                          v
 s_axis (Q1.15) --> [ history 32 x 16 bit ] --> [ operand regs ] --> [ 16x16 mult ] --> [ 40-bit acc ]
   tvalid/tready      shift on each accepted       mux h[k], x[n-k]      1 DSP              |
                      sample; every R-th one                                   round, saturate, flag
                      starts 32 MAC cycles                                                  |
                                                               m_axis (Q1.15) <-- [ output reg ]
                                                                                   tvalid/tready
```

- **Clocking:** one clock (`aclk`) for the AXI4-Lite slave, both streams and the
  datapath. Synchronous active-low reset `aresetn`. There is no CDC logic; if
  control and data run on different clocks, put an AXI clock converter outside.
- **Arithmetic:** input, coefficients and output are signed Q1.15. Products are
  31 bit, accumulated in 40 bits (no internal overflow possible for 32 taps).
  Output = `sat16(floor((acc + 2^14) / 2^15))`: round half up, saturate to
  [-32768, 32767]; a saturation sets the sticky OVERFLOW bit.
- **Decimation:** an output is produced after every R accepted input samples
  (R = 2..8): `y[m] = sum h[k] * x[mR + R-1 - k]`, history starts at zero.
- **Throughput:** one shared multiplier. Each output costs R input handshakes plus
  about 36 cycles of MAC and pipeline drain (from the state machine, so roughly
  R + 36 cycles per output). `s_axis_tready` is low while the MAC runs and while
  an output waits for `m_axis_tready`. This trades throughput for 1 DSP.
- **Backpressure:** both streams follow the AXI4-Stream valid/ready rule. Output
  data is held stable while `tvalid` is high and `tready` is low (checked by the
  testbench on every cycle).

Files: `rtl/axil_regs.vhd`, `rtl/fir_decim.vhd`, `rtl/axi_fir_top.vhd`,
`rtl/fir_pkg.vhd`, `rtl/regmap_pkg.vhd` (generated).

## Register map

Single source: `regmap.py`. `python regmap.py` regenerates `rtl/regmap_pkg.vhd`
(addresses and reset values used by the RTL) and `docs/regmap.md`. CI fails if
they are out of sync. The testbench also imports `regmap.py` for its addresses
and expected reset values.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | CTRL | RW | 0x00000000 | bit0 ENABLE (1 = accept input samples). bit1 SOFT_RESET (write 1, self-clearing): clears sample history, decimation phase, output, SAMPLE_COUNT and OVERFLOW. Coefficients are kept. |
| 0x04 | DECIM | RW | 0x00000002 | bits[3:0] decimation factor R. Valid 2..8. Writes outside 2..8 are ignored (old value kept). Change only while ENABLE = 0, then pulse SOFT_RESET. |
| 0x08 | COEF_ADDR | RW | 0x00000000 | bits[4:0] tap index 0..31 used by COEF_DATA. Auto-increments (wraps 31 -> 0) after every COEF_DATA write. |
| 0x0C | COEF_DATA | RW | 0x00000000 | bits[15:0] signed Q1.15 coefficient. Write stores h[COEF_ADDR]; read returns h[COEF_ADDR] sign-extended. All taps reset to 0. |
| 0x10 | STATUS | RW1C | 0x00000000 | bit0 OVERFLOW (sticky, set when an output saturated; write 1 to clear). bit1 BUSY (read-only, MAC running or output waiting for tready). |
| 0x14 | SAMPLE_COUNT | RO | 0x00000000 | Number of output samples accepted by the downstream sink (wraps at 2^32). |
| 0x18 | VERSION | RO | 0x00010000 | IP version, 0xMMMMmmmm (major.minor). |

Any other address returns SLVERR on read and write (reads return 0).

Loading coefficients: write 0 to COEF_ADDR, then write the 32 taps to COEF_DATA.

## How to run

Requirements: Python 3.10+, GHDL (tested with 6.0.0, mcode), Yosys (OSS CAD Suite).

```
pip install -r requirements.txt
python model/golden.py      # golden model self-check
python tb/run.py            # build with GHDL, run all cocotb tests
bash syn/synth.sh           # GHDL synth -> Yosys synth_ecp5, prints utilisation
```

On Windows, GHDL's `lib` folder and cocotb's `libs` folder must be on `PATH` so
the VPI DLLs load.

## Verification

Golden model: `model/golden.py` computes the same integer arithmetic as the RTL
(`np.convolve` on integers, decimate, round, saturate). Coefficients are designed
with `scipy.signal.firwin` (symmetric windowed-sinc, cutoff at the new Nyquist)
and quantised to Q1.15.

| Test | What it checks |
|---|---|
| test_reset_values | All 7 registers read their documented reset value |
| test_register_rw | Read back of CTRL, DECIM (all legal values; 0, 1, 9, 15, 0x102 rejected), all 32 coefficients with auto-increment and wrap, writes to RO registers ignored |
| test_illegal_address | Writes and reads to 0x1C, 0x20, 0x40, 0xFC return SLVERR and change nothing |
| test_lowpass_random_backpressure (x7) | R = 2..8, firwin low-pass, random input, random tvalid (70%) and tready (60%), bit-exact vs golden, SAMPLE_COUNT, OVERFLOW |
| test_random_coefficients | Non-symmetric random taps, full-scale random input, R = 3, bit-exact |
| test_impulse | Impulse response equals the (decimated) coefficients |
| test_step | Settled step output equals DC gain within 1 LSB |
| test_two_tone_spectrum | Passband tone vs folded stopband tone at R = 4, FFT check requires > 40 dB |
| test_overflow_flag | Saturation to +32767 and -32768 bit-exact, OVERFLOW set, cleared by write-1 |
| test_soft_reset_and_disable | SOFT_RESET clears SAMPLE_COUNT, tready stays low while disabled |

Every stream test also checks the AXI4-Stream stability rule on the output.

### Results from my runs (2026-10-15, Windows 11, GHDL 6.0.0 mcode, cocotb 2.1.0)

- cocotb: **16 tests, 16 pass, 0 fail**, about 353 us simulated time.
- Two-tone test: passband to aliased-stopband ratio **68.5 dB** at R = 4.
- Yosys 0.70 `synth_ecp5` (via `ghdl synth`): 1550 LUT4, 1239 FF, 102 CCU2C,
  201 PFUMX, 1 L6MUX21, **1 MULT18X18D**. No timing analysis was done for ECP5
  (no place and route run).

Coverage-style summary: all 7 registers, all 4 access types (RW, RW1C, RO,
illegal), all 7 legal decimation factors plus 5 illegal values, 3 coefficient
sources (firwin designs, random, all-max), both saturation directions, random
backpressure on both streams. Not covered: wstrb partial writes (ignored by
design), R changed while streaming, simultaneous OVERFLOW event and clear.

## Run in Vivado

Script: `vivado/build.tcl` (non-project mode, out-of-context, VHDL-2008), clock
constraint `vivado/axi_fir_top.xdc` (100 MHz on `aclk`). Default part
`xc7a35tcpg236-1` (Artix-7 35T, supported by the free Vivado ML Standard).

```
cd axi-fir-decimator
vivado -mode batch -source vivado/build.tcl
# other part:  vivado -mode batch -source vivado/build.tcl -tclargs xc7a100tcsg324-1
```

Reports land in `build/vivado/`: `post_synth_util.rpt`, `post_route_util.rpt`,
`post_route_timing.rpt`. I have **not** run this script yet; the table below is
empty until I do.

| Metric (xc7a35tcpg236-1, 100 MHz) | Value |
|---|---|
| Slice LUTs | pending |
| Slice registers | pending |
| DSP48E1 | pending |
| Block RAM | pending |
| WNS (ns) | pending |
| Vivado version | pending |

## Limitations

- Simulated and synthesised only. Not run on any FPGA board; no hardware
  measurements.
- Vivado utilisation and timing are pending my local run (table above). The ECP5
  numbers are from Yosys synthesis only, with no place and route.
- Low throughput by design (one multiplier, about R + 36 cycles per output); not
  a polyphase or systolic implementation, and it does not exploit coefficient
  symmetry.
- History and coefficients live in registers, not BRAM. Fine for 32 taps.
- No TLAST/TUSER handling, no wstrb byte writes, single outstanding AXI4-Lite
  transaction per channel.
- Changing R or coefficients while streaming is not supported; disable, change,
  soft reset.
- Personal learning project, not affiliated with or endorsed by any company.
