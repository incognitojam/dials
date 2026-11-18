#pragma once
#include <CoreAudio/CoreAudio.h>
#include <os/lock.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct EQMeter EQMeter;
EQMeter *EQMeterCreate(void);
void EQMeterFree(EQMeter *meter);
uint64_t EQHeartbeat(EQMeter *meter);
bool EQTakeNonfinite(EQMeter *meter);
void EQDidRender(EQMeter *meter, bool healthy);

typedef bool (*EQProcess)(void *processor, float *samples, intptr_t frames);
bool EQRender(const AudioBufferList *input, AudioBufferList *output, uint32_t firstInput,
              uint32_t channels, float *scratch, uint32_t capacity, void *processor, EQProcess process);
