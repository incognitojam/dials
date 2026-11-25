# Equalizer

neqMac is gaining a corrective equalizer: one measured profile per pair of headphones,
applied to what other applications play through them. Whether alert sounds and
applications that take a device exclusively are included is not yet known (experiment
E9). This is the design for it. The measurements it rests on are in
[System audio taps](audio-taps.md), [Equalizer profiles](eq-profiles.md) and
[Reading headset state](headset-control.md).

The document keeps four kinds of statement apart. **Decided** is a choice the owner has
made and a builder should follow. **Measured** links to the document that measured it.
**Inferred** was worked out from timestamps rather than heard, and still needs an
acoustic check. **Provisional** is a working assumption that a named experiment in
[Hardware experiments](#hardware-experiments) will confirm or replace; build it so it
can change.

The filter library and USB session engine are implemented. Enable an output with a
copied profile in the [equalizer settings file](equalizer-settings.md) and inspect
Activity for session status. The profile browser, editor, compare control and headset
integration are planned. Filter design and rendering are described in
[Equalizer profiles](eq-profiles.md).

## How the pieces fit

```
other apps ─▶ process tap ─▶ IOProc on a private aggregate ─▶ real output device
                               │
                               └─ EqualizerProcessor (EqualizerCore)
```

The tap is the shape [System audio taps](audio-taps.md#the-shape-that-works) measured:
bound to the current output device, excluding neqMac's own process, muted when tapped,
and joined with the real device in one private aggregate. A single IOProc reads the
tapped mix, runs it through an `EqualizerProcessor`, and writes the result to the
device. The system default output stays the real hardware, so routing and the
equalizer never disagree about which device is in use.

The equalizer follows **the system default output**, not routing's decisions. A device
picked in Control Center is equalized the same way as one routing chose, and routing
needs no knowledge of the equalizer. The controller acts after routing's own debounce
has settled, so a burst of device changes produces one rebuild rather than several.

The filters are the shipped `EqualizerCore` processor, hand-written RBJ biquads with no
Apple framework imports. The engine reuses it rather than an Apple audio unit or vDSP.

A plan is compiled away from the IO thread, at the tap's actual sample rate, and reaches
the processor through the contract documented above `EqualizerProcessor.update`: the
publisher compiles off the IO thread and protects its pending slot with a lock. Between
buffers, the IO wrapper tries that lock; if it gets it, it copies the pending plan and
mode, clears the slot, unlocks, calls `update`, then calls `process`. On contention it
calls `process` directly with the current plan. The stream's owner frees the processor
off the IO thread after IO has stopped. A try-lock needs nothing newer than macOS 14,
which is the deployment target the app keeps. Process taps need macOS 14.2, so below that
the equalizer is unavailable at runtime while routing keeps working.

The private aggregate is visible to the process that creates it, so neqMac's own device
list would otherwise contain it. Left alone, routing would make a rule for it, and
creating it would change the device list, which the equalizer answers by reconciling: a
loop. Its UID carries a fixed prefix and it is dropped from the device list before either
sees it.

## Profiles and assignments

A **profile** is an OPRA `eq_info`: a preamp and a prioritised list of bands, never
coefficients. neqMac keeps its own copy of every profile it uses, recording where it came
from — an OPRA entry, a pasted AutoEq block, or one made by hand — along with the author
and measurement details the licence requires it to credit. Because the copy is
self-contained, an assigned profile keeps working offline and survives the upstream
catalogue changing or removing it.

An **assignment** connects an output device to what it should get. It identifies the
device with the same semantics as routing's `DeviceRule.matches`, so a device keeps the
same identity in both. A rule matches a device only in the same direction, and then:

- if the Core Audio UID is identical;
- or, for USB audio UIDs (`AppleUSBAudioEngine:` with at least five colon-separated
  parts), if both reduce to the same key after dropping the second-to-last part when it
  looks like a USB location ID: one to seven hex digits ending in zero. That part is
  where the serial number sits, and Core Audio puts the port's location there for a
  device without one;
- or, for AirPlay, if the device's transport is AirPlay and its name equals the rule's,
  provided the rule's name is not empty and is not the *Unknown device* placeholder.

So an assignment for a serial-less DAC usually survives moving it between ports, and two
identical serial-less DACs connected at once share one assignment. The location test is a
heuristic: a real serial number that happens to look like a location ID is dropped too,
and two units with such serials share an assignment. Two AirPlay receivers with the same
name share one. The interface must not imply finer identity than that.

An output's assignment is in one of these states (decided):

| State | Meaning |
| --- | --- |
| No assignment | Nothing recorded. EQ is off, and neqMac may suggest a match. |
| Suggested | A name match is waiting for confirmation. Nothing is applied until the user confirms it with one click. |
| Assigned | A profile, or one profile per noise-cancelling state. |
| No equalizer | The user said this device needs none. EQ is off and nothing is ever suggested. |

*No assignment* is the absence of a record and may lead to a suggestion; *No equalizer* is
a stored decision, and neqMac never raises the device again. A dismissed suggestion is
stored the same way, so a soundbar whose name resembles a headphone is asked about once.

Assigned devices also have an **on/off switch** of their own, separate from the choice, so
switching EQ off for a device keeps its profile. Above all of it sits a **master switch**,
which is the only way to release the tap everywhere without unassigning anything.

When a product has several profiles, nothing is pre-selected; see
[Nobody picks for the user](eq-profiles.md#nobody-picks-for-the-user).

### Noise cancelling

OPRA treats a headset with noise cancelling on and the same headset with it off as
different products, and the correction for one is wrong for the other. An assignment for
such a headset therefore holds a profile for each state, and the engine applies whichever
matches the state the headset reports. If no profile exists for the current state, EQ
pauses and says why, rather than applying a correction measured in the other one.

OPRA publishes nothing for ambient sound. The default is to use the noise-cancelling-off
profile there. That is a product default, not a finding: nothing has measured how close
the WH-1000XM4's ambient response is to its off response. Milestone 6 exposes it as the
user's choice.

Until neqMac can read the headset (milestone 6), an assignment holds the single profile
the user chose, and switching variants is up to them. That manual choice stays as the
fallback afterwards. When the state read on connecting fails, or the control channel
closes or stops answering so the last known state can no longer be trusted, the engine
applies the manual choice and the interface says that the headset's state is unknown.

Only the WH-1000XM4 needs this today. `samsung::galaxy_buds_live` has no noise-cancelling
variants in OPRA, so the Buds Live channel is useful only to warn that the earbuds' own
equalizer is on.

### Where it is stored

Equalizer settings live in a file of their own, `equalizer.json` in neqMac's Application
Support folder, never in the saved routing policy (decided).

The routing policy uses Swift's synthesised `Decodable`. A new optional field would decode
when absent, but a new required one would not, and the bigger hazard is what happens on
any decode failure: `UserDefaultsPolicyStore.load()` returns a default, empty policy, and
the next save overwrites the stored bytes with it. One mistake in an equalizer field would
cost the user their routing. Keeping assignments out of the routing rules also means
removing a disconnected device from the routing list, or collapsing duplicate rules,
never deletes its equalizer setting.

The equalizer file is decoded by hand. A field that is missing takes its documented
default, deliberately, so older documents load. A field that is present but malformed is
an error, kept distinct from an absent one: a damaged assignment is reported, not silently
read as *No assignment*, and the file is not rewritten over it.

The OPRA catalogue is a cache, kept in the user's Caches folder and never in this file.

### Desired processing and session status

Two things are tracked separately, and the interface shows both.

**Desired processing** is a pure function of the output device, the settings, the
headset's reported state and the sample rate. It answers whether this output should be
equalized and with which profile, or why not: no assignment, suggestion pending, no
equalizer, off for this device, master switch off, unsupported transport, sample rate too
low, or no profile for the current noise-cancelling state. It knows nothing about
permission or the engine, so every combination is a unit test without hardware.

**Session status** is observed from the engine: idle, starting, running, comparing,
permission denied, or failed with a reason. The engine starts a
session only while desired processing says to equalize, and stops it as soon as it does
not.

The first attempt for an output starts when desired processing first says to equalize it
after an explicit user action: confirming a profile or switching a device on in the app,
or, in milestone 2, adding a matching assignment to the settings file. That attempt is
what raises the system prompts.

Denial is only handled when it can be observed. A denied tap may report success and
deliver exact zeros, which the engine cannot tell from a silent player (see
[Failure](#failure)), so a session that was refused that way may look healthy while the
output is silent. Whether denial or later revocation can be detected at all is what E6
decides. Where a failure is observed, the session ends, the assignment is kept, the device
shows *Permission denied* or the failure with an action to open System Settings, and
neqMac does not try again on its own. **Retry** takes the retained assignment, evaluates
desired processing again, and if it still says to equalize, starts one fresh session; if
the failure recurs, the status returns to it.

## Which outputs get an equalizer

Transport decides eligibility first; only an eligible output can be assigned anything.

| Transport | Eligible |
| --- | --- |
| USB | From milestone 2 |
| Built-in | From milestone 3, through a pasted or hand-made profile |
| Bluetooth | Not until the split pipeline below is built and tested |
| AirPlay, HDMI and DisplayPort | Not until E10 and E13 say how a tap behaves on them (milestone 8) |
| Virtual devices and aggregates | Never. Loopback and recording devices would capture equalized audio, and aggregates include neqMac's own |

So a soundbar or display connected over HDMI or DisplayPort cannot be assigned a profile
until milestone 8, whatever kind of device it is. Bluetooth is held back until the engine
moves to the split pipeline described in
[Bluetooth delay and the split pipeline](#bluetooth-delay-and-the-split-pipeline).

Among eligible outputs, the kind of device decides only what neqMac offers:

- Bluetooth headphones get a name-match suggestion that needs one click to confirm.
- A USB DAC or amp is never suggested. The Mac can see the amp, not the headphones on it,
  so neqMac asks what is plugged in.
- Built-in speakers and Bluetooth speakers or soundbars are never suggested. They read *No
  EQ* until the user gives them a pasted or hand-made profile.

Once any eligible output has a profile, it is treated like headphones from then on: its
real status is shown in the pane and the menu bar, with the same failure controls.

At sample rates below 32 kHz — a Bluetooth headset that has switched to its call profile
because a microphone opened — EQ suspends and the tap is torn down (decided). Calls are
sensitive to latency, and the published correction describes the music path anyway. It
resumes when the rate does. Measurement supports this: a tap kept through call mode
dropped out for 40–65 ms about once a second during the call, and leaked 35–50 ms of
unprocessed audio at the ear when the call ended
([Rate changes keep the IOProc](audio-taps.md#rate-changes-keep-the-ioproc)).

A device with more than two channels gets the same chain on every channel.

### Bluetooth delay and the split pipeline

**Measured, current engine.** With a microphone in the earcup of a WH-1000XM4, the engine's
combined aggregate added about 227 ms at the ear at the default buffer, and 216 ms at the
smallest buffer the aggregate granted. The headset's reported output latency did not
change, so a player relying on that property has no indication to delay the picture
further, and players never see the aggregate. If playback was in sync before enabling EQ,
we would expect sound to lag picture by about 227 ms afterwards (predicted; no picture or
video player was measured), past both the 125 ms detectability and the 185 ms
acceptability thresholds ITU-R BT.1359-1 gives for delayed sound.

**Measured, cause.** The delay comes from combining the tap and the output in one
aggregate, not from tapping. In a tap-only aggregate a burst's samples arrive within a few
milliseconds of the player producing them; the combined aggregate hands them over about
205 ms later, close to the headset's declared 203.2 ms output latency, before the output
adds that latency again.

**Measured, two ways around it.** A split pipeline — a tap-only aggregate capturing into a
lock-free ring, read by a separate IOProc directly on the headset — added 26–32 ms at the
ear on this headset in three readable one-buffer cycles of one sweep, with 31.4 ms in a
separate one-minute run that logged no underruns or overruns. With that, the
predicted lip-sync offset becomes about 30 ms, below the BT.1359-1 detectability figure;
that too is a prediction until a real player is tested. Compensating inside the combined
aggregate with the sub-tap's extra input latency achieved about 24 ms, but it is **not to
be used**: a setting 512 frames beyond the device's latency crashed the system audio
server, the value is fixed when the aggregate is created, and a device's latency can fall
while it runs, as in Bluetooth call mode. The figures are in
[The delay comes from combining the tap and the output](audio-taps.md#the-delay-comes-from-combining-the-tap-and-the-output)
and the sections after it.

**The intended direction, not yet built:** move the engine to the split pipeline. That
changes how the engine captures on every device, not only on Bluetooth: capture through a
private tap-only aggregate, transfer through a preallocated single-producer,
single-consumer ring, and play through an IOProc on the output device itself. The ring
needs atomics that work on macOS 14, which the app keeps as its minimum; the experiment's
ring used `Synchronization.Atomic`, which needs macOS 15. The teardown order, the
watchdog and the failure rules above were measured on the combined aggregate and need to
be re-established for two IOProcs.

Bluetooth stays ineligible until the split pipeline is built and these are tested on it:
call mode, rate and format changes, reconnection, sleep and wake, the headset's 256-frame
buffer, runs of 30 minutes or more, behaviour on USB and built-in outputs, a lip-sync
check with a real video player, and runs with the headset's noise cancelling and upscaler
in a known state.

**Alternatives considered.** Before the cause was found, this document recorded an open
product decision between not offering Bluetooth EQ, an explicit opt-in with a warning
that it "delays audio by about a quarter of a second; fine for music, not for video",
driving the headset's own equalizer over its control channel (coarse bands, no added
delay), and a virtual output device that reports the combined latency to players, the
approach [System audio taps](audio-taps.md) set aside for other reasons. That framing is
superseded by this result. The split pipeline is the recommended path; the owner has not
been asked to choose between it and those alternatives, which stay recorded in case it
fails.

## The engine

### Lifecycle

A session is built on its own serial queue, never on the main thread, because
[a permission prompt can hold up construction](audio-taps.md#the-first-prompt).

1. Translate neqMac's process ID to a Core Audio process object, retrying, since this
   fails transiently just after launch (measured; the retry budget is provisional).
2. Create the tap for the output device's first stream, excluding neqMac, muted when
   tapped.
3. Create a private aggregate containing just the tap. Confirm its tap UUID and sole
   input stream ID, then attach the real output as its main sub-device.
4. Identify the aggregate's tap input and match its starting channel, channel count and
   Float32 format to the buffer configuration. Compile the plan at the tap rate.
5. Create the IO proc, enable only the verified tap stream for input, read back every
   stream flag, and start IO. The callback checks the selected planes and the null
   buffers of disabled inputs. A mismatched layout produces silence and cannot advance
   the watchdog heartbeat.

A USB device with inputs requires the assignment key `allowDuplexInput` to be true. The
default suspends before tap creation. Opt-in keeps all the identity, format and
stream-usage checks. The macOS SDK documents that sub-taps have no streams of their own.
On an output-only DAC the aggregate's sole input identifies the tap even if HAL reissues
the stream ID. On a duplex DAC the tap-only stream ID must survive attachment at either
end of the stream list, alongside one stream per physical input stream. Reconfiguration
checks the IO-proc mask and repairs a changed mask before republishing the input
selection. Apple's stream mask applies to the IO proc. Driver-level microphone power and
the behaviour of the target USB DAC still need hardware verification.
[Apple’s IO-proc stream usage](https://developer.apple.com/documentation/coreaudio/audiohardwareioprocstreamusage)

Playback headroom covers DC through Nyquist. The peak search samples DC, 4096
logarithmic intervals from 1 Hz to Nyquist, and each in-range band center. It refines
the peak estimate around local maxima.
Any peak above 0 dB reduces both preamp and compare gain by the excess. Activity records
the reduction. A final clamp bounds each rendered sample to [−1, 1].

A failure at any step must destroy whatever the earlier steps created (decided). The
rest of this section follows from the measurements in [What the tap does at its
edges](audio-taps.md#what-the-tap-does-at-its-edges), made on the built-in speakers and
on a Bluetooth headset, first by timestamps and later with a microphone in the earcup.
[The USB runs](#usb-output-on-macos-2701) tested these rules on a DAC.

- **The IOProc never blocks.** A stuck callback keeps the output silent until the tap is
  destroyed, a frozen process keeps it silent until it is continued or dies, and
  `AudioDeviceStop` waits behind a stuck callback. Nothing in the callback may wait on
  anything that can block.
- **Teardown destroys the tap first,** then stops and destroys the IOProc, then destroys
  the aggregate. With the callback stuck, destroying the tap returned in under 0.2 ms and
  the original was back at the microphone about 81 ms later, while stopping the IOProc
  first left the output silent for the whole stall; tap-first is the order that
  succeeded. In normal operation the orders sounded the same. Destroying the aggregate
  before the IOProc made the IOProc's destroy fail. Teardown runs on the session queue,
  never the main thread, because stopping the IOProc can block.
- **Retargeting** stops the old session and starts one for the new device. Ending on the
  speakers, this gave 35–50 ms of unprocessed audio, then about 25 ms with both the
  original and the marker present, and no silence; the order made no measurable
  difference there.
- **Rate and format changes recompile at the verified tap rate.** The built-in speakers
  resumed after 108–184 ms between callbacks. A USB DAC took up to 0.78 s to relock.
  A notification opens a two-second window. Verification runs on a worker while the
  watchdog checks IO independently. Idle or progressing IO can allow an in-flight
  check up to 800 ms more, once. Further notifications cannot move that deadline.
  Verified IO keeps the session. If layout verification or callback progress fails,
  release the tap and try one fresh session. A failed recovery counts toward back-off.
  The callback accepts changes in channel count and buffer size. M2 observes the
  negotiated buffer size; requesting a different size remains open until E11.
  If the watchdog releases the mute because the layout became unverifiable, the controller
  re-evaluates the current output and settings once after 750 ms. A repeated layout loss
  stays suspended. A rate below 32 kHz, such as the 16 kHz one-channel call profile a
  headset switched to, is not recompiled: it suspends EQ and tears the tap down.
- **Device loss is detected from notifications.** In all three Bluetooth losses the device
  reported it was no longer alive and the device list changed, while the IOProc kept being
  called with silent input, zero output channels and no error; the orphaned aggregate
  re-adopted the headset when it reconnected. The session tears down on those
  notifications when the device is no longer alive or is absent from the hardware list.
  An empty aggregate output list alone can occur during a rate change.
- **Sleep** stops the session before the Mac sleeps and reconciles after it wakes. This is
  provisional until E4.
- Repeated overloads are logged.

### Off means off

Turning EQ off for a device, with its switch, the master switch or by choosing *No
equalizer*, **tears the tap down** (decided). A running tap costs latency (measured: on
wired outputs two buffer periods plus the device's safety offsets, and on USB,
acoustically, about 2.3 ms more than the timestamps report; on a Bluetooth headset about
227 ms at the ear with the combined aggregate), a permission, a wakeup on every cycle,
and a way to make the Mac silent. None of that is worth paying to apply no filter.

Building or tearing down a tap did not leave a silent gap on the speakers. The original
and the marker that stood in for the processed copy overlapped for up to about 45 ms.
With real passthrough that would be the same audio twice about 26 ms apart, by the IO
timestamps, which should sound like a flam rather than a dropout (inferred). On/off is
still a deliberate, debounced switch, never a hover or something that can be toggled
rapidly. On the headset it is a gap, not an overlap: building a tap mid-playback left
220–235 ms of silence at the ear, and tearing it down 15–20 ms, after which the programme
should jump by about 227 ms (inferred; a steady tone cannot show it).

The one exception is **compare**: holding a button to hear the difference, which keeps the
tap running and switches the processor's mode (decided). Compare is level-matched. A
correction's preamp can be as low as −18.1 dB, so the unequalized signal at full level is
louder and would always sound better. In compare mode the processor plays the dry signal
at the plan's compare gain: the K-weighted RMS of the profile's magnitude response,
preamp included, over 256 logarithmically spaced points from 20 Hz to the lower of 20 kHz
and Nyquist. A profile with no bands compares at its preamp gain. Profile changes, compare
and its release go through the processor's crossfade, which reduces switching artefacts.

### Permission

An enabled assignment authorizes the capture request as described in
[Desired processing and session status](#desired-processing-and-session-status).
See [System audio capture permission](audio-taps.md#system-audio-capture-permission)
for the observed grant and silent failure modes. Revocation remains open (E6).

### Failure

The invariant (decided): **no state leaves a tap muting the output without a running,
healthy IOProc**. Because `mutedWhenTapped` silences the device while the tap runs, a
broken equalizer does not degrade audio, it stops it. Every failure that can be observed
therefore ends the same way: tear down, let the audio play uncorrected, and say so. A
denied or revoked permission that delivers zeros is not yet observable; see E6.

- **Heartbeat.** The IOProc counts its cycles, and a watchdog on another thread checks
  the count. An idle tap gets no callbacks. The watchdog disarms while a fresh activity
  poll confirms that no other process is running output on the device. A failed poll or
  an idle reading older than 250 ms arms it until a fresh result arrives. The tolerance
  is a chosen 350 ms, informed by the largest gap seen around a format change, 340.5 ms
  when a headset left its call profile. On expiry the watchdog destroys the tap before
  querying physical removal. A separate queue samples other-process activity so a
  blocked HAL query cannot hold up mute release. The watchdog lives in the same process,
  so it can act on a stuck callback but not on the whole process being suspended; that
  case only ends when the process continues or dies.
- **Zeros are not a failure.** Paused players and silent media keep their output running
  and send exact zeros, throughout the observed 5.94 s pause in QuickTime's case, so a
  tap that delivers only zeros is not treated as failed and there is no back-off based
  on zeros (decided). The cost is that an unauthorised tap, which also delivers zeros,
  is not caught this way; detecting a missing or revoked permission is left to E6.
- **Non-finite samples.** The processor already silences the affected sample, resets that
  channel and fades back in; the controller logs it.
- **Back-off.** After a failure, neqMac does not restart the session on its own until the
  next device change or user action, and limits attempts per device, so a broken equalizer
  cannot flap the audio on and off. The limits are provisional.
- **Activity.** A rate-change notification burst produces one “Equalizer reconfiguring”
  entry. Automatic restarts give the reason as an informational event. Failures and
  suspensions carry a warning. Ordinary profile edits keep their playback status.
- **Crashes need nothing.** Ending the process released the mute and left no tap or
  aggregate behind in every run, so there is nothing to recover after a crash. A hang is
  the danger: a frozen process keeps the device silent until it is continued or killed.

A false positive from a check turns the equalizer off. That is acceptable; the opposite
failure is not.

## The interface

Decided by the owner, built from milestone 3.

The equalizer gets its own **Equalizer pane** in the settings window, beside Routing. The
routing list answers *which device wins* and is ordered by priority; the equalizer answers
*what does this device need*, and needs room for the attribution, a pair of
noise-cancelling profiles and a curve.

On the left of the pane are the outputs, ordered by relevance rather than priority.
Headphones come first. Speakers and displays without a profile follow, dimmed, each reading
*No EQ*; one with a profile shows its real status like any other. Outputs that are not
eligible yet, such as AirPlay, HDMI, DisplayPort and virtual devices, are folded away
behind a single row. On the right is the selected device's detail: its profile, or one per
noise-cancelling state with the live one marked; the response curve with the preamp; and
the credit, author first and OPRA second. For a headset that reports it, the detail also
says whether the headset's own equalizer is off, so nothing is corrected twice.

Assigning happens in **one search sheet**, used for every device, which also carries the
attribution [Equalizer profiles](eq-profiles.md#what-the-database-contains) requires.

A USB DAC or amp gets a question instead of a field: **"What's plugged into
\<device\>?"** It is asked about the headphones, not presented as a setting of the amp,
because the Mac cannot see what is on the end of the cable. The answer opens the same
sheet, and the headphones used on that amp become a **quick switch in the menu bar**, so
swapping pairs takes one click. Only USB outputs get it.

In the **menu bar**, EQ is one line inside the existing Output card, because it is a
property of the output that is playing: the profile name, an on/off switch and a
hold-to-compare button. An output without a profile shows no line, so for speakers and
displays the panel looks as it does today. When the engine observes a failure, including
a denied permission once E6 shows how to detect one, the line becomes the existing
orange error banner, and its first sentence is what the user hears — that audio is
playing normally, without correction — with **Retry** or an action to open System
Settings.

Before requesting system audio capture, the app will explain that audio is processed
locally and that routing also works without the grant.

Profile chips on the routing rows as the main surface, and a headphone library as the
primary model, were considered and not chosen.

## Milestones

Milestone 2 merged as three dependent pull requests covering settings and headroom, the
session and renderer, and app integration. The [USB hardware
runs](#usb-output-on-macos-2701) cover the original engine and its recovery fixes.

1. **`EqualizerCore`.** Profile format, AutoEq import, filter design, response
   evaluation and the real-time processor, with no Apple framework imports. *Shipped in
   [#31](https://github.com/incognitojam/dials/pull/31) and
   [#33](https://github.com/incognitojam/dials/pull/33).*
2. **The engine, configured by a hand-edited settings file, for USB outputs.** Shared
   device identity with routing, the settings file and its store, desired processing and
   session status, the controller and tap session, filtering neqMac's own aggregate, the
   usage strings, rate changes, sleep and wake, low-rate suspension, the failure checks,
   back-off and Activity events. An install without the file behaves exactly as today.
   *Merged in [#39](https://github.com/incognitojam/dials/pull/39),
   [#40](https://github.com/incognitojam/dials/pull/40) and
   [#41](https://github.com/incognitojam/dials/pull/41). The USB runs led to
   [#46](https://github.com/incognitojam/dials/pull/46) and
   [#47](https://github.com/incognitojam/dials/pull/47).*
3. **Assigning profiles in the app.** The Equalizer pane, importing a pasted AutoEq block,
   per-device on/off and the master switch, permission onboarding, status display, Retry,
   compare, the USB "What's plugged in?" question and its menu bar quick switch, built-in
   outputs, and Bluetooth once the engine runs the split pipeline described in
   [Bluetooth delay and the split pipeline](#bluetooth-delay-and-the-split-pipeline) and it
   has been tested there.
4. **The OPRA catalogue.** Fetching, caching and searching it, variant grouping, copying a
   profile on assignment, the attribution, and name-match suggestions with their
   dismissal.
5. **Curves and hand-made profiles.** The response curve, and a band editor for devices
   without a published profile, such as a soundbar.
6. **WH-1000XM4 noise-cancelling following.** An RFCOMM client built from
   [`tools/bt-probe`](../tools/bt-probe/README.md), a profile per noise-cancelling state,
   the ambient-sound choice, the fallback to the manual choice, and a warning when the
   headset's own equalizer is not flat.
7. **Galaxy Buds Live.** A warning when the earbuds' own equalizer is on, read passively.
8. **Buffer size, AirPlay, HDMI and DisplayPort.** A latency setting or a better default,
   and enabling the transports the experiments clear.

## Hardware experiments

### Run

These were run on macOS 27.0.1 with the built-in speakers and a WH-1000XM4 over
Bluetooth; the details are in [What the tap does at its
edges](audio-taps.md#what-the-tap-does-at-its-edges). The first runs heard only the
speakers; the headset results marked *in the cup* were measured later with a wired
microphone in the earcup, with the headset's noise cancelling and upscaler in an unknown
state.

| # | Result | What remains |
| --- | --- | --- |
| E1 | Build and teardown overlap the original and the marker for up to about 45 ms on the speakers, with no silent gap, in 7 builds across three teardown orders; both aggregate-first teardowns failed to destroy the IOProc. Retarget order made no audible difference in the two retargets that ended on the speakers. On the headset, in the cup, building mid-playback left 220–235 ms of silence (3 readable runs of 6) and tearing down 15–20 ms (3 of 6). | The programme skip at teardown on Bluetooth, with real programme material |
| E2, Bluetooth | One power-off and two software disconnects left the IOProc running with silent input and no error; the loss arrived as notifications. The speakers the audio moved to were not muted. The orphaned aggregate re-adopted the reconnected headset; in the cup, audio played to it was normal, neither muted nor doubled, in 4 of 4 runs. | USB unplug results below |
| E3 | A rate change left 108–184 ms between callbacks and the IOProc resumed at the new rate; the call profile changed the channel count and buffer size. In the cup, a tap kept through call mode dropped out about once a second and leaked 35–50 ms of unprocessed audio when the call ended. | USB results below |
| E5 | Ending the process without teardown released the mute in all 11 runs, and no tap or aggregate was left after any of the 15. A frozen process kept the output silent while stopped; a stuck callback kept it silent until the tap was destroyed, while `AudioDeviceStop` waited 2.5 s behind it. | USB results below |
| E8 | In the cup, the combined aggregate added 227.5 ms at the ear on Bluetooth at the default buffer (sd 0.14 and 0.07 ms over 12 and 8 cycles in two runs) and 215.9 ms at 256 frames. Cause, from timestamps: a tap-only aggregate receives a burst about 6 ms after the player produces it, the combined aggregate about 211 ms after, a shift of about 205 ms close to the headset's declared 203.2 ms. A split pipeline (tap-only capture, ring, separate output IOProc) added 26–32 ms at the ear in three readable one-buffer cycles of one sweep, with 31.4 ms in a separate one-minute run that logged no underruns or overruns. Compensating with the sub-tap's extra input latency gave 24.3 ms, but over-compensating by 512 frames crashed `coreaudiod` once. Sound lagging picture is predicted from these, not measured. | Moved to E16 |
| E7 | Paused and silent players send exact zeros while running output; an idle tap gets no callbacks. Zeros are not a failure signal. | None for the decision |

### USB output on macOS 27.0.1

#### First run on 2026-11-20, before #46 and #47

One DAC exposed its microphone and output as separate Core Audio devices. The
output had one stereo stream and no input streams.

- **Engine stayed idle (fixed in [#46](https://github.com/incognitojam/dials/pull/46)).**
  HAL reported the wrong size for the default-output ID read. Swift had inferred an
  optional ID, whose storage takes five bytes. The remaining trials used the same
  build (`05ebc0a`) with four scalar reads corrected locally.
- **Selection and startup.** The sole tap input retained its stream ID across
  attachment and idle rate changes. At 48 kHz it was interleaved Float32 stereo,
  starting at channel 1, with a 512-frame IO buffer and verified tap-only mask.
  A warm file-triggered build took about 57 ms. The [first prompt](audio-taps.md#the-first-prompt)
  measurements cover the build that requested capture access.
- **Acoustic response.** A microphone between closed headphone cups recorded
  −36 dBFS tones. With a 1 kHz, 12 dB/octave low-pass and −12 dB gain, measured
  changes at 250 Hz and 1 kHz were approximately −11.7 and −14.7 dB (design
  −12.0 and −15.0). The 4 kHz estimate was about 37 dB down (design 36.5 dB),
  but the processed tone was within 2 dB of the measured noise floor. At 8 kHz the
  tone was 14 dB above the floor and about 43 dB below direct (design 49.8 dB).
  Across three switches, enabling produced a 10–20 ms dip and disabling about 40 ms. No
  high-frequency burst stood out in the 10 ms analysis windows. The processed
  level arrived 275 and 295 ms after the two saves that enabled EQ.
- **Clock changes (fixed in [#47](https://github.com/incognitojam/dials/pull/47)).**
  The first run measured a 0.70–0.78 s gap with or without EQ using a 10 dB
  drop in the recorded tone. In all three playing transitions (48→44.1, 48→96,
  96→48 kHz) the 350 ms watchdog released the tap. Playback stayed at the
  unprocessed level until a file edit.
  Verification occupied the session queue for about 660 ms. Two trials also
  logged aggregate StartIO error 35. The idle 48→44.1→96→48 kHz sequence kept
  the session and its processing. Each idle change logged 13 tap formats and
  13 input verifications. The playing changes logged two formats each and two,
  two and one verifications respectively. See the [re-run](#re-run-on-2026-11-25)
  for recovery with the fix.
- **Process termination.** From measured level transitions, quit, SIGTERM and
  SIGKILL restored direct audio in about 230, 90 and 110 ms respectively, with
  at most 30 ms of silence and no observed burst (one run each). SIGSTOP kept
  the output silent for the two-second stop. After SIGCONT, processing returned
  in about 60 ms. One “Repeated equalizer IO overloads” message followed about
  a second after SIGCONT.
- **Unplug.** Two unplugs included one during playback. The app reported one
  removal on loss. Fallback speaker playback was confirmed by ear only. On
  replug the DAC became default and a verified session restarted in about 54 ms
  without a file edit. The cup recording measured −14.9 dB at 1 kHz after replug.
- **Watchdog and settings.** Outside the playing rate changes, starts/stops, two
  mid-tone player IO restarts, eight seconds of exact zeros and idle periods
  caused no observed false failure. Absent or disabled settings and an explicit
  “none” assignment stayed idle. Truncated
  JSON, a missing field, a wrong type and an empty UID produced Activity reasons.
  A +6 dB preamp and +6 dB peak, a +12 dB peak at 5 Hz, a +24 dB shelf at
  8 Hz, and +30 dB preamp alone reported 12, 12, 24 and 30 dB headroom.

#### Re-run on 2026-11-25

With both fixes on the same DAC and an enabled settings file already present, the
first `running` status came 2.72 s after the first app log entry. IO proc creation
took 2.52 s of that time. Whether a prompt appeared was not recorded. The 1 kHz
tone measured about 15 dB below direct playback, within roughly 1 dB of the
design. Steady passages were 14.2–14.6 dB down at 48 kHz and 15.7–16.1 dB
down at 44.1 and 96 kHz. [What it costs](audio-taps.md#what-it-costs) gives the
separate burst measurement of playback latency.

During continuous playback the DAC went from 48 to 44.1 kHz and back, to 96 kHz
and back, then to 44.1 kHz and back. All six changes returned to `running` and
the corrected tone level without a file edit. HAL logged `_StartIO` error 35 at
every playing change and one of the two idle changes. None produced a watchdog
stall. Both idle changes (48→44.1→48 kHz) returned to `running`, and the next
tone at each rate had the correction.

In 50 ms microphone windows the tone stayed more than 3 dB below its steady level
for about 750–850 ms with EQ and 750–800 ms in four untapped changes. On four of the
six playing changes, short portions of the returning tone reached the
direct-playback level before the correction settled. Counting 10 ms windows within 6
dB of the direct tone at 1 kHz gave about 20–80 ms per affected change. None
exceeded the direct recording at 1 kHz. This criterion can also include partially
processed audio.

One unplug suspended EQ with “Device removed”. When the DAC reappeared, EQ was
running again within about a second. A fresh tone on the DAC had the correction.
This re-run did not include a second unplug. The player was pinned to the DAC,
so following the system default away from it and back remains untested.

These small counts describe one DAC. Neither session tested a denied or unanswered
permission prompt, sleep and wake, EQ with automatic routing enabled, rates below
32 kHz, or inspection for leftover private taps after USB teardown.
The code taps and mutes only output stream 0, so other output streams are
expected to pass through unprocessed. This was not measured. Multi-buffer,
more-than-stereo and non-interleaved layouts have only run against test doubles.

Several equalized recordings, including the first tone in a fresh session, had
brief broadband transients about 1–4 times per second during steady playback.
They were absent from the direct controls and occurred away from rate changes.
Their source remains unknown.

### Open

| # | Question | What it decides | Needed by |
| --- | --- | --- | --- |
| E4 | Sleep and wake with a tap running, compared with tearing it down first | Sleep handling | 2 |
| E6 | Is there a public way to check audio-capture permission in advance? When it is revoked while a tap runs, is the process killed, do callbacks continue with zeros, or does an error arrive? | Permission flow, and how a missing or revoked permission is detected | 2, 3 |
| E9 | Are alert sounds, and apps that take a device exclusively, captured by the tap? | What the equalizer can promise to cover | 3 |
| E10 | Does a tap work on AirPlay, HDMI and DisplayPort outputs at all, with what channel count and latency? | Which transports are supported | 8 |
| E11 | Does a 64- or 128-frame aggregate buffer change a wired device's buffer for other apps, and what does it cost? On Bluetooth, one in-cup run requested 64 frames and was granted 256, with the headset staying at 512, which saved 11.6 ms; when Bluetooth grants less than 256, and what that costs, is still open. | The default buffer size | 8 |
| E12 | Does holding the Sony control channel open disturb playback, and is state broadcast with multipoint on? On firmware 3.0.1, does cycling the earcup button produce change notifications? | Whether following noise cancelling is safe, and whether notifications can be relied on on 3.0.1 | 6 |
| E13 | A soundbar over HDMI at 5.1: what layout does the tap deliver, and does one chain per channel sound right? | Multichannel outputs | 8 |
| E14 | Does the tap's added latency appear in `kAudioDevicePropertyLatency` on a wired output, where video players would read it? On Bluetooth it does not: the headset reported the same latency tapped and untapped. | Lip-sync on wired outputs | 8 |
| E15 | Does a persistently unanswered prompt block subsequent requests, and does answering always clear it? See [the first prompt](audio-taps.md#the-first-prompt). Does the session need a timeout and a cancel path? | The session queue's design | 2 |
| E16 | The split pipeline, once built into the engine: call mode, rate and format changes, reconnection, sleep and wake, the headset's 256-frame buffer, runs of 30 minutes or more with ring fill and dropouts logged, behaviour on USB and built-in outputs, a lip-sync check with a real video player, and the headset's noise cancelling and upscaler in a known state | Whether the engine moves to it, and whether Bluetooth becomes eligible | Bluetooth |
