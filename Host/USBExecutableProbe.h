#pragma once
#import <Foundation/Foundation.h>

// Non-executing kernel diagnostic. Copies the already SideStore-signed host
// Mach-O to a unique temporary file on selected USB, registers the unchanged
// embedded signature, and attempts executable-page mapping. Never jumps into it.
// This tests the HOST process only, not LiveProcess extension permissions.
FOUNDATION_EXPORT NSString *LSBProbeUSBExecutableMapping(NSURL *usbFolder);
