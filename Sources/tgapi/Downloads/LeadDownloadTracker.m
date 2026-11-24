#import "LeadDownloadTracker.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <zlib.h>
#import <sys/stat.h>

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
static UIBackgroundTaskIdentifier sBackgroundTask = (UIBackgroundTaskIdentifier)NSUIntegerMax;
static BOOL sInBackground;
static BOOL sInstalled;
// Queue-owned state: one pending publication, one selected file, real bytes only.
static BOOL sPublishScheduled;
static NSDictionary *sLastPublished;
static NSString *sSelectedToken;
static NSMutableSet<NSString *> *sMediaRoots;
static NSArray<NSString *> *sMediaDirectories;
static CFAbsoluteTime sLastDirectoryRefresh;
static CFAbsoluteTime sLastCachePoll;
static CFAbsoluteTime sLastPublishTime;
static dispatch_source_t sProgressTimer;
static const NSTimeInterval kLeadDownloadIdle = 120.0;
static const NSTimeInterval kLeadFinishHold = 5.0;

// Merge sorted byte intervals. Overlapping/retried chunks must not count twice.
static uint64_t LeadMergeRange(NSMutableArray<NSValue *> *ranges, uint64_t offset, NSUInteger count) {
    if (offset > NSUIntegerMax - count) return 0;
    NSUInteger lo = (NSUInteger)offset, hi = lo + count;
    uint64_t oldCoverage = 0;
    NSUInteger first = 0;
    while (first < ranges.count && NSMaxRange(ranges[first].rangeValue) < lo) first++;
    NSUInteger end = first;
    while (end < ranges.count) {
        NSRange r = ranges[end].rangeValue;
        if (r.location > hi) break;
        oldCoverage += r.length;
        lo = MIN(lo, r.location);
        hi = MAX(hi, NSMaxRange(r));
        end++;
    }
    if (end > first) [ranges removeObjectsInRange:NSMakeRange(first, end - first)];
    [ranges insertObject:[NSValue valueWithRange:NSMakeRange(lo, hi-lo)] atIndex:first];
    return (uint64_t)(hi-lo) - oldCoverage;
}


// Telegram's MediaBoxFileMap stores verified received intervals in _partial.meta.
// Read-only, checksum validated; file length alone is NOT download progress
// because out-of-order writes can make the partial file sparse.
static BOOL LeadReadMediaMap(NSString *path, uint64_t *received, int64_t *total) {
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0 ||
        st.st_size < 12 || st.st_size > 1024 * 1024) return NO;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:nil];
    if (data.length < 12 || data.length > 1024 * 1024) return NO;
    const uint8_t *p = data.bytes;
    BOOL wide = LeadU32(p) == 0x7bac1487;
    NSUInteger header = wide ? 12 : 8, width = wide ? 8 : 4;
    if (data.length < header + width) return NO;
    uint32_t expectedCRC = LeadU32(p + (wide ? 4 : 0));
    int32_t count = (int32_t)LeadU32(p + (wide ? 8 : 4));
    if (count < 0 || (NSUInteger)count > (data.length-header-width)/(2*width)) return NO;
    NSUInteger payloadSize = width + (NSUInteger)count*2*width;
    if ((uint32_t)crc32(0, p+header, (uInt)payloadSize) != expectedCRC) return NO;
    int64_t truncation = wide ? (int64_t)LeadU64(p+header) : (int64_t)(int32_t)LeadU32(p+header);
    uint64_t sum = 0, previousEnd = 0;
    for (int32_t i=0; i<count; i++) {
        const uint8_t *r = p+header+width+(NSUInteger)i*2*width;
        int64_t start = wide ? (int64_t)LeadU64(r) : (int64_t)(int32_t)LeadU32(r);
        int64_t length = wide ? (int64_t)LeadU64(r+width) : (int64_t)(int32_t)LeadU32(r+width);
        if (start < 0 || length <= 0 || (uint64_t)start < previousEnd ||
            (uint64_t)length > INT64_MAX-(uint64_t)start ||
            (uint64_t)length > INT64_MAX-sum) return NO;
        previousEnd = (uint64_t)start + (uint64_t)length;
        sum += (uint64_t)length;
    }
    if (truncation > 0 && previousEnd > (uint64_t)truncation) return NO;
    *received = sum;
    *total = truncation;
    return YES;
}

