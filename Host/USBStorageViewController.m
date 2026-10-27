#import "USBStorageViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "../ProcessSupport/SpawnPlan.h"
#import <Foundation/Foundation.h>

static NSString *const LSBUSBBookmarkKey = @"LSBUSBStorageDirectoryBookmarkV1";
static NSString *const LSBUSBPackageName = @"LiveSimBooter-USB-23A343";

@interface LSBUSBStorageViewController ()
@property (nonatomic, copy) NSString *status;
@property (nonatomic, copy) NSString *location;
@property (nonatomic, assign) BOOL busy;
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; return section == 0 ? 2 : 2;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; return section == 0 ? @"USB drive" : @"Prepared simulator";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return self.status;
    return @"Store copies the existing, signed and prepared simulator on USB. Restore copies it into the App Group before boot. "
           @"The current loader cannot execute the entire guest directly from USB; this does not eliminate the local runtime space requirement. "
           @"Keep the app open and the drive connected during each transfer. Never unplug during a copy.";
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
    } else if (indexPath.section == 0) {
        cell.textLabel.text = @"Check USB connection";
        cell.detailTextLabel.text = @"Check the saved Files permission";
    } else if (indexPath.row == 0) {
        cell.textLabel.text = @"Store prepared simulator on USB";
        cell.detailTextLabel.text = @"Copies local RuntimeRoot and optional SimulatorData without deleting the originals";
    } else {
        cell.textLabel.text = @"Restore simulator from USB";
        cell.detailTextLabel.text = @"Copies the prepared RuntimeRoot to the App Group when no local runtime exists";
    }
    cell.userInteractionEnabled = !self.busy;
    cell.textLabel.enabled = !self.busy;
    cell.detailTextLabel.enabled = !self.busy;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.busy) return;
    if (indexPath.section == 0 && indexPath.row == 0) {
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    } else if (indexPath.section == 0) {
        [self refreshSelection];
    } else {
        BOOL exporting = indexPath.row == 0;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:exporting ? @"Store on USB?" : @"Restore from USB?"
            message:exporting ? @"The source simulator must already be fully prepared and signed. A USB copy may be over 15 GB. Existing USB backups will not be overwritten." :
                                @"Restoring requires the full simulator size in free iPhone storage. Existing local runtime and data will not be overwritten."
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
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject;
    if (!url || ![url startAccessingSecurityScopedResource]) {
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
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { (void)controller; }

+ (NSError *)storageError:(NSString *)description {
    return [NSError errorWithDomain:@"LiveSimBooter.USBStorage" code:1
                          userInfo:@{NSLocalizedDescriptionKey: description}];
}

+ (BOOL)hasPreparedRoot:(NSURL *)root {
    BOOL directory = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:root.path isDirectory:&directory] && directory &&
           [NSFileManager.defaultManager fileExistsAtPath:
                 [[root URLByAppendingPathComponent:@"usr/lib/dyld_sim"] path]];
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
        NSURL *group = [manager containerURLForSecurityApplicationGroupIdentifier:@LSB_APP_GROUP];
        if (!error && !scoped) error = [LSBUSBStorageViewController storageError:@"USB disconnected or Files permission denied."];
        if (!error && !group) error = [LSBUSBStorageViewController storageError:@"App Group missing. Sign the app and LiveProcess with matching App Group entitlement."];
        NSURL *usbPackage = [usb URLByAppendingPathComponent:LSBUSBPackageName isDirectory:YES];
        NSURL *localRoot = [group URLByAppendingPathComponent:@"RuntimeRoot" isDirectory:YES];
        NSURL *localData = [group URLByAppendingPathComponent:@"SimulatorData" isDirectory:YES];
        NSURL *sourceRoot = exporting ? localRoot : [usbPackage URLByAppendingPathComponent:@"RuntimeRoot" isDirectory:YES];
        if (!error && ![LSBUSBStorageViewController hasPreparedRoot:sourceRoot])
            error = [LSBUSBStorageViewController storageError:@"The source has no prepared RuntimeRoot/usr/lib/dyld_sim."];
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
