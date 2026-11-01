#import <TargetConditionals.h>
#if TARGET_OS_OSX
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "LooperCore.h"
NS_ASSUME_NONNULL_BEGIN
// AUHAL remains the verified Mac hardware adapter; AVAudioEngine renders the shared graph.
@interface MLMacAudioDriver : NSObject
- (nullable instancetype)initWithEngine:(AVAudioEngine *)engine inputFormat:(AVAudioFormat *)inputFormat outputFormat:(AVAudioFormat *)outputFormat error:(NSError **)error;
- (BOOL)startWithCore:(TLCore *)core device:(AudioDeviceID)device rate:(double)rate inputs:(UInt32)inputs outputs:(UInt32)outputs inputLeft:(UInt32)il inputRight:(UInt32)ir outputLeft:(UInt32)ol outputRight:(UInt32)or error:(NSError **)error;
- (void)stop;
@property(nonatomic, readonly) OSStatus renderError;
@end
NS_ASSUME_NONNULL_END
#endif
