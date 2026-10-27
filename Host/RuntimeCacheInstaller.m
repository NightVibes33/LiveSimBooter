#import "RuntimeCacheInstaller.h"
#import <CommonCrypto/CommonDigest.h>
#import <zlib.h>

static NSString *const LSBManifestURL = @"https://raw.githubusercontent.com/NightVibes33/LiveSimBooter/runtime-cache-23A343/manifest.json";
static NSString *const LSBDownloadBase = @"https://raw.githubusercontent.com/NightVibes33/LiveSimBooter/runtime-cache-23A343/";
static NSString *const LSBStagingName = @".LiveSimBooter-Helpers-23A343-incomplete";
static NSString *const LSBPublishedName = @"LiveSimBooter-Helpers-23A343";
static NSUInteger const LSBMaxChunkBytes = 4 * 1024 * 1024;
static NSUInteger const LSBMaxFiles = 128;
static NSUInteger const LSBMaxChunksPerFile = 512;

static NSError *LSBCacheError(NSString *message) {
    return [NSError errorWithDomain:@"LiveSimBooter.RuntimeCache" code:1
                          userInfo:@{NSLocalizedDescriptionKey:message}];
}

static NSString *LSBHashData(NSData *bytes) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:64];
    for (NSUInteger n = 0; n < sizeof(digest); ++n) [result appendFormat:@"%02x", digest[n]];
    return result;
}

static BOOL LSBValidSHA(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length != 64) return NO;
    static NSCharacterSet *hex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"]; });
    return [value rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound;
}

static BOOL LSBValidRelativePath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.length || [path hasPrefix:@"/"] || path.length > 220) return NO;
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/"]; });
    if ([path rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return NO;
    for (NSString *component in [path componentsSeparatedByString:@"/"])
        if (!component.length || [component isEqualToString:@"."] || [component isEqualToString:@".."]) return NO;
    return YES;
}

@interface LSBRuntimeCacheInstaller ()
@property (nonatomic, strong) NSURL *folder;
@property (nonatomic, strong) NSURL *stage;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, copy) void (^update)(NSString *);
@property (nonatomic, copy) void (^completion)(NSError *);
@property (nonatomic, strong) NSArray<NSDictionary *> *files;
@property (nonatomic) NSUInteger fileIndex;
@property (nonatomic) NSUInteger chunkIndex;
@property (nonatomic) unsigned long long transferred;
@property (nonatomic) unsigned long long totalBytes;
@property (nonatomic) BOOL scoped;
@property (nonatomic) BOOL finished;
@property (nonatomic) BOOL cancelled;
@end

@implementation LSBRuntimeCacheInstaller
- (instancetype)initWithUSBFolder:(NSURL *)folder
                           update:(void (^)(NSString *))update
                       completion:(void (^)(NSError *))completion {
    if (!(self = [super init])) return nil;
    _folder = folder;
    _update = [update copy];
    _completion = [completion copy];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.URLCache = nil;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.timeoutIntervalForRequest = 50;
    config.timeoutIntervalForResource = 180;
    _session = [NSURLSession sessionWithConfiguration:config];
    return self;
}

- (void)message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{ if (!self.finished && self.update) self.update(message); });
}

- (void)finish:(NSError *)error {
    @synchronized (self) { if (self.finished) return; self.finished = YES; }
    [self.session invalidateAndCancel];
    if (self.scoped) [self.folder stopAccessingSecurityScopedResource];
    self.scoped = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.completion) self.completion(error); });
}

- (void)cancel {
    self.cancelled = YES;
    [self finish:LSBCacheError(@"Download cancelled. Verified chunks remain on USB for the next attempt.")];
}

