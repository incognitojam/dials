#include "EqualizerIO.h"
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_BOOL_LOCK_FREE == 2, "IO needs lock-free counters");
struct EQMeter { atomic_ullong cycles, overloads; atomic_bool nonfinite, layoutMismatch, unverified; };
EQMeter *EQMeterCreate(void) { return calloc(1, sizeof(EQMeter)); }
void EQMeterFree(EQMeter *meter) { free(meter); }
uint64_t EQHeartbeat(EQMeter *meter) { return atomic_load_explicit(&meter->cycles, memory_order_relaxed); }
bool EQTakeNonfinite(EQMeter *meter) { return atomic_exchange_explicit(&meter->nonfinite, false, memory_order_relaxed); }
void EQPermitRender(EQMeter *meter, bool permitted) { atomic_store(&meter->unverified, !permitted); }
bool EQLayoutMismatch(EQMeter *meter) { return atomic_load_explicit(&meter->layoutMismatch, memory_order_relaxed); }
static void EQDidRender(EQMeter *meter, bool healthy) {
    atomic_fetch_add_explicit(&meter->cycles, 1, memory_order_relaxed);
    if (!healthy) atomic_store_explicit(&meter->nonfinite, true, memory_order_relaxed);
}

static uint32_t frames(const AudioBuffer *b) {
    return b->mNumberChannels && b->mData ? b->mDataByteSize / sizeof(float) / b->mNumberChannels : 0;
}

OSStatus EQHALStreamUsage(bool write, AudioObjectID device, UInt32 *bytes, AudioHardwareIOProcStreamUsage *usage) {
    AudioObjectPropertyAddress key = { kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput,
                                       kAudioObjectPropertyElementMain };
    if (write) return AudioObjectSetPropertyData(device, &key, 0, NULL, *bytes, usage);
    return AudioObjectGetPropertyData(device, &key, 0, NULL, bytes, usage);
}

OSStatus EQTapStreamUsage(AudioObjectID device, AudioDeviceIOProcID io, UInt32 count, UInt32 tap, bool install, EQUsageAccess access) {
    size_t size = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + (size_t)count * sizeof(UInt32);
    if (tap >= count || size > UINT32_MAX) return kAudioHardwareIllegalOperationError;
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = io;
    usage->mNumberStreams = count;
    usage->mStreamIsOn[tap] = 1;
    UInt32 bytes = (UInt32)size;
    OSStatus status = install ? access(true, device, &bytes, usage) : noErr;
    if (status == noErr) {
        memset(usage, 0, size);
        usage->mIOProc = io;
        usage->mNumberStreams = count;
        status = access(false, device, &bytes, usage);
        if (status == noErr && (bytes != size || usage->mNumberStreams != count))
            status = kAudioHardwareBadPropertySizeError;
        for (UInt32 i = 0; status == noErr && i < count; ++i)
            if ((usage->mStreamIsOn[i] != 0) != (i == tap)) status = kAudioHardwareIllegalOperationError;
    }
    free(usage);
    return status;
}

static bool verifiedInput(const AudioBufferList *input, EQInputLayout layout, uint32_t channels) {
    if (input->mNumberBuffers != layout.totalBuffers || layout.firstBuffer >= layout.totalBuffers ||
        layout.bufferCount > layout.totalBuffers - layout.firstBuffer ||
        (uint64_t)layout.bufferCount * layout.channelsPerBuffer != channels) return false;
    for (uint32_t i = 0; i < input->mNumberBuffers; ++i) {
        const AudioBuffer *b = &input->mBuffers[i];
        if (i >= layout.firstBuffer && i - layout.firstBuffer < layout.bufferCount) {
            if (!b->mData || b->mNumberChannels != layout.channelsPerBuffer) return false;
        } else if (b->mData) return false; // A disabled physical stream must have a null pointer.
    }
    return true;
}

void EQRender(EQMeter *meter, const AudioBufferList *input, AudioBufferList *output, EQInputLayout layout,
              uint32_t channels, float *scratch, uint32_t capacity, void *processor, EQProcess process) {
    if (atomic_load(&meter->unverified) || !verifiedInput(input, layout, channels)) {
        for (uint32_t i = 0; i < output->mNumberBuffers; ++i) {
            AudioBuffer *b = &output->mBuffers[i];
            if (b->mData) memset(b->mData, 0, b->mDataByteSize);
        }
        atomic_store_explicit(&meter->layoutMismatch, true, memory_order_relaxed);
        return;
    }
    uint32_t length = 0;
    for (uint32_t i = 0; i < output->mNumberBuffers; ++i) {
        uint32_t count = frames(&output->mBuffers[i]);
        if (count > length) length = count;
    }
    bool healthy = true;
    for (uint32_t start = 0; start < length; ) {
        uint32_t count = length - start < capacity ? length - start : capacity;
        memset(scratch, 0, count * (size_t)channels * sizeof(float));
        uint32_t channel = 0;
        for (uint32_t i = layout.firstBuffer; i < layout.firstBuffer + layout.bufferCount; ++i) {
            const AudioBuffer *b = &input->mBuffers[i];
            uint32_t end = frames(b);
            for (uint32_t j = 0; j < b->mNumberChannels && channel < channels; ++j, ++channel) {
                for (uint32_t f = 0; f < count && start + f < end; ++f)
                    scratch[f * channels + channel] = ((float *)b->mData)[(start + f) * b->mNumberChannels + j];
            }
        }
        if (!process(processor, scratch, count)) healthy = false;
        channel = 0;
        for (uint32_t i = 0; i < output->mNumberBuffers; ++i) {
            AudioBuffer *b = &output->mBuffers[i];
            uint32_t end = frames(b);
            for (uint32_t j = 0; j < b->mNumberChannels; ++j, ++channel) {
                for (uint32_t f = 0; f < count && start + f < end; ++f)
                    ((float *)b->mData)[(start + f) * b->mNumberChannels + j] =
                        channel < channels ? __builtin_fminf(1, __builtin_fmaxf(-1, scratch[f * channels + channel])) : 0;
            }
        }
        start += count;
    }
    atomic_store_explicit(&meter->layoutMismatch, false, memory_order_relaxed);
    EQDidRender(meter, healthy);
}

static OSStatus overload(AudioObjectID object, UInt32 count, const AudioObjectPropertyAddress *keys, void *context) {
    EQMeter *meter = context;
    atomic_fetch_add_explicit(&meter->overloads, 1, memory_order_relaxed);
    return noErr;
}

OSStatus EQObserveOverloads(AudioObjectID device, EQMeter *meter, bool observe) {
    AudioObjectPropertyAddress key = { kAudioDeviceProcessorOverload, kAudioObjectPropertyScopeGlobal,
                                       kAudioObjectPropertyElementMain };
    return observe ? AudioObjectAddPropertyListener(device, &key, overload, meter)
                   : AudioObjectRemovePropertyListener(device, &key, overload, meter);
}

uint64_t EQTakeOverloads(EQMeter *meter) {
    return atomic_exchange_explicit(&meter->overloads, 0, memory_order_relaxed);
}
