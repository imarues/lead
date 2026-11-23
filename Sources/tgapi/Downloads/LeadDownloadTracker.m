#import "LeadDownloadTracker.h"
#import <objc/runtime.h>
#import <objc/message.h>

NSString *const LeadDownloadStatusDidChange = @"LeadDownloadStatusDidChange";

static const int32_t kLeadGetFile = -1101843010;
static const int32_t kLeadGetCdnFile = 962554330;
static const uint32_t kLeadUploadFile = 0x096a18d5;
static const uint32_t kLeadUploadCdnFile = 0xa99fca4f;
static const uint32_t kLeadCdnRedirect = 0xf18cda44;
static const uint32_t kLeadDocumentLocation = 0xbad07584;
static NSString *const kLeadProgressKey = @"LeadShowDownloadProgress";
static NSString *const kLeadAudioKey = @"LeadDownloadBackgroundAudio";

static uint32_t LeadU32(const uint8_t *b) {
    uint32_t n; memcpy(&n, b, sizeof(n)); return CFSwapInt32LittleToHost(n);
}
static uint64_t LeadU64(const uint8_t *b) {
    uint64_t n; memcpy(&n, b, sizeof(n)); return CFSwapInt64LittleToHost(n);
}

// Decode upload.file.bytes rather than counting TL header and padding.
static NSUInteger LeadFileChunkBytes(NSData *data) {
    if (data.length < 8) return 0;
    const uint8_t *b = data.bytes;
    uint32_t ctor = LeadU32(b);
    NSUInteger start;
    if (ctor == kLeadUploadFile) start = 12; // file type, mtime, bytes
    else if (ctor == kLeadUploadCdnFile) start = 4; // bytes
    else return 0; // redirect, error or another type: do not count
    if (data.length <= start) return 0;
    uint8_t first = b[start];
    NSUInteger head = first == 254 ? 4 : 1;
    if (first == 255 || start + head > data.length) return 0;
    NSUInteger count = first == 254
        ? ((NSUInteger)b[start+1] | ((NSUInteger)b[start+2] << 8) | ((NSUInteger)b[start+3] << 16))
        : first;
    if (start + head + count > data.length) return 0;
    return count;
}

static NSMutableDictionary<NSString *, NSMutableDictionary *> *sTasks;
static NSMutableDictionary<NSString *, NSDictionary *> *sMetadata;
static NSMutableDictionary<NSString *, NSString *> *sCdnAliases;
static dispatch_queue_t sQueue;
static AVAudioPlayer *sAudio;
static BOOL sAudioOwnsSession;
static UIBackgroundTaskIdentifier sBackgroundTask = UIBackgroundTaskInvalid;
static BOOL sInBackground;
static BOOL sInstalled;

@implementation LeadDownloadTracker

+ (void)initialize {
    if (self != LeadDownloadTracker.class) return;
    sQueue = dispatch_queue_create("lead.download.progress", DISPATCH_QUEUE_SERIAL);
    sTasks = [NSMutableDictionary new];
    sMetadata = [NSMutableDictionary new];
    sCdnAliases = [NSMutableDictionary new];
}

+ (NSString *)tokenForPayload:(NSData *)payload functionID:(int32_t)functionID {
    if ((functionID != kLeadGetFile && functionID != kLeadGetCdnFile) || payload.length < 24) return nil;
    const uint8_t *b = payload.bytes;
    NSUInteger locationStart = functionID == kLeadGetFile ? 8 : 4;
    NSUInteger locationLen = payload.length - locationStart - 12;
    if (locationLen < 4 || locationLen > 2048) return nil;
    if (functionID == kLeadGetFile && LeadU32(b + locationStart) == kLeadDocumentLocation &&
        locationLen >= 24) {
        // A document's thumbnail has the SAME ID, but must not be counted
        // against the full document's filesize. Skip thumb_size != "".
        NSUInteger fileRef = locationStart + 20;
        if (fileRef < locationStart + locationLen) {
            uint8_t first = b[fileRef];
            NSUInteger head = first == 254 ? 4 : 1;
            NSUInteger len = first == 254 && fileRef + 4 <= locationStart+locationLen
                ? ((NSUInteger)b[fileRef+1] | ((NSUInteger)b[fileRef+2] << 8) | ((NSUInteger)b[fileRef+3] << 16))
                : (first < 254 ? first : 0);
            NSUInteger padded = (head + len + 3) & ~(NSUInteger)3;
            NSUInteger thumb = fileRef + padded;
            if (first != 255 && thumb < locationStart + locationLen && b[thumb] == 0) {
                int64_t document = (int64_t)LeadU64(b + locationStart + 4);
                return [NSString stringWithFormat:@"doc:%lld", (long long)document];
            }
        }
    }
    // FNV-1a over the *location*, excluding the changing offset and limit.
    // Supports photo/video locations and CDN tokens without guessing filenames.
    uint64_t hash = 14695981039346656037ULL;
    for (NSUInteger i=locationStart; i < locationStart+locationLen; i++) {
        hash = (hash ^ b[i]) * 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"loc:%016llx", (unsigned long long)hash];
}

