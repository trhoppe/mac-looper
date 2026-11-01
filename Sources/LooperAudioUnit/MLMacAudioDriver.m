#import "MLMacAudioDriver.h"
#if TARGET_OS_OSX

typedef struct {
    __unsafe_unretained AVAudioEngineManualRenderingBlock render;
    const AudioBufferList *input;
} MLManualContext;
static OSStatus renderGraph(void *context, const AudioBufferList *input, float *l, float *r, UInt32 frames, const AudioTimeStamp *time) {
    (void)time;
    MLManualContext *c = context;
    c->input = input;
    struct { UInt32 count; AudioBuffer buffers[2]; } output = {2, {{1, frames * sizeof(float), l}, {1, frames * sizeof(float), r}}};
    OSStatus error = 0;
    AVAudioEngineManualRenderingStatus status = c->render(frames, (AudioBufferList *)&output, &error);
    if (status != AVAudioEngineManualRenderingStatusSuccess) {
        memset(l, 0, frames * sizeof(float)); memset(r, 0, frames * sizeof(float));
        return error ? error : -60002;
    }
    return noErr;
}
@implementation MLMacAudioDriver {
    AVAudioEngine *_engine;
    AVAudioEngineManualRenderingBlock _render;
    MLManualContext *_context;
    TLHardware *_hardware;
}
- (instancetype)initWithEngine:(AVAudioEngine *)engine inputFormat:(AVAudioFormat *)input outputFormat:(AVAudioFormat *)output error:(NSError **)error {
    self = [super init]; if (!self) return nil;
    _engine = engine;
    if (![engine enableManualRenderingMode:AVAudioEngineManualRenderingModeRealtime format:output maximumFrameCount:8192 error:error]) return nil;
    _context = calloc(1, sizeof(MLManualContext));
    if (!_context) return nil;
    MLManualContext *c = _context;
    if (![engine.inputNode setManualRenderingInputPCMFormat:input inputBlock:^const AudioBufferList *(AVAudioFrameCount frames) {
        if (!c->input || c->input->mBuffers[0].mDataByteSize < frames * sizeof(float)) return NULL;
        return c->input;
    }]) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nil];
        return nil;
    }
    _render = [engine.manualRenderingBlock copy]; c->render = _render;
    return self;
}
- (BOOL)startWithCore:(TLCore *)core device:(AudioDeviceID)device rate:(double)rate inputs:(UInt32)inputs outputs:(UInt32)outputs inputLeft:(UInt32)il inputRight:(UInt32)ir outputLeft:(UInt32)ol outputRight:(UInt32)or error:(NSError **)error {
    OSStatus status = 0;
    _hardware = tl_hardware_create(core, device, rate, inputs, outputs, il, ir, ol, or, &status);
    if (!_hardware) { if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil]; return NO; }
    tl_hardware_set_graph(_hardware, renderGraph, _context);
    status = tl_hardware_start(_hardware);
    if (status && error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
    return status == noErr;
}
- (OSStatus)renderError { return tl_hardware_error(_hardware); }
- (void)stop { tl_hardware_destroy(_hardware); _hardware = NULL; }
- (void)dealloc { [self stop]; free(_context); }
@end
#endif
