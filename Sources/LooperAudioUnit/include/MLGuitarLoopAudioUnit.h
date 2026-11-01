#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import "LooperDSP.h"

NS_ASSUME_NONNULL_BEGIN
@interface MLGuitarLoopAudioUnit : AUAudioUnit
@property(nonatomic, readonly, nullable) TLCore *core;
@property(nonatomic) UInt32 inputLeft;
@property(nonatomic) UInt32 inputRight;
@property(nonatomic) BOOL require32Frames;
@property(nonatomic, readonly) OSStatus renderError;
@property(nonatomic, readonly) UInt64 callbackCount;
@property(nonatomic, readonly) UInt32 callbackFrames;
@end
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
@interface MLAudioGraphTools : NSObject
+ (BOOL)connect:(AVAudioEngine *)engine source:(AVAudioNode *)source sourceBus:(AVAudioNodeBus)sourceBus destination:(AVAudioNode *)destination destinationBus:(AVAudioNodeBus)destinationBus format:(AVAudioFormat *)format error:(NSError **)error;
+ (BOOL)start:(AVAudioEngine *)engine error:(NSError **)error;
+ (BOOL)prepare:(AVAudioEngine *)engine error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
