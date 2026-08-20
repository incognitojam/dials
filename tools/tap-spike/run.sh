#!/bin/zsh

# Runs one measurement and waits for it to finish.
#
#   ./run.sh <mode> <output-uid> [microphone-uid] [buffer-frames]
#
# Modes: control (no tap), passthrough, lowpass, silence.
# Device UIDs come from ./build/devices. Everything is addressed by UID, so a run
# never follows the system default onto a device you are wearing.

set -euo pipefail

SCRIPT_DIR=${0:A:h}
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/TapSpike.app"

MODE=${1:-}
OUTPUT_UID=${2:-}
MICROPHONE_UID=${3:-}
BUFFER_FRAMES=${4:-512}

if [[ -z "$MODE" || -z "$OUTPUT_UID" ]]; then
    print -u2 "usage: ${0:t} <mode> <output-uid> [microphone-uid] [buffer-frames]"
    print -u2 "modes: control passthrough lowpass silence"
    exit 1
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
    print -u2 "No app bundle. Run ./build.sh first."
    exit 1
fi

RESULTS_DIR="$BUILD_DIR/results"
mkdir -p "$RESULTS_DIR"
PREFIX="$RESULTS_DIR/$MODE-$BUFFER_FRAMES"
rm -f "$PREFIX"-*(N)

ARGUMENTS=(--role parent --mode "$MODE" --seconds 6 --play yes
           --out-uid "$OUTPUT_UID" --buffer-frames "$BUFFER_FRAMES"
           --noise-level 0.03 --click-level 0.2
           --prefix "$PREFIX" --log "$PREFIX.log")

if [[ -n "$MICROPHONE_UID" ]]; then
    ARGUMENTS+=(--mic-uid "$MICROPHONE_UID")
fi

# `open` rather than running the binary directly: launchd becomes the parent, so
# the bundle is its own responsible process and TCC prompts for it by name.
open -a "$APP_BUNDLE" --args $ARGUMENTS

waited=0
while pgrep -f "TapSpike.app/Contents/MacOS/TapSpike" > /dev/null; do
    sleep 1
    waited=$((waited + 1))
    if (( waited > 60 )); then
        print -u2 "Timed out. An unanswered permission prompt will do this."
        pkill -f "TapSpike.app/Contents/MacOS/TapSpike" || true
        exit 1
    fi
done

cat "$PREFIX.log"
