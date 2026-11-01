#import "MLGuitarLoopAudioUnit.h"
#include <stdatomic.h>
#include <math.h>

typedef struct {
    TLCore *core;
    double rate;
    AudioBufferList *input;
    float *storage, *left, *right;
    UInt32 channels, capacity;
    _Atomic UInt32 il, ir, frames;
    _Atomic BOOL strict;
    _Atomic int error;
    _Atomic UInt64 callbacks;
} MLRenderContext;
static void silence(AudioBufferList *list) {
    for (UInt32 i = 0; i < list->mNumberBuffers; i++) if (list->mBuffers[i].mData) memset(list->mBuffers[i].mData, 0, list->mBuffers[i].mDataByteSize);
}

@implementation MLGuitarLoopAudioUnit {
    AUAudioUnitBusArray *_inputs, *_outputs;
    AUAudioUnitBus *_inputBus, *_outputBus;
    AUInternalRenderBlock _block;
    MLRenderContext *_context;
}
- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)options error:(NSError **)error {
    self = [super initWithComponentDescription:d options:options error:error];
    if (!self) return nil;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    _inputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    _outputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    if (!_inputBus || !_outputBus) return nil;
    _inputBus.maximumChannelCount = 128; _outputBus.maximumChannelCount = 2;
    _inputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_inputBus]];
    _outputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_outputBus]];
    self.maximumFramesToRender = 8192;
    _context = calloc(1, sizeof(MLRenderContext));
    if (!_context) return nil;
    atomic_init(&_context->il, 0); atomic_init(&_context->ir, 1); atomic_init(&_context->strict, NO);
    atomic_init(&_context->frames, 0); atomic_init(&_context->error, 0); atomic_init(&_context->callbacks, 0);
    MLRenderContext *c = _context;
    _block = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                              AUAudioFrameCount n, NSInteger bus, AudioBufferList *output,
                              const AURenderEvent *events, AURenderPullInputBlock pull) {
        (void)bus; (void)events;
        atomic_store_explicit(&c->frames, n, memory_order_relaxed);
        if (!c->core || !pull || !c->input) { silence(output); return kAudioUnitErr_Uninitialized; }
        if (n > c->capacity || (atomic_load_explicit(&c->strict, memory_order_relaxed) && n != 32)) {
            atomic_store_explicit(&c->error, n > c->capacity ? kAudioUnitErr_TooManyFramesToProcess : -60001, memory_order_relaxed);
            silence(output); return noErr;
        }
        for (UInt32 i = 0; i < c->channels; i++) {
            c->input->mBuffers[i].mData = c->storage + i * c->capacity;
            c->input->mBuffers[i].mDataByteSize = n * sizeof(float);
        }
        AUAudioUnitStatus status = pull(flags, time, n, 0, c->input);
        if (status) { atomic_store_explicit(&c->error, status, memory_order_relaxed); silence(output); return status; }
        if (output->mNumberBuffers != 2) { silence(output); return kAudioUnitErr_FormatNotSupported; }
        UInt32 il = atomic_load_explicit(&c->il, memory_order_relaxed), ir = atomic_load_explicit(&c->ir, memory_order_relaxed);
        if (il >= c->channels || ir >= c->channels) { silence(output); return kAudio_ParamError; }
        if (!output->mBuffers[0].mData) output->mBuffers[0].mData = c->left;
        if (!output->mBuffers[1].mData) output->mBuffers[1].mData = c->right;
        output->mBuffers[0].mDataByteSize = output->mBuffers[1].mDataByteSize = n * sizeof(float);
        tl_process(c->core, c->input->mBuffers[il].mData, c->input->mBuffers[ir].mData,
                   output->mBuffers[0].mData, output->mBuffers[1].mData, n);
        // The output is loop playback, never live input. Do not propagate an input-silent flag.
        *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        atomic_fetch_add_explicit(&c->callbacks, 1, memory_order_relaxed);
        return noErr;
    };
    return self;
}
- (AUAudioUnitBusArray *)inputBusses { return _inputs; }
- (AUAudioUnitBusArray *)outputBusses { return _outputs; }
- (AUInternalRenderBlock)internalRenderBlock { return _block; }
- (BOOL)shouldChangeToFormat:(AVAudioFormat *)format forBus:(AUAudioUnitBus *)bus {
    return format.commonFormat == AVAudioPCMFormatFloat32 && !format.interleaved && format.sampleRate >= 8000 && format.sampleRate <= 192000 &&
        (bus == _inputBus ? format.channelCount >= 1 && format.channelCount <= 128 : format.channelCount == 2);
}
- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    double rate = _outputBus.format.sampleRate;
    if (fabs(rate - _inputBus.format.sampleRate) > 0.1) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nil];
        return NO;
    }
    if (![super allocateRenderResourcesAndReturnError:error]) return NO;
    MLRenderContext *c = _context;
    // Graph branch reconnection can reallocate render resources. Preserve a captured loop
    // if the hardware sample rate is unchanged; true route changes create a new unit.
    if (!c->core || c->rate != rate) {
        tl_destroy(c->core); c->core = tl_create(rate, (uint32_t)ceil(rate * 64) + 4); c->rate = rate;
    }
    free(c->input); free(c->storage); free(c->left); free(c->right);
    c->channels = _inputBus.format.channelCount; c->capacity = self.maximumFramesToRender;
    c->input = calloc(1, sizeof(AudioBufferList) + (c->channels - 1) * sizeof(AudioBuffer));
    c->storage = calloc((size_t)c->channels * c->capacity, sizeof(float));
    c->left = calloc(c->capacity, sizeof(float)); c->right = calloc(c->capacity, sizeof(float));
    if (!c->core || !c->input || !c->storage || !c->left || !c->right) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:-108 userInfo:nil];
        return NO;
    }
    c->input->mNumberBuffers = c->channels;
    for (UInt32 i = 0; i < c->channels; i++) c->input->mBuffers[i] = (AudioBuffer){1, c->capacity * sizeof(float), c->storage + i * c->capacity};
    volatile float *pages[] = {c->storage, c->left, c->right};
    size_t sizes[] = {(size_t)c->channels * c->capacity, c->capacity, c->capacity};
    for (int i = 0; i < 3; i++) for (size_t n = 0; n < sizes[i]; n += 1024) pages[i][n] = 0;
    atomic_store(&c->error, 0);
    return YES;
}
- (void)deallocateRenderResources { [super deallocateRenderResources]; }
- (TLCore *)core { return _context->core; }
- (UInt32)inputLeft { return atomic_load(&_context->il); }
- (void)setInputLeft:(UInt32)v { atomic_store(&_context->il, v); }
- (UInt32)inputRight { return atomic_load(&_context->ir); }
- (void)setInputRight:(UInt32)v { atomic_store(&_context->ir, v); }
- (BOOL)require32Frames { return atomic_load(&_context->strict); }
- (void)setRequire32Frames:(BOOL)v { atomic_store(&_context->strict, v); }
- (OSStatus)renderError { return atomic_load(&_context->error); }
- (UInt64)callbackCount { return atomic_load(&_context->callbacks); }
- (UInt32)callbackFrames { return atomic_load(&_context->frames); }
- (void)dealloc {
    if (_context) { tl_destroy(_context->core); free(_context->input); free(_context->storage); free(_context->left); free(_context->right); free(_context); }
}
@end

