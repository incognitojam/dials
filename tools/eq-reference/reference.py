"""Prewarp analog prototypes and substitute s = cot(pi*f/fs)*(1-z^-1)/(1+z^-1)."""

from cmath import exp
from math import log10, pi, sqrt, tan


def design(kind, frequency, gain, q, rate):
    a = 10 ** (gain / 40)
    denominator = (1, 1 / q, 1)
    if kind == "peak":
        numerator = (1, a / q, 1)
        denominator = (1, 1 / (q * a), 1)
    elif kind == "ls":
        numerator = (a, a * sqrt(a) / q, a * a)
        denominator = (a, sqrt(a) / q, 1)
    elif kind == "hs":
        numerator = (a * a, a * sqrt(a) / q, a)
        denominator = (1, sqrt(a) / q, a)
    else:
        numerator = {"bp": (0, 1 / q, 0), "bs": (1, 0, 1),
                     "hp": (1, 0, 0), "lp": (0, 0, 1)}[kind]

    k = 1 / tan(pi * frequency / rate)

    def bilinear(a, b, c):
        return [a*k*k + b*k + c, 2*(c - a*k*k), a*k*k - b*k + c]

    n, d = bilinear(*numerator), bilinear(*denominator)
    return [value / d[0] for value in n + d[1:]]


def magnitude_db(coefficients, z):
    b0, b1, b2, a1, a2 = coefficients
    return 20 * log10(abs((b0 + b1*z + b2*z*z) / (1 + a1*z + a2*z*z)))


for case in [
    ("peak", 20, 6, 2, 192000), ("ls", 105, -4, 0.7, 44100),
    ("hs", 8500, 8, 1.2, 96000), ("bp", 3200, 0, 3, 48000),
    ("bs", 20000, 0, 12, 48000), ("hp", 500, 0, 2**-0.5, 48000),
    ("lp", 500, 0, 2**-0.5, 48000),
]:
    print(case, design(*case))

profile = [("ls", 100, 4, 0.7), ("peak", 2000, -6, 2), ("hs", 8000, 3, 1)]
for frequency in [20, 250, 2000, 10000]:
    z = exp(-2j * pi * frequency / 48000)
    print(frequency, -5 + sum(magnitude_db(design(*band, 48000), z) for band in profile))
