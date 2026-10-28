#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block and turns an Objective-C exception (which Swift cannot catch) into an NSError.
/// AVAudioEngine raises exceptions for invalid graph changes on some audio devices.
@interface SRNObjC : NSObject
+ (BOOL)tryBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
