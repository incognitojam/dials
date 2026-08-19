# nitMac

nitMac gives the physical brightness keys control over an external monitor. It does that and nothing else: no colour management, no resolution switching, no virtual displays.

A nit is the unit of display luminance, which is the one thing this app touches.

## Requirements

- macOS 14 or later
- Xcode 16 or later, including the macOS SDK and command-line tools
- An external display macOS reports as adjustable

## Build and run

Run the tests:

```sh
swift test
```

Build an ad-hoc signed menu-bar app:

```sh
./scripts/build-app.sh
open build/nitMac.app
```

nitMac appears in the menu bar rather than the Dock. Brightness keys need Accessibility access; the slider in the menu-bar panel works without it.

macOS ties an Accessibility grant to the app's signing identity, and an ad-hoc signature changes on every build, so the permission is dropped each time it is rebuilt. `build-app.sh` therefore signs with a certificate named `nitMac Local` when one exists, and falls back to ad-hoc when it does not. To create it once:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj "/CN=nitMac Local" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout /tmp/nitmac.key -out /tmp/nitmac.crt
openssl pkcs12 -export -legacy -macalg sha1 \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
  -inkey /tmp/nitmac.key -in /tmp/nitmac.crt \
  -name "nitMac Local" -out /tmp/nitmac.p12 -passout pass:nitmac
security import /tmp/nitmac.p12 -k ~/Library/Keychains/login.keychain-db -P nitmac -A
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db /tmp/nitmac.crt
rm /tmp/nitmac.key /tmp/nitmac.p12 /tmp/nitmac.crt
```

The `-legacy` flags matter: OpenSSL 3 writes a PKCS12 that the macOS keychain refuses to read without them. Any other identity can be used instead with `SIGN_IDENTITY="..." ./scripts/build-app.sh`.

Changing the identity changes the signature, so nitMac has to be removed from the Accessibility list and re-added once after the switch.

## How it reaches the monitor

Through `DisplayServices`, the private framework the system brightness slider itself uses. It addresses a display by `CGDirectDisplayID`, reads back in about 0.1 ms, and a write can be read back immediately, so nitMac keeps no cached brightness: every key press reads what the display is actually at, steps from there, and writes it back. A brightness changed in System Settings or by another app is joined rather than jumped from.

Only displays that answer `DisplayServicesCanChangeBrightness` are offered. A monitor macOS will not drive itself needs raw DDC/CI over the private `IOAVService` symbols, which nitMac deliberately does not carry.

The framework is resolved with `dlsym` at run time. A macOS release that withdraws it leaves nitMac reporting no controllable display rather than failing to launch.

## Current behaviour

- Brightness up and down keys move every controllable display by one of sixteen evenly spread stops
- Shift-option steps by a single percent, matching how macOS fine-tunes its own brightness
- A key press that nitMac cannot act on is passed straight back to macOS, so the built-in display keeps working normally
- Its own HUD replaces the system one, which is swallowed along with the key press
- A slider per display in the menu bar, usable without Accessibility access
- Displays are rediscovered when the screen arrangement changes

## Known limits

- Every controllable display moves together. There is no per-display key binding.
- A monitor macOS declines to drive is not supported. Reaching those means raw DDC/CI, which is a slow, lossy side channel and a maintenance burden nitMac does not take on.
- Other brightness utilities, BetterDisplay among them, watch the same keys and will need their shortcuts turned off.