- (BOOL)validManifest:(NSDictionary *)root error:(NSError **)outError {
    if (![root isKindOfClass:NSDictionary.class] ||
        ![root[@"formatVersion"] isEqual:@1] ||
        ![root[@"guestBuild"] isEqual:@"23A343"] ||
        ![root[@"contentType"] isEqual:@"open-source-helpers"] ||
        ![root[@"files"] isKindOfClass:NSArray.class]) {
        if (outError) *outError = LSBCacheError(@"GitHub cache manifest is invalid or is not the supported open-source helper cache.");
        return NO;
    }
    NSArray *files = root[@"files"];
    if (!files.count || files.count > LSBMaxFiles) {
        if (outError) *outError = LSBCacheError(@"Cache manifest has an invalid file count.");
        return NO;
    }
    unsigned long long total = 0;
    NSMutableSet *paths = [NSMutableSet set];
    // This generated cache can install only the project’s own helper tools.
    NSSet<NSString *> *allowed = [NSSet setWithArray:@[@"usr/lib/libLiveSimSpawn.dylib",
        @"bin/spawn-probe", @"usr/libexec/terminal-fish", @"usr/libexec/display-settings",
        @"usr/libexec/launchctl-control", @"usr/libexec/app-registration"]];
    for (id item in files) {
        if (![item isKindOfClass:NSDictionary.class]) goto invalid;
        NSString *path = item[@"path"];
        NSArray *chunks = item[@"chunks"];
        NSNumber *size = item[@"size"];
        if (!LSBValidRelativePath(path) || ![allowed containsObject:path] || !LSBValidSHA(item[@"sha256"]) ||
            ![item[@"compression"] isEqual:@"gzip"] ||
            ![size isKindOfClass:NSNumber.class] || size.unsignedLongLongValue == 0 ||
            size.unsignedLongLongValue > 1024ULL * 1024 * 1024 ||
            ![chunks isKindOfClass:NSArray.class] || !chunks.count || chunks.count > LSBMaxChunksPerFile ||
            [paths containsObject:path]) goto invalid;
        [paths addObject:path];
        for (id c in chunks) {
            if (![c isKindOfClass:NSDictionary.class] || !LSBValidSHA(c[@"sha256"]) ||
                !LSBValidRelativePath(c[@"name"]) || ![c[@"name"] hasPrefix:@"cache/"] ||
                ![c[@"size"] isKindOfClass:NSNumber.class] ||
                [c[@"size"] unsignedLongLongValue] == 0 ||
                [c[@"size"] unsignedLongLongValue] > LSBMaxChunkBytes) goto invalid;
            total += [c[@"size"] unsignedLongLongValue];
            if (total > 1024ULL * 1024 * 1024) goto invalid;
        }
    }
    if (paths.count != allowed.count) goto invalid;
    self.files = files;
    self.totalBytes = total;
    return YES;
invalid:
    if (outError) *outError = LSBCacheError(@"GitHub cache rejected: unsafe file path, hash, chunk size or unexpected format.");
    return NO;
}

- (void)start {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self start]; });
        return;
    }
    self.scoped = [self.folder startAccessingSecurityScopedResource];
    if (!self.scoped) { [self finish:LSBCacheError(@"USB folder permission was not granted. Select it again in Files.")]; return; }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *published = [self.folder URLByAppendingPathComponent:LSBPublishedName isDirectory:YES];
    if ([fm fileExistsAtPath:published.path]) {
        [self finish:LSBCacheError(@"Helper cache is already installed on this drive. Existing files were not overwritten.")];
        return;
    }
    self.stage = [self.folder URLByAppendingPathComponent:LSBStagingName isDirectory:YES];
    NSError *error = nil;
    if (![fm createDirectoryAtURL:self.stage withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self finish:error]; return;
    }
    [self message:@"Checking the GitHub helper cache manifest…"];
    NSURL *url = [NSURL URLWithString:LSBManifestURL];
    [[self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        if (self.finished) return;
        if (networkError) { [self finish:networkError]; return; }
        if (![response isKindOfClass:NSHTTPURLResponse.class] ||
            ((NSHTTPURLResponse *)response).statusCode != 200 || data.length == 0 || data.length > 1024 * 1024) {
            [self finish:LSBCacheError(@"Helper manifest is not published on GitHub yet, or the server returned an invalid response.")]; return;
        }
        NSError *parseError = nil;
        id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
        if (![self validManifest:root error:&parseError]) { [self finish:parseError]; return; }
        self.fileIndex = 0;
        [self nextFile];
    }] resume];
}

- (NSURL *)completedFileForEntry:(NSDictionary *)entry {
    return [[self.stage URLByAppendingPathComponent:@"RuntimeRoot" isDirectory:YES]
            URLByAppendingPathComponent:entry[@"path"]];
}

- (BOOL)existingFileValid:(NSURL *)path entry:(NSDictionary *)entry {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path.path];
    if (!handle) return NO;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned long long count = 0;
    @try {
        for (;;) {
            NSData *data = [handle readDataOfLength:65536];
            if (!data.length) break;
            count += data.length;
            if (count > [entry[@"size"] unsignedLongLongValue]) break;
            CC_SHA256_Update(&context, data.bytes, (CC_LONG)data.length);
        }
    } @catch (NSException *exception) { (void)exception; count = UINT64_MAX; }
    [handle closeFile];
    if (count != [entry[@"size"] unsignedLongLongValue]) return NO;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString string];
    for (unsigned i=0; i<sizeof(digest); ++i) [hex appendFormat:@"%02x",digest[i]];
    return [hex isEqualToString:entry[@"sha256"]];
}

