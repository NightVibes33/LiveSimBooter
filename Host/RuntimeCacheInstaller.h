#pragma once
#import <Foundation/Foundation.h>

// Downloads only repository-owned guest helpers described by the pinned schema.
// No Apple simulator runtime is bundled, downloaded, or constructed here.
@interface LSBRuntimeCacheInstaller : NSObject
- (instancetype)initWithUSBFolder:(NSURL *)folder
                           update:(void (^)(NSString *message))update
                       completion:(void (^)(NSError * _Nullable error))completion;
- (void)start;
- (void)cancel;
@end
