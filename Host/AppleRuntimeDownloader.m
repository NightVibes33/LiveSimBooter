#import "AppleRuntimeDownloader.h"
#import <CommonCrypto/CommonDigest.h>

static NSString *const LSBAppleManifest = @"https://raw.githubusercontent.com/NightVibes33/LiveSimBooter/feature/usb-runtime-storage/runtime-downloads/ios26-23A343-arm64.json";
static NSString *const LSBAppleName = @"iOS-26.0-23A343-arm64.aar";
static NSString *const LSBApplePartial = @"iOS-26.0-23A343-arm64.aar.partial";
static const unsigned long long LSBAppleByteWindow = 8ULL * 1024ULL * 1024ULL;
static const unsigned long long LSBAppleMaxSize = 16ULL * 1024ULL * 1024ULL * 1024ULL;

static NSError *LSBArchiveError(NSString *message) {
    return [NSError errorWithDomain:@"LiveSimBooter.AppleArchive" code:1
        userInfo:@{NSLocalizedDescriptionKey:message ?: @"Apple simulator download failed."}];
}
static BOOL LSBHexDigest(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length != 64) return NO;
    static NSCharacterSet *nonHex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        nonHex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet;
    });
    return [text rangeOfCharacterFromSet:nonHex].location == NSNotFound;
}

@interface LSBAppleRuntimeDownloader () <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, strong) NSURL *folder;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSFileHandle *writer;
@property (nonatomic, strong) NSDictionary *manifest;
@property (nonatomic, copy) void (^update)(NSString *);
@property (nonatomic, copy) void (^completion)(NSError *);
@property (nonatomic) unsigned long long expectedSize;
@property (nonatomic) unsigned long long requestStart;
@property (nonatomic) unsigned long long requestLength;
@property (nonatomic) unsigned long long received;
@property (nonatomic) BOOL scoped;
@property (nonatomic) BOOL finished;
@property (nonatomic) BOOL cancelled;
@property (nonatomic) BOOL approvedResponse;
@property (nonatomic) BOOL loadingManifest;
@property (nonatomic, strong) NSMutableData *manifestData;
@property (nonatomic, strong) NSError *requestError;
@end