- (void)nextFile {
    if (self.finished) return;
    if (self.fileIndex >= self.files.count) { [self publish]; return; }
    NSDictionary *entry = self.files[self.fileIndex];
    NSURL *output = [self completedFileForEntry:entry];
    if ([self existingFileValid:output entry:entry]) {
        for (NSDictionary *chunk in entry[@"chunks"]) [NSFileManager.defaultManager removeItemAtURL:[self chunkFileFor:chunk] error:nil];
        self.fileIndex++;
        [self nextFile];
        return;
    }
    self.chunkIndex = 0;
    [self nextChunk];
}

- (NSURL *)chunkFileFor:(NSDictionary *)chunk {
    return [[self.stage URLByAppendingPathComponent:@"chunks" isDirectory:YES]
            URLByAppendingPathComponent:chunk[@"name"]];
}

- (void)nextChunk {
    if (self.finished) return;
    NSDictionary *entry = self.files[self.fileIndex];
    NSArray *chunks = entry[@"chunks"];
    if (self.chunkIndex >= chunks.count) {
        [self decompressEntry:entry];
        return;
    }
    NSDictionary *chunk = chunks[self.chunkIndex];
    NSURL *local = [self chunkFileFor:chunk];
    NSDictionary *stat = [NSFileManager.defaultManager attributesOfItemAtPath:local.path error:nil];
    if ([stat[NSFileSize] unsignedLongLongValue] == [chunk[@"size"] unsignedLongLongValue]) {
        NSData *bytes = [NSData dataWithContentsOfURL:local options:NSDataReadingMappedIfSafe error:nil];
        if (bytes && [LSBHashData(bytes) isEqualToString:chunk[@"sha256"]]) {
            self.chunkIndex++;
            [self nextChunk];
            return;
        }
    }
    [self downloadChunk:chunk attempt:0];
}

- (void)downloadChunk:(NSDictionary *)chunk attempt:(NSUInteger)attempt {
    if (self.finished) return;
    NSString *relative = chunk[@"name"];
    NSURL *url = [NSURL URLWithString:[LSBDownloadBase stringByAppendingString:relative]];
    if (![url.scheme isEqualToString:@"https"] || ![url.host isEqualToString:@"raw.githubusercontent.com"]) {
        [self finish:LSBCacheError(@"Unsafe download URL.")]; return;
    }
    [self message:[NSString stringWithFormat:@"Downloading helper %lu/%lu · chunk %lu · %.1f MB cache",
        (unsigned long)(self.fileIndex + 1), (unsigned long)self.files.count,
        (unsigned long)(self.chunkIndex + 1), (double)self.totalBytes / 1048576.0]];
    [[self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        if (self.finished) return;
        BOOL okay = !networkError && [response isKindOfClass:NSHTTPURLResponse.class] &&
            ((NSHTTPURLResponse *)response).statusCode == 200 &&
            data.length == [chunk[@"size"] unsignedLongLongValue] &&
            [LSBHashData(data) isEqualToString:chunk[@"sha256"]];
        if (!okay) {
            if (attempt < 2) { [self downloadChunk:chunk attempt:attempt+1]; return; }
            [self finish:networkError ?: LSBCacheError(@"Download failed SHA-256, length or HTTP status verification. No unverified data was installed.")];
            return;
        }
        NSURL *dest = [self chunkFileFor:chunk];
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:dest.URLByDeletingLastPathComponent
                                     withIntermediateDirectories:YES attributes:nil error:&error] ||
            ![data writeToURL:dest options:NSDataWritingAtomic error:&error]) {
            [self finish:error ?: LSBCacheError(@"Could not save a verified chunk onto USB.")]; return;
        }
        self.transferred += data.length;
        self.chunkIndex++;
        [self nextChunk];
    }] resume];
}

