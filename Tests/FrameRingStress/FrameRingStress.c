#include "FrameRingStress.h"
#include "EqualizerRing.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <sched.h>

enum { capacity = 256, total = 10000000 };
struct Producer {
    EQRing *ring;
    uint64_t dropped;
    atomic_bool sawFull;
    uint32_t consumerMark;
    bool skipPublishedMark;
};

static void *produce(void *arg) {
    struct Producer *producer = arg;
    float samples[capacity * 2];
    uint32_t next = 0, seed = 107;
    while (next < total) {
        seed = seed * 1664525 + 1013904223;
        uint32_t count = next == 0 ? capacity : 1 + (seed >> 16) % capacity;
        if (count > total - next) count = total - next;
        for (uint32_t i = 0; i < count; ++i) {
            samples[i * 2] = (float)(next + i);
            samples[i * 2 + 1] = -samples[i * 2];
        }
        EQRingBuffer buffer = {2, (uint32_t)(count * 2 * sizeof(float)), samples};
        uint32_t accepted = EQRingWriteBuffers(producer->ring, &buffer, 1, count);
        if (!accepted) atomic_store_explicit(&producer->sawFull, true, memory_order_relaxed);
        if (next == capacity && accepted) {
            producer->skipPublishedMark = producer->consumerMark == capacity / 2;
        }
        producer->dropped += count - accepted;
        next += accepted;
    }
    return NULL;
}

int EQTestConcurrentRing(void) {
    struct Producer producer = {.ring = EQRingCreate(capacity, 2)};
    if (!producer.ring) return 1;
    uint32_t next = 0, seed = 83;
    float output[193 * 2];
    bool sawEmpty = EQRingRead(producer.ring, output, 1) == 0;
    uint64_t missing = 1;
    int failed = 0;
    pthread_t thread;
    if (pthread_create(&thread, NULL, produce, &producer)) { EQRingFree(producer.ring); return 1; }

    // Isolate Skip's release from Read's next release. The producer checks the
    // consumer's mark after its first write into the space returned by Skip.
    while (!atomic_load_explicit(&producer.sawFull, memory_order_relaxed)) sched_yield();
    producer.consumerMark = (uint32_t)(EQRingFill(producer.ring) / 2);
    next = (uint32_t)EQRingSkip(producer.ring, producer.consumerMark);
    while (EQRingFill(producer.ring) <= capacity - next) sched_yield();
    uint32_t passes = 0, skipped = 0;
    while (next < total) {
        if (++passes % 8 == 0) {
            uint32_t discarded = (uint32_t)EQRingSkip(producer.ring, EQRingFill(producer.ring) / 2);
            next += discarded;
            skipped += discarded;
        }
        seed = seed * 22695477 + 1;
        uint32_t request = 1 + (seed >> 16) % 193;
        uint32_t count = EQRingRead(producer.ring, output, request);
        if (!count) sawEmpty = true;
        for (uint32_t i = 0; i < count; ++i) {
            float expected = (float)(next + i);
            if (output[2*i] != expected || output[2*i+1] != -expected) failed = 1;
        }
        missing += request - count;
        next += count;
    }
    pthread_join(thread, NULL);
    failed |= !producer.skipPublishedMark || !atomic_load_explicit(&producer.sawFull, memory_order_relaxed) || !sawEmpty || !skipped;
    failed |= EQRingUnderruns(producer.ring) != missing ||
              EQRingOverruns(producer.ring) != producer.dropped || EQRingFill(producer.ring) != 0;
    EQRingFree(producer.ring);
    return failed;
}

#ifdef EQ_STANDALONE_TEST
int main(void) { return EQTestConcurrentRing(); }
#endif