@implementation MLAudioGraphTools
+ (BOOL)start:(AVAudioEngine *)engine error:(NSError **)error {
    @try { return [engine startAndReturnError:error]; }
    @catch (NSException *e) {
        if (error) *error = [NSError errorWithDomain:@"MacLooper.AudioGraph" code:-60003 userInfo:@{NSLocalizedDescriptionKey:e.reason ?: @"Audio graph could not start."}];
        return NO;
    }
}
+ (BOOL)connect:(AVAudioEngine *)engine source:(AVAudioNode *)source sourceBus:(AVAudioNodeBus)sourceBus destination:(AVAudioNode *)destination destinationBus:(AVAudioNodeBus)destinationBus format:(AVAudioFormat *)format error:(NSError **)error {
    @try { [engine connect:source to:destination fromBus:sourceBus toBus:destinationBus format:format]; return YES; }
    @catch (NSException *e) {
        if (error) *error = [NSError errorWithDomain:@"MacLooper.AudioGraph" code:-60003 userInfo:@{NSLocalizedDescriptionKey:e.reason ?: @"Audio graph connection failed."}];
        return NO;
    }
}
+ (BOOL)prepare:(AVAudioEngine *)engine error:(NSError **)error {
    @try { [engine prepare]; return YES; }
    @catch (NSException *e) {
        if (error) *error = [NSError errorWithDomain:@"MacLooper.AudioGraph" code:-60003 userInfo:@{NSLocalizedDescriptionKey:e.reason ?: @"Audio graph preparation failed."}];
        return NO;
    }
}
@end
