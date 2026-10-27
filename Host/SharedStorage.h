#pragma once
#import <Foundation/Foundation.h>

// Resolve the actual, signed iOS App Groups entitlement rather than trusting an
// unsigned IPA's original hard-coded identifier. No entitlement is fabricated.
FOUNDATION_EXPORT NSURL * _Nullable LSBSharedStorageContainerURL(NSString * _Nullable * _Nullable selectedGroup);
FOUNDATION_EXPORT NSString *LSBSharedStorageDiagnostic(void);
