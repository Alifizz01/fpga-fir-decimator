"""cocotb tests for axi_fir_top (AXI4-Lite registers + AXI4-Stream FIR decimator)."""
import random
import sys
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT), str(ROOT / "model")]
from golden import NTAPS, design_lowpass, fir_decimate, quantize  # noqa: E402
from regmap import REGS  # noqa: E402

A = {name: off for name, off, *_ in REGS}
OKAY, SLVERR = 0, 2


# ---------------------------------------------------------------- AXI helpers
async def wait_hs(dut, valid, ready):
    """Hold until valid and ready are both high at a rising edge."""
    while True:
        await ReadOnly()
        if int(getattr(dut, valid).value) and int(getattr(dut, ready).value):
            await RisingEdge(dut.aclk)
            return
        await RisingEdge(dut.aclk)


async def axil_write(dut, addr, data):
    dut.s_axil_awaddr.value = addr
    dut.s_axil_wdata.value = data & 0xFFFFFFFF
    dut.s_axil_wstrb.value = 0xF
    dut.s_axil_awvalid.value = 1
    dut.s_axil_wvalid.value = 1
    await wait_hs(dut, "s_axil_awvalid", "s_axil_awready")
    dut.s_axil_awvalid.value = 0
    dut.s_axil_wvalid.value = 0
    dut.s_axil_bready.value = 1
    while True:
        await ReadOnly()
        if int(dut.s_axil_bvalid.value):
            resp = int(dut.s_axil_bresp.value)
            await RisingEdge(dut.aclk)
            break
        await RisingEdge(dut.aclk)
    dut.s_axil_bready.value = 0
    return resp


async def axil_read(dut, addr):
    dut.s_axil_araddr.value = addr
    dut.s_axil_arvalid.value = 1
    await wait_hs(dut, "s_axil_arvalid", "s_axil_arready")
    dut.s_axil_arvalid.value = 0
    dut.s_axil_rready.value = 1
    while True:
        await ReadOnly()
        if int(dut.s_axil_rvalid.value):
            data, resp = int(dut.s_axil_rdata.value), int(dut.s_axil_rresp.value)
            await RisingEdge(dut.aclk)
            break
        await RisingEdge(dut.aclk)
    dut.s_axil_rready.value = 0
    return data, resp


async def write_ok(dut, name, data):
    assert await axil_write(dut, A[name], data) == OKAY


async def read_ok(dut, name):
    data, resp = await axil_read(dut, A[name])
    assert resp == OKAY
    return data


async def setup(dut):
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    for s in ("s_axil_awvalid", "s_axil_wvalid", "s_axil_bready", "s_axil_arvalid",
              "s_axil_rready", "s_axis_tvalid", "m_axis_tready"):
        getattr(dut, s).value = 0
    dut.s_axil_awaddr.value = 0
    dut.s_axil_wdata.value = 0
    dut.s_axil_wstrb.value = 0
    dut.s_axil_araddr.value = 0
    dut.s_axis_tdata.value = 0
    dut.aresetn.value = 0
    for _ in range(5):
        await RisingEdge(dut.aclk)
    dut.aresetn.value = 1
    await RisingEdge(dut.aclk)


async def load_coefs(dut, h):
    await write_ok(dut, "COEF_ADDR", 0)
    for c in h:
        await write_ok(dut, "COEF_DATA", int(c) & 0xFFFF)


# ------------------------------------------------------------- stream helpers
async def stream_source(dut, samples, p_valid):
    i = 0
    dut.s_axis_tvalid.value = 0
    while i < len(samples):
        if not int(dut.s_axis_tvalid.value) and random.random() < p_valid:
            dut.s_axis_tdata.value = int(samples[i]) & 0xFFFF
            dut.s_axis_tvalid.value = 1
        await ReadOnly()
        hs = int(dut.s_axis_tvalid.value) and int(dut.s_axis_tready.value)
        await RisingEdge(dut.aclk)
        if hs:
            i += 1
            dut.s_axis_tvalid.value = 0
    dut.s_axis_tvalid.value = 0


