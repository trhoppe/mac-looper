#include "LooperCore.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <math.h>

#define WAVE_BINS 256
#define COMMANDS 32
typedef struct { int kind; uint32_t length; } TLCommand;
struct TLCore {
    double rate;
    uint32_t capacity, preCount, historyPosition, historyValid;
    float *left, *right, *historyLeft, *historyRight;
    int state;
    uint32_t length, recorded, position;
    uint64_t cycles;
    float gain, volume, lastLeft, lastRight, tailLeft, tailRight;
    uint32_t tailRemaining, rampFrames, edgeFrames;
    TLCommand commands[COMMANDS];
    _Atomic uint32_t commandRead, commandWrite;
    _Atomic float threshold, targetVolume;
    _Atomic int publishedState;
    _Atomic uint32_t publishedLength, publishedRecorded, publishedPosition;
    _Atomic uint64_t publishedCycles;
    _Atomic float peak, outputPeak, waveform[WAVE_BINS];
};
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Realtime atomics must be lock free");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Realtime atomics must be lock free");

uint32_t tl_loop_frames(double rate, double bpm, uint32_t bars, uint32_t beats) {
    if (!isfinite(rate) || !isfinite(bpm) || rate <= 0 || bpm <= 0 || !bars || !beats) return 0;
    double n = rate * (60.0 / bpm) * beats * bars;
    return n >= 1 && n <= UINT32_MAX ? (uint32_t)llround(n) : 0;
}
TLCore *tl_create(double rate, uint32_t capacity) {
    if (!isfinite(rate) || rate < 8000 || rate > 384000 || capacity < 16) return NULL;
    TLCore *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->rate = rate; c->capacity = capacity;
    c->preCount = (uint32_t)llround(rate * .005);
    c->rampFrames = (uint32_t)llround(rate * .003);
    c->edgeFrames = (uint32_t)llround(rate * .002);
    c->left = calloc(capacity, sizeof(float)); c->right = calloc(capacity, sizeof(float));
    c->historyLeft = calloc(c->preCount, sizeof(float));
    c->historyRight = calloc(c->preCount, sizeof(float));
    if (!c->left || !c->right || !c->historyLeft || !c->historyRight) { tl_destroy(c); return NULL; }
    atomic_init(&c->commandRead, 0); atomic_init(&c->commandWrite, 0);
    atomic_init(&c->threshold, .031622777f); atomic_init(&c->targetVolume, .7f);
    atomic_init(&c->publishedState, TL_EMPTY); atomic_init(&c->publishedLength, 0);
    atomic_init(&c->publishedRecorded, 0); atomic_init(&c->publishedPosition, 0);
    atomic_init(&c->publishedCycles, 0); atomic_init(&c->peak, 0); atomic_init(&c->outputPeak, 0);
    for (int b = 0; b < WAVE_BINS; b++) atomic_init(&c->waveform[b], 0);
    // Float atomics must also be lock-free on the runtime architecture.
    if (!atomic_is_lock_free(&c->threshold)) { tl_destroy(c); return NULL; }
    // Fault in loop/history pages on the control thread, before AudioOutputUnitStart.
    volatile float *pages[] = {c->left, c->right, c->historyLeft, c->historyRight};
    uint32_t counts[] = {capacity, capacity, c->preCount, c->preCount};
    for (int b = 0; b < 4; b++) {
        for (uint32_t i = 0; i < counts[b]; i += 1024) pages[b][i] = 0;
        pages[b][counts[b] - 1] = 0;
    }
    c->volume = .7f;
    return c;
}
void tl_destroy(TLCore *c) {
    if (!c) return;
    free(c->left); free(c->right); free(c->historyLeft); free(c->historyRight); free(c);
}
bool tl_command(TLCore *c, int command, uint32_t length) {
    if (!c || command < TL_CMD_ARM || command > TL_CMD_RECORD) return false;
    if ((command == TL_CMD_ARM || command == TL_CMD_RECORD) && (length < 16 || length > c->capacity)) return false;
    uint32_t w = atomic_load_explicit(&c->commandWrite, memory_order_relaxed);
    if (w - atomic_load_explicit(&c->commandRead, memory_order_acquire) >= COMMANDS) return false;
    c->commands[w % COMMANDS] = (TLCommand){command, length};
    atomic_store_explicit(&c->commandWrite, w + 1, memory_order_release);
    return true;
}
void tl_set_threshold(TLCore *c, float v) {
    if (c && isfinite(v)) atomic_store_explicit(&c->threshold, fminf(1, fmaxf(.00001f, v)), memory_order_relaxed);
}
void tl_set_volume(TLCore *c, float v) {
    if (c && isfinite(v)) atomic_store_explicit(&c->targetVolume, fminf(1, fmaxf(0, v)), memory_order_relaxed);
}
TLSnapshot tl_snapshot(TLCore *c) {
    if (!c) return (TLSnapshot){0};
    // Independent atomic telemetry: at worst one render quantum out of sync; never touches audio memory.
    return (TLSnapshot){atomic_load(&c->publishedState), atomic_load(&c->publishedLength),
        atomic_load(&c->publishedRecorded), atomic_load(&c->publishedPosition),
        atomic_load(&c->peak), atomic_load(&c->outputPeak), atomic_load(&c->publishedCycles)};
}
float tl_waveform(TLCore *c, uint32_t bin) {
    return c && bin < WAVE_BINS ? atomic_load_explicit(&c->waveform[bin], memory_order_relaxed) : 0;
}
static void store_sample(TLCore *c, float l, float r) {
    uint32_t i = c->recorded++;
    c->left[i] = l; c->right[i] = r;
    uint32_t b = (uint32_t)((uint64_t)i * WAVE_BINS / c->length);
    float p = fmaxf(fabsf(l), fabsf(r));
    float old = atomic_load_explicit(&c->waveform[b], memory_order_relaxed);
    if (p > old) atomic_store_explicit(&c->waveform[b], p, memory_order_relaxed);
}
static void reset_tail(TLCore *c) {
    c->tailLeft = c->lastLeft; c->tailRight = c->lastRight;
    c->tailRemaining = c->rampFrames;
    c->gain = 0;
}
static void consume_commands(TLCore *c) {
    uint32_t r = atomic_load_explicit(&c->commandRead, memory_order_relaxed);
    uint32_t w = atomic_load_explicit(&c->commandWrite, memory_order_acquire);
    // Bounded: process only commands present at the start of the callback.
    while (r != w) {
        TLCommand cmd = c->commands[r++ % COMMANDS];
        // A stale UI/MIDI Arm must never replace an existing take.
        if (cmd.kind == TL_CMD_ARM && c->state != TL_EMPTY) continue;
        if (cmd.kind == TL_CMD_ARM || cmd.kind == TL_CMD_CLEAR) {
            reset_tail(c);
            c->length = cmd.kind == TL_CMD_ARM ? cmd.length : 0;
            c->recorded = 0; c->position = 0; c->cycles = 0;
            c->state = cmd.kind == TL_CMD_ARM ? TL_ARMED : TL_EMPTY;
            for (int b = 0; b < WAVE_BINS; b++) atomic_store_explicit(&c->waveform[b], 0, memory_order_relaxed);
        } else if (cmd.kind == TL_CMD_RECORD) {
            if (c->state == TL_EMPTY || c->state == TL_ARMED) {
                reset_tail(c);
                c->length = cmd.length;
                c->recorded = c->position = 0; c->cycles = 0;
                c->state = TL_RECORDING; // Capture the next sample, with no threshold or history.
                for (int b = 0; b < WAVE_BINS; b++) atomic_store_explicit(&c->waveform[b], 0, memory_order_relaxed);
            } else if (c->state == TL_RECORDING && c->recorded > 0) {
                // Stretch existing peak bins to the shortened take. Constant bounded work;
                // never rescan seconds of audio or allocate on the render thread.
                float peaks[WAVE_BINS];
                for (int b = 0; b < WAVE_BINS; b++) peaks[b] = atomic_load_explicit(&c->waveform[b], memory_order_relaxed);
                for (int b = 0; b < WAVE_BINS; b++) {
                    uint32_t source = (uint32_t)((uint64_t)b * c->recorded / c->length);
                    atomic_store_explicit(&c->waveform[b], peaks[source], memory_order_relaxed);
                }
                c->length = c->recorded;
                c->position = 0; c->gain = 0; c->state = TL_PLAYING;
            }
            // A second press before even one sample, or after auto-completion, is harmless.
        } else if (cmd.kind == TL_CMD_PLAY_STOP) {
            if (c->state == TL_PLAYING) { reset_tail(c); c->state = TL_STOPPED; c->position = 0; }
            else if (c->state == TL_STOPPED) { c->state = TL_PLAYING; c->position = 0; c->gain = 0; }
            else if (c->state == TL_ARMED || c->state == TL_RECORDING) {
                c->state = TL_EMPTY; c->length = 0; c->recorded = 0; c->position = 0;
                for (int b = 0; b < WAVE_BINS; b++) atomic_store_explicit(&c->waveform[b], 0, memory_order_relaxed);
            }
        }
    }
    atomic_store_explicit(&c->commandRead, r, memory_order_release);
}
void tl_suspend(TLCore *c) {
    if (!c) return;
    consume_commands(c);
    if (c->state == TL_PLAYING || c->state == TL_STOPPED) {
        c->state = TL_STOPPED; c->position = 0;
    } else {
        c->state = TL_EMPTY; c->length = c->recorded = c->position = 0;
        c->cycles = 0;
        for (int b = 0; b < WAVE_BINS; b++) atomic_store(&c->waveform[b], 0);
    }
    c->gain = 0; c->lastLeft = c->lastRight = c->tailLeft = c->tailRight = 0;
    c->tailRemaining = 0; c->historyValid = c->historyPosition = 0;
    atomic_store(&c->publishedState, c->state); atomic_store(&c->publishedLength, c->length);
    atomic_store(&c->publishedRecorded, c->recorded); atomic_store(&c->publishedPosition, c->position);
    atomic_store(&c->publishedCycles, c->cycles); atomic_store(&c->peak, 0); atomic_store(&c->outputPeak, 0);
}
void tl_process(TLCore *c, const float *left, const float *right, float *outL, float *outR, uint32_t frames) {
    if (!c || !outL || !outR) return;
    consume_commands(c);
    const float threshold = atomic_load_explicit(&c->threshold, memory_order_relaxed);
    const float targetVolume = atomic_load_explicit(&c->targetVolume, memory_order_relaxed);
    float peak = 0, outputPeak = 0;
    for (uint32_t i = 0; i < frames; i++) {
        float l = left && isfinite(left[i]) ? left[i] : 0;
        float r = right && isfinite(right[i]) ? right[i] : l;
        peak = fmaxf(peak, fmaxf(fabsf(l), fabsf(r)));
        // Render before capture: the sample after the Nth captured sample plays loop frame 0.
        float ol = 0, or = 0;
        c->volume += (targetVolume - c->volume) * .002f;
        if (c->state == TL_PLAYING) {
            uint32_t p = c->position;
            uint32_t edge = c->edgeFrames < c->length/4 ? c->edgeFrames : c->length/4;
            float envelope = 1;
            // Raised-cosine 2ms boundary fades preserve exactly N frames, with no period shortening.
            if (p < edge) envelope = .5f - .5f * cosf((float)M_PI * p / edge);
            else if (p >= c->length - edge) envelope = .5f - .5f * cosf((float)M_PI * (c->length - 1 - p) / edge);
            c->gain = fminf(1, c->gain + 1.0f / c->rampFrames);
            ol = c->left[p] * envelope * c->gain * c->volume;
            or = c->right[p] * envelope * c->gain * c->volume;
            if (++c->position == c->length) { c->position = 0; c->cycles++; }
        }
        if (c->tailRemaining) {
            float t = (float)c->tailRemaining-- / c->rampFrames;
            ol += c->tailLeft * t; or += c->tailRight * t;
        }
        if (c->state == TL_ARMED && fmaxf(fabsf(l), fabsf(r)) >= threshold) {
            c->state = TL_RECORDING;
            uint32_t n = c->preCount < c->length - 1 ? c->preCount : c->length - 1;
            // Include a fixed 5ms look-behind; pad unavailable startup history with silence.
            for (uint32_t j = 0; j < n; j++) {
                uint32_t back = n - j;
                uint32_t h = (c->historyPosition + c->preCount - back) % c->preCount;
                store_sample(c, back <= c->historyValid ? c->historyLeft[h] : 0,
                             back <= c->historyValid ? c->historyRight[h] : 0);
            }
        }
        if (c->state == TL_RECORDING) {
            store_sample(c, l, r);
            if (c->recorded == c->length) { c->state = TL_PLAYING; c->position = 0; c->gain = 0; }
        }
        c->historyLeft[c->historyPosition] = l; c->historyRight[c->historyPosition] = r;
        c->historyPosition = (c->historyPosition + 1) % c->preCount;
        if (c->historyValid < c->preCount) c->historyValid++;
        // Unity-preserving safety saturation only at full scale. No live input is mixed in.
        outL[i] = fmaxf(-1, fminf(1, ol)); outR[i] = fmaxf(-1, fminf(1, or));
        c->lastLeft = outL[i]; c->lastRight = outR[i];
        outputPeak = fmaxf(outputPeak, fmaxf(fabsf(outL[i]), fabsf(outR[i])));
    }
    atomic_store(&c->publishedLength, c->length); atomic_store(&c->publishedRecorded, c->recorded);
    atomic_store(&c->publishedPosition, c->position); atomic_store(&c->publishedCycles, c->cycles);
    atomic_store(&c->publishedState, c->state);
    atomic_store_explicit(&c->peak, peak, memory_order_relaxed);
    atomic_store_explicit(&c->outputPeak, outputPeak, memory_order_relaxed);
}
