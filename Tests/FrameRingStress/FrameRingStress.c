#include "FrameRingStress.h"
#include "EqualizerRing.h"
#include <pthread.h>

enum { total = 10000000 };
struct Producer {
    EQRing *ring;
    uint64_t dropped;
};

static void *produce(void *arg) {
    struct Producer *producer = arg;
    float samples[256 * 2];
    uint32_t next = 0, seed = 107;
    while (next < total) {
        seed = seed * 1664525 + 1013904223;
        uint32_t count = 1 + (seed >> 24);
        if (count > total - next) count = total - next;
        for (uint32_t i = 0; i < count; ++i) {
            samples[i * 2] = (float)(next + i);
            samples[i * 2 + 1] = -samples[i * 2];
        }
        EQRingBuffer buffer = {2, (uint32_t)(count * 2 * sizeof(float)), samples};
        uint32_t accepted = EQRingWriteBuffers(producer->ring, &buffer, 1, count);
        producer->dropped += count - accepted;
        next += accepted;
    }
    return NULL;
}

int EQTestConcurrentRing(void) {
    struct Producer producer = {EQRingCreate(256, 2), 0};
    if (!producer.ring) return 1;
    pthread_t thread;
    if (pthread_create(&thread, NULL, produce, &producer)) { EQRingFree(producer.ring); return 1; }
    uint32_t next = 0, seed = 83;
    float output[193 * 2];
    uint64_t missing = 0;
    int failed = 0;
    while (next < total) {
        seed = seed * 22695477 + 1;
        uint32_t request = 1 + (seed >> 16) % 193;
        uint32_t count = EQRingRead(producer.ring, output, request);
        for (uint32_t i = 0; i < count; ++i) {
            float expected = (float)(next + i);
            if (output[2*i] != expected || output[2*i+1] != -expected) failed = 1;
        }
        missing += request - count;
        next += count;
    }
    pthread_join(thread, NULL);
    failed |= EQRingUnderruns(producer.ring) != missing ||
              EQRingOverruns(producer.ring) != producer.dropped || EQRingFill(producer.ring) != 0;
    EQRingFree(producer.ring);
    return failed;
}

#ifdef EQ_STANDALONE_TEST
int main(void) { return EQTestConcurrentRing(); }
#endif
