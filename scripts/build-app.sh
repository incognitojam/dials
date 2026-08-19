#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_BUNDLE="$PROJECT_DIR/build/nitMac.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

# macOS ties the Accessibility grant to the signing identity, and an ad-hoc
# signature changes on every build, so the grant is dropped each time. Signing
# with a stable self-signed certificate keeps it. See the README for how to make
# one; without it this falls back to ad-hoc and the permission has to be granted
# again after every build.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    if security find-identity -v -p codesigning | grep -q "nitMac Local"; then
        SIGN_IDENTITY="nitMac Local"
    else
        SIGN_IDENTITY="-"
    fi
fi

if [[ "$APP_BUNDLE" != "$PROJECT_DIR/build/nitMac.app" ]]; then
    print -u2 "Refusing to replace an unexpected app bundle path."
    exit 1
fi

cd "$PROJECT_DIR"
swift build --configuration release --product nitMac

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
cp ".build/release/nitMac" "$MACOS_DIR/nitMac"
cp "Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
print "$APP_BUNDLE (signed by: $SIGN_IDENTITY)"
