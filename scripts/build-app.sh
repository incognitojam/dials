#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_BUNDLE="$PROJECT_DIR/build/neqMac.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

if [[ "$APP_BUNDLE" != "$PROJECT_DIR/build/neqMac.app" ]]; then
    print -u2 "Refusing to replace an unexpected app bundle path."
    exit 1
fi

cd "$PROJECT_DIR"
swift build --configuration release --product neqMac

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
cp ".build/release/neqMac" "$MACOS_DIR/neqMac"
cp "Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

codesign --force --sign - "$APP_BUNDLE"
print "$APP_BUNDLE"
