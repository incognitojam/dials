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

## Before you play anything

Pin the device. Every tool that plays or taps takes the output's UID and stops with an
error if it is missing or matches no device; nothing falls back to the system default
output, because the default may be headphones someone is wearing. Read the UID from
`./build/devices`, and check the name `run.sh` prints before it plays.

Confirm headphones are off a head, or unplugged, before playing to them.

The generated test signal, noise and clicks, peaks at −30 dBFS unless `--level` says
otherwise. Raise it only when a microphone cannot hear the device, and only for a device
nobody is wearing. That limit covers only what the rig generates: in `passthrough` and
`lowpass` the tap re-emits whatever other apps are playing to the device, at their own
level, and nothing limits it, because a limiter would spoil the bit-exact comparison. Quit
or pause other audio first.

## Use

```sh
./build.sh
./build/devices                      # find the UIDs you want
./run.sh control     <output-uid> <mic-uid>
./run.sh passthrough <output-uid> <mic-uid> 64
./run.sh --level -24 lowpass <output-uid> <mic-uid>
python3 analyze.py build/results/passthrough-64-<timestamp>-<pid>
```

`run.sh` checks its arguments, and both UIDs with `./build/devices --require-output` and
`--require-input`, before launching anything. Each run writes to its own prefix, which it
prints. The wrapper exits non-zero unless the run reports `COMPLETED`, and Ctrl-C stops
that run's app, which stops its player and tears the tap down.

`WINDOW_MS` widens the click search window, which a device with high inherent latency
needs — Bluetooth arrives around 250 ms later, well outside the 80 ms default:

```sh
WINDOW_MS=400 python3 analyze.py build/results/control-512-<timestamp>-<pid>
```

`./build/aggregate-check --out-uid <uid>` runs an IOProc that writes silence on that
device, or with `--aggregate` on a plain aggregate holding it and no tap. When a tapped
run reports no callbacks, that separates a broken aggregate from a refused tap.

## Permissions

Both permissions it needs are granted to the signing identity, so the first run of a
freshly built bundle raises a prompt and blocks in `AudioDeviceStart` until it is
answered. A run that times out is usually a dialog nobody clicked.
