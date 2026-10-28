#import "USBStorageViewController.h"
#import "SharedStorage.h"
#import "RuntimeCacheInstaller.h"
#import "AppleRuntimeDownloader.h"
#import "USBExecutableProbe.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "../ProcessSupport/SpawnPlan.h"
#import <Foundation/Foundation.h>

static NSString *const LSBUSBBookmarkKey = @"LSBUSBStorageDirectoryBookmarkV1";
static NSString *const LSBUSBPackageName = @"LiveSimBooter-USB-23A343";
static NSString *const LSBUSBDownloadCheckpointKey = @"LSBUSBLastDownloadCheckpointV2";
static NSString *const LSBUSBDownloadActiveKey = @"LSBUSBDownloadWasActiveV2";

@interface LSBUSBStorageViewController ()
@property (nonatomic, copy) NSString *status;
@property (nonatomic, copy) NSString *location;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) BOOL importingPreparedRuntime;
@property (nonatomic, strong) LSBRuntimeCacheInstaller *cacheInstaller;
@property (nonatomic, strong) LSBAppleRuntimeDownloader *appleDownloader;
@end

@implementation LSBUSBStorageViewController

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"USB Storage";
    self.status = @"Select a folder on an attached USB drive.";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
    [self refreshSelection];
    if ([NSUserDefaults.standardUserDefaults boolForKey:LSBUSBDownloadActiveKey]) {
        NSString *stage = [NSUserDefaults.standardUserDefaults stringForKey:LSBUSBDownloadCheckpointKey];
        if (stage.length) {
            self.status = [NSString stringWithFormat:@"%@\nPrevious download ended without completion. Last stage: %@. Check Settings → Privacy & Security → Analytics Data for LiveSimBooter crash reports.", self.status ?: @"", stage];
            [self.tableView reloadData];
        }
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:LSBUSBDownloadActiveKey];
    }
}

- (NSURL *)selectedFolderWithError:(NSError **)error {
    NSData *data = [NSUserDefaults.standardUserDefaults dataForKey:LSBUSBBookmarkKey];
    if (!data.length) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError
                                            userInfo:@{NSLocalizedDescriptionKey: @"Select a USB folder first."}];
        return nil;
    }
    BOOL stale = NO;
    NSURL *url = [NSURL URLByResolvingBookmarkData:data options:0 relativeToURL:nil
                              bookmarkDataIsStale:&stale error:error];
    if (stale) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoPermissionError
                                            userInfo:@{NSLocalizedDescriptionKey: @"USB access expired. Select the folder again."}];
        return nil;
    }
    return url;
}

