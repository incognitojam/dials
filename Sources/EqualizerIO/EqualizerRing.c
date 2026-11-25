#include "EqualizerRing.h"
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(sizeof(unsigned long long) == 8 && ATOMIC_LLONG_LOCK_FREE == 2, "requires lock-free 64-bit counters");
struct EQRing {
    _Alignas(128) atomic_ullong written;
    atomic_ullong overruns;
    _Alignas(128) atomic_ullong read;
    atomic_ullong underruns;
    uint32_t capacity, channels;
    float *samples;
};

EQRing *EQRingCreate(uint32_t capacity, uint32_t channels) {
    if (!capacity || (capacity & (capacity - 1)) || !channels ||
        capacity > SIZE_MAX / sizeof(float) / channels) return NULL;
    EQRing *ring = aligned_alloc(_Alignof(EQRing), sizeof(EQRing));
    if (!ring) return NULL;
    ring->samples = calloc((size_t)capacity * channels, sizeof(float));
    if (!ring->samples) { free(ring); return NULL; }
    ring->capacity = capacity;
    ring->channels = channels;
    atomic_init(&ring->written, 0);
    atomic_init(&ring->read, 0);
    atomic_init(&ring->overruns, 0);
    atomic_init(&ring->underruns, 0);
    return ring;
}

void EQRingFree(EQRing *ring) {
    if (ring) { free(ring->samples); free(ring); }
}

uint64_t EQRingFill(const EQRing *ring) {
    uint64_t read = atomic_load_explicit(&ring->read, memory_order_acquire);
    uint64_t fill = atomic_load_explicit(&ring->written, memory_order_acquire) - read;
    return fill < ring->capacity ? fill : ring->capacity;
}

uint64_t EQRingSkip(EQRing *ring, uint64_t frames) {
    uint64_t fill = EQRingFill(ring);
    uint64_t read = atomic_load_explicit(&ring->read, memory_order_relaxed);
    uint64_t skipped = frames < fill ? frames : fill;
    atomic_store_explicit(&ring->read, read + skipped, memory_order_release);
    return skipped;
}

uint64_t EQRingUnderruns(const EQRing *ring) { return atomic_load_explicit(&ring->underruns, memory_order_relaxed); }
uint64_t EQRingOverruns(const EQRing *ring) { return atomic_load_explicit(&ring->overruns, memory_order_relaxed); }

uint32_t EQRingWriteBuffers(EQRing *ring, const EQRingBuffer *buffers, uint32_t count, uint32_t frames) {
    if (!frames || !buffers || count > ring->channels) return 0;
    uint32_t channels = 0;
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t width = buffers[i].mNumberChannels;
        if (!width || width > ring->channels - channels || !buffers[i].mData ||
            frames > buffers[i].mDataByteSize / sizeof(float) / width) return 0;
        channels += width;
    }
    if (channels != ring->channels) return 0;
    uint64_t written = atomic_load_explicit(&ring->written, memory_order_relaxed);
    uint32_t used = (uint32_t)(written - atomic_load_explicit(&ring->read, memory_order_acquire));
    uint32_t space = ring->capacity - used;
    uint32_t accepted = frames < space ? frames : space;
    uint32_t offset = written & (ring->capacity - 1);
    uint32_t first = ring->capacity - offset;
    if (first > accepted) first = accepted;
    if (count == 1) {
        const float *source = buffers[0].mData;
        size_t split = (size_t)first * channels;
        memcpy(ring->samples + (size_t)offset * channels, source, split * sizeof(float));
        memcpy(ring->samples, source + split, (size_t)(accepted - first) * channels * sizeof(float));
    } else {
        uint32_t channel = 0;
        for (uint32_t i = 0; i < count; ++i) {
            uint32_t width = buffers[i].mNumberChannels;
            const float *source = buffers[i].mData;
            for (uint32_t f = 0; f < accepted; ++f) {
                size_t slot = (offset + f) & (ring->capacity - 1);
                memcpy(ring->samples + slot * channels + channel, source + (size_t)f * width, width * sizeof(float));
            }
            channel += width;
        }
    }
    atomic_store_explicit(&ring->written, written + accepted, memory_order_release);
    if (accepted < frames) atomic_fetch_add_explicit(&ring->overruns, frames - accepted, memory_order_relaxed);
    return accepted;
}

uint32_t EQRingRead(EQRing *ring, float *output, uint32_t frames) {
    if (!frames) return 0;
    uint64_t fill = EQRingFill(ring);
    uint32_t taken = fill < frames ? (uint32_t)fill : frames;
    uint64_t read = atomic_load_explicit(&ring->read, memory_order_relaxed);
    uint32_t offset = read & (ring->capacity - 1);
    uint32_t first = ring->capacity - offset;
    if (first > taken) first = taken;
    size_t split = (size_t)first * ring->channels;
    memcpy(output, ring->samples + (size_t)offset * ring->channels, split * sizeof(float));
    memcpy(output + split, ring->samples, (size_t)(taken - first) * ring->channels * sizeof(float));
    atomic_store_explicit(&ring->read, read + taken, memory_order_release);
    if (taken < frames) {
        memset(output + (size_t)taken * ring->channels, 0, (size_t)(frames - taken) * ring->channels * sizeof(float));
        atomic_fetch_add_explicit(&ring->underruns, frames - taken, memory_order_relaxed);
    }
    return taken;
}