// Inflate a gzip member incrementally using <= 64 KiB buffers. The compressed
// chunks remain on USB until verification, then are removed on success.
- (void)decompressEntry:(NSDictionary *)entry {
    if (self.finished) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *destination = [self completedFileForEntry:entry];
        NSURL *partial = [NSURL fileURLWithPath:[destination.path stringByAppendingString:@".partial"]];
        NSError *error = nil;
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm createDirectoryAtURL:destination.URLByDeletingLastPathComponent
          withIntermediateDirectories:YES attributes:nil error:&error]) { [self finish:error]; return; }
        [fm removeItemAtURL:partial error:nil];
        if (![fm createFileAtPath:partial.path contents:nil attributes:nil]) {
            [self finish:LSBCacheError(@"Failed to create a staging file on USB.")]; return;
        }
        NSFileHandle *writer = [NSFileHandle fileHandleForWritingAtPath:partial.path];
        z_stream stream = {0};
        if (inflateInit2(&stream, 15+32) != Z_OK) {
            [writer closeFile];
            [self finish:LSBCacheError(@"gzip decompression could not start.")]; return;
        }
        CC_SHA256_CTX hash; CC_SHA256_Init(&hash);
        unsigned long long size = 0;
        BOOL ended = NO;
        for (NSDictionary *chunk in entry[@"chunks"]) {
            if (self.finished || error) break;
            NSFileHandle *reader = [NSFileHandle fileHandleForReadingAtPath:[self chunkFileFor:chunk].path];
            if (!reader) { error = LSBCacheError(@"Saved USB chunk disappeared."); break; }
            @try {
                for (;;) {
                    NSData *data = [reader readDataOfLength:65536];
                    if (!data.length) break;
                    if (ended) { error = LSBCacheError(@"Extra trailing gzip data."); break; }
                    stream.next_in = (Bytef *)data.bytes;
                    stream.avail_in = (uInt)data.length;
                    while (stream.avail_in > 0 && !error) {
                        unsigned char buffer[65536];
                        stream.next_out = buffer;
                        stream.avail_out = sizeof(buffer);
                        int result = inflate(&stream, Z_NO_FLUSH);
                        NSUInteger produced = sizeof(buffer)-stream.avail_out;
                        size += produced;
                        if (size > [entry[@"size"] unsignedLongLongValue]) {
                            error = LSBCacheError(@"Decompressed file exceeded manifest size."); break;
                        }
                        if (produced) {
                            CC_SHA256_Update(&hash, buffer, (CC_LONG)produced);
                            [writer writeData:[NSData dataWithBytes:buffer length:produced]];
                        }
                        if (result == Z_STREAM_END) {
                            ended = YES;
                            if (stream.avail_in) error = LSBCacheError(@"Trailing data in gzip stream.");
                            break;
                        }
                        if (result != Z_OK) { error = LSBCacheError(@"gzip data corrupt."); break; }
                        if (!produced && stream.avail_in == 0) break;
                    }
                    if (error) break;
                }
            } @catch (NSException *exception) { error = LSBCacheError(exception.reason ?: @"USB file read/write failed."); }
            [reader closeFile];
        }
        inflateEnd(&stream);
        [writer closeFile];
        if (!error && !ended) error = LSBCacheError(@"gzip stream ended prematurely.");
        if (!error && size != [entry[@"size"] unsignedLongLongValue]) error = LSBCacheError(@"Uncompressed file size does not match the manifest.");
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_Final(digest, &hash);
        NSMutableString *hex = [NSMutableString string];
        for (unsigned i=0;i<sizeof(digest);++i) [hex appendFormat:@"%02x", digest[i]];
        if (!error && ![hex isEqualToString:entry[@"sha256"]]) error = LSBCacheError(@"Uncompressed SHA-256 mismatch. The helper is not installed.");
        if (!error && [fm fileExistsAtPath:destination.path] && ![fm removeItemAtURL:destination error:&error]) {}
        if (!error && ![fm moveItemAtURL:partial toURL:destination error:&error]) {}
        if (error) {
            [fm removeItemAtURL:partial error:nil];
            [self finish:error];
            return;
        }
        for (NSDictionary *chunk in entry[@"chunks"]) [fm removeItemAtURL:[self chunkFileFor:chunk] error:nil];
        self.fileIndex++;
        [self message:[NSString stringWithFormat:@"Verified helper %lu of %lu · %@",
            (unsigned long)self.fileIndex, (unsigned long)self.files.count, entry[@"path"]]];
        [self nextFile];
    });
}

- (void)publish {
    if (self.finished) return;
    NSURL *published = [self.folder URLByAppendingPathComponent:LSBPublishedName isDirectory:YES];
    if ([NSFileManager.defaultManager fileExistsAtPath:published.path]) {
        [self finish:LSBCacheError(@"Target already exists; no files replaced.")]; return;
    }
    NSError *error = nil;
    // This package is deliberately separate from the bootable 23A343 runtime.
    // The app must never claim it is a prepared Apple simulator.
    if (![NSFileManager.defaultManager moveItemAtURL:self.stage toURL:published error:&error]) {
        [self finish:error]; return;
    }
    [self finish:nil];
}
@end
