#!/bin/sh
set -eu
binary="${1:?pass the output binary path}"
if [ "$(uname -s)" = Linux ]; then
    # The Swift toolchain's Linux TSan runtime includes libdispatch interceptors.
    set -- -L/usr/lib/swift/linux -Wl,-rpath,/usr/lib/swift/linux -ldispatch -lBlocksRuntime
else
    set --
fi
clang -std=c11 -fsanitize=thread -O1 -g -pthread -DEQ_STANDALONE_TEST \
    -ISources/EqualizerIO/include -ITests/FrameRingStress/include \
    Sources/EqualizerIO/EqualizerRing.c Tests/FrameRingStress/FrameRingStress.c -o "$binary" "$@"
# The ring copies sample payloads with memcpy. Include interceptor accesses in race checks.
TSAN_OPTIONS="${TSAN_OPTIONS:+$TSAN_OPTIONS:}ignore_interceptors_accesses=0:halt_on_error=1" "$binary"
