import sys, os, numpy as np
WINDOW = float(os.environ.get('WINDOW_MS', '80'))

RATE = 48000.0

def load(path):
    data = np.fromfile(path, dtype='<f4')
    if data.size == 0:
        return np.zeros((0, 2))
    return data.reshape(-1, 2)

def timeline(path):
    rows = []
    try:
        for line in open(path):
            line = line.strip()
            if line:
                frame, ns = line.split()
                rows.append((int(frame), float(ns)))
    except FileNotFoundError:
        pass
    return rows

def frame_to_ns(rows, frame):
    if not rows:
        return None
    index = np.searchsorted([r[0] for r in rows], frame, side='right') - 1
    index = max(index, 0)
    base_frame, base_ns = rows[index]
    return base_ns + (frame - base_frame) / RATE * 1e9

def ns_to_frame(rows, ns):
    if not rows:
        return None
    times = [r[1] for r in rows]
    index = np.searchsorted(times, ns, side='right') - 1
    index = max(index, 0)
    base_frame, base_ns = rows[index]
    return int(base_frame + (ns - base_ns) / 1e9 * RATE)

def spectrum(signal, block=4096):
    if signal.size < block:
        return None, None
    count = signal.size // block
    trimmed = signal[:count * block].reshape(count, block)
    window = np.hanning(block)
    spectra = np.abs(np.fft.rfft(trimmed * window, axis=1)) ** 2
    power = spectra.mean(axis=0)
    freqs = np.fft.rfftfreq(block, 1 / RATE)
    return freqs, power

def band_db(freqs, power, low, high):
    mask = (freqs >= low) & (freqs < high)
    if not mask.any() or power[mask].sum() <= 0:
        return float('nan')
    return 10 * np.log10(power[mask].mean() + 1e-30)

def rms(x):
    return float(np.sqrt(np.mean(x ** 2))) if x.size else 0.0

def compare_spectra(label, a, b):
    fa, pa = spectrum(a)
    fb, pb = spectrum(b)
    if fa is None or fb is None:
        print(f"  {label}: not enough data")
        return
    print(f"  {label} (positive = second louder)")
    for low, high in [(60, 125), (125, 250), (250, 500), (500, 1000),
                      (1000, 2000), (2000, 4000), (4000, 8000), (8000, 16000)]:
        d = band_db(fb, pb, low, high) - band_db(fa, pa, low, high)
        bar = '#' * max(0, min(40, int(40 + d))) if np.isfinite(d) else ''
        print(f"    {low:>5}-{high:<5} Hz  {d:+7.1f} dB  {bar}")

def latency(prefix, window_ms=80):
    mic = load(prefix + '-mic.f32')
    if mic.size == 0:
        return None
    rows = timeline(prefix + '-mictimes.txt')
    try:
        clicks = [float(x) for x in open(prefix + '-clicks.txt').read().split()]
    except FileNotFoundError:
        return None
    if not rows or not clicks:
        return None

    length = int(RATE * 0.001)
    t = np.arange(length)
    template = np.hanning(length) * np.sin(2 * np.pi * 3000 * t / RATE)
    channel = mic[:, 0] if rms(mic[:, 0]) >= rms(mic[:, 1]) else mic[:, 1]
    correlation = np.abs(np.correlate(channel, template, mode='same'))

    results = []
    for emit in clicks:
        start = ns_to_frame(rows, emit)
        if start is None:
            continue
        window = correlation[max(0, start):min(correlation.size, start + int(RATE * window_ms / 1000))]
        if window.size < 10:
            continue
        peak = int(np.argmax(window))
        if window[peak] < 5 * np.median(correlation) or window[peak] <= 0:
            continue
        arrival = frame_to_ns(rows, max(0, start) + peak)
        results.append((arrival - emit) / 1e6)
    return results

for prefix in sys.argv[1:]:
    name = prefix.split('/')[-1]
    print(f"\n=== {name} ===")
    raw = load(prefix + '-tapraw.f32')
    processed = load(prefix + '-tapproc.f32')
    mic = load(prefix + '-mic.f32')
    print(f"  tap raw   frames {raw.shape[0]:>7}  rms {rms(raw):.6f}")
    print(f"  tap proc  frames {processed.shape[0]:>7}  rms {rms(processed):.6f}")
    print(f"  mic       frames {mic.shape[0]:>7}  rms {rms(mic):.6f}")
    if raw.size and processed.size:
        compare_spectra('tap raw -> processed', raw[:, 0], processed[:, 0])
    values = latency(prefix, WINDOW)
    if values:
        arr = np.array(values)
        print(f"  acoustic latency: n={arr.size}  min {arr.min():.2f}  median {np.median(arr):.2f}  max {arr.max():.2f} ms  spread {arr.max()-arr.min():.2f}")
    elif mic.size:
        print("  acoustic latency: no clicks detected")