async def stream_sink(dut, n, p_ready, out):
    """Collect n outputs with random tready; check tdata stays stable while stalled."""
    held = None
    while len(out) < n:
        dut.m_axis_tready.value = 1 if random.random() < p_ready else 0
        await ReadOnly()
        if int(dut.m_axis_tvalid.value):
            d = dut.m_axis_tdata.value.to_signed()
            assert held is None or held == d, "tdata changed while tvalid high and not accepted"
            if int(dut.m_axis_tready.value):
                out.append(d)
                held = None
            else:
                held = d
        else:
            assert held is None, "tvalid dropped before handshake"
        await RisingEdge(dut.aclk)
    dut.m_axis_tready.value = 0


async def run_stream(dut, x, h, r, p_valid=0.7, p_ready=0.6):
    await load_coefs(dut, h)
    await write_ok(dut, "DECIM", r)
    await write_ok(dut, "CTRL", 0b10)   # soft reset
    await write_ok(dut, "CTRL", 0b01)   # enable
    exp, ovf = fir_decimate(x, h, r)
    out = []
    src = cocotb.start_soon(stream_source(dut, x, p_valid))
    await stream_sink(dut, len(exp), p_ready, out)
    await src
    assert np.array_equal(np.array(out), exp), _diff(out, exp)
    assert await read_ok(dut, "SAMPLE_COUNT") == len(exp)
    assert (await read_ok(dut, "STATUS")) & 1 == int(ovf.any())
    return np.array(out)


def _diff(out, exp):
    bad = [i for i, (a, b) in enumerate(zip(out, exp)) if a != b]
    return f"{len(bad)} mismatches, first at {bad[:5]}: got {[out[i] for i in bad[:5]]} exp {[int(exp[i]) for i in bad[:5]]}"


def rand_q15(n, amp=0.5, seed=1):
    return quantize(np.random.default_rng(seed).uniform(-amp, amp, n))


# ---------------------------------------------------------------------- tests
@cocotb.test()
async def test_reset_values(dut):
    await setup(dut)
    for name, off, _, reset, _ in REGS:
        data, resp = await axil_read(dut, off)
        assert resp == OKAY and data == reset, f"{name}: 0x{data:08X} != 0x{reset:08X}"


@cocotb.test()
async def test_register_rw(dut):
    await setup(dut)
    await write_ok(dut, "CTRL", 1)
    assert await read_ok(dut, "CTRL") == 1
    await write_ok(dut, "CTRL", 0)
    assert await read_ok(dut, "CTRL") == 0
    for r in range(2, 9):
        await write_ok(dut, "DECIM", r)
        assert await read_ok(dut, "DECIM") == r
    for bad in (0, 1, 9, 15, 0x102):
        await write_ok(dut, "DECIM", bad)
        assert await read_ok(dut, "DECIM") == 8, f"illegal DECIM {bad} was accepted"
    h = [random.randint(-32768, 32767) for _ in range(NTAPS)]
    await load_coefs(dut, h)
    assert await read_ok(dut, "COEF_ADDR") == 0, "COEF_ADDR should wrap to 0 after 32 writes"
    for i, c in enumerate(h):
        await write_ok(dut, "COEF_ADDR", i)
        v = await read_ok(dut, "COEF_DATA")
        assert v == (c & 0xFFFFFFFF), f"tap {i}: 0x{v:08X} vs {c}"
    await write_ok(dut, "VERSION", 0)
    assert await read_ok(dut, "VERSION") == REGS[-1][3]
    await write_ok(dut, "SAMPLE_COUNT", 123)
    assert await read_ok(dut, "SAMPLE_COUNT") == 0


@cocotb.test()
async def test_illegal_address(dut):
    await setup(dut)
    for addr in (0x1C, 0x20, 0x40, 0xFC):
        assert await axil_write(dut, addr, 0xDEADBEEF) == SLVERR
        data, resp = await axil_read(dut, addr)
        assert resp == SLVERR and data == 0
    assert await read_ok(dut, "CTRL") == 0   # illegal writes changed nothing


