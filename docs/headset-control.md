# Reading headset state

An equalizer profile is only correct for a headset in a particular state. Noise cancelling
changes the frequency response, and a vendor equalizer applies after neqMac's, so a
published correction stacked on top of one corrects twice. [Equalizer profiles](eq-profiles.md)
records how the upstream database handles that — noise cancelling on is a different product,
not a modifier — but it leaves neqMac needing to know which one is being worn.

Asking the user is the fallback. This is the measurement of whether the headphones can be
asked instead. They can: the state is readable, and changes are pushed rather than polled.

Everything below was measured on macOS 26.6.1 against a Sony WH-1000XM4 on firmware 2.9.0.

## Finding the channel

Headsets that have a companion app expose a vendor RFCOMM service alongside the standard
Bluetooth profiles. macOS caches the SDP records at pairing time, and reading that cache
needs no entitlement, raises no prompt, and does not contact the device — `tools/bt-probe`
prints it.

The tested unit advertises:

```
Serial HPC    rfcomm 9    96CC203E-5068-46AD-B32D-E316F5E069BA
```

That UUID is Sony's, and is the one every open-source Sony client targets. The channel
number is a property of the device rather than the model, so it has to be read from the
service record rather than hardcoded.

From there the macOS path is ordinary IOBluetooth: `getServiceRecord(for:)` with the vendor
UUID, `getRFCOMMChannelID`, `openRFCOMMChannelAsync` with a delegate. Opening the channel
raised no permission prompt either, which is worth not relying on — an app doing this should
still declare `NSBluetoothAlwaysUsageDescription`, and a sandboxed one needs
`com.apple.security.device.bluetooth`.

## The Sony protocol

Frames are `0x3E`, escaped body, `0x3C`. Inside: a type byte, a sequence byte, a four-byte
big-endian payload length, the payload, and a checksum that is the sum of everything before
it. Bytes that collide with the markers are escaped as `0x3D` followed by the byte with bit
4 cleared. Type `0x0C` carries commands, `0x01` is an acknowledgement.

**Every frame from the device must be acknowledged** with type `0x01` and the inverted
sequence number, or it retransmits indefinitely.

Commands come in families of three: `0x66` gets, `0x67` returns, `0x68` sets, with a second
byte naming the subject. Noise cancelling is subject `0x02`:

```
-> 66 02
<- 67 02 01 02 02 01 01 00
```

The reply is `[RET, subject, effect, settingType, ncDualSingle, asmSettingType, asmId,
asmLevel]`. Three states were observed:

| Payload | Meaning |
| --- | --- |
| `67 02 01 02 02 01 01 00` | noise cancelling, dual mic |
| `67 02 01 02 00 01 01 14` | ambient sound, level 20, voice focus |
| `67 02 00 02 00 01 01 14` | off |

The equalizer is `0x56`/`0x57`/`0x58` on subject `0x01`:

```
-> 56 01
<- 57 01 00 06 0A 0A 0A 0A 0A 0A
```

Preset `0x00` is off, then a band count and six values — the five bands plus Clear Bass —
each centred at `0x0A`. So neqMac can confirm the headset's own equalizer is flat before
applying a profile, rather than assuming it.

Subjects are model-specific. `0x17` for noise cancelling and `0x03` for the equalizer belong
to newer models and this one ignores them. An unsupported subject is **acknowledged and then
never answered**, so silence after an ACK means the wrong command rather than a dead channel.

## State changes are pushed

The useful part. Command `0x69` arrives unsolicited when the state changes:

```
<- 69 02 01 02 00 01 01 14   ambient sound, level 20, voice focus
<- 69 02 00 02 00 01 01 14   off
<- 69 02 01 02 02 01 01 00   noise cancelling, dual mic
```

Twelve of these were captured across four full cycles of the earcup button, every transition
reported, none missed or duplicated. neqMac can hold the channel open and react to the
headset being changed, rather than polling for it.

Reading state on attach is still needed, because the first notification only says what
changed since the app connected.

## What this does not establish

Whether a change made from another device is broadcast. The tested headset had *Connect to 2
devices simultaneously* switched off, so the phone could not hold the headset at the same
time as the Mac, and a run with the vendor app open produced no notifications — which proves
nothing, since nothing could have changed. In the single-connection case it does not matter:
no other controller can be attached. With multipoint on, it is an open question, and if
changes are not broadcast then a slow poll of `66 02` is the fallback.

Whether opening the channel disturbs A2DP. Nothing was playing during any of these runs.

The write path. Only `GET` commands were ever sent. Setting state — turning the vendor
equalizer off before applying a profile, say — is a different risk and has not been tried.

Whether firmware 3.0.1 changes any of it. Its only published change is "enhances system
software security features", which on a control channel with no authentication of any kind
is a plausible thing to lock down. 2.9.0 is the baseline these traces belong to.

## Samsung

Untested, but the shape is the same and the evidence is strong. GalaxyBudsClient implements
the Galaxy Buds Live over standard SPP, its device specification lists noise cancelling as a
supported feature, and it has a decoder named `NOISE_REDUCTION_MODE_UPDATE` — an update
rather than a response, so those push too. It also exposes an equalizer toggle.

A paired Buds Live showed no cached SDP records, meaning macOS has never queried it. Connect
it and run `bt-probe --query` to populate them.

## One thing that wasted an hour

*Automatic Power Off: off when headphones are removed* means headphones sitting on a desk
switch themselves off part way through a measurement, closing the channel. Two runs died
this way and the disconnect looked like a protocol fault. Turn it off before measuring.

While in that settings screen: *DSEE Extreme* was set to Auto throughout. It is an adaptive
upscaler sitting between whatever the Mac sends and the drivers, and it is a better candidate
than noise cancelling for the unexplained acoustic timing scatter in
[System audio taps](audio-taps.md), since the vendor equalizer was verified off the whole
time. Disable it before repeating that measurement.
