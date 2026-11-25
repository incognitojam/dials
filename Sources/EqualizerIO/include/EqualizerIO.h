#pragma once
#include "EqualizerRing.h"
#ifdef __APPLE__
#include <CoreAudio/CoreAudio.h>
#include <os/lock.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct EQMeter EQMeter;
EQMeter *EQMeterCreate(void);
void EQMeterFree(EQMeter *meter);
uint64_t EQHeartbeat(EQMeter *meter);
bool EQTakeNonfinite(EQMeter *meter);
void EQPermitRender(EQMeter *meter, bool permitted);
bool EQLayoutMismatch(EQMeter *meter);

typedef bool (*EQProcess)(void *processor, float *samples, intptr_t frames);
typedef struct {
    uint32_t firstBuffer, bufferCount, totalBuffers, channelsPerBuffer;
} EQInputLayout;

// Installs (or verifies) the input-only mask for this IO proc.
typedef OSStatus (*EQUsageAccess)(bool write, AudioObjectID device, UInt32 *bytes, AudioHardwareIOProcStreamUsage *usage);
OSStatus EQHALStreamUsage(bool write, AudioObjectID device, UInt32 *bytes, AudioHardwareIOProcStreamUsage *usage);
OSStatus EQTapStreamUsage(AudioObjectID device, AudioDeviceIOProcID io, UInt32 count, UInt32 tap, bool install, EQUsageAccess access);
void EQRender(EQMeter *meter, const AudioBufferList *input, AudioBufferList *output, EQInputLayout layout,
              uint32_t channels, float *scratch, uint32_t capacity, void *processor, EQProcess process);
OSStatus EQObserveOverloads(AudioObjectID device, EQMeter *meter, bool observe);
uint64_t EQTakeOverloads(EQMeter *meter);
#endif