@cocotb.test()
@cocotb.parametrize(r=list(range(2, 9)))
async def test_lowpass_random_backpressure(dut, r):
    await setup(dut)
    random.seed(r)
    await run_stream(dut, rand_q15(40 * r, seed=r), design_lowpass(r), r)


@cocotb.test()
async def test_random_coefficients(dut):
    """Non-symmetric random taps, full-scale input, no backpressure."""
    await setup(dut)
    rng = np.random.default_rng(7)
    h = rng.integers(-2000, 2000, NTAPS)
    await run_stream(dut, rng.integers(-32768, 32768, 300), h, 3, p_valid=1.0, p_ready=1.0)


@cocotb.test()
async def test_impulse(dut):
    await setup(dut)
    h = design_lowpass(2)
    x = np.zeros(80, dtype=np.int64)
    x[1] = 32767           # lands on the last sample of the first decimation group
    y = await run_stream(dut, x, h, 2)
    assert np.array_equal(y[:16], (h[0::2] * 32767 + (1 << 14)) >> 15)


@cocotb.test()
async def test_step(dut):
    await setup(dut)
    h = design_lowpass(4)
    x = np.full(160, 16384, dtype=np.int64)    # 0.5 full scale
    y = await run_stream(dut, x, h, 4)
    dc_gain = h.sum() / 32768
    assert abs(y[-1] - 16384 * dc_gain) <= 1, (y[-1], 16384 * dc_gain)


@cocotb.test()
async def test_two_tone_spectrum(dut):
    """Passband tone survives, stopband tone (would alias after R=4) is attenuated."""
    await setup(dut)
    r, n = 4, 1024
    h = design_lowpass(r)
    t = np.arange(n)
    f_pass, f_stop = 0.025, 0.30          # cycles/sample at the input rate
    x = quantize(0.4 * np.sin(2 * np.pi * f_pass * t) + 0.4 * np.sin(2 * np.pi * f_stop * t))
    y = await run_stream(dut, x, h, r, p_valid=0.9, p_ready=0.9)
    ys = y[NTAPS:]                         # drop the filter start-up
    spec = np.abs(np.fft.rfft(ys * np.hanning(len(ys))))
    freqs = np.fft.rfftfreq(len(ys))       # cycles/sample at the output rate
    p = spec[np.argmin(abs(freqs - f_pass * r))]
    alias = abs(((f_stop * r + 0.5) % 1.0) - 0.5)   # where the stopband tone folds to
    s = spec[np.argmin(abs(freqs - alias))]
    rej_db = 20 * np.log10(p / max(s, 1e-9))
    dut._log.info("two-tone: passband/alias ratio %.1f dB", rej_db)
    assert rej_db > 40, f"stopband rejection only {rej_db:.1f} dB"


@cocotb.test()
async def test_overflow_flag(dut):
    await setup(dut)
    h = np.full(NTAPS, 32767)
    x = np.full(64, 32767)
    x[32:] = -32768
    y = await run_stream(dut, x, h, 2, p_valid=1.0, p_ready=1.0)
    assert 32767 in y and -32768 in y
    st = await read_ok(dut, "STATUS")
    assert st & 1, "OVERFLOW not set"
    await write_ok(dut, "STATUS", 1)       # write 1 to clear
    assert (await read_ok(dut, "STATUS")) & 1 == 0


@cocotb.test()
async def test_soft_reset_and_disable(dut):
    await setup(dut)
    await run_stream(dut, rand_q15(40), design_lowpass(2), 2)
    assert await read_ok(dut, "SAMPLE_COUNT") == 20
    await write_ok(dut, "CTRL", 0b10)
    assert await read_ok(dut, "SAMPLE_COUNT") == 0
    assert await read_ok(dut, "CTRL") == 0           # soft reset clears ENABLE too (bit0 written 0)
    dut.s_axis_tvalid.value = 1
    for _ in range(5):
        await ReadOnly()
        assert int(dut.s_axis_tready.value) == 0, "tready high while disabled"
        await RisingEdge(dut.aclk)
    dut.s_axis_tvalid.value = 0
