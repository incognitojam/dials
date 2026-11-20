#pragma once

#include <stdint.h>
#ifdef __APPLE__
#include <CoreAudio/CoreAudio.h>
typedef AudioBuffer EQRingBuffer;
#else
typedef struct {
    uint32_t mNumberChannels, mDataByteSize;
    void *mData;
} EQRingBuffer;
#endif

typedef struct EQRing EQRing;
enum { EQRingCapacityFrames = 16384 };

// Create off the IO thread with a nonzero power-of-two capacity and a fixed channel
// count. Free after both endpoints stop. All counts and return values are frames.
EQRing *EQRingCreate(uint32_t capacity, uint32_t channels);
void EQRingFree(EQRing *ring);

// Single producer. Concatenate buffer channels in order into interleaved Float32.
// Invalid or short buffers reject the whole request. Otherwise write what fits,
// discarding the newest excess frames. Zero-length operations do nothing.
uint32_t EQRingWriteBuffers(EQRing *ring, const EQRingBuffer *buffers, uint32_t count, uint32_t frames);
#ifdef __APPLE__
static inline uint32_t EQRingWrite(EQRing *ring, const AudioBufferList *list, uint32_t frames) {
    if (!list) return 0;
    return EQRingWriteBuffers(ring, list->mBuffers, list->mNumberBuffers, frames);
}
#endif

// Single consumer. Read available frames, leaving the destination tail untouched.
// Fill is the consumer's snapshot. Skip discards at most the current fill.
uint32_t EQRingRead(EQRing *ring, float *interleaved, uint32_t frames);
uint64_t EQRingFill(const EQRing *ring);
void EQRingSkip(EQRing *ring, uint64_t frames);

// Lifetime totals of missing read frames and dropped write frames respectively.
// Invalid input and explicit skips do not count. Safe to sample from another thread.
uint64_t EQRingUnderruns(const EQRing *ring);
uint64_t EQRingOverruns(const EQRing *ring);