@implementation LSBAppleRuntimeDownloader
- (instancetype)initWithUSBFolder:(NSURL *)folder
                           update:(void (^)(NSString *))update
                       completion:(void (^)(NSError *))completion {
    if (!(self = [super init])) return nil;
    _folder = folder;
    _update = [update copy];
    _completion = [completion copy];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache = nil;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = 90;
    configuration.timeoutIntervalForResource = 600;
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:queue];
    return self;
}
- (NSURL *)partialURL { return [self.folder URLByAppendingPathComponent:LSBApplePartial]; }
- (NSURL *)completeURL { return [self.folder URLByAppendingPathComponent:LSBAppleName]; }
- (void)report:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.finished && self.update) self.update(message);
    });
}
- (void)finish:(NSError *)error {
    @synchronized (self) {
        if (self.finished) return;
        self.finished = YES;
    }
    [self.task cancel];
    [self.session invalidateAndCancel];
    [self.writer closeFile];
    self.writer = nil;
    if (self.scoped) [self.folder stopAccessingSecurityScopedResource];
    self.scoped = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.completion) self.completion(error);
    });
}
- (void)cancel {
    self.cancelled = YES;
    [self finish:LSBArchiveError(@"Cancelled. Partial Apple archive stays on USB and the next download can resume.")];
}
- (void)start {
    self.scoped = [self.folder startAccessingSecurityScopedResource];
    if (!self.scoped) {
        [self finish:LSBArchiveError(@"USB access unavailable. Re-select the external drive in Files.")]; return;
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:self.completeURL.path]) {
        [self finish:LSBArchiveError(@"Apple runtime archive already exists. It was not overwritten or assumed verified.")]; return;
    }
    self.loadingManifest = YES;
    self.manifestData = [NSMutableData data];
    [self report:@"Fetching pinned iOS 26.0 23A343 archive metadata from GitHub…"];
    self.task = [self.session dataTaskWithURL:[NSURL URLWithString:LSBAppleManifest]];
    [self.task resume];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
    newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))handler {
    (void)session; (void)task; (void)response;
    NSString *host = request.URL.host.lowercaseString;
    BOOL accepted = [request.URL.scheme isEqualToString:@"https"] &&
        ([host isEqualToString:@"updates.cdn-apple.com"] ||
         [host isEqualToString:@"raw.githubusercontent.com"]);
    handler(accepted ? request : nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
    completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))handler {
    (void)session; (void)dataTask;
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
    self.approvedResponse = NO;
    if (!http) {
        self.requestError = LSBArchiveError(@"Unexpected response type from Apple or GitHub.");
        handler(NSURLSessionResponseCancel); return;
    }
    if (self.loadingManifest) {
        self.approvedResponse = http.statusCode == 200;
        if (!self.approvedResponse) self.requestError = LSBArchiveError(@"Runtime metadata is not available in the repository.");
    } else {
        NSString *expected = [NSString stringWithFormat:@"bytes %llu-%llu/%llu",
            self.requestStart, self.requestStart + self.requestLength - 1, self.expectedSize];
        NSString *actual = [[http allHeaderFields][@"Content-Range"] description];
        // Some servers normalize header capitalization.
        if (!actual) {
            for (id key in http.allHeaderFields) {
                if ([[key description] caseInsensitiveCompare:@"Content-Range"] == NSOrderedSame)
                    actual = [http.allHeaderFields[key] description];
            }
        }
        self.approvedResponse = http.statusCode == 206 && [actual isEqualToString:expected];
        if (!self.approvedResponse)
            self.requestError = LSBArchiveError(@"Apple CDN did not honor the exact byte range. Refusing a full 8 GB response.");
    }
    handler(self.approvedResponse ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveData:(NSData *)data {
    (void)session; (void)task;
    if (self.finished || !self.approvedResponse) return;
    if (self.loadingManifest) {
        if (self.manifestData.length + data.length > 65536) {
            self.requestError = LSBArchiveError(@"Unreasonably large or invalid runtime manifest.");
            [self.task cancel]; return;
        }
        [self.manifestData appendData:data];
    } else {
        if (self.received + data.length > self.requestLength) {
            self.requestError = LSBArchiveError(@"Apple CDN sent bytes beyond the requested range.");
            [self.task cancel]; return;
        }
        @try {
            [self.writer writeData:data];
            self.received += data.length;
        } @catch (NSException *exception) {
            self.requestError = LSBArchiveError(exception.reason ?: @"Unable to write Apple download on USB.");
            [self.task cancel];
        }
    }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    (void)session; (void)task;
    if (self.finished) return;
    NSError *failure = self.requestError ?: error;
    self.requestError = nil;
    if (failure || !self.approvedResponse) {
        [self finish:failure ?: LSBArchiveError(@"Unexpected download response.")]; return;
    }
    if (self.loadingManifest) {
        self.loadingManifest = NO;
        NSError *parseError = nil;
        id manifest = [NSJSONSerialization JSONObjectWithData:self.manifestData options:0 error:&parseError];
        if (![manifest isKindOfClass:NSDictionary.class]) {
            [self finish:parseError ?: LSBArchiveError(@"Invalid JSON manifest.")]; return;
        }
        NSDictionary *info = manifest;
        NSURL *target = [NSURL URLWithString:info[@"url"] ?: @""];
        NSNumber *length = info[@"sizeBytes"];
        if (![info[@"formatVersion"] isEqual:@1] || ![info[@"build"] isEqualToString:@"23A343"] ||
            ![info[@"architecture"] isEqualToString:@"arm64"] ||
            ![info[@"state"] isEqualToString:@"originalArchiveOnly"] ||
            ![info[@"cacheFile"] isEqualToString:LSBAppleName] ||
            !LSBHexDigest(info[@"sha256"]) ||
            ![length isKindOfClass:NSNumber.class] || length.unsignedLongLongValue < 5ULL * 1024 * 1024 * 1024 ||
            length.unsignedLongLongValue > LSBAppleMaxSize ||
            ![target.scheme isEqualToString:@"https"] || ![target.host isEqualToString:@"updates.cdn-apple.com"] ||
            ![target.pathExtension isEqualToString:@"aar"]) {
            [self finish:LSBArchiveError(@"Manifest is not an authorized original Apple 23A343 ARM64 archive reference.")]; return;
        }
        self.manifest = info;
        self.expectedSize = length.unsignedLongLongValue;
        [self downloadNextRange];
        return;
    }
    [self.writer synchronizeFile];
    [self.writer closeFile];
    self.writer = nil;
    if (self.received != self.requestLength) {
        [self finish:LSBArchiveError(@"Apple download ended early; received bytes are preserved for resume.")]; return;
    }
    [self report:[NSString stringWithFormat:@"Downloaded %.2f / %.2f GB directly to USB",
        (double)(self.requestStart+self.received)/1000000000.0, (double)self.expectedSize/1000000000.0]];
    [self downloadNextRange];
}
- (void)downloadNextRange {
    if (self.finished) return;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:self.partialURL.path error:nil];
    unsigned long long offset = [attributes[NSFileSize] unsignedLongLongValue];
    if (offset > self.expectedSize) {
        [self finish:LSBArchiveError(@"An existing partial archive is larger than the expected Apple download; refusing to overwrite it.")]; return;
    }
    if (offset == self.expectedSize) { [self verifyCompletedArchive]; return; }
    if (![NSFileManager.defaultManager fileExistsAtPath:self.partialURL.path] &&
        ![NSFileManager.defaultManager createFileAtPath:self.partialURL.path contents:nil attributes:nil]) {
        [self finish:LSBArchiveError(@"Could not create the archive on USB.")]; return;
    }
    self.writer = [NSFileHandle fileHandleForWritingAtPath:self.partialURL.path];
    if (!self.writer) { [self finish:LSBArchiveError(@"Cannot reopen USB archive for resume.")]; return; }
    [self.writer seekToEndOfFile];
    self.requestStart = offset;
    self.requestLength = MIN(LSBAppleByteWindow,self.expectedSize-offset);
    self.received = 0;
    self.approvedResponse = NO;
    NSString *range = [NSString stringWithFormat:@"bytes=%llu-%llu", offset,offset+self.requestLength-1];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:self.manifest[@"url"]]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:90];
    [request setValue:range forHTTPHeaderField:@"Range"];
    self.task = [self.session dataTaskWithRequest:request];
    [self.task resume];
}
- (void)verifyCompletedArchive {
    [self report:@"Verifying full Apple archive SHA-256 on USB…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:self.partialURL.path];
        if (!handle) { [self finish:LSBArchiveError(@"Cannot read downloaded Apple archive for verification.")]; return; }
        CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
        unsigned long long count = 0;
        NSError *failure = nil;
        @try {
            for (;;) {
                NSData *data = [handle readDataOfLength:1024*1024];
                if (!data.length) break;
                count += data.length;
                if (count > self.expectedSize) { failure = LSBArchiveError(@"Archive size overflow."); break; }
                CC_SHA256_Update(&ctx,data.bytes,(CC_LONG)data.length);
            }
        } @catch (NSException *exception) { failure = LSBArchiveError(exception.reason); }
        [handle closeFile];
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_Final(digest,&ctx);
        NSMutableString *sha = [NSMutableString string];
        for (NSUInteger i=0;i<sizeof(digest);i++) [sha appendFormat:@"%02x",digest[i]];
        if (!failure && (count != self.expectedSize || ![sha isEqualToString:self.manifest[@"sha256"]]))
            failure = LSBArchiveError(@"Full Apple archive checksum/size mismatch. File retained as .partial for inspection; do not install.");
        if (!failure && ![NSFileManager.defaultManager moveItemAtURL:self.partialURL toURL:self.completeURL error:&failure]) {}
        [self finish:failure];
    });
}
@end
