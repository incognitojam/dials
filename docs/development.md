# Development

## Requirements

- macOS 14 or later
- Xcode 16 or later, including the macOS SDK and command-line tools

## Build and run

Run every test:

```sh
swift test
```

Build one app:

```sh
./scripts/build-app.sh nitMac
open build/nitMac.app
```

Install one app:

```sh
./scripts/build-app.sh --install nitMac
```

`--install` copies the built bundle to `~/Applications`, quitting a running copy first and relaunching it if it was running. A bundle left in `build/` works when opened by path but is invisible to Raycast, to Spotlight's application list and to the Open dialog, all of which only look in the Applications folders. Set `INSTALL_DIR` to install somewhere else.

Both apps appear in the menu bar rather than the Dock.

Shared code belongs in `Sources/DialsKit`; app-specific code stays in its own target.

## Start at login

Each app has a Start at login switch that registers it with `SMAppService`. macOS records the bundle's path, so an app that is moved after being switched on leaves a stale entry behind and stops starting. Install an app to where it will live, then turn the switch on there. Rebuilding in place is fine, because the bundle path and the signing identity both stay the same, and so is `--install` over an existing installed copy.

That makes the installed copy the one to switch on, not the one in `build/`. Switching it on in a `build/` copy registers a path inside the repository, which a `git clean` or a deleted worktree then strands.

## Signing

macOS ties permission grants to an app's signing identity, and an ad-hoc signature changes on every build, so a permission is dropped each time it is rebuilt. `build-app.sh` signs with a certificate named `<app> Local` when one exists and falls back to ad-hoc otherwise. To create one:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj "/CN=nitMac Local" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout /tmp/local.key -out /tmp/local.crt
openssl pkcs12 -export -legacy -macalg sha1 \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
  -inkey /tmp/local.key -in /tmp/local.crt \
  -name "nitMac Local" -out /tmp/local.p12 -passout pass:local
security import /tmp/local.p12 -k ~/Library/Keychains/login.keychain-db -P local -A
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db /tmp/local.crt
rm /tmp/local.key /tmp/local.p12 /tmp/local.crt
```

The `-legacy` flags matter: OpenSSL 3 writes a PKCS12 that the macOS keychain refuses to read without them. The `basicConstraints` and `keyUsage` extensions matter too: without them `openssl req -x509` writes a `CA:TRUE` certificate with no key usage, which `security find-identity -p codesigning` rejects as `Invalid Key Usage for policy`. Any other identity works via `SIGN_IDENTITY="..." ./scripts/build-app.sh <app>`.

Changing an app's identity changes its signature, so it has to be removed from the relevant Privacy list and re-added once after the switch.
