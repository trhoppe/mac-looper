#import <AudioToolbox/AudioToolbox.h>
NS_ASSUME_NONNULL_BEGIN
int64_t MLFramesUntilDownbeat(void * _Nullable context, double sampleTime);
// Configure/attach/detach while the audio graph is stopped. Render callbacks use
// preallocated C state and lock-free controls; they never call into Swift/UI.
@interface MLPluginTransport : NSObject
@property(nonatomic) double tempo;
@property(nonatomic, getter=isPlaying) BOOL playing;
@property(nonatomic, readonly) double beatPosition;
@property(nonatomic, readonly) UInt64 renderedCallbacks;
@property(nonatomic, readonly) UInt32 renderedFrames;
@property(nonatomic, readonly) UInt64 musicalQueries;
@property(nonatomic, readonly) UInt64 transportQueries;
@property(nonatomic, readonly) float observedPeak;
- (void)observeAudioBuffers:(const AudioBufferList *)buffers;
- (void)resetObservedPeak;
- (void)configureSampleRate:(double)sampleRate;
- (void)attachToAudioUnit:(AUAudioUnit *)unit;
- (void)detach;
- (void)beginRenderFrames:(UInt32)frames;
- (void)endRenderFrames:(UInt32)frames;
// Render-thread query in the engine sample-time domain, independent of which
// mixer branch is pulled first. -1 means stopped.
- (void *)renderContext;
- (int64_t)framesUntilDownbeatAtSampleTime:(double)sampleTime;
- (void)beginRenderFrames:(UInt32)frames atSampleTime:(double)sampleTime;
@end
NS_ASSUME_NONNULL_END
