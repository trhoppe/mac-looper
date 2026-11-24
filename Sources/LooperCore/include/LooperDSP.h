#ifndef LOOPER_DSP_H
#define LOOPER_DSP_H
#include <stdint.h>
#include <stdbool.h>

typedef struct TLCore TLCore;
typedef struct TLHardware TLHardware;
enum { TL_BUFFER_FRAMES = 32, TL_BUFFER_SIZE_ERROR = -60001 };
enum { TL_EMPTY = 0, TL_ARMED, TL_RECORDING, TL_PLAYING, TL_STOPPED, TL_WAITING };
enum { TL_CMD_ARM = 1, TL_CMD_CLEAR, TL_CMD_PLAY_STOP, TL_CMD_RECORD, TL_CMD_PLAY_SYNC };
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
// Control-thread suspension only AFTER rendering is paused and callbacks have
// stopped. Drains pending commands, preserves completed audio, cancels capture.
void tl_suspend(TLCore *core);
// One control-thread editor, retaining the core's owner throughout. Begin closes
// the render gate; retry until true, then copy/load off the audio thread and end.
// Rendering never waits: this branch emits silence during the short transfer.
bool tl_begin_edit(TLCore *core);
void tl_end_edit(TLCore *core);
double tl_sample_rate(TLCore *core);
bool tl_copy_loop(TLCore *core, float *left, float *right, uint32_t frames);
bool tl_load_loop(TLCore *core, const float *left, const float *right, uint32_t frames);
// No allocation, locks, UI dispatch, logging, or file access in this function.
// Input is captured only; it is NEVER passed through to output.
void tl_process(TLCore *core, const float *left, const float *right,
                float *outLeft, float *outRight, uint32_t frames);
// Offset from this callback's sample time to the drummer's next bar. Negative
// means no drummer is running; waiting playback starts immediately in that case.
void tl_process_timed(TLCore *core, const float *left, const float *right,
                      float *outLeft, float *outRight, uint32_t frames, int64_t downbeatOffset);

#endif