- (void)refreshSelection {
    if (self.busy) return;
    NSError *error = nil;
    NSURL *folder = [self selectedFolderWithError:&error];
    if (!folder) {
        self.location = @"Not connected";
        self.status = error.localizedDescription ?: @"Choose a USB folder.";
    } else if (![folder startAccessingSecurityScopedResource]) {
        self.location = folder.lastPathComponent;
        self.status = @"USB permission unavailable. Reconnect the drive and select its folder again.";
    } else {
        BOOL directory = NO;
        BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:folder.path isDirectory:&directory];
        self.location = folder.lastPathComponent;
        self.status = exists && directory ? @"Folder accessible. Prepared runtime can be stored here." :
                                              @"The selected USB folder is unavailable.";
        [folder stopAccessingSecurityScopedResource];
    }
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; return section == 0 ? 3 : (section == 1 ? 2 : 4);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; return section == 0 ? @"USB drive" : (section == 1 ? @"Download to USB" : @"Prepared simulator");
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return [NSString stringWithFormat:@"%@\n\n%@", self.status, LSBSharedStorageDiagnostic()];
    if (section == 1) return @"Download the original iOS 26.0 (23A343) ARM64 Apple simulator archive DIRECTLY from Apple’s CDN. Its ~8 GB .aar is NOT a prepared or bootable RuntimeRoot; decrypting, staging and signing are still required. GitHub provides only its manifest. Separately, fetch our open-source helper files from GitHub. "
           @"They are NOT a bootable Apple simulator; iOS 26.0 (23A343) still requires appropriately obtained, prepared and signed Apple runtime components. "
           @"Install resumes already verified chunks after interruption. Temporary chunks are deleted after each helper is installed. "
           @"No full-size temporary download is stored on iPhone.";
    return @"First import a prepared iOS Simulator 26.0 (23A343) RuntimeRoot folder from Files, or store one already in the app. "
           @"The original Xcode .simruntime is not sufficient: dyld_sim, launchd_sim, shared cache, and guest helpers must be prepared and signed. "
           @"USB storage/backup does not enable executing guest Mach-O code directly from USB. Restore to iPhone before boot. "
           @"Keep the app open and USB connected throughout transfers.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (indexPath.section == 0 && indexPath.row == 0) {
        cell.textLabel.text = @"Choose USB folder";
        cell.detailTextLabel.text = self.location ?: @"Not connected";
    } else if (indexPath.section == 0 && indexPath.row == 1) {
        cell.textLabel.text = @"Check USB connection";
        cell.detailTextLabel.text = @"Check the saved Files permission";
    } else if (indexPath.section == 0) {
        cell.textLabel.text = @"Diagnose USB executable mapping";
        cell.detailTextLabel.text = @"Physical iPhone: register the signed host executable and probe PROT_EXEC from USB, without executing code";
    } else if (indexPath.section == 1 && indexPath.row == 0) {
        cell.textLabel.text = @"Download original iOS 26 simulator archive";
        cell.detailTextLabel.text = @"Apple CDN → USB · 7.99 GB · resumable byte ranges · full SHA-256";
    } else if (indexPath.section == 1) {
        cell.textLabel.text = @"Download LiveSimBooter helpers to USB";
        cell.detailTextLabel.text = @"GitHub · gzip chunks · SHA-256 · resumable";
    } else if (indexPath.row == 0) {
        cell.textLabel.text = @"Import prepared simulator from Files";
        cell.detailTextLabel.text = @"Select RuntimeRoot folder and copy directly to USB without first copying it to iPhone storage";
    } else if (indexPath.row == 1) {
        cell.textLabel.text = @"Store existing iPhone simulator on USB";
        cell.detailTextLabel.text = @"Requires an already-installed prepared App Group RuntimeRoot";
    } else if (indexPath.row == 2) {
        cell.textLabel.text = @"Restore USB simulator to iPhone";
        cell.detailTextLabel.text = @"Copies the prepared runtime back to the App Group before launching";
    } else {
        cell.textLabel.text = @"Check USB simulator contents";
        cell.detailTextLabel.text = @"Verify the required prepared files are present; does not validate code signatures";
    }
    cell.userInteractionEnabled = !self.busy;
    cell.textLabel.enabled = !self.busy;
    cell.detailTextLabel.enabled = !self.busy;
    return cell;
}
- (void)diagnoseUSBExecutableMapping {
    NSError *error = nil;
    NSURL *usb = [self selectedFolderWithError:&error];
    if (!usb) {
        self.status = error.localizedDescription ?: @"Choose the USB folder first.";
        [self.tableView reloadData]; return;
    }
    self.busy = YES;
    self.status = @"Testing signed Mach-O file mapping from USB on the host; no code will be executed…";
    [self.tableView reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *diagnosis = LSBProbeUSBExecutableMapping(usb);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.status = diagnosis;
            [self.tableView reloadData];
        });
    });
}
// Download startup is intentionally decoupled from UIAlertAction's dismissal
// transaction. Every potentially blocking USB security-scope and file operation
// runs on a background queue, not inside a UIKit animation callback.
- (void)downloadCheckpoint:(NSString *)stage active:(BOOL)active {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:stage ?: @"unknown" forKey:LSBUSBDownloadCheckpointKey];
    [defaults setBool:active forKey:LSBUSBDownloadActiveKey];
    NSLog(@"[LiveSimBooter.USB] download stage=%@ active=%d", stage, active);
}
- (void)finishUSBDownload:(NSError *)error apple:(BOOL)apple {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self finishUSBDownload:error apple:apple]; });
        return;
    }
    if (!self.busy) return; // Never surface two callbacks for a failed start/cancel race.
    self.busy = NO;
    // A completed operation is not an interrupted download, even on error.
    [self downloadCheckpoint:error ? @"completed-with-error" : @"completed-successfully" active:NO];
    self.appleDownloader = nil;
    self.cacheInstaller = nil;
    self.status = error ? [NSString stringWithFormat:@"%@: %@",
        apple ? @"Apple archive download failed" : @"Helper cache failed",
        error.localizedDescription ?: @"Unknown error"] :
        (apple ?
         @"The original iOS 26.0 (23A343) Apple archive was verified on USB. It is not yet a bootable RuntimeRoot." :
         @"LiveSimBooter helper cache downloaded and verified on USB. These helpers do not include the Apple simulator.");
    [self.tableView reloadData];
}
- (void)beginDownloadOnUSB:(NSURL *)usb apple:(BOOL)apple {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self beginDownloadOnUSB:usb apple:apple]; });
        return;
    }
    if (self.busy) return;
    self.busy = YES;
    self.status = apple ? @"Preparing Apple iOS 26 archive download…" : @"Preparing GitHub helper download…";
    [self downloadCheckpoint:apple ? @"apple-confirmed" : @"helpers-confirmed" active:YES];
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    void (^progress)(NSString *) = ^(NSString *message) {
        __strong typeof(weakSelf) current = weakSelf;
        if (!current) return;
        [current downloadCheckpoint:apple ? @"apple-network-or-storage" : @"helpers-network-or-storage" active:YES];
        current.status = message ?: @"Download in progress…";
        [current.tableView reloadData];
    };
    void (^completed)(NSError *) = ^(NSError *error) {
        __strong typeof(weakSelf) current = weakSelf;
        if (current) [current finishUSBDownload:error apple:apple];
    };
    // Delay construction until the alert has returned control to UIKit.
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) owner = weakSelf;
        if (!owner || !owner.busy) return;
        @try {
            if (apple) {
                owner.appleDownloader = [[LSBAppleRuntimeDownloader alloc]
                    initWithUSBFolder:usb update:progress completion:completed];
            } else {
                owner.cacheInstaller = [[LSBRuntimeCacheInstaller alloc]
                    initWithUSBFolder:usb update:progress completion:completed];
            }
            if ((apple && !owner.appleDownloader) || (!apple && !owner.cacheInstaller)) {
                [owner finishUSBDownload:[LSBUSBStorageViewController storageError:@"Unable to initialize the download service."] apple:apple];
                return;
            }
            [owner downloadCheckpoint:apple ? @"apple-start-dispatched" : @"helpers-start-dispatched" active:YES];
            // Retain the operation independently of the UI while startAccessing
            // security-scoped USB resources and opening files.
            id operation = apple ? owner.appleDownloader : owner.cacheInstaller;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @autoreleasepool {
                    @try {
                        [operation start];
                    } @catch (NSException *exception) {
                        NSError *failure = [LSBUSBStorageViewController storageError:
                            [NSString stringWithFormat:@"USB download startup rejected: %@", exception.reason ?: @"Unknown exception"]];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            __strong typeof(weakSelf) current = weakSelf;
                            if (current) [current finishUSBDownload:failure apple:apple];
                        });
                        [operation cancel]; // Cancel any partly created task and release USB scope.
                        NSLog(@"[LiveSimBooter.USB] startup exception: %@", failure.localizedDescription);
                    }
                }
            });
        } @catch (NSException *exception) {
            [owner finishUSBDownload:[LSBUSBStorageViewController storageError:
                [NSString stringWithFormat:@"Cannot start download: %@",exception.reason ?: @"Unknown exception"]] apple:apple];
        }
    });
}
- (void)startAppleRuntimeDownload {
    NSError *error = nil;
    NSURL *usb = [self selectedFolderWithError:&error];
    if (!usb) {
        self.status = error.localizedDescription ?: @"Choose the USB folder first.";
        [self.tableView reloadData];
        return;
    }
    __weak typeof(self) weakSelf = self;
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Download Apple's iOS 26 simulator archive?"
        message:@"The original ARM64 iOS Simulator 26.0 build 23A343 is about 7.99 GB. Download directly to the selected USB folder with HTTP range resume and SHA-256 verification. The raw .aar archive does not boot without preparation and signing."
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Download from Apple" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        __strong typeof(weakSelf) owner = weakSelf;
        if (!owner) return;
        // UIAlertController dismisses automatically; avoid reloading the
        // table during its transition, which can destabilize UIKit on iOS betas.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [owner beginDownloadOnUSB:usb apple:YES];
        });
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}
- (void)startHelperDownload {
    NSError *error = nil;
    NSURL *usb = [self selectedFolderWithError:&error];
    if (!usb) {
        self.status = error.localizedDescription ?: @"Choose a USB folder first.";
        [self.tableView reloadData];
        return;
    }
    __weak typeof(self) weakSelf = self;
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Download LiveSimBooter helpers?"
        message:@"Downloads the SHA-256-verified compressed open-source helpers from GitHub to USB. This does not include the Apple simulator runtime."
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Download" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        __strong typeof(weakSelf) owner = weakSelf;
        if (!owner) return;
        // UIAlertController dismisses automatically; avoid reloading the
        // table during its transition, which can destabilize UIKit on iOS betas.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [owner beginDownloadOnUSB:usb apple:NO];
        });
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)presentFolderPickerForImport:(BOOL)importing {
    self.importingPreparedRuntime = importing;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.busy) return;
    if (indexPath.section == 0 && indexPath.row == 0) {
        [self presentFolderPickerForImport:NO];
        return;
    }
    if (indexPath.section == 0 && indexPath.row == 1) { [self refreshSelection]; return; }
    if (indexPath.section == 0 && indexPath.row == 2) { [self diagnoseUSBExecutableMapping]; return; }
    if (indexPath.section == 1) { if (indexPath.row == 0) [self startAppleRuntimeDownload]; else [self startHelperDownload]; return; }
    if (indexPath.row == 0) {
        NSError *error = nil;
        NSURL *usb = [self selectedFolderWithError:&error];
        if (!usb || ![usb startAccessingSecurityScopedResource]) {
            self.status = error.localizedDescription ?: @"Select an accessible USB folder first.";
            [self.tableView reloadData];
            return;
        }
        [usb stopAccessingSecurityScopedResource];
        [self presentFolderPickerForImport:YES];
        return;
    }
    if (indexPath.row == 3) { [self inspectUSBPreparedRuntime]; return; }
    BOOL exporting = indexPath.row == 1;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:exporting ? @"Store on USB?" : @"Restore to iPhone?"
        message:exporting ? @"Store requires a prepared RuntimeRoot already installed inside the app's group. If you haven't installed one, use Import prepared simulator from Files instead." :
                            @"Restore copies the USB simulator into iPhone storage. It cannot currently run directly from USB, and needs the full runtime size available locally."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:exporting ? @"Store" : @"Restore"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        [weakSelf transferToUSB:exporting];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject;
    BOOL importing = self.importingPreparedRuntime;
    self.importingPreparedRuntime = NO;
    if (!url) return;
    if (importing) { [self importPreparedRuntimeFromURL:url]; return; }
    if (![url startAccessingSecurityScopedResource]) {
        self.status = @"Unable to access the chosen folder. Check Files permissions.";
        [self.tableView reloadData];
        return;
    }
    NSError *error = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
    [url stopAccessingSecurityScopedResource];
    if (bookmark.length) [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:LSBUSBBookmarkKey];
    else self.status = error.localizedDescription ?: @"Could not save folder access.";
    [self refreshSelection];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    self.importingPreparedRuntime = NO;
}

