#import "SharedStorage.h"
#import "../ProcessSupport/SpawnPlan.h"
#import <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

static NSArray<NSString *> *LSBSignedAppGroups(void) {
    // These Security functions exist in the system framework but are not
    // declared by the iPhoneOS public SDK. Check symbols at runtime instead
    // of assuming a private export is present in every iOS release.
    typedef CFTypeRef (*CreateTask)(CFAllocatorRef);
    typedef CFTypeRef (*CopyEntitlement)(CFTypeRef, CFStringRef, CFErrorRef *);
    void *library = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_LOCAL);
    if (!library) return @[];
    CreateTask create = (CreateTask)dlsym(library, "SecTaskCreateFromSelf");
    CopyEntitlement read = (CopyEntitlement)dlsym(library, "SecTaskCopyValueForEntitlement");
    if (!create || !read) { dlclose(library); return @[]; }
    CFTypeRef task = create(kCFAllocatorDefault);
    CFTypeRef value = task ? read(task, CFSTR("com.apple.security.application-groups"), NULL) : NULL;
    if (task) CFRelease(task);
    dlclose(library);
    if (!value) return @[];
    if (CFGetTypeID(value) != CFArrayGetTypeID()) {
        CFRelease(value);
        return @[];
    }
    NSArray *raw = CFBridgingRelease(value);
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    for (id item in raw) if ([item isKindOfClass:NSString.class] && [item hasPrefix:@"group."] && [item length] > 6)
        [groups addObject:item];
    return groups;
}

NSURL *LSBSharedStorageContainerURL(NSString **selectedGroup) {
    if (selectedGroup) *selectedGroup = nil;
    NSArray<NSString *> *signedGroups = LSBSignedAppGroups();
    NSString *preferred = @LSB_APP_GROUP;
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if ([signedGroups containsObject:preferred]) [candidates addObject:preferred];
    // SideStore may rewrite a bundled App Group identifier during resigning.
    for (NSString *group in signedGroups) if (![candidates containsObject:group] &&
        [group.localizedLowercaseString containsString:@"livesimbooter"]) [candidates addObject:group];
    for (NSString *group in signedGroups) if (![candidates containsObject:group]) [candidates addObject:group];
    for (NSString *group in candidates) {
        NSURL *container = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
        if (!container) continue;
        if (selectedGroup) *selectedGroup = group;
        return container;
    }
    return nil;
}

NSString *LSBSharedStorageDiagnostic(void) {
    NSArray<NSString *> *groups = LSBSignedAppGroups();
    if (!groups.count)
        return @"The signed app has no App Groups entitlement. SideStore must preserve a valid App Group in the main app "
               @"and LiveProcess extension and issue profiles that authorize it; installing the unsigned IPA alone does not.";
    NSString *group = nil;
    NSURL *container = LSBSharedStorageContainerURL(&group);
    if (container)
        return [NSString stringWithFormat:@"Signed App Group %@ is accessible in the host. The LiveProcess extension "
                @"must also have this App Group in its own provisioning profile.", group];
    return [NSString stringWithFormat:@"Signed App Groups are %@, but iOS returned no shared container. "
            @"Check both provisioning profiles, the app and LiveProcess entitlements, and that SideStore kept the extension.",
            [groups componentsJoinedByString:@", "]];
}
