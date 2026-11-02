#import <AudioToolbox/AudioToolbox.h>
NS_ASSUME_NONNULL_BEGIN
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
@end
NS_ASSUME_NONNULL_END
