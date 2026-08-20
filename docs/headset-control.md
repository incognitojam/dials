# Reading headset state

An equalizer profile is only correct for a headset in a particular state. Noise cancelling
changes the frequency response, and a vendor equalizer applies after neqMac's, so a
published correction stacked on top of one corrects twice. [Equalizer profiles](eq-profiles.md)
records how the upstream database handles that — noise cancelling on is a different product,
not a modifier — but it leaves neqMac needing to know which one is being worn.

Asking the user is the fallback. This is the measurement of whether the headphones can be
asked instead. They can: the state is readable, and changes are pushed rather than polled.

Everything below was measured on macOS 26.6.1, against a Sony WH-1000XM4 on firmware 2.9.0
and a Samsung Galaxy Buds Live whose firmware version was not read.

## Finding the channel

Headsets that have a companion app expose a vendor RFCOMM service alongside the standard
Bluetooth profiles. macOS caches the SDP records at pairing time, and reading that cache
needs no entitlement, raises no prompt, and does not contact the device — `tools/bt-probe`
prints it.

The Sony unit advertises:

```
Serial HPC    rfcomm 9    96CC203E-5068-46AD-B32D-E316F5E069BA
```

That UUID is Sony's, and is the one every open-source Sony client targets. The channel
number is a property of the device rather than the model, so it has to be read from the
service record rather than hardcoded.

Samsung is less obliging. The Buds Live advertise five vendor-looking services, and the one
that works is the only one wearing an ordinary UUID:

```
SPPSERVICE4     rfcomm 4    F8620674-A1ED-41AB-A8B9-DE9AD655729D
SPPSERVICE3     rfcomm 1    B4A9D6A0-B2E3-4E40-976D-A69F167EA895
SAMSUNGDEVICE   rfcomm 2    A23D00BC-217C-123B-9C00-FC44577136EE
BTIS            rfcomm 9    E7AB2241-CA64-4A69-AC02-05F5C6FE2D62
GEARMANAGER     rfcomm 1    00001101-0000-1000-8000-00805F9B34FB
```

`GEARMANAGER` is the control channel, on the standard Serial Port Profile UUID. So an
unfamiliar 16-byte UUID is a good hint that a vendor channel exists, but its absence means
nothing — the service name carries the information here.

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

## Sony pushes state changes

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

## The Samsung protocol

Frames are `0xFD`, a little-endian 16-bit header, a message id, the payload, a 16-bit
checksum and `0xDD`. The low ten bits of the header are the length of everything from the
message id through the checksum; bits 13 and 14 mark fragments and responses.

The checksum is CRC-16/XMODEM over the message id and payload. It is verified by swapping
the two checksum bytes back into the buffer and checksumming the lot, which yields zero for
a good frame. Nothing needs acknowledging, and nothing retransmits.

Unlike Sony, nothing has to be asked for. Opening the channel and sending **no bytes at all**
produces a burst of state, repeated several times over about five seconds:

```
<- EXTENDED_STATUS_UPDATED  [08 01 64 64 01 00 33 5E 00 00 00 22 01 00 16 01 16 01 00 00 03 01 10 00]
```

Message id 97, and for this model the payload decodes as:

| Offset | Field |
| --- | --- |
| 0 | protocol revision, 8 here |
| 2, 3 | battery left, right |
| 5 | which earbud holds the link |
| 6 | placement, one nibble each: 1 wearing, 2 idle, 3 in case |
| 7 | case battery |
| 9 | equalizer: 0 off, otherwise preset + 1 |
| 11 | touch-and-hold assignment, one nibble each; 2 is noise controls |
| 12 | noise cancelling |

Those offsets shift on every model after Buds+, so the decode is per-model and not
generic. Battery arrives separately and continuously as `STATUS_UPDATED`, id 96, which
repeats the revision, batteries, link, placement and case battery in seven bytes.

The single frame carrying both noise cancelling and the equalizer preset is the useful part:
one unsolicited message answers the double-correction question, where Sony needs two
round trips.

## Samsung pushes state changes too

Toggling noise cancelling on the earbud produced, again with nothing sent:

```
<- NOISE_REDUCTION_MODE_UPDATE  [00]   off
<- NOISE_REDUCTION_MODE_UPDATE  [01]   on
<- NOISE_REDUCTION_MODE_UPDATE  [00]   off
```

A dedicated message id with a one-byte payload, so unlike Sony's `0x69` there is no need to
diff a full state block to work out what moved.

The gesture only exists if it is assigned. Byte 11 of the status frame reports the
touch-and-hold action for each earbud, so an app can tell whether the user is even able to
change noise cancelling from the earbud before waiting on a notification that may never come.

Two accidents confirmed the byte-level decode independently of the reference
implementation: placement read *in case* while the earbuds were in their case, and the
placement stream tracked one earbud being taken out and worn and then the other, in the
right order.

## The two vendors compared

| | Sony WH-1000XM4 | Galaxy Buds Live |
| --- | --- | --- |
| Service | vendor UUID | standard SPP UUID, named `GEARMANAGER` |
| Reading state | `GET` request | pushed on connect, unprompted |
| Change notification | `0x69`, full state block | dedicated id, one byte |
| Frame integrity | none | CRC-16 on every frame |
| Acknowledgement | required, or it retransmits forever | none |
| Vendor equalizer | second request | in the same frame as the state |
| Bytes written to prove it | two per request | zero |

Both were read without a permission prompt, and the Samsung side was proven entirely
passively.

## What this does not establish

Whether a change made from another device is broadcast. The tested headset had *Connect to 2
devices simultaneously* switched off, so the phone could not hold the headset at the same
time as the Mac, and a run with the vendor app open produced no notifications — which proves
nothing, since nothing could have changed. In the single-connection case it does not matter:
no other controller can be attached. With multipoint on, it is an open question, and if
changes are not broadcast then a slow poll of `66 02` is the fallback.

Whether opening the channel disturbs A2DP. Nothing was playing during any of these runs,
on either headset.

The write path, on both. Only `GET` commands were sent to the Sony, and nothing at all to
the Samsung. Setting state — turning the vendor equalizer off before applying a profile,
say — is a different risk and has not been tried.

What most of the Samsung traffic is. The earbuds volunteer a great deal besides state:
version information, voice-wake-up status, and frequent 32- to 104-byte debug frames, some
containing ASCII diagnostics. All of it checksums correctly, none of it is understood, and
none of it appears to be needed.

Whether firmware 3.0.1 changes any of it. Its only published change is "enhances system
software security features", which on a control channel with no authentication of any kind
is a plausible thing to lock down. 2.9.0 is the baseline these traces belong to.

## One thing that wasted an hour

*Automatic Power Off: off when headphones are removed* means headphones sitting on a desk
switch themselves off part way through a measurement, closing the channel. Two runs died
this way and the disconnect looked like a protocol fault. Turn it off before measuring.

While in that settings screen: *DSEE Extreme* was set to Auto throughout. It is an adaptive
upscaler sitting between whatever the Mac sends and the drivers, and it is a better candidate
than noise cancelling for the unexplained acoustic timing scatter in
[System audio taps](audio-taps.md), since the vendor equalizer was verified off the whole
time. Disable it before repeating that measurement.
