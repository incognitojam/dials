# System audio taps

neqMac equalises audio it does not own, so it has to get inside a signal path that
belongs to other applications. There are two ways to do that on macOS, and this
records why the second one was chosen and what it costs.

The first is a HAL virtual driver, which is how eqMac does it: install a fake output
device, make it the system default, process, forward to the real hardware. It works,
but it puts a device in the Sound picker that is not a device, and it makes the system
default something other than the hardware — which is exactly the state neqMac's routing
policy exists to reason about.

The second is a Core Audio process tap, available since macOS 14.2. The first
measurements below were made on real hardware before any of it was built into the app:
a USB DAC at 48 kHz and a Bluetooth headset over A2DP at 44.1 kHz, with a wired
microphone sitting inside the headphone cup so the acoustic path could be measured
rather than assumed. [What the tap does at its edges](#what-the-tap-does-at-its-edges)
was measured later, on different hardware, and says how.
The harness is in [`tools/tap-spike`](../tools/tap-spike/README.md).

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

Continuous digital silence cannot be treated as that failure, though: a paused or silent
player sends exact zeros too, as [Silence is
normal](#silence-is-normal-and-so-is-no-io-at-all) records. From the samples alone the
app has one way to mute the machine and no way to notice; how a missing or revoked
permission can be detected is still open.

The permission attaches to the signing identity, so build with a stable `neqMac Local`
certificate, as described in [Signing](development.md#signing). An ad-hoc rebuild drops
both grants.

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
latency, about 203 ms, and in these in-cup runs an untapped control measured 248.7 ms
acoustically end to end.

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

## What the tap does at its edges

The measurements above describe a tap that is already running. These describe what
happens when one is built, torn down, retargeted, stalled or killed, when the device
changes rate or disappears, and when nothing is playing. They were measured later, on
macOS 27.0.1, with the built-in speakers (44.1 kHz, 512 frames) and the same Bluetooth
headset (A2DP, 44.1 kHz, 512 frames, 8961 frames of declared latency), before a USB DAC
was to hand and without the microphone in the cup. The harness is the same tap,
aggregate and IOProc as above, in an experimental build of the rig.

The source was a separate process playing a 1 kHz tone at −36 dBFS to one named device.
Instead of passing audio through, the tapping process wrote a 1.5 kHz marker whose level
followed the captured input, so the built-in microphone could tell the original from
the processed copy, and silence from both. The analysis split the microphone signal into
5 ms steps and counted a tone as present in a step when it was within 10 dB of the
original's level measured before the tap was built (the marker's threshold is 6 dB lower
again, since it is written 6 dB down).

Two limits apply to everything below:

- **Only the speakers were heard.** At −36 dBFS the built-in microphone could not hear
  the headset over its noise floor. Every headset figure comes from callback times and
  IO timestamps, and is marked *inferred*. Nothing here says what the headset audibly
  did.
- **Acoustic and host times line up only roughly.** The procedure estimates the
  speaker-to-microphone path at 45–85 ms, which the HAL does not report, and so treats
  the alignment of microphone and host times as good to about ±20 ms. Durations within
  the microphone stream are good to the 5 ms step; the moment a sound began relative to
  an API call is not.

### A dead process releases the mute; a stuck one does not

Speakers, acoustic. Ending the tapping process mid-playback never left output muted: 5
runs with `SIGKILL`, 3 with an unhandled `SIGTERM`, and 3 with `exit(0)` and no
teardown, alongside 2 clean teardowns for comparison. In each, the copy stopped and the
original came back as quickly as after a clean teardown, with no silent interval longer
than the analysis resolves: three of the runs show a single 5–10 ms step with neither
tone. After all 15 runs in this set, including the two below, no tap or aggregate was
left behind, and nothing needed restarting.

Lifetime releases the mute, not IO. In 2 runs a process stopped with `SIGSTOP` kept the
output silent for the whole two seconds it was stopped; output returned when it was
continued.

A stuck callback has the same effect while the process stays alive. In 4 runs the IOProc
slept for three seconds and teardown began half a second into the stall, in two orders:

- **Stopping the IOProc first** (2 runs). `AudioDeviceStop` did not return until the
  callback did, and the output stayed silent for the whole stall.
- **Destroying the tap first** (2 runs). `AudioHardwareDestroyProcessTap` returned in
  0.17 and 0.09 ms with the callback still asleep, and the original was back at the
  microphone about 81 ms later.

`AudioDeviceStop` took 2,500–2,532 ms in all four. Destroying the tap released the mute,
and tap-first was the order that succeeded.

### Building and tearing down overlap rather than gap

Speakers, acoustic, 7 runs: 3 that stopped the IOProc first, 2 that destroyed the tap
first and 2 that destroyed the aggregate first. After `AudioDeviceStart` returned on a
tap built mid-playback, the original stayed audible for about 90 ms, then original and
copy were both present for 30–45 ms before the original was muted. Teardown was the
mirror image: 0–30 ms of overlap and no silence. The three orders sounded the same, but
in both aggregate-first runs the later `AudioDeviceDestroyIOProcID` failed with `'!dev'`.

What was recorded is a 1 kHz original overlapping a 1.5 kHz marker. With real
passthrough the two would be the same audio about 26 ms apart, two buffers and the
safety offsets at this rate according to the IO timestamps, so the overlap would
presumably be heard as a flam rather than a dropout. That is inferred, not heard.

Retargeting, 4 runs, one for each order in each direction. In the two that moved
playback from the headset to the speakers, with the tap moved immediately after, the
speakers played unprocessed audio for 35–50 ms, then both tones for about 25 ms, and
there was no silence. Those runs began on the inaudible headset, so the reference above
could not be taken; these figures count a tone as present when it is at least about
15 dB above its own noise floor before the switch. Starting the new session before or
after stopping the old one made no measurable difference on the speakers. The other two
runs ended on the headset, so they could not be heard.

### On Bluetooth the tap may hear audio a device latency late (inferred)

On the speakers, in 2 runs, the first non-zero captured buffer carried an input
timestamp 2.8 ms before the player's own output timestamp, and reached the IOProc
10.2 ms after it. On the headset, in 4 runs (two arrivals on an idle tap and two
retargets from the speakers), the first non-zero buffer's input timestamp was
197.3–197.4 ms after the player's output timestamp, and it reached the IOProc 209.2 ms
after. That is close to the headset's declared latency of 203 ms. A tap built under a
headset stream that was already playing delivered 17 callbacks of exact zeros first,
about 197 ms, in both runs.

This is inferred from timestamps. If it is real rather than a timestamp convention,
tapped Bluetooth audio plays about 200 ms later than untapped, not the 23 ms the IO
timestamps in [What it costs](#what-it-costs) suggest, and a tap built mid-playback
leaves about 200 ms of silence on the headset. Both would matter for video sync. It
might also account for the scatter in [Open questions](#open-questions): clicks arriving
near 450 ms, against a 400 ms search window and a 500 ms click period, would be matched
inconsistently. Only an acoustic measurement inside the cup can confirm any of it.

### Rate changes keep the IOProc

Speakers, 3 runs with two changes each. Switching the device between 44.1 and 48 kHz
while tapped left an interval of 108–184 ms between callbacks, after which the aggregate
restarted on its own. The IOProc kept its registration and resumed at the new rate with
the same buffer size, and the captured tone was at the right pitch. Acoustically that
was 100–130 ms of silence, and in four of the six changes 15–50 ms of unprocessed audio
and a short overlap followed before the copy resumed.

Several notifications came during that interval. The aggregate's stopped-running
notification arrived first, 48–169 ms before the first callback at the new rate;
`kAudioTapPropertyFormat` followed, 42–118 ms before it, then the aggregate's rate, its
sub-device and tap lists, `DeviceHasChanged`, and the device's own rate.

Opening the headset's microphone, 2 runs, inferred. The headset switched to its call
profile: the output became 16 kHz, **one channel** and 320 frames, and the tap format
followed. Callbacks resumed after 131–140 ms, and the notification order differed
between the two runs. About two seconds after the microphone closed, the output went
back to 44.1 kHz stereo after a 319–341 ms gap between callbacks, but kept the
320-frame buffer, and the first ~200 ms were zeros again.

### Silence is normal, and so is no IO at all

From callbacks, 5 runs on both devices. A tap on a device nothing is playing to gets
**no callbacks**. `AudioDeviceStart` succeeds, and the aggregate does not run until
another process starts output. Once started, it kept running after that process
stopped.

From callbacks, 4 runs. While a process is running output, the tap delivers bit-exact
zeros whenever that process sends silence:

- a process writing zeros
- `afplay` on a silent file
- QuickTime Player while paused, which kept its output running for the whole 5.94 s it
  stayed paused, until it was quit
- Safari's media process, for an estimated eight seconds after the media ended

The tapping process itself also reports running output on the device.

### When the device disappears, nothing tells the IOProc

Headset, inferred. The headset was switched off once and disconnected in software twice
while tapped. In all three, notifications arrived — the device reported
`kAudioDevicePropertyDeviceIsAlive` = 0, and the device list and default output changed
— while the IOProc kept being called with silent input, zero output channels and no
error. Callbacks with zero output channels continued for about 129 s after the
power-off, until the run ended, and about 16 s in each disconnect run. The audio that
moved to the speakers was not muted, which was heard in all three.

In the two disconnect runs the headset was then reconnected and a second source played
to it. The orphaned aggregate reconfigured to use the headset as its output again within
half a second of the device reappearing, but the old tap captured nothing from it.
Whether the headset was muted in that state could not be heard. Tearing the orphaned
session down returned no errors.

### The first prompt

Once, on a fresh signing identity, building a session took 41.5 s while the permission
prompt was on screen and completed once it was answered. In that run the logged
`AudioDeviceStart` took 0.118 ms and returned `noErr`, so the wait came before it; which
call blocked was not recorded.

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
[Equalizer profiles](eq-profiles.md) records how the upstream profile database handles
this: the setting is part of the product identity rather than metadata on the curve.
[Reading headset state](headset-control.md) then measures the headset reporting that setting
over its vendor Bluetooth channel. It also notes that the tested headset had an adaptive
upscaler enabled throughout, while its equalizer was verified off — which makes the upscaler
the better suspect for the scatter above.

[What the tap does at its edges](#what-the-tap-does-at-its-edges) now covers device loss
on Bluetooth, rate changes, stalls and process death. Still untested: whether alert sounds
and applications that open a device exclusively are caught by the tap, unplugging a USB
device while tapped, and everything on the headset that needs a microphone in the cup —
whether tapped Bluetooth audio really arrives about 200 ms late, whether a tap built
mid-playback leaves the headset silent for that long, and whether a reconnected headset is
muted by an orphaned tap. That rig also settles the scatter above, with the headset's noise
cancelling and upscaling switched off first.
