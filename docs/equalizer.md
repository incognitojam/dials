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
| Bluetooth | From milestone 3, and only once E8 has run |
| AirPlay, HDMI and DisplayPort | Not until E10 and E13 say how a tap behaves on them (milestone 8) |
| Virtual devices and aggregates | Never. Loopback and recording devices would capture equalized audio, and aggregates include neqMac's own |

So a soundbar or display connected over HDMI or DisplayPort cannot be assigned a profile
until milestone 8, whatever kind of device it is. Bluetooth waits for E8 because
[System audio taps](audio-taps.md#open-questions) leaves the acoustic timing of a tapped
Bluetooth stream unexplained; milestone 3 does not enable it until that is understood.
The edge-case runs sharpen the concern: timestamps suggest the tap receives a headset's
audio about one device latency late, roughly 200 ms on the WH-1000XM4. That is inferred,
not heard. If an acoustic measurement confirms it, tapped Bluetooth playback is about
200 ms later than untapped, a real cost for video sync that the interface would have to
state.

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
resumes when the rate does.

A device with more than two channels gets the same chain on every channel.

## The engine

### Lifecycle

A session is built on its own serial queue, never on the main thread, because
[a permission prompt can hold up construction](audio-taps.md#two-things-not-to-repeat).
The measured 41.5 s wait occurred before `AudioDeviceStart`. Building it:

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

A USB device with inputs requires the assignment key `allowDuplexInput` to be true.
The default suspends before tap creation. Opt-in keeps all the identity, format and
stream-usage checks. The macOS SDK documents that sub-taps have no streams of their
own. On an output-only DAC the aggregate's sole input identifies the tap even if HAL
reissues the stream ID. On a duplex DAC the tap-only stream ID must survive attachment
at either end of the stream list, alongside one stream per physical input stream.
Reconfiguration checks the IO-proc mask and repairs a changed mask before republishing
the input selection. Apple's stream mask applies to the
IO proc. Driver-level microphone power and the behaviour of the target USB DAC still
need hardware verification. [Apple’s IO-proc stream usage](https://developer.apple.com/documentation/coreaudio/audiohardwareioprocstreamusage)

Playback headroom covers DC through Nyquist. The peak search samples DC, 4096
logarithmic intervals from 1 Hz to Nyquist, and each in-range band center. It refines
the peak estimate around local maxima.
Any peak above 0 dB reduces both preamp and compare gain by the excess. Activity records
the reduction. A final clamp bounds each rendered sample to [−1, 1].

A failure at any step must destroy whatever the earlier steps created (decided). The
rest of this section follows from the measurements in [What the tap does at its
edges](audio-taps.md#what-the-tap-does-at-its-edges), made on the built-in speakers and,
by timestamps only, on a Bluetooth headset. They are decided unless marked otherwise;
the USB repeats listed in [Hardware experiments](#hardware-experiments) could still
change them.

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
- **Rate and format changes recompile, never rebuild,** while the device stays eligible.
  The IOProc survives a rate change on its own: on the speakers the interval between
  callbacks was 108–184 ms, after which the aggregate restarted at the new rate. The plan
  is recompiled on the format notification. The IOProc must tolerate the channel count
  changing and the buffer size changing. M2 observes the current size. Requesting a
  different size remains open until E11 measures the effect on other clients.
  Format notifications reset the watchdog interval. Transient property-read failures
  retry on subsequent notifications, with suspension after three unsuccessful updates.
  If the watchdog releases the mute because the layout became unverifiable, the controller
  re-evaluates the current output and settings once after 750 ms. A repeated layout loss
  stays suspended. A rate below 32 kHz, such as the 16 kHz one-channel call profile a headset
  switched to, is not recompiled: it suspends EQ and tears the tap down.
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
equalizer*, **tears the tap down** (decided). A running tap costs two buffer periods of
latency plus the device's safety offsets (measured; on USB, acoustically, about 2.3 ms
more than the timestamps report), a permission, a wakeup on every cycle, and a way to make
the Mac silent. None of that is worth paying to apply no filter.

Building or tearing down a tap did not leave a silent gap on the speakers. The original
and the marker that stood in for the processed copy overlapped for up to about 45 ms.
With real passthrough that would be the same audio twice about 26 ms apart, by the IO
timestamps, which should sound like a flam rather than a dropout (inferred). On/off is
still a deliberate, debounced switch, never a hover or something that can be toggled
rapidly. On the headset, a tap built mid-playback delivered about 200 ms of zeros first,
which may be heard as silence (inferred).

The one exception is **compare**: holding a button to hear the difference, which keeps the
tap running and switches the processor's mode (decided). Compare is level-matched. A
correction's preamp can be as low as −18.1 dB, so the unequalized signal at full level is
louder and would always sound better. In compare mode the processor plays the dry signal
at the plan's compare gain: the K-weighted RMS of the profile's magnitude response,
preamp included, over 256 logarithmically spaced points from 20 Hz to the lower of 20 kHz
and Nyquist. A profile with no bands compares at its preamp gain. Profile changes, compare
and its release go through the processor's crossfade, which reduces switching artefacts.

### Permission

The tap needs two permissions, microphone and system audio capture, and both usage
strings must be in neqMac's `Info.plist` (measured). A user who only routes must never
see either prompt, so neqMac never asks at launch; the first request follows the user
action described in [Desired processing and session
status](#desired-processing-and-session-status). There appears to be no public way to
check audio-capture authorisation in advance, and what happens when it is revoked
mid-session is unknown; E6 answers both. On one fresh signing identity, building a
session took 41.5 s while the prompt was on screen and completed once it was answered;
the logged `AudioDeviceStart` took 0.118 ms, so the wait came before it, and which call
blocked is not known.

### Failure

The invariant (decided): **no state leaves a tap muting the output without a running,
healthy IOProc**. Because `mutedWhenTapped` silences the device while the tap runs, a
broken equalizer does not degrade audio, it stops it. Every failure that can be observed
therefore ends the same way: tear down, let the audio play uncorrected, and say so. A
denied or revoked permission that delivers zeros is not yet observable; see E6.

- **Heartbeat.** The IOProc counts its cycles, and a watchdog on another thread checks
  the count. An idle tap gets no callbacks. The watchdog disarms while a fresh activity
  poll confirms that no other process is running output on the device. A failed poll or
  an idle reading older than 250 ms arms it until a fresh result arrives. The tolerance is a chosen 350 ms, informed by the
  largest gap seen around a format change, 340.5 ms when a headset left its call profile.
  On expiry the watchdog destroys the tap before querying physical removal. A separate
  queue samples other-process activity so a blocked HAL query cannot hold up mute release.
  The watchdog lives in the same process, so it can act on a stuck callback but not on the whole process being
  suspended; that case only ends when the process continues or dies.
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
- **Activity.** Every start, stop and failure is posted to the Activity timeline with its
  reason.
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

The permission request is preceded by a short explanation of the two system prompts that
follow: audio is processed on the Mac and never recorded or sent anywhere, routing works
whether or not it is allowed, and if processing fails, audio plays without EQ.

Profile chips on the routing rows as the main surface, and a headphone library as the
primary model, were considered and not chosen.

## Milestones

Milestone 2 ships as three dependent pull requests covering settings and headroom, the
session and renderer, and app integration. Each layer includes its tests.

1. **`EqualizerCore`.** Profile format, AutoEq import, filter design, response
   evaluation and the real-time processor, with no Apple framework imports. *Shipped in
   [#31](https://github.com/incognitojam/dials/pull/31) and
   [#33](https://github.com/incognitojam/dials/pull/33).*
2. **The engine, configured by a hand-edited settings file, for USB outputs.** Shared
   device identity with routing, the settings file and its store, desired processing and
   session status, the controller and tap session, filtering neqMac's own aggregate, the
   usage strings, rate changes, sleep and wake, low-rate suspension, the failure checks,
   back-off and Activity events. An install without the file behaves exactly as today.
3. **Assigning profiles in the app.** The Equalizer pane, importing a pasted AutoEq block,
   per-device on/off and the master switch, permission onboarding, status display, Retry,
   compare, the USB "What's plugged in?" question and its menu bar quick switch, built-in
   outputs, and Bluetooth once E8 has run.
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
edges](audio-taps.md#what-the-tap-does-at-its-edges). Only the speakers could be heard,
so every headset result is inferred from timestamps.

| # | Result | What remains |
| --- | --- | --- |
| E1 | Build and teardown overlap the original and the marker for up to about 45 ms on the speakers, with no silent gap, in 7 builds across three teardown orders; both aggregate-first teardowns failed to destroy the IOProc. Retarget order made no audible difference in the two retargets that ended on the speakers. On the headset a tap built mid-playback delivered about 197 ms of zeros first (inferred). | Repeat on a USB DAC, and listen on the headset with a microphone in the cup |
| E2, Bluetooth | One power-off and two software disconnects left the IOProc running with silent input and no error; the loss arrived as notifications. The speakers the audio moved to were not muted. In the two runs that reconnected and played to the headset, the orphaned aggregate re-adopted it. | Unplugging a USB DAC while tapped; whether a reconnected headset is muted by an orphaned tap, with a microphone in the cup |
| E3 | A rate change left 108–184 ms between callbacks and the IOProc resumed at the new rate; the call profile changed the channel count and buffer size. Recompile while the device stays eligible, never rebuild. | Repeat on a USB DAC |
| E5 | Ending the process without teardown released the mute in all 11 runs, and no tap or aggregate was left after any of the 15. A frozen process kept the output silent while stopped; a stuck callback kept it silent until the tap was destroyed, while `AudioDeviceStop` waited 2.5 s behind it. | Repeat on a USB DAC |
| E7 | Paused and silent players send exact zeros while running output; an idle tap gets no callbacks. Zeros are not a failure signal. | None for the decision |

### Open

None of these questions has been answered. E4, E6 and E15, and the USB repeats of E1,
E2, E3 and E5 above, should be answered before milestone 2 merges, since it equalizes
USB outputs; several can use that branch's build.

| # | Question | What it decides | Needed by |
| --- | --- | --- | --- |
| E4 | Sleep and wake with a tap running, compared with tearing it down first | Sleep handling | 2 |
| E6 | Is there a public way to check audio-capture permission in advance? When it is revoked while a tap runs, is the process killed, do callbacks continue with zeros, or does an error arrive? | Permission flow, and how a missing or revoked permission is detected | 2, 3 |
| E8 | Measure a tapped Bluetooth stream acoustically with a microphone in the cup, with the headset's upscaler and noise cancelling off: is it about 200 ms later than untapped, as the timestamps suggest? Check lip-sync through the tap | The open question in [System audio taps](audio-taps.md#open-questions), and whether Bluetooth is enabled | 3 |
| E9 | Are alert sounds, and apps that take a device exclusively, captured by the tap? | What the equalizer can promise to cover | 3 |
| E10 | Does a tap work on AirPlay, HDMI and DisplayPort outputs at all, with what channel count and latency? | Which transports are supported | 8 |
| E11 | Does a 64- or 128-frame aggregate buffer change the device's buffer for other apps, and what does it cost on Bluetooth? | The default buffer size | 8 |
| E12 | Does holding the Sony control channel open disturb playback, and is state broadcast with multipoint on? On firmware 3.0.1, does cycling the earcup button produce change notifications? | Whether following noise cancelling is safe, and whether notifications can be relied on on 3.0.1 | 6 |
| E13 | A soundbar over HDMI at 5.1: what layout does the tap deliver, and does one chain per channel sound right? | Multichannel outputs | 8 |
| E14 | Does the tap's added latency appear in `kAudioDevicePropertyLatency`, where video players would read it? | Lip-sync on wired outputs | 8 |
| E15 | Which call blocks while the first prompt is unanswered, and does it always clear when the user answers? Once, a build waited 41.5 s and completed after the prompt was answered, but the wait came before `AudioDeviceStart`. Does the session need a timeout and a cancel path? | The session queue's design | 2 |