+ (void)receivedResponse:(NSData *)response forToken:(NSString *)token
                payload:(NSData *)payload functionID:(int32_t)functionID {
    if (!token || !response || payload.length < 16 ||
        ![[NSUserDefaults standardUserDefaults] boolForKey:kLeadProgressKey]) return;
    NSUInteger chunk = LeadFileChunkBytes(response);
    // A CDN redirect maps the original document location to a CDN token.
    // Both tokens use identical TL byte encodings, so they can share progress.
    if (functionID == kLeadGetFile && response.length >= 12 &&
        LeadU32(response.bytes) == kLeadCdnRedirect) {
        const uint8_t *r = response.bytes;
        NSUInteger start = 8;
        uint8_t first = r[start];
        NSUInteger head = first == 254 ? 4 : 1;
        NSUInteger size = first == 254 && response.length >= 12
            ? ((NSUInteger)r[9] | ((NSUInteger)r[10] << 8) | ((NSUInteger)r[11] << 16))
            : (first < 254 ? first : 0);
        NSUInteger padded = (head + size + 3) & ~(NSUInteger)3;
        if (first != 255 && padded && start+padded <= response.length) {
            uint64_t hash = 14695981039346656037ULL;
            for (NSUInteger i=start; i<start+padded; i++)
                hash = (hash ^ r[i]) * 1099511628211ULL;
            NSString *cdn = [NSString stringWithFormat:@"loc:%016llx", (unsigned long long)hash];
            dispatch_async(sQueue, ^{
                sCdnAliases[cdn] = token;
                if (sCdnAliases.count > 2000)
                    [sCdnAliases removeObjectForKey:sCdnAliases.allKeys.firstObject];
            });
        }
        return;
    }
    if (!chunk) return;
    const uint8_t *p = payload.bytes;
    uint64_t offset = LeadU64(p + payload.length - 12);
    if (offset > (uint64_t)INT64_MAX || chunk > 2 * 1024 * 1024) return;
    dispatch_async(sQueue, ^{
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        // Stale incomplete transfers disappear after 45 seconds without a response.
        for (NSString *key in [sTasks allKeys]) {
            NSDictionary *item = sTasks[key];
            if (now - [item[@"last"] doubleValue] > 45) [sTasks removeObjectForKey:key];
        }
        NSString *resolvedToken = sCdnAliases[token] ?: token;
        NSMutableDictionary *entry = sTasks[resolvedToken];
        if (!entry) {
            entry = [@{@"token": resolvedToken, @"received": @0, @"last": @(now),
                       @"parts": [NSMutableDictionary new], @"completed": @NO} mutableCopy];
            sTasks[resolvedToken] = entry;
        }
        NSMutableDictionary<NSNumber *, NSNumber *> *parts = entry[@"parts"];
        NSNumber *offKey = @(offset);
        NSUInteger old = [parts[offKey] unsignedIntegerValue];
        if (chunk > old) {
            entry[@"received"] = @([entry[@"received"] unsignedLongLongValue] + chunk - old);
            parts[offKey] = @(chunk);
        }
        entry[@"last"] = @(now);
        NSDictionary *meta = sMetadata[resolvedToken];
        if (meta) {
            entry[@"name"] = meta[@"name"];
            entry[@"total"] = meta[@"size"];
            long long total = [meta[@"size"] longLongValue];
            if (total > 0 && [entry[@"received"] longLongValue] >= total) {
                entry[@"completed"] = @YES;
            }
        }
        // No percent when Telegram's document size hasn't been identified.
        [self announceLocked];
    });
}