@implementation LeadDownloadTracker

+ (void)initialize {
    if (self != LeadDownloadTracker.class) return;
    sQueue = dispatch_queue_create("lead.download.progress", DISPATCH_QUEUE_SERIAL);
    sTasks = [NSMutableDictionary new];
    sMetadata = [NSMutableDictionary new];
    sCdnAliases = [NSMutableDictionary new];
    sMediaRoots = [NSMutableSet new];
    sMediaDirectories = @[];
}

+ (void)registerMediaRoot:(NSString *)root {
    if (!root.length) return;
    dispatch_async(sQueue, ^{
        if (sMediaRoots.count < 32 && ![sMediaRoots containsObject:root]) {
            [sMediaRoots addObject:root];
            sLastDirectoryRefresh = 0;
        }
    });
}

+ (void)refreshMediaDirectoriesLocked {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - sLastDirectoryRefresh < 8) return;
    sLastDirectoryRefresh = now;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableSet<NSString *> *roots = [sMediaRoots mutableCopy];
    NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [roots addObject:documents];
    NSString *fallback = [documents stringByAppendingPathComponent:@"AppGroup"];
    [roots addObject:fallback];
    NSString *clients = [fallback stringByAppendingPathComponent:@"Lead"];
    for (NSString *client in [fm contentsOfDirectoryAtPath:clients error:nil] ?: @[]) {
        if (![client hasPrefix:@"_"]) [roots addObject:[clients stringByAppendingPathComponent:client]];
    }
    NSMutableSet<NSString *> *directories = [NSMutableSet new];
    for (NSString *root in roots) {
        NSString *dataPath = [root stringByAppendingPathComponent:@"telegram-data"];
        for (NSString *account in [fm contentsOfDirectoryAtPath:dataPath error:nil] ?: @[]) {
            if (![account hasPrefix:@"account-"]) continue;
            NSString *media = [[dataPath stringByAppendingPathComponent:account]
                                stringByAppendingPathComponent:@"postbox/media"];
            BOOL isDirectory = NO;
            if ([fm fileExistsAtPath:media isDirectory:&isDirectory] && isDirectory)
                [directories addObject:media];
        }
    }
    sMediaDirectories = directories.allObjects;
}

