#import "SirenaObjC.h"

@implementation SRNObjC
+ (BOOL)tryBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"SirenaObjCException" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""]}];
        }
        return NO;
    }
}
@end