+ (void)registerDocumentId:(int64_t)documentId size:(int64_t)size name:(NSString *)name {
    if (documentId == 0 || size <= 0) return;
    NSString *token = [NSString stringWithFormat:@"doc:%lld", (long long)documentId];
    NSString *safeName = name.length ? [name lastPathComponent] : @"Telegram file";
    dispatch_async(sQueue, ^{
        sMetadata[token] = @{@"size": @(size), @"name": safeName};
        if (sMetadata.count > 2000) [sMetadata removeObjectForKey:sMetadata.allKeys.firstObject];
        NSMutableDictionary *task = sTasks[token];
        if (task) {
            task[@"name"] = safeName; task[@"total"] = @(size);
            if ([task[@"received"] longLongValue] >= size) task[@"completed"] = @YES;
            [self announceLocked];
        }
    });
}

+ (NSDictionary *)snapshotLocked {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSDictionary *best = nil;
    for (NSDictionary *task in sTasks.allValues) {
        if (now - [task[@"last"] doubleValue] > 45 || [task[@"completed"] boolValue]) continue;
        if (!best || [task[@"last"] doubleValue] > [best[@"last"] doubleValue]) best = task;
    }
    if (!best) return @{};
    long long received = [best[@"received"] longLongValue];
    long long total = [best[@"total"] longLongValue];
    NSInteger percent = total > 0 ? (NSInteger)MIN(100, (received * 100.0 / total)) : -1;
    return @{@"name": best[@"name"] ?: @"Telegram file",
             @"received": @(received), @"total": @(total),
             @"percent": @(percent), @"token": best[@"token"] ?: @""};
}

+ (NSDictionary *)currentDownload {
    __block NSDictionary *snapshot;
    dispatch_sync(sQueue, ^{ snapshot = [self snapshotLocked]; });
    return snapshot;
}

+ (NSUInteger)activeDownloadCount {
    __block NSUInteger count = 0;
    dispatch_sync(sQueue, ^{
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        for (NSDictionary *entry in sTasks.allValues) {
            if (![entry[@"completed"] boolValue] &&
                now - [entry[@"last"] doubleValue] < 20) count++;
        }
    });
    return count;
}

// A tiny WAV loop. Audio keepalive is experimental: iOS may still suspend it.
// It must be opt-in, and the signed host IPA must declare UIBackgroundModes=audio.
+ (NSData *)quietWAV {
    const NSUInteger sampleCount = 8000;
    NSMutableData *wave = [NSMutableData dataWithLength:44 + sampleCount * 2];
    uint8_t *b = wave.mutableBytes;
    memcpy(b, "RIFF", 4);
    uint32_t riff = CFSwapInt32HostToLittle((uint32_t)wave.length - 8); memcpy(b+4, &riff, 4);
    memcpy(b+8, "WAVEfmt ", 8);
    uint32_t fmt = CFSwapInt32HostToLittle(16); memcpy(b+16, &fmt, 4);
    uint16_t pcm = CFSwapInt16HostToLittle(1); memcpy(b+20, &pcm, 2);
    uint16_t mono = CFSwapInt16HostToLittle(1); memcpy(b+22, &mono, 2);
    uint32_t rate = CFSwapInt32HostToLittle(8000); memcpy(b+24, &rate, 4);
    uint32_t bytes = CFSwapInt32HostToLittle(16000); memcpy(b+28, &bytes, 4);
    uint16_t align = CFSwapInt16HostToLittle(2); memcpy(b+32, &align, 2);
    uint16_t bits = CFSwapInt16HostToLittle(16); memcpy(b+34, &bits, 2);
    memcpy(b+36, "data", 4);
    uint32_t length = CFSwapInt32HostToLittle(sampleCount * 2); memcpy(b+40, &length, 4);
    return wave;
}

