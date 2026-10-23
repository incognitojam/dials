# neqMac

neqMac is an early native macOS audio device guardian. It keeps the system on the highest-priority connected input and output devices, and can reject devices that should never become a system default.

This proof of concept deliberately contains no equalizer yet. Its job is to validate reliable device discovery and switching before an audio-processing pipeline is added.

How the equalizer will reach the signal path, and what a Core Audio process tap costs in latency and permissions, is measured in [System audio taps](audio-taps.md).

Where the curves it applies come from, and the format they are stored in, is covered in [Equalizer profiles](eq-profiles.md).

## Build and run

```sh
./scripts/build-app.sh --install neqMac
```

Requirements, signing and Start at login are covered in the [development instructions](development.md).

neqMac appears in the menu bar rather than the Dock. Automatic routing starts off, so the first launch does not change any audio device.

## First device test

1. Open **Routing Preferences…** from the neqMac menu bar panel.
2. Drag the preferred fallback output above the built-in speakers.
3. In **Input**, drag the Bluetooth headset microphone below **Never use**.
4. Turn on **Automatic routing**.
5. Connect and disconnect the headset, then sleep and wake the Mac.
6. Check **Activity** to confirm why each change occurred.

The headset may remain an allowed output while its input is excluded. “Never use” prevents neqMac from accepting that device as the macOS system default; it cannot stop another application from explicitly opening the device itself.

## Current behaviour

- Independent persisted priority lists for inputs and outputs, reordered by dragging a row (or from its context menu)
- **Edit** selects several devices at once, or every disconnected one with **Select Disconnected**, to **Never Use**, **Allow** or **Remove**; only disconnected devices can be removed, and a removed device is added back if it reconnects
- A transport icon on each device; rules saved without transport metadata infer USB, Bluetooth or built-in from their UID
- Persisted per-direction exclusions, shown as a **Never use** group below each priority list; drag a device across the divider, or use its context menu, to exclude or allow it
- **Use Now** on hover, or double-click a row, to switch to a device and pin it
- New devices join the list by connection type, after the last allowed device of the same or a preferred type: Bluetooth, AirPlay, USB, HDMI or DisplayPort, built-in, then virtual. On first launch this sorts every device by type; after that the order within and across types is yours
- Automatic fallback when devices appear or disappear
- Manual overrides that end when the chosen device disconnects
- **System sounds follow the output**, an option to move alert sounds along with the main output
- Debounced Core Audio listener handling to avoid switch loops
- Local in-memory activity timeline
- A Start at login switch in the menu bar panel, registered through `SMAppService`

Device rules use Core Audio UIDs, so renaming a device does not create a second rule. AirPlay devices are also matched by their exact display name within each direction, so changing UIDs does not fill the list with duplicates. Existing AirPlay duplicates collapse into their highest-priority entry, keeping “Never use” enabled if any duplicate was excluded. Older rules with a generic transport label are repaired when their UID identifies AirPlay (including screen-mirroring sessions) or their name matches a known AirPlay receiver; live devices with another known transport stay separate. AirPlay receivers with the same name share one rule; give them distinct names to manage them separately.

USB audio devices without a serial number, such as the Schiit Fulla, get a UID from the port they are plugged into, so moving one between ports or docks would otherwise add a new rule each time. neqMac matches these by manufacturer, product and interface instead, and collapses existing per-port duplicates the same way as AirPlay. Two identical serial-less devices connected at once therefore share one rule.