+ (void)refreshDiskProgressLocked {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - sLastCachePoll < 0.45) return;
    sLastCachePoll = now;
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kLeadProgressKey]) return;
    [self refreshMediaDirectoriesLocked];
    if (!sMediaDirectories.count) return;
    // Only examine known documents already observed by the download hook.
    // No recursive scan or file-content access. Map data contains byte ranges only.
    for (NSString *token in sTasks.allKeys) {
        NSMutableDictionary *entry = sTasks[token];
        NSDictionary *meta = sMetadata[token];
        if (!meta || ![token hasPrefix:@"doc:"] ||
            [entry[@"completed"] boolValue] ||
            now - [entry[@"last"] doubleValue] > kLeadDownloadIdle) continue;
        long long expected = [meta[@"size"] longLongValue];
        NSInteger dc = [meta[@"dc"] integerValue];
        if (expected <= 0 || dc <= 0) continue;
        NSString *file = [NSString stringWithFormat:@"telegram-cloud-document-%ld-%@",
                          (long)dc, [token substringFromIndex:4]];
        uint64_t best = 0;
        BOOL found = NO;
        for (NSString *dir in sMediaDirectories) {
            NSString *base = [dir stringByAppendingPathComponent:file];
            struct stat st;
            if (stat(base.fileSystemRepresentation, &st) == 0 &&
                S_ISREG(st.st_mode) && st.st_size == expected) {
                best = (uint64_t)expected;
                found = YES;
                break;
            }
            uint64_t bytes = 0;
            int64_t truncation = -1;
            if (LeadReadMediaMap([base stringByAppendingString:@"_partial.meta"], &bytes, &truncation) &&
                bytes <= (uint64_t)expected && (truncation <= 0 || truncation == expected)) {
                found = YES;
                best = MAX(best, bytes);
            }
        }
        if (!found) continue;
        uint64_t previous = [entry[@"received"] unsignedLongLongValue];
        uint64_t network = [entry[@"networkBytes"] unsignedLongLongValue];
        uint64_t combined = MAX(best, network);
        entry[@"source"] = best >= network ? @"MediaBox" : @"MTProto";
        entry[@"received"] = @(combined);
        if (combined > previous) entry[@"last"] = @(now);
        if (best == (uint64_t)expected) {
            entry[@"completed"] = @YES;
            entry[@"finishedAt"] = @(now);
        }
    }
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
        // Keep the same file selected during brief pauses and discard old transfers.
        [self refreshDiskProgressLocked];
        for (NSString *key in [sTasks allKeys]) {
            NSDictionary *item = sTasks[key];
            if (now - [item[@"last"] doubleValue] > kLeadDownloadIdle) [sTasks removeObjectForKey:key];
        }
        NSString *resolvedToken = sCdnAliases[token] ?: token;
        NSMutableDictionary *entry = sTasks[resolvedToken];
        if (!entry) {
            entry = [@{@"token": resolvedToken, @"received": @0, @"last": @(now),
                       @"ranges": [NSMutableArray new], @"networkBytes": @0, @"source": @"MTProto", @"completed": @NO} mutableCopy];
            sTasks[resolvedToken] = entry;
        }
        if ([entry[@"completed"] boolValue]) return;
        NSDictionary *known = sMetadata[resolvedToken];
        uint64_t totalBytes = [known[@"size"] unsignedLongLongValue];
        NSUInteger cappedChunk = chunk;
        if (totalBytes > 0) {
            if (offset >= totalBytes) return;
            cappedChunk = (NSUInteger)MIN((uint64_t)chunk, totalBytes - offset);
        }
        NSMutableArray<NSValue *> *ranges = entry[@"ranges"];
        uint64_t added = LeadMergeRange(ranges, offset, cappedChunk);
        if (added > 0) {
            entry[@"networkBytes"] = @([entry[@"networkBytes"] unsignedLongLongValue] + added);
            if ([entry[@"networkBytes"] unsignedLongLongValue] > [entry[@"received"] unsignedLongLongValue]) {
                entry[@"source"] = @"MTProto";
                entry[@"received"] = entry[@"networkBytes"];
            }
        }
        entry[@"last"] = @(now);
        NSDictionary *meta = sMetadata[resolvedToken];
        if (meta) {
            entry[@"name"] = meta[@"name"];
            entry[@"total"] = meta[@"size"];
            long long total = [meta[@"size"] longLongValue];
            if (total > 0 && [entry[@"received"] longLongValue] >= total) {
                entry[@"completed"] = @YES;
                entry[@"finishedAt"] = @(now);
            }
        }
        // No percent when Telegram's document size hasn't been identified.
        [self announceLocked];
    });
}

+ (void)registerDocumentId:(int64_t)documentId size:(int64_t)size name:(NSString *)name datacenter:(NSInteger)dc {
    if (documentId == 0 || size <= 0) return;
    NSString *token = [NSString stringWithFormat:@"doc:%lld", (long long)documentId];
    NSString *safeName = name.length ? [name lastPathComponent] : @"Telegram file";
    dispatch_async(sQueue, ^{
        sMetadata[token] = @{@"size": @(size), @"name": safeName, @"dc": @(dc)};
        if (sMetadata.count > 2000) [sMetadata removeObjectForKey:sMetadata.allKeys.firstObject];
        NSMutableDictionary *task = sTasks[token];
        if (task) {
            task[@"name"] = safeName; task[@"total"] = @(size);
            if ([task[@"received"] longLongValue] >= size && ![task[@"completed"] boolValue]) {
                task[@"completed"] = @YES;
                task[@"finishedAt"] = @(CFAbsoluteTimeGetCurrent());
            }
            [self announceLocked];
        }
    });
}

