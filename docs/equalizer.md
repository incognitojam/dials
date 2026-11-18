# Equalizer

neqMac is gaining a corrective equalizer: one measured profile per pair of headphones,
applied to what other applications play through them. Whether alert sounds and
applications that take a device exclusively are included is not yet known (experiment
E9). This is the design for it. The measurements it rests on are in
[System audio taps](audio-taps.md), [Equalizer profiles](eq-profiles.md) and
[Reading headset state](headset-control.md).

The document keeps three kinds of statement apart. **Decided** is a choice the owner has
made and a builder should follow. **Measured** links to the document that measured it.
**Provisional** is a working assumption that a named experiment in
[Open hardware experiments](#open-hardware-experiments) will confirm or replace; build it
so it can change.

Only the first piece exists. `EqualizerCore` decodes and imports profiles, designs the
filters and renders them in real time, as described in
[How curves are computed](eq-profiles.md#how-curves-are-computed) and
[Rendering a profile](eq-profiles.md#rendering-a-profile). Nothing in the app uses it
yet: there is no tap, no settings file and no interface. Everything below that is not
`EqualizerCore` is a plan.

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
permission denied, suspected capture failure, or failed with a reason. The engine starts a
session only while desired processing says to equalize, and stops it as soon as it does
not.

The first attempt for an output starts when desired processing first says to equalize it
after an explicit user action: confirming a profile or switching a device on in the app,
or, in milestone 2, adding a matching assignment to the settings file. That attempt is
what raises the system prompts. If permission is denied, the session ends, the assignment
is kept, and the device shows *Permission denied* with an action to open System Settings.
neqMac does not try again on its own. **Retry** takes the retained assignment, evaluates
desired processing again, and if it still says to equalize, starts one fresh session; if
permission is still missing, the status returns to *Permission denied*.

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
[an unanswered permission prompt can block `AudioDeviceStart`](audio-taps.md#two-things-not-to-repeat)
indefinitely (measured). Building it:

1. Translate neqMac's process ID to a Core Audio process object, retrying, since this
   fails transiently just after launch (measured; the retry budget is provisional).
2. Create the tap for the output device's first stream, excluding neqMac, muted when
   tapped.
3. Create the private aggregate with the device as its main sub-device and the tap in
   its tap list.
4. Read the tap's format and compile the plan at that rate.
5. Create and start the IOProc.

A failure at any step must destroy whatever the earlier steps created; that is a
requirement. Everything else in this section is provisional:

- **Teardown order.** Stop and destroy the IOProc, then the aggregate, then the tap. The
  spike established that a tap mutes the device while an IOProc runs, not exactly when the
  mute begins or lifts. E2 and E5 decide the order.
- **Retargeting.** When the output changes, stop the old session and start one for the
  new device. E1 measures the gap and whether starting the new one first is better.
- **Rate and format changes.** Recompile the plan, and rebuild the session if the IOProc
  stopped. E3 decides which happens.
- **Sleep.** Stop the session before the Mac sleeps and reconcile after it wakes. E4
  decides whether that is needed.
- A device that dies stops its session, and repeated overloads are logged.

### Off means off

Turning EQ off for a device, with its switch, the master switch or by choosing *No
equalizer*, **tears the tap down** (decided). A running tap costs two buffer periods of
latency plus the device's safety offsets (measured; on USB, acoustically, about 2.3 ms
more than the timestamps report), a permission, a wakeup on every cycle, and a way to make
the Mac silent. None of that is worth paying to apply no filter.

Building or tearing down a tap interrupts playback for a time E1 will measure, so on/off is
a deliberate, debounced switch, never a hover or something that can be toggled rapidly.

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
strings must be in neqMac's `Info.plist` (measured). A user who only routes must never see
either prompt, so neqMac never asks at launch; the first request follows the user action
described in [Desired processing and session status](#desired-processing-and-session-status).
There appears to be no public way to check audio-capture authorisation in advance, and
what happens when it is revoked mid-session is unknown; E6 answers both.

### Failure

The invariant (decided): **no state leaves a tap muting the output without a running,
healthy IOProc**. Because `mutedWhenTapped` silences the device while the tap runs, a
broken equalizer does not degrade audio, it stops it. Every failure therefore ends the
same way: tear down, let the audio play uncorrected, and say so.

- **Heartbeat.** The IOProc counts its cycles. If the count stops moving while the
  session claims to be running, it is torn down. The timeout is provisional.
- **Suspected capture failure.** An unauthorised tap reports success and delivers exact
  zeros (measured). But zeros are not proof of failure — silence is valid audio — and a
  non-zero sample shows only that capture worked at that moment, since permission might be
  revoked while callbacks continue (E6). E7 decides whether a reliable signal exists, such
  as exact zeros while another process is known to be playing to the device, before any
  threshold is chosen. Until then the check is a suspicion that tears down and says so,
  not a diagnosis.
- **Non-finite samples.** The processor already silences the affected sample, resets that
  channel and fades back in; the controller logs it.
- **Back-off.** After a failure, neqMac does not restart the session on its own until the
  next device change or user action, and limits attempts per device, so a broken equalizer
  cannot flap the audio on and off. The limits are provisional.
- **Activity.** Every start, stop and failure is posted to the Activity timeline with its
  reason.
- **Crashes.** The tap and aggregate belong to the process and should disappear with it.
  E5 has to show that before any of this reaches a user.

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
displays the panel looks as it does today. When the session fails or permission is denied,
the line becomes the existing orange error banner, and its first sentence is what the user
hears — that audio is playing normally, without correction — with **Retry** or an action
to open System Settings.

The permission request is preceded by a short explanation of the two system prompts that
follow: audio is processed on the Mac and never recorded or sent anywhere, routing works
whether or not it is allowed, and if processing fails, audio plays without EQ.

Profile chips on the routing rows as the main surface, and a headphone library as the
primary model, were considered and not chosen.

## Milestones

Each is one pull request with its own tests, and updates this document.

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

## Open hardware experiments

None of these has been run. E1 to E7 and E15 should be answered before milestone 2 merges;
several can use that branch's build.

| # | Question | What it decides | Needed by |
| --- | --- | --- | --- |
| E1 | How long and how audible is the gap when a tap is created or destroyed mid-playback, or retargeted to another device? Is creating the new one before destroying the old one better? | The cost of on/off and of routing switches, and the retarget order | 2 |
| E2 | Unplugging USB or disconnecting Bluetooth while tapped: does the IOProc stop cleanly, does the aggregate go away, and is anything left muted on the device the system falls back to? When exactly does the mute lift during teardown? | The teardown order and whether it keeps the never-silent invariant | 2 |
| E3 | Changing the device's sample rate while tapped, including Bluetooth switching to its call profile: does the IOProc continue, and do the tap and aggregate follow? | Whether a rate change recompiles or rebuilds | 2 |
| E4 | Sleep and wake with a tap running, compared with tearing it down first | Sleep handling | 2 |
| E5 | `kill -9` or a crash with a tap running: does output resume immediately on its own? | Whether a crash can leave the Mac silent; the largest unknown | 2 |
| E6 | Is there a public way to check audio-capture permission in advance? When it is revoked while a tap runs, is the process killed, do callbacks continue with zeros, or does an error arrive? | Permission flow, and how mid-session loss is detected | 2, 3 |
| E7 | Do common players and call apps send exact zeros while paused but still running IO? Is there any signal that distinguishes a failed capture from real silence? | Whether a capture-failure check can be reliable, and its threshold | 2 |
| E8 | Repeat the Bluetooth acoustic timing scatter with the headset's upscaler and noise cancelling off, and check lip-sync through the tap | The open question in [System audio taps](audio-taps.md#open-questions), and whether Bluetooth is enabled | 3 |
| E9 | Are alert sounds, and apps that take a device exclusively, captured by the tap? | What the equalizer can promise to cover | 3 |
| E10 | Does a tap work on AirPlay, HDMI and DisplayPort outputs at all, with what channel count and latency? | Which transports are supported | 8 |
| E11 | Does a 64- or 128-frame aggregate buffer change the device's buffer for other apps, and what does it cost on Bluetooth? | The default buffer size | 8 |
| E12 | Does holding the Sony control channel open disturb playback, and is state broadcast with multipoint on? On firmware 3.0.1, does cycling the earcup button produce change notifications? | Whether following noise cancelling is safe, and whether notifications can be relied on on 3.0.1 | 6 |
| E13 | A soundbar over HDMI at 5.1: what layout does the tap deliver, and does one chain per channel sound right? | Multichannel outputs | 8 |
| E14 | Does the tap's added latency appear in `kAudioDevicePropertyLatency`, where video players would read it? | Lip-sync on wired outputs | 8 |
| E15 | Once an unanswered first prompt blocks `AudioDeviceStart`, does it clear when the user answers? Does the session need a timeout and a cancel path? | The session queue's design | 2 |
