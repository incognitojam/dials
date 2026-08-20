# neqMac

neqMac is an early native macOS audio device guardian. It keeps the system on the highest-priority connected input and output devices, and can reject devices that should never become a system default.

This proof of concept deliberately contains no equalizer yet. Its job is to validate reliable device discovery and switching before an audio-processing pipeline is added.

## Requirements

- macOS 14 or later
- Xcode 16 or later, including the macOS SDK and command-line tools

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

Device rules use Core Audio UIDs rather than display names, so renaming a device does not create a second rule.
