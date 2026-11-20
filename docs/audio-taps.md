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

## System audio capture permission

On one Mac running macOS 27.0.1, neqMac started with microphone and system audio
capture access both undecided. Only the system-audio-capture prompt appeared.
After Allow, the tap delivered the USB output mix with microphone access still
undecided. The bundle included both `NSAudioCaptureUsageDescription` and
`NSMicrophoneUsageDescription`. This run did not test omitting the microphone
usage string, denying capture, or leaving the prompt unanswered.

In the earlier spike, omitting the audio-capture usage string prevented the prompt:

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
certificate, as described in [Signing](development.md#signing). An ad-hoc rebuild
can require fresh authorization.

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

On Bluetooth these internal figures are not the whole cost. The headset declares 8961
frames of latency, about 203 ms; in these in-cup runs an untapped control measured
248.7 ms acoustically end to end; and a later acoustic measurement found the combined
aggregate adding about 227 ms there, as
[On Bluetooth the tap adds a second device latency](#on-bluetooth-the-tap-adds-a-second-device-latency)
records.

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

Two limits apply to these built-in-microphone runs. The sections on Bluetooth measured
later with a microphone in the earcup say so and are not bound by the first:

- **Only the speakers were heard.** At −36 dBFS the built-in microphone could not hear
  the headset over its noise floor. Every headset figure from these runs comes from
  callback times and IO timestamps, and is marked *inferred*.
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

### On Bluetooth the tap adds a second device latency

Measured acoustically on macOS 27.0.1, on the same headset over A2DP at 44.1 kHz, with a
wired microphone inside the earcup recorded through a USB audio interface at 48 kHz. The
headset's noise cancelling and upscaler were in an unknown state: the read-only control
channel did not open during these runs. The comparisons below are between tapped and
untapped audio in the same stream, so that state cancels out as long as it did not
change.

The stimulus was a 4 ms, 2 kHz tone burst at −36 dBFS once a second. The tap was built
and torn down every 8 s, so tapped and untapped bursts alternated through each run, and
bursts emitted from 1.5 s before to 0.7 s after a change were left out. Arrival is the
envelope peak of the matched-filtered microphone signal, mapped to host time through the
interface's input timestamps, minus 2 ms for the onset, and measured from the player's
output timestamp. The microphone path is the same in both conditions, so the difference
does not depend on it. Bursts more than 5 ms from their condition's median were
excluded. The last column is the median, over cycles, of each tapped segment's median
minus the mean of the neighbouring untapped segments' medians.

| Run | Untapped | Tapped | Tapped − untapped, per cycle |
| --- | ---: | ---: | ---: |
| 512-frame aggregate | 249.1 ms (sd 0.4, n 67) | 476.7 ms (sd 0.4, n 64) | 227.5 ms (sd 0.14, 12 cycles) |
| 512-frame aggregate, repeat | 248.3 ms (sd 0.14, n 44) | 475.8 ms (sd 0.15, n 40) | 227.5 ms (sd 0.07, 8 cycles) |
| 64 frames requested, 256 granted | 247.7 ms (247.2–251.6, n 26) | 463.7 ms (463.4–468.7, n 25) | 215.9 ms (sd 0.6, 5 cycles) |
| Global tap instead of a device tap | 253.4 ms (sd 0.5, n 35) | 482.0 ms (sd 0.5, n 30) | 228.5 ms (sd 0.08, 6 cycles) |

A second onset detector, a 1.5–2.5 kHz band-pass and the first crossing of half the
peak, gives the same differences to within 0.15 ms.

The added delay matches the headset's declared output latency (8961 frames, 203.2 ms)
plus the aggregate's two buffers (23.2 ms at 512 frames, 11.6 ms at 256), plus about
1 ms, and the aggregate reports an input latency of 8961 frames for the tap: the
headset's latency is traversed a second time.
[The delay comes from combining the tap and the output](#the-delay-comes-from-combining-the-tap-and-the-output)
locates where: the aggregate holds the tap's samples back by that latency.

A global tap captured no earlier. In its single run it delivered 48 kHz and added about
1 ms more than the device tap; the cause was not isolated. When 64 frames were requested
the aggregate reported 256 while the headset stayed at 512, and the 512-to-256 comparison
saved 11.6 ms on this setup. That is not an established floor: the timestamp measurements
in [What it costs](#what-it-costs) ran a Bluetooth aggregate at 64 and 128 frames, on
another occasion.

On this headset the tap added about 227 ms at the ear. The headset's reported output
latency did not change, so a player relying on that property has no indication to delay
the picture further. If playback was in sync before enabling EQ, we would expect sound to
lag picture by about 227 ms afterwards. That is a prediction: no picture was measured and
no video player was tried. If it holds, the offset is past both thresholds that
[Recommendation ITU-R BT.1359-1](https://www.itu.int/rec/R-REC-BT.1359) gives for sound
delayed against vision, about 125 ms for detection and about 185 ms for acceptability.

Untapped arrival differed between streams by up to 13 ms, from 247.2 ms to 260.4 ms across
five runs including a calibration run, but was steady within a stream to a few tenths of
a millisecond, except in the 64-frame run. There both conditions drifted together over two
minutes: keeping the drifting arrivals and dropping only clear noise, untapped arrivals
ran from 247.2 to 256.4 ms and tapped ones from 463.4 to 471.5 ms. The 5 ms filter
excluded 14 of that run's 65 bursts, 13 of them drift and one a noise match at 856 ms,
which is why its table row has narrower ranges and 5 cycles rather than 6. The earlier
untapped figure of 248.7 ms is inside the range across runs.

Room noise beat the burst in 18 of 149 bursts in the first run, a few seconds at a time,
and in 1 of 85 and none of 65 in the repeat and the global run.

### Building a tap on Bluetooth leaves a gap

Same rig, with a continuous 1 kHz original and the tapping process writing a 1.5 kHz
marker, as on the speakers. Times are at the microphone, so they include the measured
untapped arrival of about 249 ms, not just the headset's declared 203 ms.

Building, 6 runs. Three transitions are readable: the original stopped 319–326 ms after
`AudioDeviceStart` returned, and 225, 220 and 235 ms of silence followed before the copy
began, the third with some room noise in it. Two noisier runs show the original stopping
at the same point and a silence whose end is lost in room noise; in the sixth, room noise
was above the tone throughout. Unlike on the
speakers there is no overlap: the mute takes effect at once, and the copy needs the extra
227 ms to arrive.

Tearing down, which stopped the IOProc first, 6 runs. In the three readable ones the
copy kept playing for 273–281 ms after teardown began, then about 15–20 ms of silence,
at the analysis's 5 ms resolution, came before the original. The other three were too
noisy to read. Because the copy runs 227 ms behind, the switch back should skip about
227 ms of programme; a steady tone cannot show a skip, so that is inferred.

The earlier timestamp measurements agree. On the speakers, in 2 runs, the first non-zero
captured buffer carried an input timestamp 2.8 ms before the player's own output
timestamp, and reached the IOProc 10.2 ms after it. On the headset, in 4 runs (two
arrivals on an idle tap and two retargets from the speakers), the first non-zero
buffer's input timestamp was 197.3–197.4 ms after the player's output timestamp, and it
reached the IOProc 209.2 ms after. That is close to the headset's declared latency of
203 ms. A tap built under a headset stream that was already playing delivered 17
callbacks of exact zeros first, about 197 ms, in both runs.

### The delay comes from combining the tap and the output

A follow-up on the same headset and rig located where the 227 ms is spent. The tap has
the audio almost at once; an aggregate that also contains the output device holds the
tap's samples back by the device's declared output latency before handing them over. The
delay is a property of combining the tap and its output in one aggregate, not of tapping.

The tapping process recorded, for each burst, the input timestamp of the first sample
over a threshold and the time its callback received it, both relative to the player's
output timestamp. Callbacks wrote silence, so these were measured from timestamps, not
at the ear. 15 bursts per row:

| Aggregate | Muted when tapped | Sample timestamp | Callback receives it |
| --- | --- | ---: | ---: |
| Tap only, no output sub-device | no | +0.5 ms | +6.0 ms (0.7–12.1) |
| Tap only, no output sub-device | yes | +0.5 ms | +6.0 ms (1.4–11.7) |
| Tap and output device | no | +204.8 ms | +211.1 ms (205.8–216.1) |
| Tap and output device | yes | +204.9 ms | +211.4 ms (205.6–216.6) |

The 0.5 ms is the burst's own rise to the threshold. In the combined aggregate the same
samples arrive about 205 ms later, close to the headset's declared 203.2 ms.

The alignment is controlled by the sub-tap's extra input latency
(`kAudioSubTapExtraInputLatencyKey`) in the aggregate's tap list. In the combined
aggregate, 8 bursts per row:

| Setting | Sample timestamp |
| --- | ---: |
| none | +204.8 ms |
| extra input latency +512 frames | +216.5 ms |
| extra input latency −8961 frames | +1.6 ms |
| extra output latency −8961 frames | +204.8 ms |
| drift compensation off | +203.8 ms |
| output sub-device's extra latency −8961 frames | +204.8 ms |

The extra input latency moved the samples frame for frame: +512 frames is 11.6 ms. Neither
output-latency setting moved the median; disabling drift compensation advanced it by about
1 ms. The value can only be given when the aggregate is created:
every property queried on the IDs in `kAudioAggregateDevicePropertySubTapList` of a running
aggregate returned `'!obj'`.

### Two ways around it

Both were measured at the ear against untapped playback in the same run, with bursts at
−42 dBFS (−30 or −36 dBFS after the crash below reset the headset's volume). Arrivals are
found as above, but each segment is reduced differently: its value is the median of the
densest cluster of arrivals within ±5 ms, a segment needs at least two bursts in that
cluster to count, and a tapped segment is compared with the mean of its neighbouring
untapped segments, or with one of them if only one is usable. That rule decides which
noisy cycles count in the split results.

**Compensating inside the combined aggregate.** One run, 5 cycles of each setting, 15
bursts each, no outliers:

| Extra input latency | Added at the ear |
| --- | ---: |
| none | 227.50 ms (sd 0.04) |
| −8961 frames, the device's latency | 24.28 ms (sd 0.05) |
| −8448 frames, 513 frames short of it | 35.92 ms (sd 0.05) |

24.28 ms is the aggregate's two buffers (23.22 ms) plus about 1 ms. In a separate 24 s run
at −8961 frames, the log has 2062 callbacks; after the first 20, one of which carried
slightly less than a full buffer of tone, all 2042 remaining carried a full tone with no
zero samples and a constant peak. At the ear, in the analysis window starting 1.5 s after
startup, the tone never fell 6 dB below its untapped level in any of 4514 5 ms blocks.
Built mid-playback, it left a gap whose size depends on the smoothing: about 15–20 ms of
silence with two-block smoothing, one 25 ms gap with four. Teardown left 10–15 ms. That is
one build and one teardown.

**Splitting capture from playback.** A private aggregate holding only the tap, muted when
tapped, with drift compensation off, writes each callback into a preallocated
single-producer, single-consumer ring. A second IOProc, directly on the headset, starts
reading once a target fill is queued. Playback starting after one capture buffer:

| Queued before playback | Added at the ear | Cycles |
| --- | ---: | ---: |
| Queued before playback | Added at the ear | Readable cycles | Retained bursts |
| --- | ---: | ---: | ---: |
| One capture buffer | 26.4, 29.5, 31.9 ms | 3 | 10 |
| +256 frames | 35.2–39.0 ms | 4 | 11 |
| +512 frames | 38.3–46.5 ms | 3 | 8 |
| +1024 frames | 49.7 ms | 1 | 3 |
| One capture buffer, separate one-minute run | 31.4 ms (sd 0.26) | 1 | 40 of 65 |

One sweep, at a median burst signal-to-noise ratio of 12.7 dB, supplied the first four
rows; 11 of its 16 cycles contributed and the rest were lost to room noise. Three other
recordings were too noisy to read at all, with median burst signal-to-noise ratios of
10.1–10.9 dB, and are not counted: two attempted the same four-depth sweep and one was a
single +512-frame run. The one-minute run kept 40 of its 65 tapped bursts, the rest beaten
by room noise, against one untapped reference before it.

The spread at one buffer is plausibly the phase between the two IOProcs, which differs on
every start, though that was not established. Capture delivers 512 frames at a time, which
would explain why +256 and +512 land close together.

Over that minute neither side logged an underrun or overrun. Capture callbacks, 5869 of
them, recorded 512–1024 queued frames after writing, and playback callbacks recorded
zero after reading. Capture and playback advanced at the same rate, which supports no
measurable rate drift over this run; the tap-only aggregate runs on the headset's clock.
The delay at the ear moved by about 0.5 ms between the first and last ten bursts. In one
readable run with a continuous tone, starting the pipeline left about 15 ms of silence
at the ear and stopping it 25–35 ms, twice each; a second such run was too noisy to
read.

### Over-compensating crashed the audio server

Once, an extra input latency of −9473 frames, 512 beyond the device's 8961, crashed
`coreaudiod`. `AudioDeviceStart` returned `noErr`; about 104 ms later the device count fell
to zero, the server restarted itself, and devices began reappearing about 2.2 s after
that. The crash report shows a bus error (`EXC_BAD_ACCESS`, `KERN_PROTECTION_FAILURE`) in
`memmove` under `HALS_DelayProcessor::Process`, on the aggregate's own IO thread. The logs
show a system-wide audio-service interruption; they do not record how each application
recovered. Afterwards the headset's volume was 43.75 % instead of about 100 %, and the
built-in speakers came back muted at zero volume. The likeliest reading, an
inference, is that the compensation is a delay line inside the server and a net negative
delay reads outside its buffer.

The experiment established a crash at startup, not how the server handles a later change.
Even so, it makes the compensated aggregate unsafe wherever a device's latency can fall
while the aggregate runs, because the value cannot be changed once it is created.
Bluetooth call mode is such a change, and another application triggers it by opening the
microphone. What the server does when the latency falls under a running compensated
aggregate was not tested: testing it risked another system-wide audio interruption.

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

At the ear, 2 runs with the tap and 2 without, timed at the microphone from the moment
the headset's input opened. Entering call mode silenced the output for about 500 ms with
the tap and about 520 ms without. With the tap, the output then dropped out for 40–65 ms
roughly once a second for as long as the call profile persisted: near 1.2, 2.2, 3.2,
4.3, 5.3 and 6.3 s after the input opened, the last two after it closed at about 5.0 s.
The tap's callbacks continued without a gap. The untapped runs had no dropout of 15 ms
or more, but their tone level fell by about 4.5 dB for the whole call, and a dropout is
a step more than 10 dB below the reference, so the threshold matters to that comparison.
The cause was not found. Leaving call mode, the untapped runs were silent for 580–645
ms. The tapped runs were silent for 620–655 ms, then 35–50 ms of the unprocessed
original leaked through, then 265–270 ms more silence came before the copy.

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
Tearing the orphaned session down returned no errors.

With the microphone in the earcup, the same sequence was repeated 4 times. Audio played to
the reconnected headset under the orphaned session was neither muted nor doubled in all
4: its median level was within about 0.2 dB of the same run's level before the
disconnect, and the orphan's tap delivered only exact zeros throughout, so no copy was
being played. The third run had some room noise in the recording. Each run then ended the
session and played again as a control, at the same level. In the first three a bug in
the tool ignored the request for a clean teardown, so the session ended with its process;
only the fourth logged a clean teardown, with every step returning `noErr`.

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

The acoustic arrival time of a tapped Bluetooth stream is now measured, in
[On Bluetooth the tap adds a second device latency](#on-bluetooth-the-tap-adds-a-second-device-latency),
and it is consistent with the scatter the first in-cup runs saw. An untapped control
clustered at 248.7 ms within 0.1 ms, while the same measurement through the tap scattered
across a 300 ms range. Tapped clicks arrive at about 475 ms, outside the 400 ms window that
measurement searched after each click, so it would have been matching noise.

Those measurements were made with the headset's noise cancelling and upscaler in an
unknown state. Untapped arrivals were steady regardless, but a repeat with both
explicitly off would confirm the tapped figure does not depend on them.

That processing matters beyond measurement. A vendor equaliser applies *after* neqMac's,
and published correction curves target the raw driver response, so a profile stacked on
top of a headset's own tuning will correct twice. Profiles need to record what the
headset was set to.
[Equalizer profiles](eq-profiles.md) records how the upstream profile database handles
this: the setting is part of the product identity rather than metadata on the curve.
[Reading headset state](headset-control.md) then measures the headset reporting that setting
over its vendor Bluetooth channel.

[What the tap does at its edges](#what-the-tap-does-at-its-edges) now covers device loss,
rate changes, stalls and process death, and on the headset the added delay, building,
tearing down, call mode and reconnection. Still untested: whether alert sounds and
applications that open a device exclusively are caught by the tap, unplugging a USB
device while tapped, and the programme skip at teardown on Bluetooth, which needs real
programme material rather than a tone.