+ (void)stopAudio {
    if (!sAudio) return;
    [sAudio stop]; sAudio = nil;
    if (sAudioOwnsSession) {
        [[AVAudioSession sharedInstance] setActive:NO
                                     withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                           error:nil];
    }
    sAudioOwnsSession = NO;
}

+ (void)backgroundStateRefresh {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self backgroundStateRefresh]; });
        return;
    }
    BOOL playing = sInBackground && [self activeDownloadCount] > 0;
    BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:kLeadAudioKey];
    if (!playing || !enabled) {
        [self stopAudio];
        if (sBackgroundTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:sBackgroundTask];
            sBackgroundTask = UIBackgroundTaskInvalid;
        }
        return;
    }
    if (sBackgroundTask == UIBackgroundTaskInvalid) {
        sBackgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"Lead Telegram download" expirationHandler:^{
            if (sBackgroundTask != UIBackgroundTaskInvalid) {
                [[UIApplication sharedApplication] endBackgroundTask:sBackgroundTask];
                sBackgroundTask = UIBackgroundTaskInvalid;
            }
        }];
    }
    if (sAudio) return;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    // Don't take over a phone/video call's active audio route.
    if ([session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) return;
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayback
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error]) return;
    if (![session setActive:YES error:&error]) return;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithData:[self quietWAV] error:&error];
    if (!player) return;
    player.numberOfLoops = -1;
    [player prepareToPlay];
    if ([player play]) {
        sAudio = player;
        sAudioOwnsSession = YES;
    }
}

+ (void)announceLocked {
    NSDictionary *snapshot = [self snapshotLocked];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:LeadDownloadStatusDidChange
                                                            object:nil userInfo:snapshot];
        // ActivityKit bridge is built only into IPA variants that also ship the
        // companion Widget extension. Otherwise this is a harmless no-op.
        Class bridge = NSClassFromString(@"LeadDownloadActivityBridge");
        SEL sel = NSSelectorFromString(@"updateWithName:received:total:");
        if (bridge && [bridge respondsToSelector:sel] &&
            [[NSUserDefaults standardUserDefaults] boolForKey:kLeadProgressKey]) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(
                bridge, sel, snapshot[@"name"] ?: @"", snapshot[@"received"] ?: @0,
                snapshot[@"total"] ?: @0);
        }
        [self backgroundStateRefresh];
    });
}

+ (void)installLifecycle {
    if (sInstalled) return;
    sInstalled = YES;
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        @"LeadShowDownloadProgress": @YES,
        @"LeadDownloadBackgroundAudio": @YES
    }];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                       object:nil queue:[NSOperationQueue mainQueue]
                   usingBlock:^(__unused NSNotification *note) {
        sInBackground = YES;
        [self backgroundStateRefresh];
    }];
    [center addObserverForName:UIApplicationWillEnterForegroundNotification
                       object:nil queue:[NSOperationQueue mainQueue]
                   usingBlock:^(__unused NSNotification *note) {
        sInBackground = NO;
        [self backgroundStateRefresh];
    }];
    [center addObserverForName:@"LeadDownloadDocumentMetadata"
                       object:nil queue:nil
                   usingBlock:^(NSNotification *note) {
        NSNumber *doc = note.userInfo[@"id"], *size = note.userInfo[@"size"];
        if (doc && size) [self registerDocumentId:doc.longLongValue size:size.longLongValue
                                              name:note.userInfo[@"name"]];
    }];
    [center addObserverForName:UIApplicationWillResignActiveNotification
                       object:nil queue:[NSOperationQueue mainQueue]
                   usingBlock:^(__unused NSNotification *note) {
        // Pre-arm playback while foreground; starting it after suspension may fail.
        sInBackground = YES;
        [self backgroundStateRefresh];
    }];
    [center addObserverForName:@"LeadSettingsDidChangeNotification"
                       object:nil queue:[NSOperationQueue mainQueue]
                   usingBlock:^(__unused NSNotification *note) {
        [self backgroundStateRefresh];
    }];
    // Stop when an unfinished transfer has gone quiet (a hook cannot observe cancellation).
    __block void (^poll)(void);
    poll = ^{
        [self backgroundStateRefresh];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), poll);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), poll);
}
@end
