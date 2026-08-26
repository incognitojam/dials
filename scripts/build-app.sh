#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}

INSTALL=0
if [[ "${1:-}" == "--install" ]]; then
    INSTALL=1
    shift
fi

APP=${1:-}
if [[ -z "$APP" ]]; then
    print -u2 "usage: ${0:t} [--install] <app>"
    print -u2 "apps: $(ls "$PROJECT_DIR/Resources" | tr '\n' ' ')"
    exit 1
fi

if [[ "$APP" == */* || "$APP" == .* ]]; then
    print -u2 "Refusing to build an app name that is a path."
    exit 1
fi

INFO_PLIST="$PROJECT_DIR/Resources/$APP/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
    print -u2 "No Info.plist for '$APP' at $INFO_PLIST"
    exit 1
fi

APP_BUNDLE="$PROJECT_DIR/build/$APP.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

# macOS ties the Accessibility grant to the signing identity, and an ad-hoc
# signature changes on every build, so the grant is dropped each time. Signing
# with a stable self-signed certificate keeps it. See the README for how to make
# one; without it this falls back to ad-hoc and any permission the app has been
# granted has to be granted again after every build.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    if security find-identity -v -p codesigning | grep -q "$APP Local"; then
        SIGN_IDENTITY="$APP Local"
    else
        SIGN_IDENTITY="-"
    fi
fi

cd "$PROJECT_DIR"
swift build --configuration release --product "$APP"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
cp ".build/release/$APP" "$MACOS_DIR/$APP"
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"

codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
print "$APP_BUNDLE (signed by: $SIGN_IDENTITY)"

if (( ! INSTALL )); then
    exit 0
fi

INSTALL_DIR=${INSTALL_DIR:-$HOME/Applications}
DEST="$INSTALL_DIR/$APP.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST")

WAS_RUNNING=0
if pgrep -qf "$DEST/Contents/MacOS/$APP"; then
    WAS_RUNNING=1
fi
osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true

mkdir -p "$INSTALL_DIR"
rm -rf "$DEST"
ditto "$APP_BUNDLE" "$DEST"
codesign --verify --strict "$DEST"

print "$DEST"

if (( WAS_RUNNING )); then
    open "$DEST"
    print "Relaunched."
fi
