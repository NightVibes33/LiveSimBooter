#pragma once
#import <UIKit/UIKit.h>

// User-controlled external Files folder for storing a complete, prepared runtime.
// The current guest broker still launches from the local App Group; a saved
// external folder bookmark is not executable code access for LiveProcess.
@interface LSBUSBStorageViewController : UITableViewController <UIDocumentPickerDelegate>
@end
