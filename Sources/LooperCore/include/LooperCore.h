#ifndef LOOPER_CORE_H
#define LOOPER_CORE_H
#include <stdint.h>
#include <stdbool.h>
#include <AudioToolbox/AudioToolbox.h>

typedef struct TLCore TLCore;
typedef struct TLHardware TLHardware;
enum { TL_EMPTY = 0, TL_ARMED, TL_RECORDING, TL_PLAYING, TL_STOPPED };
enum { TL_CMD_ARM = 1, TL_CMD_CLEAR, TL_CMD_PLAY_STOP };
typedef struct {
    int state;
    uint32_t length, recorded, position;
    float peak, outputPeak;
    uint64_t cycles;
} TLSnapshot;

// Create/destroy only while no callback can access the core. Single audio-thread owner.
TLCore *tl_create(double sampleRate, uint32_t capacity);
void tl_destroy(TLCore *core);
// UI is the single producer. Commands use a bounded SPSC queue; false means full.
bool tl_command(TLCore *core, int command, uint32_t length);
void tl_set_threshold(TLCore *core, float linear);
void tl_set_volume(TLCore *core, float volume);
TLSnapshot tl_snapshot(TLCore *core);
float tl_waveform(TLCore *core, uint32_t bin);
uint32_t tl_loop_frames(double rate, double bpm, uint32_t bars, uint32_t beats);
// No allocation, locks, UI dispatch, logging, or file access in this function.
// Input is captured only; it is NEVER passed through to output.
void tl_process(TLCore *core, const float *left, const float *right,
                float *outLeft, float *outRight, uint32_t frames);

// One AUHAL duplex device, which can be a private drift-compensated aggregate.
// Channel indices are zero-based physical/aggregate channels.
TLHardware *tl_hardware_create(TLCore *core, AudioDeviceID device, double rate,
                              uint32_t inputChannels, uint32_t outputChannels,
                              uint32_t inputLeft, uint32_t inputRight,
                              uint32_t outputLeft, uint32_t outputRight,
                              OSStatus *error);
OSStatus tl_hardware_start(TLHardware *hardware);
void tl_hardware_destroy(TLHardware *hardware);
OSStatus tl_hardware_error(TLHardware *hardware);
uint64_t tl_hardware_callbacks(TLHardware *hardware);
#endif