+ (NSDictionary *)snapshotLocked {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kLeadProgressKey]) {
        sSelectedToken = nil;
        return @{};
    }
    NSDictionary *best = sSelectedToken ? sTasks[sSelectedToken] : nil;
    if (best) {
        BOOL completed = [best[@"completed"] boolValue];
        BOOL expired = completed
            ? now - [best[@"finishedAt"] doubleValue] > kLeadFinishHold
            : now - [best[@"last"] doubleValue] > kLeadDownloadIdle;
        if (expired) { best = nil; sSelectedToken = nil; }
    }
    // Only show identified documents: thumbnail/autoplay traffic must not replace
    // the foreground file or make the Live Activity jump back to zero.
    if (!best) {
        for (NSDictionary *task in sTasks.allValues) {
            if ([task[@"total"] longLongValue] <= 0 ||
                [task[@"completed"] boolValue] ||
                now - [task[@"last"] doubleValue] > kLeadDownloadIdle) continue;
            if (!best || [task[@"last"] doubleValue] > [best[@"last"] doubleValue]) best = task;
        }
        sSelectedToken = best[@"token"];
    }
    if (!best) return @{};
    long long total = [best[@"total"] longLongValue];
    long long received = MIN(total, [best[@"received"] longLongValue]);
    NSInteger percent = total > 0 ? (NSInteger)MIN(100, (received * 100.0 / total)) : -1;
    return @{@"name": best[@"name"] ?: @"Telegram file",
             @"received": @(received), @"total": @(total),
             @"percent": @(percent), @"token": best[@"token"] ?: @"",
             @"source": best[@"source"] ?: @"MTProto"};
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
    // Coalesce bursts on the tracker queue; always publish the newest snapshot.
    // Never enqueue one expensive main-thread UI update per network chunk.
    if (sPublishScheduled) return;
    sPublishScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), sQueue, ^{
        sPublishScheduled = NO;
        NSDictionary *snapshot = [self snapshotLocked];
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        // A periodic resend also recovers an activity that iOS dismissed or
        // didn't display after the first submission, without inventing progress.
        if ([sLastPublished isEqualToDictionary:snapshot] &&
            (!snapshot.count || now - sLastPublishTime < 5.0)) return;
        sLastPublishTime = now;
        sLastPublished = [snapshot copy];
        if (snapshot.count) {
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            [d setObject:[NSDate date] forKey:@"LeadDownloadV4SampleAt"];
            [d setObject:snapshot[@"received"] forKey:@"LeadDownloadV4SampleBytes"];
            [d setObject:snapshot[@"source"] forKey:@"LeadDownloadV4SampleSource"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:LeadDownloadStatusDidChange
                                                                object:nil userInfo:snapshot];
            Class bridge = NSClassFromString(@"LeadDownloadActivityBridge");
            SEL sel = NSSelectorFromString(@"updateWithName:received:total:");
            if (bridge && [bridge respondsToSelector:sel]) {
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(
                    bridge, sel, snapshot[@"name"] ?: @"", snapshot[@"received"] ?: @0,
                    snapshot[@"total"] ?: @0);
            }
            [self backgroundStateRefresh];
        });
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
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                       object:nil queue:[NSOperationQueue mainQueue]
                   usingBlock:^(__unused NSNotification *note) {
        sInBackground = NO;
        [self backgroundStateRefresh];
        dispatch_async(sQueue, ^{ [self announceLocked]; });
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
                                              name:note.userInfo[@"name"]
                                         datacenter:[note.userInfo[@"dc"] integerValue]];
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
    // Use a serial dispatch timer rather than the UI run loop, so reads continue
    // while the process is executing in the background even if UIKit is busy.
    sProgressTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sQueue);
    dispatch_source_set_timer(sProgressTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.75 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(sProgressTimer, ^{
        [self refreshDiskProgressLocked];
        [self announceLocked];
        dispatch_async(dispatch_get_main_queue(), ^{ [self backgroundStateRefresh]; });
    });
    dispatch_resume(sProgressTimer);
}

@end