+ (NSError *)storageError:(NSString *)description {
    return [NSError errorWithDomain:@"LiveSimBooter.USBStorage" code:1
                          userInfo:@{NSLocalizedDescriptionKey: description}];
}

+ (NSArray<NSString *> *)missingPreparedFilesAtRoot:(NSURL *)root {
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:root.path isDirectory:&isDirectory] || !isDirectory)
        return @[@"RuntimeRoot directory"];
    NSArray<NSString *> *required = @[
        @"usr/lib/dyld_sim",
        @"sbin/launchd_sim",
        @"usr/lib/libLiveSimSpawn.dylib",
        @"System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64"
    ];
    NSMutableArray<NSString *> *missing = [NSMutableArray new];
    for (NSString *relative in required) {
        NSString *path = [[root URLByAppendingPathComponent:relative] path];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if (![attributes[NSFileSize] respondsToSelector:@selector(unsignedLongLongValue)] ||
            [attributes[NSFileSize] unsignedLongLongValue] == 0) [missing addObject:relative];
    }
    return missing;
}

+ (BOOL)hasPreparedRoot:(NSURL *)root {
    return [self missingPreparedFilesAtRoot:root].count == 0;
}

+ (NSURL *)preparedRootWithinSelection:(NSURL *)selected {
    NSArray<NSURL *> *candidates = @[
        selected,
        [selected URLByAppendingPathComponent:@"RuntimeRoot" isDirectory:YES],
        [[selected URLByAppendingPathComponent:LSBUSBPackageName isDirectory:YES]
            URLByAppendingPathComponent:@"RuntimeRoot" isDirectory:YES]
    ];
    for (NSURL *candidate in candidates) if ([self hasPreparedRoot:candidate]) return candidate;
    return nil;
}

