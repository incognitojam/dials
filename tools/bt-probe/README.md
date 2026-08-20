# bt-probe

Read-only look at what paired Bluetooth devices advertise over SDP, used to work out
whether a headset exposes a vendor control channel that neqMac could read its state from.
See [Equalizer profiles](../../docs/eq-profiles.md) for why that matters.

```sh
swiftc -O -o build/probe probe.swift
./build/probe            # cached records only
./build/probe --query    # fresh SDP query, which connects to the device
```

Without `--query` it reads only the service records macOS cached when the device was
paired, so it neither connects to nor writes anything to a headset. A device paired but
never queried shows no records; connect it and pass `--query` to populate them.

Output is one block per device, listing each service record's name, its RFCOMM channel if
it has one, and its service class UUIDs:

```
Example Headphones  [connected]
  Serial HPC                   rfcomm 9
      96CC203E-5068-46AD-B32D-E316F5E069BA
  Hands-Free unit              rfcomm 1
      0000111E
```

A 16-byte UUID next to an RFCOMM channel is a vendor protocol. The 4-digit ones are
standard Bluetooth profiles, so `0000111E` is Hands-Free and `0000110B` is A2DP Sink.

Reading cached records needs no entitlement and raises no prompt. Opening a channel does:
an app doing that needs `NSBluetoothAlwaysUsageDescription`, and sandboxed also
`com.apple.security.device.bluetooth`.

## sony.swift

Opens the Sony vendor channel on a connected headset and reads from it. It sends only
`GET` commands and never a `SET`, so it cannot change a setting on the headphones.

```sh
swiftc -O -o build/sony sony.swift
./build/sony                 # defaults to a device named WH-1000XM4
./build/sony "WH-1000XM5"
```

It sends an init, asks for the current noise-cancelling state, listens for thirty seconds
while you change modes on the headset, then reads the headset's own equalizer. Frames are
acknowledged as the protocol requires — without an ACK the device retransmits forever.

The commands and framing come from
[sony-ult-ctl](https://github.com/Leonard013/sony-ult-ctl) and
[SonyHeadphonesClient](https://github.com/Plutoberth/SonyHeadphonesClient). Not every
inquired type exists on every model: an unsupported one is acknowledged and then ignored,
so silence after an ACK means the wrong command rather than a broken channel.
