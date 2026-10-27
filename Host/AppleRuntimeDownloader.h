#pragma once
#import <Foundation/Foundation.h>

// Downloads Apple's unchanged official iOS 26.0 (23A343) .aar archive to the
// user's selected USB folder. NO Apple binaries are hosted by this project,
// and the raw archive is NOT a prepared or bootable simulator RuntimeRoot.
@interface LSBAppleRuntimeDownloader : NSObject
- (instancetype)initWithUSBFolder:(NSURL *)folder
                           update:(void (^)(NSString *message))update
                       completion:(void (^)(NSError * _Nullable error))completion;
- (void)start;
- (void)cancel;
@end