- (void)inspectUSBPreparedRuntime {
    NSError *error = nil;
    NSURL *usb = [self selectedFolderWithError:&error];
    BOOL scoped = usb && [usb startAccessingSecurityScopedResource];
    if (!scoped) {
        self.status = error.localizedDescription ?: @"USB folder inaccessible. Select it again.";
    } else {
        NSURL *root = [LSBUSBStorageViewController preparedRootWithinSelection:usb];
        if (root) self.status = @"Required prepared runtime files found on USB. File presence does not prove signatures or successful guest execution.";
        else {
            NSURL *expected = [[usb URLByAppendingPathComponent:LSBUSBPackageName isDirectory:YES]
                                 URLByAppendingPathComponent:@"RuntimeRoot" isDirectory:YES];
            NSArray<NSString *> *missing = [LSBUSBStorageViewController missingPreparedFilesAtRoot:expected];
            self.status = [NSString stringWithFormat:@"No prepared iOS 26.0 (23A343) runtime on this USB folder. Missing: %@. "
                           @"Use Import prepared simulator from Files, after preparing the runtime with the repository setup scripts.",
                           [missing componentsJoinedByString:@", "]];
        }
        [usb stopAccessingSecurityScopedResource];
    }
    [self.tableView reloadData];
}

- (void)importPreparedRuntimeFromURL:(NSURL *)selected {
    self.busy = YES;
    self.status = @"Inspecting prepared simulator and USB drive…";
    [self.tableView reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *usb = [self selectedFolderWithError:&error];
        BOOL usbScoped = usb && [usb startAccessingSecurityScopedResource];
        BOOL sourceScoped = [selected startAccessingSecurityScopedResource];
        if (!error && !usbScoped)
            error = [LSBUSBStorageViewController storageError:@"USB folder unavailable. Reconnect USB and choose it again."];
        if (!error && !sourceScoped)
            error = [LSBUSBStorageViewController storageError:@"Files did not grant access to the selected simulator folder."];
        NSURL *sourceRoot = !error ? [LSBUSBStorageViewController preparedRootWithinSelection:selected] : nil;
        if (!error && !sourceRoot) {
            NSArray<NSString *> *missing = [LSBUSBStorageViewController missingPreparedFilesAtRoot:selected];
            error = [LSBUSBStorageViewController storageError:[NSString stringWithFormat:
                @"The selected folder is not a PREPARED simulator runtime (iOS 26.0, build 23A343). "
                @"Missing prepared files: %@. Apple's original .simruntime must first be staged and signed on a Mac.",
                [missing componentsJoinedByString:@", "]]];
        }
        NSURL *package = [usb URLByAppendingPathComponent:LSBUSBPackageName isDirectory:YES];
        // This UI does not replace an existing runtime or an incomplete previous transfer.
        if (!error && [[NSFileManager defaultManager] fileExistsAtPath:package.path])
            error = [LSBUSBStorageViewController storageError:@"USB already contains the target package. Existing contents were not replaced."];
        // Detect selection of a runtime already inside this USB folder and avoid claiming a copy happened.
        if (!error && [sourceRoot.path isEqualToString:[[usb URLByAppendingPathComponent:@"RuntimeRoot"] path]])
            error = [LSBUSBStorageViewController storageError:@"The selected RuntimeRoot is already on USB. No import is required; use Check USB simulator contents."];
        NSURL *stage = nil;
        if (!error) {
            NSString *directory = [@".LiveSimBooter-import-" stringByAppendingString:NSUUID.UUID.UUIDString];
            stage = [usb URLByAppendingPathComponent:directory isDirectory:YES];
            if (![[NSFileManager defaultManager] createDirectoryAtURL:stage withIntermediateDirectories:NO attributes:nil error:&error])
                stage = nil;
        }
        if (stage && !error) {
            NSURL *copied = [stage URLByAppendingPathComponent:@"RuntimeRoot" isDirectory:YES];
            if (![LSBUSBStorageViewController copyFolder:sourceRoot to:copied error:&error] && !error)
                error = [LSBUSBStorageViewController storageError:@"Could not copy prepared RuntimeRoot to USB."];
            if (!error && ![LSBUSBStorageViewController hasPreparedRoot:copied])
                error = [LSBUSBStorageViewController storageError:@"Staged USB runtime is incomplete. Original was not modified."];
            if (!error) {
                NSDictionary *manifest = @{@"guestBuild": @"23A343", @"formatVersion": @1, @"createdAt": NSDate.date,
                    @"note": @"Copied from Files; signed executable mapping and actual boot NOT verified."};
                if (![manifest writeToURL:[stage URLByAppendingPathComponent:@"USBStorage.plist"] atomically:YES])
                    error = [LSBUSBStorageViewController storageError:@"Unable to write USB manifest."];
            }
            if (!error && ![[NSFileManager defaultManager] moveItemAtURL:stage toURL:package error:&error]) {}
        }
        if (stage) [[NSFileManager defaultManager] removeItemAtURL:stage error:nil];
        if (sourceScoped) [selected stopAccessingSecurityScopedResource];
        if (usbScoped) [usb stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.status = error ? [NSString stringWithFormat:@"Import failed: %@", error.localizedDescription] :
                @"Prepared simulator stored on USB without importing it into the iPhone App Group. "
                 @"To boot with the current loader, use Restore simulator to iPhone.";
            [self.tableView reloadData];
        });
    });
}

