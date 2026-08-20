# System audio taps

neqMac equalises audio it does not own, so it has to get inside a signal path that
belongs to other applications. There are two ways to do that on macOS, and this
records why the second one was chosen and what it costs.

The first is a HAL virtual driver, which is how eqMac does it: install a fake output
device, make it the system default, process, forward to the real hardware. It works,
but it puts a device in the Sound picker that is not a device, and it makes the system
default something other than the hardware — which is exactly the state neqMac's routing
policy exists to reason about.

The second is a Core Audio process tap, available since macOS 14.2. Everything below
was measured on real hardware before any of it was built into the app: a USB DAC at
48 kHz and a Bluetooth headset over A2DP at 44.1 kHz, with a wired microphone sitting
inside the headphone cup so the acoustic path could be measured rather than assumed.

## The shape that works

Create a tap bound to the current output device and stream, exclusive, excluding
neqMac's own process, with `muteBehavior` set to `mutedWhenTapped`. Put that tap and
the real output device into one private aggregate device. Run a single IOProc on the
aggregate: read the tapped mix, filter it, write it to the real output.

Every other application's audio to that device is captured and silenced at the same
moment, and neqMac plays the processed copy in its place. The system default output
stays the real hardware, nothing new appears in the Sound picker, hardware volume keys
keep working, and there is no driver to install.

Excluding neqMac's own process from the tap is what stops the processed output being
captured again as input.

## It needs two permissions, and fails silently without either

A tap requires `kTCCServiceMicrophone` to be created and `kTCCServiceAudioCapture` to
deliver samples. Both usage strings must be present in `Info.plist`:

- `NSMicrophoneUsageDescription`
- `NSAudioCaptureUsageDescription`

Miss the second one and the system refuses to even ask:

```
Refusing authorization request for service kTCCServiceAudioCapture ...
without NSAudioCaptureUsageDescription key
```

The failure is invisible from the API. `AudioHardwareCreateProcessTap` returns `noErr`,
the aggregate assembles with the expected stream layout, the IOProc runs at the normal
rate — and every sample is zero. Because `mutedWhenTapped` has already silenced the
real audio by then, an unauthorised tap does not degrade playback, it stops it.

So an authorised tap that reads continuous digital silence has to be treated as a
failure. Without that check the app has one way to mute the machine and no way to
notice.

The permission attaches to the signing identity, which is why `build-app.sh` signs with
a stable certificate. An ad-hoc rebuild drops both grants.

## It must be a signed bundle that is its own responsible process

TCC attributes a tap request to the *responsible* process, not the one calling the API.
A command-line binary is therefore attributed to whatever launched it, and if that
parent is hardened-runtime signed without `com.apple.security.device.audio-input`, TCC
refuses to prompt at all. A helper tool can never hold this permission on its own.

## What it costs

The tap adds one IO cycle in each direction. Measured delay between the tap's input
timestamp and the output timestamp for the same buffer, at the device's own rate:

| Buffer | 48 kHz (USB) | 44.1 kHz (Bluetooth) |
| ---: | ---: | ---: |
| 64 | 4.50 ms | 2.90 ms |
| 128 | 7.17 ms | 5.80 ms |
| 256 | 12.50 ms | — |
| 512 (default) | 23.17 ms | 23.22 ms |
| 1024 | 44.50 ms | — |

It is `2 × buffer / rate` plus the device's safety offsets, and it is stable to 0.01 ms
across thousands of cycles. The aggregate accepts a requested buffer size down to 64
frames, so this is a tunable rather than a fixed cost.

Measured acoustically through a microphone in the headphone cup, the real added delay
is about 2.3 ms more than the timestamps report — 6.81 ms rather than 4.50 ms at 64
frames — presumably the tap's own capture buffering ahead of the IOProc. Treat the
internal figure as a lower bound.

None of this matters on Bluetooth, where the headset already declares 8961 frames of
latency, about 203 ms, and measured 248.7 ms acoustically end to end.

## What the tap delivers

Bit-exact. A passthrough IOProc reproduces the tapped signal with identical RMS and
0.0 dB difference in every octave band, and the acoustic level through the speaker
matches an untapped control within 0.2 dB on USB and 0.4 dB on Bluetooth.

A second-order low-pass at 500 Hz applied to the tapped stream measured −1.2 dB at
250–500 Hz, −6.8 dB at 500–1000 Hz, −17.7 dB at 1–2 kHz and −56.5 dB at 8–16 kHz: the
12 dB per octave the filter asks for.

Muting works. With the IOProc writing silence, a microphone inside the cup drops to the
room noise floor on both transports, so the original audio is genuinely suppressed
rather than played alongside the processed copy.

## Filters belong to devices, not to the app

The tap's format follows the device, and the two tested devices do not agree: 48 kHz on
USB, 44.1 kHz over A2DP. Biquad coefficients depend on the sample rate, so a stored EQ
profile has to be frequencies, gains and Q values, with coefficients derived whenever
the output device or its rate changes.

## Two things not to repeat

`kAudioHardwarePropertyTranslatePIDToProcessObject` fails transiently just after launch,
before the process is registered, and a tap cannot be built without it. One measurement
run died outright on this. It needs a retry rather than a single attempt.

Once a permission prompt for an identity has gone unanswered, later requests from that
identity appear to block rather than take the fast refusal path — runs hung in
`AudioDeviceStart` with nothing logged. Deleting the usage-description key to force a
quick denial does not get the old behaviour back.

## Open questions

The acoustic arrival time of a tapped Bluetooth stream could not be measured. An
untapped control clustered at 248.7 ms within 0.1 ms, while the same measurement through
the tap scattered across a 300 ms range without clustering, non-monotonically, at a
40 dB click-to-noise ratio. The internal timestamps were perfectly stable throughout,
and level and muting both checked out, so this may be an artefact of the measurement
rather than the audio path. It should be understood before shipping EQ over Bluetooth.

The headset's own processing is the first thing to rule out. Noise cancelling is
adaptive rather than a fixed transfer function, and the tested headset also carries a
vendor equaliser and upscaling, all of it sitting between the Mac's output and the
microphone in the cup. The wired measurements went through passive headphones and were
stable to 0.1 ms, so any repeat should disable noise cancelling and vendor EQ first.

That processing matters beyond measurement. A vendor equaliser applies *after* neqMac's,
and published correction curves target the raw driver response, so a profile stacked on
top of a headset's own tuning will correct twice. Profiles need to record what the
headset was set to.

Also untested: whether alert sounds and applications that open a device exclusively are
caught by the tap, what happens to a running tap when its device disappears, and how to
retarget the tap when the routing policy changes the output device.
