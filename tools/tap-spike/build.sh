#!/bin/zsh

# Builds the tap rig as a signed app bundle. It has to be a bundle, and it has to
# be launched so that it is its own responsible process, or TCC attributes the tap
# request to whatever started it and refuses to prompt. See docs/audio-taps.md.

set -euo pipefail

SCRIPT_DIR=${0:A:h}
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/TapSpike.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"

# The two TCC grants ride on the bundle identifier and the signing identity, so the
# identifier is kept stable and an ad-hoc signature would drop both on every rebuild.
# Reuse neqMac's local certificate when it exists.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    if security find-identity -v -p codesigning | grep -q "neqMac Local"; then
        SIGN_IDENTITY="neqMac Local"
    else
        SIGN_IDENTITY="-"
    fi
fi

mkdir -p "$CONTENTS_DIR/MacOS"

swiftc -O -o "$CONTENTS_DIR/MacOS/TapSpike" "$SCRIPT_DIR/spike.swift"
swiftc -O -o "$BUILD_DIR/devices" "$SCRIPT_DIR/devices.swift"
swiftc -O -o "$BUILD_DIR/aggregate-check" "$SCRIPT_DIR/aggregate-check.swift"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>TapSpike</string>
    <key>CFBundleIdentifier</key><string>dev.neqmac.spike</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>TapSpike</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>TapSpike measures the audio path neqMac will equalise.</string>
    <key>NSAudioCaptureUsageDescription</key><string>TapSpike captures system audio to measure what an equaliser would do to it.</string>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
print "$APP_BUNDLE (signed by: $SIGN_IDENTITY)"
