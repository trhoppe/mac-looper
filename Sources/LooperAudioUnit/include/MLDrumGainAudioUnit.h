#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
// A gain stage that always pulls its input, even at zero volume. This lets a
// transport-driven instrument observe Stop/Start while its output is muted.
@interface MLDrumGainAudioUnit : AUAudioUnit
@property(nonatomic) float volume;
@end
NS_ASSUME_NONNULL_END