+ (BOOL)copyFolder:(NSURL *)source to:(NSURL *)destination error:(NSError **)error {
    // File coordination is essential for Files locations backed by a document provider.
    // The destination is a unique sibling staging directory, never an active runtime.
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    __block BOOL copied = NO;
    __block NSError *copyError = nil;
    [coordinator coordinateReadingItemAtURL:source options:0 error:error byAccessor:^(NSURL *readURL) {
        copied = [NSFileManager.defaultManager copyItemAtURL:readURL toURL:destination error:&copyError];
    }];
    if (copyError && error) *error = copyError;
    return copied;
}

- (void)transferToUSB:(BOOL)exporting {
    self.busy = YES;
    self.status = exporting ? @"Storing on USB. Keep this app open and the drive connected…" :
                             @"Restoring to iPhone. Keep this app open and the drive connected…";
    [self.tableView reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *usb = [self selectedFolderWithError:&error];
        BOOL scoped = usb && [usb startAccessingSecurityScopedResource];
        NSURL *group = LSBSharedStorageContainerURL(NULL);
        if (!error && !scoped) error = [LSBUSBStorageViewController storageError:@"USB disconnected or Files permission denied."];
        if (!error && !group) error = [LSBUSBStorageViewController storageError:LSBSharedStorageDiagnostic()];
        NSURL *usbPackage = [usb URLByAppendingPathComponent:LSBUSBPackageName isDirectory:YES];
        NSURL *localRoot = [group URLByAppendingPathComponent:@"RuntimeRoot" isDirectory:YES];
        NSURL *localData = [group URLByAppendingPathComponent:@"SimulatorData" isDirectory:YES];
        NSURL *sourceRoot = exporting ? localRoot : [usbPackage URLByAppendingPathComponent:@"RuntimeRoot" isDirectory:YES];
        if (!error && ![LSBUSBStorageViewController hasPreparedRoot:sourceRoot])
            error = [LSBUSBStorageViewController storageError:exporting ?
                @"No prepared simulator is installed in the App Group. Use Import prepared simulator from Files to install one onto USB." :
                @"No prepared simulator was found on USB. Use Import prepared simulator from Files first."];
        if (!error && exporting && [manager fileExistsAtPath:usbPackage.path])
            error = [LSBUSBStorageViewController storageError:@"USB package already exists. It will not be overwritten."];
        if (!error && !exporting && [manager fileExistsAtPath:localRoot.path])
            error = [LSBUSBStorageViewController storageError:@"Local runtime already exists. Nothing was replaced. Back it up and remove it manually before restoring."];
        NSURL *stage = nil;
        if (!error) {
            NSURL *destinationParent = exporting ? usb : group;
            NSString *prefix = exporting ? @".LiveSimBooter-usb-write-" : @".LiveSimBooter-usb-restore-";
            stage = [destinationParent URLByAppendingPathComponent:[prefix stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
            if (![manager createDirectoryAtURL:stage withIntermediateDirectories:NO attributes:nil error:&error]) stage = nil;
        }
        if (stage && !error) {
            NSURL *copiedRoot = [stage URLByAppendingPathComponent:@"RuntimeRoot" isDirectory:YES];
            if (![LSBUSBStorageViewController copyFolder:sourceRoot to:copiedRoot error:&error]) {
                if (!error) error = [LSBUSBStorageViewController storageError:@"Could not copy RuntimeRoot."];
            }
            if (!error && ![LSBUSBStorageViewController hasPreparedRoot:copiedRoot])
                error = [LSBUSBStorageViewController storageError:@"The staged runtime is incomplete."];
            NSURL *sourceData = exporting ? localData : [usbPackage URLByAppendingPathComponent:@"SimulatorData" isDirectory:YES];
            BOOL dataDirectory = NO;
            if (!error && [manager fileExistsAtPath:sourceData.path isDirectory:&dataDirectory] && dataDirectory) {
                NSURL *stagedData = [stage URLByAppendingPathComponent:@"SimulatorData" isDirectory:YES];
                if (![LSBUSBStorageViewController copyFolder:sourceData to:stagedData error:&error] && !error)
                    error = [LSBUSBStorageViewController storageError:@"Could not copy SimulatorData."];
            }
            if (!error && exporting) {
                NSDictionary *manifest = @{@"guestBuild": @"23A343", @"createdAt": NSDate.date,
                    @"formatVersion": @1, @"note": @"Prepared simulator backup; must restore locally before boot."};
                if (![manifest writeToURL:[stage URLByAppendingPathComponent:@"USBStorage.plist"] atomically:YES])
                    error = [LSBUSBStorageViewController storageError:@"Could not write USB manifest."];
                if (!error && ![manager moveItemAtURL:stage toURL:usbPackage error:&error]) {}
            } else if (!error) {
                // Never overwrite existing mutable data. Finish the runtime transfer last if data exists.
                NSURL *stagedData = [stage URLByAppendingPathComponent:@"SimulatorData"];
                if ([manager fileExistsAtPath:stagedData.path] && ![manager fileExistsAtPath:localData.path]) {
                    if (![manager moveItemAtURL:stagedData toURL:localData error:&error]) {}
                }
                if (!error && ![manager moveItemAtURL:copiedRoot toURL:localRoot error:&error]) {}
            }
        }
        if (stage) [manager removeItemAtURL:stage error:nil];
        if (scoped) [usb stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.status = error ? [NSString stringWithFormat:@"Transfer failed: %@", error.localizedDescription] :
                exporting ? @"USB storage complete. Local runtime remains installed; USB is a separate copy." :
                            @"Runtime restored to App Group. USB does not directly execute guest processes.";
            [self.tableView reloadData];
        });
    });
}

@end
