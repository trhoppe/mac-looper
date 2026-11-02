#import "MLPluginTransport.h"
#include <stdatomic.h>
#include <math.h>
typedef struct {
    _Atomic double requestedTempo, rate, publishedBeat;
    _Atomic BOOL requestedPlaying;
    _Atomic UInt64 reset, callbacks, musicQueries, transportQueries;
    _Atomic UInt32 frames;
    _Atomic float observedPeak;
    _Atomic double beat, sample, bpm;
    _Atomic BOOL moving, changed;
    UInt64 seenReset;
} MLTransportContext;
static void begin(MLTransportContext *c, UInt32 n) {
    BOOL moving = atomic_load_explicit(&c->requestedPlaying, memory_order_relaxed);
    double bpm = atomic_load_explicit(&c->requestedTempo, memory_order_relaxed);
    UInt64 reset = atomic_load_explicit(&c->reset, memory_order_acquire);
    BOOL discontinuity = reset != c->seenReset || (moving && !c->moving);
    if (discontinuity) { c->beat = 0; c->sample = 0; c->seenReset = reset; }
    if (discontinuity || moving != c->moving || bpm != c->bpm) atomic_store_explicit(&c->changed, YES, memory_order_release);
    c->moving = moving; c->bpm = bpm;
    atomic_store_explicit(&c->frames, n, memory_order_relaxed);
}
static void end(MLTransportContext *c, UInt32 n) {
    if (c->moving) {
        c->sample += n;
        c->beat += (double)n * c->bpm / (60.0 * atomic_load_explicit(&c->rate, memory_order_relaxed));
    }
    atomic_store_explicit(&c->publishedBeat, c->beat, memory_order_relaxed);
    atomic_fetch_add_explicit(&c->callbacks, 1, memory_order_relaxed);
}
@implementation MLPluginTransport {
    MLTransportContext *_context;
    AUAudioUnit *_unit;
    NSInteger _observer;
    BOOL _attached;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _context = calloc(1, sizeof(MLTransportContext));
    if (!_context) return nil;
    atomic_init(&_context->requestedTempo, 120); atomic_init(&_context->rate, 48000);
    atomic_init(&_context->requestedPlaying, NO); atomic_init(&_context->publishedBeat, 0);
    atomic_init(&_context->observedPeak, 0);
    atomic_init(&_context->musicQueries, 0); atomic_init(&_context->transportQueries, 0);
    atomic_init(&_context->reset, 1); atomic_init(&_context->callbacks, 0); atomic_init(&_context->frames, 0);
    atomic_init(&_context->beat, 0); atomic_init(&_context->sample, 0); atomic_init(&_context->bpm, 120);
    atomic_init(&_context->moving, NO); atomic_init(&_context->changed, NO);
    if (!atomic_is_lock_free(&_context->requestedTempo)) { free(_context); _context = NULL; return nil; }
    return self;
}
- (void)configureSampleRate:(double)rate {
    if (isfinite(rate) && rate >= 8000 && rate <= 192000) {
        atomic_store(&_context->rate, rate); atomic_fetch_add_explicit(&_context->reset, 1, memory_order_release);
    }
}
- (double)tempo { return atomic_load(&_context->requestedTempo); }
- (void)setTempo:(double)bpm { if (isfinite(bpm) && bpm >= 30 && bpm <= 240) atomic_store(&_context->requestedTempo, bpm); }
- (BOOL)isPlaying { return atomic_load(&_context->requestedPlaying); }
- (void)setPlaying:(BOOL)value {
    if (value && !atomic_load(&_context->requestedPlaying)) atomic_fetch_add_explicit(&_context->reset, 1, memory_order_release);
    atomic_store_explicit(&_context->requestedPlaying, value, memory_order_release);
}
- (double)beatPosition { return atomic_load(&_context->publishedBeat); }
- (UInt64)renderedCallbacks { return atomic_load(&_context->callbacks); }
- (float)observedPeak { return atomic_load(&_context->observedPeak); }
- (void)resetObservedPeak { atomic_store(&_context->observedPeak, 0); }
- (void)observeAudioBuffers:(const AudioBufferList *)buffers {
    float peak = atomic_load_explicit(&_context->observedPeak, memory_order_relaxed);
    for (UInt32 b = 0; b < buffers->mNumberBuffers; b++) {
        const float *samples = buffers->mBuffers[b].mData;
        if (!samples) continue;
        for (UInt32 n = 0; n < buffers->mBuffers[b].mDataByteSize / sizeof(float); n++) peak = fmaxf(peak, fabsf(samples[n]));
    }
    atomic_store_explicit(&_context->observedPeak, peak, memory_order_relaxed);
}
- (UInt64)musicalQueries { return atomic_load(&_context->musicQueries); }
- (UInt64)transportQueries { return atomic_load(&_context->transportQueries); }
- (UInt32)renderedFrames { return atomic_load(&_context->frames); }
- (void)beginRenderFrames:(UInt32)n { begin(_context, n); }
- (void)endRenderFrames:(UInt32)n { end(_context, n); }
- (void)attachToAudioUnit:(AUAudioUnit *)unit {
    [self detach]; _unit = unit;
    MLTransportContext *c = _context;
    unit.musicalContextBlock = ^BOOL(double *tempo, double *numerator, NSInteger *denominator,
                                    double *beat, NSInteger *nextBeat, double *downbeat) {
        atomic_fetch_add_explicit(&c->musicQueries, 1, memory_order_relaxed);
        if (tempo) *tempo = c->bpm;
        if (numerator) *numerator = 4;
        if (denominator) *denominator = 4;
        if (beat) *beat = c->beat;
        if (downbeat) *downbeat = floor(c->beat / 4.0) * 4.0;
        if (nextBeat) {
            double phase = c->beat - floor(c->beat);
            *nextBeat = phase < 1e-9 ? 0 : (NSInteger)ceil((1.0 - phase) * 60.0 * atomic_load_explicit(&c->rate, memory_order_relaxed) / c->bpm);
        }
        return YES;
    };
    unit.transportStateBlock = ^BOOL(AUHostTransportStateFlags *flags, double *sample, double *start, double *finish) {
        atomic_fetch_add_explicit(&c->transportQueries, 1, memory_order_relaxed);
        if (flags) *flags = (c->moving ? AUHostTransportStateMoving : 0) | (atomic_exchange_explicit(&c->changed, NO, memory_order_acquire) ? AUHostTransportStateChanged : 0);
        if (sample) *sample = c->sample;
        if (start) *start = 0;
        if (finish) *finish = 0;
        return YES;
    };
    _observer = [unit tokenByAddingRenderObserver:^(AudioUnitRenderActionFlags flags, const AudioTimeStamp *time, AUAudioFrameCount frames, NSInteger bus) {
        (void)time;
        if (bus != 0) return;
        if (flags & kAudioUnitRenderAction_PreRender) begin(c, frames);
        if (flags & kAudioUnitRenderAction_PostRender) end(c, frames);
    }];
    _attached = YES;
}
- (void)detach {
    if (_attached) { [_unit removeRenderObserver:_observer]; _unit.musicalContextBlock = nil; _unit.transportStateBlock = nil; }
    _attached = NO; _unit = nil;
}
- (void)dealloc { [self detach]; free(_context); }
@end
