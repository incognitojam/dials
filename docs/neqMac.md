# neqMac

neqMac is an early native macOS audio device guardian. It keeps the system on the highest-priority connected input and output devices, and can reject devices that should never become a system default.

This proof of concept deliberately contains no equalizer yet. Its job is to validate reliable device discovery and switching before an audio-processing pipeline is added.

How the equalizer will reach the signal path, and what a Core Audio process tap costs in latency and permissions, is measured in [System audio taps](audio-taps.md).

Where the curves it applies come from, and the format they are stored in, is covered in [Equalizer profiles](eq-profiles.md).

## Requirements

- macOS 14 or later
- Xcode 26 or later, including the macOS SDK and command-line tools

Check the active toolchain with:

```sh
xcode-select -p
xcodebuild -version
swift --version
```

## Build and run

Run the tests:

```sh
swift test
```

Build an ad-hoc signed menu-bar app:

```sh
./scripts/build-app.sh neqMac
open build/neqMac.app
```

Or install it to `~/Applications`:

```sh
./scripts/build-app.sh --install neqMac
```

neqMac appears in the menu bar rather than the Dock. Automatic routing starts off, so the first launch does not change any audio device.

## First device test

1. Open **Routing preferences…** from the neqMac menu-bar panel.
2. Put the preferred fallback output above **Mac Speakers**.
3. In **Input priority**, enable **Never use** for the Bluetooth headset microphone.
4. Turn on **Automatic routing**.
5. Connect and disconnect the headset, then sleep and wake the Mac.
6. Check **Activity** to confirm why each change occurred.

The headset may remain an allowed output while its input is excluded. “Never use” prevents neqMac from accepting that device as the macOS system default; it cannot stop another application from explicitly opening the device itself.

## Current behaviour

- Independent persisted priority lists for inputs and outputs
- Persisted per-direction exclusions
- Automatic fallback when devices appear or disappear
- Manual overrides that end when the chosen device disconnects
- Optional routing of system alert sounds with the main output
- Debounced Core Audio listener handling to avoid switch loops
- Local in-memory activity timeline
- A Start at login switch in the menu bar popover, registered through `SMAppService`

Device rules use Core Audio UIDs, so renaming a device does not create a second rule. AirPlay devices are also matched by their exact display name within each direction, so changing UIDs does not fill the list with duplicates. Existing AirPlay duplicates collapse into their highest-priority entry, keeping “Never use” enabled if any duplicate was excluded. Older rules with a generic transport label are repaired when their UID identifies AirPlay (including screen-mirroring sessions) or their name matches a known AirPlay receiver; live devices with another known transport stay separate. AirPlay receivers with the same name share one rule; give them distinct names to manage them separately.
