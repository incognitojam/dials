#include "EqualizerIO.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_BOOL_LOCK_FREE == 2, "IO needs lock-free counters");
struct EQMeter { atomic_ullong cycles; atomic_bool nonfinite; };
EQMeter *EQMeterCreate(void) { return calloc(1, sizeof(EQMeter)); }
void EQMeterFree(EQMeter *meter) { free(meter); }
uint64_t EQHeartbeat(EQMeter *meter) { return atomic_load_explicit(&meter->cycles, memory_order_relaxed); }
bool EQTakeNonfinite(EQMeter *meter) { return atomic_exchange_explicit(&meter->nonfinite, false, memory_order_relaxed); }
void EQDidRender(EQMeter *meter, bool healthy) {
    atomic_fetch_add_explicit(&meter->cycles, 1, memory_order_relaxed);
    if (!healthy) atomic_store_explicit(&meter->nonfinite, true, memory_order_relaxed);
}

static uint32_t frames(const AudioBuffer *b) {
    return b->mNumberChannels && b->mData ? b->mDataByteSize / sizeof(float) / b->mNumberChannels : 0;
}

bool EQRender(const AudioBufferList *input, AudioBufferList *output, uint32_t firstInput,
              uint32_t channels, float *scratch, uint32_t capacity, void *processor, EQProcess process) {
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
        for (uint32_t i = firstInput; i < input->mNumberBuffers && channel < channels; ++i) {
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
                        channel < channels ? scratch[f * channels + channel] : 0;
            }
        }
        start += count;
    }
    return healthy;
}
