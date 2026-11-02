#import "MLDrumGainAudioUnit.h"
#include <stdatomic.h>
#include <math.h>
typedef struct {
    _Atomic float target;
    float gain, step;
    UInt32 capacity;
    AudioBufferList *input;
    float *storage, *output;
} MLDrumGainContext;
static void zeroBuffers(AudioBufferList *buffers) {
    for (UInt32 b = 0; b < buffers->mNumberBuffers; b++)
        if (buffers->mBuffers[b].mData) memset(buffers->mBuffers[b].mData, 0, buffers->mBuffers[b].mDataByteSize);
}
@implementation MLDrumGainAudioUnit {
    AUAudioUnitBusArray *_inputs, *_outputs;
    AUAudioUnitBus *_inputBus, *_outputBus;
    MLDrumGainContext *_context;
    AUInternalRenderBlock _block;
}
- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)options error:(NSError **)error {
    if (!(self = [super initWithComponentDescription:d options:options error:error])) return nil;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    _inputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    _outputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    if (!_inputBus || !_outputBus) return nil;
    _inputBus.maximumChannelCount = _outputBus.maximumChannelCount = 2;
    _inputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_inputBus]];
    _outputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_outputBus]];
    self.maximumFramesToRender = 8192;
    _context = calloc(1, sizeof(MLDrumGainContext));
    if (!_context) return nil;
    atomic_init(&_context->target, 0);
    MLDrumGainContext *c = _context;
    _block = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                               AUAudioFrameCount n, NSInteger bus, AudioBufferList *output,
                               const AURenderEvent *events, AURenderPullInputBlock pull) {
        (void)events; (void)bus;
        if (!pull || !c->input) { zeroBuffers(output); return kAudioUnitErr_Uninitialized; }
        if (n > c->capacity || output->mNumberBuffers != 2) { zeroBuffers(output); return kAudioUnitErr_TooManyFramesToProcess; }
        for (UInt32 b = 0; b < 2; b++) {
            c->input->mBuffers[b].mData = c->storage + b * c->capacity;
            c->input->mBuffers[b].mDataByteSize = n * sizeof(float);
        }
        // Always pull: never freeze the AU's host transport at zero gain.
        AUAudioUnitStatus status = pull(flags, time, n, 0, c->input);
        if (status) { zeroBuffers(output); return status; }
        for (UInt32 b = 0; b < 2; b++) {
            if (!output->mBuffers[b].mData) output->mBuffers[b].mData = c->output + b * c->capacity;
            output->mBuffers[b].mDataByteSize = n * sizeof(float);
        }
        const float *left = c->input->mBuffers[0].mData, *right = c->input->mBuffers[1].mData;
        float *ol = output->mBuffers[0].mData, *or = output->mBuffers[1].mData;
        if (!left || !right) { zeroBuffers(output); return kAudioUnitErr_InvalidPropertyValue; }
        float target = atomic_load_explicit(&c->target, memory_order_relaxed);
        BOOL silent = YES;
        for (UInt32 i = 0; i < n; i++) {
            c->gain = c->gain < target ? fminf(target, c->gain + c->step) : fmaxf(target, c->gain - c->step);
            ol[i] = left[i] * c->gain; or[i] = right[i] * c->gain;
            silent &= ol[i] == 0 && or[i] == 0;
        }
        if (silent) *flags |= kAudioUnitRenderAction_OutputIsSilence;
        else *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    };
    return self;
}
- (AUAudioUnitBusArray *)inputBusses { return _inputs; }
- (AUAudioUnitBusArray *)outputBusses { return _outputs; }
- (AUInternalRenderBlock)internalRenderBlock { return _block; }
- (float)volume { return atomic_load(&_context->target); }
- (void)setVolume:(float)value { if (isfinite(value)) atomic_store(&_context->target, fminf(1, fmaxf(0, value))); }
- (BOOL)shouldChangeToFormat:(AVAudioFormat *)format forBus:(AUAudioUnitBus *)bus {
    return format.commonFormat == AVAudioPCMFormatFloat32 && !format.interleaved && format.channelCount == 2 && format.sampleRate >= 8000 && format.sampleRate <= 192000;
}
- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    if (_inputBus.format.sampleRate != _outputBus.format.sampleRate) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nil];
        return NO;
    }
    if (![super allocateRenderResourcesAndReturnError:error]) return NO;
    MLDrumGainContext *c = _context;
    free(c->input); free(c->storage); free(c->output);
    c->capacity = self.maximumFramesToRender; c->gain = 0;
    c->step = 1.0 / (_outputBus.format.sampleRate * 0.003);
    c->input = calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    c->storage = calloc(2 * (size_t)c->capacity, sizeof(float));
    c->output = calloc(2 * (size_t)c->capacity, sizeof(float));
    if (!c->input || !c->storage || !c->output) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:-108 userInfo:nil];
        return NO;
    }
    c->input->mNumberBuffers = 2;
    for (UInt32 b = 0; b < 2; b++) c->input->mBuffers[b] = (AudioBuffer){1, c->capacity * sizeof(float), c->storage + b * c->capacity};
    return YES;
}
- (void)dealloc { if (_context) { free(_context->input); free(_context->storage); free(_context->output); free(_context); } }
@end
