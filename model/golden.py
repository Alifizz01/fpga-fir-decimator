"""Bit-exact golden model of the FIR decimator (Q1.15 in, Q1.15 coefficients, Q1.15 out).

y[m] = sat16( floor((sum_k h[k] * x[m*R + R-1 - k] + 2^14) / 2^15) ),  x[n < 0] = 0
"""
import numpy as np
from scipy import signal

NTAPS = 32


def quantize(v):
    """Real values in [-1, 1) to Q1.15 integers (round to nearest, saturate)."""
    return np.clip(np.round(np.asarray(v) * 32768), -32768, 32767).astype(np.int64)


def design_lowpass(r, ntaps=NTAPS):
    """Symmetric (linear-phase) windowed-sinc low-pass with cutoff at the new Nyquist."""
    return quantize(signal.firwin(ntaps, 1.0 / r))


def fir_decimate(x, h, r):
    """Return (y, overflow_flags) as int64 arrays, exactly as the RTL computes them."""
    x = np.asarray(x, dtype=np.int64)
    h = np.asarray(h, dtype=np.int64)
    acc = np.convolve(x, h)[: len(x)]          # exact integer convolution, zero history
    acc = acc[r - 1 :: r][: len(x) // r]       # keep one output per R complete inputs
    q = (acc + (1 << 14)) >> 15                # round half up, arithmetic shift
    y = np.clip(q, -32768, 32767)
    return y, (q != y)


if __name__ == "__main__":
    # self-check: impulse returns the coefficients at the decimated positions
    h = design_lowpass(4)
    x = np.zeros(128, dtype=np.int64)
    x[0] = 32767
    y, ovf = fir_decimate(x, h, 4)
    expect = (h * 32767 + (1 << 14)) >> 15
    assert np.array_equal(y[:8], expect[3::4]), (y[:8], expect[3::4])
    assert not ovf.any()
    print("golden self-check ok")
