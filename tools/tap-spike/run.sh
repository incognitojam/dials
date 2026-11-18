#!/bin/zsh

# Runs one measurement and waits for it to finish.
#
#   ./run.sh [--level <dBFS>] <mode> <output-uid> [microphone-uid] [buffer-frames]
#
# Modes: control (no tap), passthrough, lowpass, silence.
# Device UIDs come from ./build/devices. A run never falls back to the system default,
# so it cannot follow it onto a device you are wearing. --level sets the peak of the
# generated test signal and defaults to -30 dBFS; in passthrough and lowpass the tap
# also re-emits whatever other apps are playing, at their own level.

set -euo pipefail

SCRIPT_DIR=${0:A:h}
SCRIPT_NAME=${0:t}
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/TapSpike.app"

usage() {
    print -u2 -r -- "usage: $SCRIPT_NAME [--level <dBFS>] <mode> <output-uid> [microphone-uid] [buffer-frames]"
    print -u2 -r -- "modes: control passthrough lowpass silence"
    exit 1
}

LEVEL_DBFS=-30
POSITIONAL=()
while (( $# > 0 )); do
    case "$1" in
        --level)
            (( $# >= 2 )) || usage
            LEVEL_DBFS=$2
            shift 2
            ;;
        --*) usage ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

if [[ ! "$LEVEL_DBFS" =~ '^-?[0-9]+(\.[0-9]+)?$' ]] || (( LEVEL_DBFS > 0 )); then
    print -u2 -r -- "--level takes a peak level in dBFS at or below 0, such as -30"
    exit 1
fi
(( ${#POSITIONAL} >= 2 && ${#POSITIONAL} <= 4 )) || usage

MODE=${POSITIONAL[1]}
OUTPUT_UID=${POSITIONAL[2]}
MICROPHONE_UID=${POSITIONAL[3]:-}
BUFFER_FRAMES=${POSITIONAL[4]:-512}

case "$MODE" in
    control|passthrough|lowpass|silence) ;;
    *) print -u2 -r -- "unknown mode: $MODE"; usage ;;
esac
if [[ ! "$BUFFER_FRAMES" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 -r -- "buffer-frames must be a positive whole number"
    exit 1
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
    print -u2 "No app bundle. Run ./build.sh first."
    exit 1
fi

OUTPUT_NAME=$("$BUILD_DIR/devices" --require-output "$OUTPUT_UID") || exit 1
if [[ -n "$MICROPHONE_UID" ]]; then
    "$BUILD_DIR/devices" --require-input "$MICROPHONE_UID" > /dev/null || exit 1
fi

RESULTS_DIR="$BUILD_DIR/results"
mkdir -p "$RESULTS_DIR"
PREFIX="$RESULTS_DIR/$MODE-$BUFFER_FRAMES-$(date +%Y%m%d-%H%M%S)-$$"
PID_FILE="$PREFIX.pid"
APP_PID=""

stop_app() {
    if [[ -z "$APP_PID" && -s "$PID_FILE" ]]; then
        APP_PID=$(<"$PID_FILE")
    fi
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2> /dev/null; then
        kill -TERM "$APP_PID" 2> /dev/null || true
        for _ in {1..50}; do
            kill -0 "$APP_PID" 2> /dev/null || return 0
            sleep 0.1
        done
        kill -KILL "$APP_PID" 2> /dev/null || true
    fi
}
trap 'stop_app; exit 130' INT TERM HUP

ARGUMENTS=(--role parent --mode "$MODE" --seconds 6 --play yes
           --out-uid "$OUTPUT_UID" --buffer-frames "$BUFFER_FRAMES"
           --level-dbfs "$LEVEL_DBFS"
           --prefix "$PREFIX" --log "$PREFIX.log" --pid-file "$PID_FILE")

if [[ -n "$MICROPHONE_UID" ]]; then
    ARGUMENTS+=(--mic-uid "$MICROPHONE_UID")
fi

print "Playing to $OUTPUT_NAME at $LEVEL_DBFS dBFS peak. Results: $PREFIX"

# `open` rather than running the binary directly: launchd becomes the parent, so
# the bundle is its own responsible process and TCC prompts for it by name.
# -n starts a new instance even if another run is still going.
open -n -a "$APP_BUNDLE" --args $ARGUMENTS

waited=0
while true; do
    if [[ -z "$APP_PID" && -s "$PID_FILE" ]]; then
        APP_PID=$(<"$PID_FILE")
    fi
    if [[ -n "$APP_PID" ]] && ! kill -0 "$APP_PID" 2> /dev/null; then
        break
    fi
    if [[ -z "$APP_PID" && -s "$PREFIX.log" ]] && grep -q '^FAILED' "$PREFIX.log"; then
        break
    fi
    sleep 1
    waited=$((waited + 1))
    if (( waited > 60 )); then
        print -u2 "Timed out. An unanswered permission prompt will do this."
        stop_app
        exit 1
    fi
done
trap - INT TERM HUP

[[ -f "$PREFIX.log" ]] && cat "$PREFIX.log"
if [[ ! -f "$PREFIX.log" ]] || [[ "$(tail -n 1 "$PREFIX.log")" != "COMPLETED" ]]; then
    print -u2 "The run did not complete. See $PREFIX.log"
    exit 1
fi
