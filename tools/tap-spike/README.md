# tap-spike

The measurement rig behind [System audio taps](../../docs/audio-taps.md). It is not part
of either app and nothing in `Sources` depends on it. It exists so the claims in that
document can be re-run rather than trusted, and so the questions it left open can be
answered when the hardware is to hand.

## What it does

`spike.swift` builds the real thing in miniature: a process tap on a chosen output
device, a private aggregate holding that tap and the device, and one IOProc that filters
the tapped audio and writes it back. It then measures itself.

- **Digital proof.** Every tapped and processed sample is written to disk, so the filter
  can be checked by comparing spectra rather than by ear.
- **Internal latency.** The gap between the tap's input timestamp and the output
  timestamp for the same buffer, sampled every IO cycle.
- **Acoustic latency.** A child process — a separate process, so the tap sees it — plays
  a click train and records the exact host time each click is presented. If a microphone
  is passed, the rig records it and the analysis matches arrivals to emissions. Putting a
  wired microphone inside a headphone cup turns the headphones into the instrument.
- **Muting.** In `silence` mode the tap captures audio and the IOProc writes nothing. If
  the microphone drops to the room noise floor, the original really was suppressed.

## Use

```sh
./build.sh
./build/devices                      # find the UIDs you want
./run.sh control     <output-uid> <mic-uid>
./run.sh passthrough <output-uid> <mic-uid> 64
./run.sh lowpass     <output-uid> <mic-uid>
python3 analyze.py build/results/passthrough-64
```

`WINDOW_MS` widens the click search window, which a device with high inherent latency
needs — Bluetooth arrives around 250 ms later, well outside the 80 ms default:

```sh
WINDOW_MS=400 python3 analyze.py build/results/control-512
```

`./build/aggregate-check` runs an IOProc on the output device and then on a plain
aggregate with no tap. When a tapped run reports no callbacks, that separates a broken
aggregate from a refused tap.

## Two cautions

It plays noise. Levels are set for headphones sitting on a desk, not on a head.

Both permissions it needs are granted to the signing identity, so the first run of a
freshly built bundle raises a prompt and blocks in `AudioDeviceStart` until it is
answered. A run that times out is usually a dialog nobody clicked.
