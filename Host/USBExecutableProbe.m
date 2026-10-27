#import "USBExecutableProbe.h"
#import <TargetConditionals.h>
#import <mach-o/loader.h>
#import <mach/machine.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *LSBProbeFailure(NSString *stage, int error) {
    return [NSString stringWithFormat:@"USB executable probe failed at %@: errno=%d (%s). "
            @"The host cannot yet confirm executable mapping from this USB filesystem. "
            @"The LiveProcess extension has a separate sandbox and remains unverified.",
            stage, error, strerror(error)];
}

NSString *LSBProbeUSBExecutableMapping(NSURL *usbFolder) {
#if TARGET_OS_SIMULATOR
    (void)usbFolder;
    return @"USB executable mapping cannot be verified in an outer Xcode simulator. Use a physical iPhone.";
#else
    if (!usbFolder || ![usbFolder isFileURL])
        return @"USB mapping probe requires a selected filesystem folder.";
    if (![usbFolder startAccessingSecurityScopedResource])
        return @"USB folder access was not granted by Files.";
    NSURL *probe = [usbFolder URLByAppendingPathComponent:
        [@".LiveSimBooter-ExecutableProbe-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *result = nil;
    int fd = -1;
    void *mapped = MAP_FAILED;
    size_t mappedLength = (size_t)getpagesize();
    @try {
        NSURL *binary = NSBundle.mainBundle.executableURL;
        NSError *copyError = nil;
        if (!binary || ![NSFileManager.defaultManager copyItemAtURL:binary toURL:probe error:&copyError]) {
            result = [NSString stringWithFormat:@"USB executable probe could not write the signed test file: %@",
                      copyError.localizedDescription ?: @"Host executable unavailable"];
            goto cleanup;
        }
        fd = open(probe.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
        if (fd < 0) { result = LSBProbeFailure(@"open", errno); goto cleanup; }
        struct stat st = {};
        if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size < (off_t)sizeof(struct mach_header_64)) {
            result = LSBProbeFailure(@"fstat", errno ?: EINVAL); goto cleanup;
        }
        struct mach_header_64 hdr = {};
        if (pread(fd, &hdr, sizeof(hdr), 0) != (ssize_t)sizeof(hdr) ||
            hdr.magic != MH_MAGIC_64 || hdr.cputype != CPU_TYPE_ARM64 ||
            hdr.ncmds > 4096 || hdr.sizeofcmds > 1024 * 1024 ||
            (uint64_t)sizeof(hdr) + hdr.sizeofcmds > (uint64_t)st.st_size) {
            result = @"USB executable probe found invalid or unsupported signed ARM64 Mach-O header.";
            goto cleanup;
        }
        void *commands = malloc(hdr.sizeofcmds);
        if (!commands) { result = LSBProbeFailure(@"allocate commands", ENOMEM); goto cleanup; }
        BOOL found = NO;
        struct linkedit_data_command signature = {};
        if (pread(fd, commands, hdr.sizeofcmds, sizeof(hdr)) == hdr.sizeofcmds) {
            size_t offset = 0;
            for (uint32_t i = 0; i < hdr.ncmds; ++i) {
                if (offset + sizeof(struct load_command) > hdr.sizeofcmds) break;
                const struct load_command *cmd = (const void *)((const char *)commands + offset);
                if (cmd->cmdsize < sizeof(*cmd) || offset + cmd->cmdsize > hdr.sizeofcmds) break;
                if (cmd->cmd == LC_CODE_SIGNATURE && cmd->cmdsize >= sizeof(signature)) {
                    memcpy(&signature, cmd, sizeof(signature));
                    found = YES;
                    break;
                }
                offset += cmd->cmdsize;
            }
        }
        free(commands);
        if (!found || !signature.datasize || signature.dataoff < mappedLength ||
            (uint64_t)signature.dataoff + signature.datasize > (uint64_t)st.st_size) {
            result = @"USB executable probe cannot locate a usable embedded code signature.";
            goto cleanup;
        }
        fsignatures_t sig = {};
        sig.fs_file_start = 0;
        sig.fs_blob_start = (void *)(uintptr_t)signature.dataoff;
        sig.fs_blob_size = signature.datasize;
        if (fcntl(fd, F_ADDFILESIGS_RETURN, &sig) < 0) {
            result = LSBProbeFailure(@"F_ADDFILESIGS_RETURN", errno);
            goto cleanup;
        }
        if (sig.fs_file_start < (off_t)signature.dataoff) {
            result = @"Kernel signature registration did not cover the host test executable.";
            goto cleanup;
        }
        mapped = mmap(NULL, mappedLength, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0);
        if (mapped == MAP_FAILED) {
            result = LSBProbeFailure(@"mmap(PROT_EXEC)", errno);
            goto cleanup;
        }
        if (((struct mach_header_64 *)mapped)->magic != MH_MAGIC_64) {
            result = @"Executable mapping returned unexpected bytes.";
            goto cleanup;
        }
        result = @"HOST USB executable-page mapping succeeded for the unchanged signed host Mach-O. "
                 @"No code was executed from USB. This does NOT validate the LiveProcess sandbox, "
                 @"guest dyld_sim signatures, or a complete iOS 26 boot.";
cleanup:
        if (mapped != MAP_FAILED) munmap(mapped, mappedLength);
        if (fd >= 0) close(fd);
        [NSFileManager.defaultManager removeItemAtURL:probe error:nil];
    } @finally {
        [usbFolder stopAccessingSecurityScopedResource];
    }
    return result ?: @"Unknown USB executable probe result.";
#endif
}
