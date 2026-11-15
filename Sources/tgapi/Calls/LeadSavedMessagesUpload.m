// Nonblocking MTProto file sending for Lead call recordings.
//
// The destination is explicitly selected by the user in the in-app chat list.
// File parts and messages.sendMedia use Telegram's existing active connection,
// never a separate account login. A shared manager retains transfers while
// the picker is dismissed and the user navigates other chats.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "LeadSavedMessagesUpload.h"

extern BOOL LeadSendRawRequest(NSData *payload, void (^done)(NSData *result, NSString *error));

// TL constructors (layer of Telegram 13.x; taken from api_sources where present).
#define kLeadTLSaveFilePart        ((int32_t)0xb304a621)  // upload.saveFilePart
#define kLeadTLSaveBigFilePart     ((int32_t)0xde7b673d)  // upload.saveBigFilePart
#define kLeadTLSendMedia           ((int32_t)53536639)    // messages.sendMedia
#define kLeadTLInputPeerSelf       ((int32_t)2107670217)  // inputPeerSelf
#define kLeadTLUploadedDocument    ((int32_t)58495792)    // inputMediaUploadedDocument
#define kLeadTLInputFile           ((int32_t)-181407105)  // inputFile
#define kLeadTLInputFileBig        ((int32_t)-95482955)   // inputFileBig
#define kLeadTLVector              ((int32_t)481674261)   // vector
#define kLeadTLAttrFilename        ((int32_t)358154344)   // documentAttributeFilename
#define kLeadTLAttrVideo           ((int32_t)1137015880)  // documentAttributeVideo
#define kLeadTLAttrAudio           ((int32_t)-1739392570) // documentAttributeAudio
#define kLeadTLBoolTrue            ((int32_t)0x997275b5)  // boolTrue

// Telegram's maximum supported individual upload part is 512 KiB; using full
// parts halves per-part RPC overhead without changing/compressing file bytes.
static const NSUInteger kLeadPartSize = 512 * 1024;
static const unsigned long long kLeadBigFileThreshold = 10ull * 1024 * 1024;
// Keep enough requests in flight to cover connection round-trip time while
// bounding upload buffer pressure to approximately four MiB per transfer.
static const NSUInteger kLeadWindow = 8;
static const int kLeadPartRetries = 3;

#pragma mark - TL writers

static void TLInt32(NSMutableData *d, int32_t v) { [d appendBytes:&v length:4]; }
static void TLInt64(NSMutableData *d, int64_t v) { [d appendBytes:&v length:8]; }
static void TLDouble(NSMutableData *d, double v) { [d appendBytes:&v length:8]; }
static void TLBytes(NSMutableData *d, NSData *bytes) {
    NSUInteger length = bytes.length, header;
    if (length < 254) {
        uint8_t l = (uint8_t)length;
        [d appendBytes:&l length:1];
        header = 1;
    } else {
        uint8_t h[4] = {254, (uint8_t)(length & 0xff), (uint8_t)((length >> 8) & 0xff),
                        (uint8_t)((length >> 16) & 0xff)};
        [d appendBytes:h length:4];
        header = 4;
    }
    [d appendData:bytes];
    NSUInteger pad = (4 - ((header + length) % 4)) % 4;
    if (pad) {
        uint8_t zero[3] = {0, 0, 0};
        [d appendBytes:zero length:pad];
    }
}
static void TLString(NSMutableData *d, NSString *s) {
    TLBytes(d, [(s ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]);
}

#pragma mark - Uploader

@interface LeadSavedMessagesUpload ()
@property(nonatomic, strong) NSFileHandle *handle;
@property(nonatomic, copy) NSData *targetPeer;
@property(nonatomic, copy) NSString *fileName;
@property(nonatomic, copy) NSString *mimeType;
@property(nonatomic, strong) NSData *attributes;   // vector body: count + items
@property(nonatomic, assign) int32_t attributeCount;
@property(nonatomic, assign) int64_t fileId;
@property(nonatomic, assign) BOOL big;
@property(nonatomic, assign) NSUInteger totalParts;
@property(nonatomic, assign) NSUInteger nextPart;
@property(nonatomic, assign) NSUInteger finishedParts;
@property(nonatomic, assign) NSUInteger inFlight;
@property(nonatomic, assign) BOOL finished;
@property(nonatomic, assign) BOOL cancelled;
@property(nonatomic, copy) void (^progress)(double);
@property(nonatomic, copy) void (^completion)(NSString *);
@end

// Required: keep an upload alive even when there is no modal holding it.
static NSMutableSet<LeadSavedMessagesUpload *> *gActiveLeadUploads;
@implementation LeadSavedMessagesUpload

+ (instancetype)startWithFile:(NSURL *)file
                     progress:(void (^)(double))progress
                   completion:(void (^)(NSString *))completion {
    int32_t selfConstructor=kLeadTLInputPeerSelf;
    NSData *selfPeer=[NSData dataWithBytes:&selfConstructor length:4];
    return [self startWithFile:file peerData:selfPeer progress:progress completion:completion];
}

+ (instancetype)startWithFile:(NSURL *)file
                    peerData:(NSData *)peerData
                    progress:(void (^)(double))progress
                  completion:(void (^)(NSString *))completion {
    LeadSavedMessagesUpload *upload = [LeadSavedMessagesUpload new];
    upload.targetPeer = [peerData copy];
    upload.progress = progress;
    upload.completion = completion;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gActiveLeadUploads) gActiveLeadUploads=[NSMutableSet new];
        [gActiveLeadUploads addObject:upload];
        [upload begin:file];
    });
    return upload;
}

- (void)cancel {
    self.cancelled = YES;
    if (self.inFlight == 0) [self finishWithError:@"cancelled"];
}

- (void)finishWithError:(NSString *)error {
    if (self.finished) return;
    self.finished = YES;
    [self.handle closeFile];
    self.handle = nil;
    void (^done)(NSString *) = self.completion;
    self.completion = nil;
    self.progress = nil;
    if (done) done(error);
    [gActiveLeadUploads removeObject:self];
}

- (void)describeFile:(NSURL *)file {
    NSString *ext = file.pathExtension.lowercaseString;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:file options:nil];
    double seconds = CMTimeGetSeconds(asset.duration);
    if (!isfinite(seconds) || seconds < 0) seconds = 0;
    NSMutableData *items = [NSMutableData data];
    int32_t count = 0;
    BOOL video = [ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"];
    if (video) {
        int32_t w = 720, h = 1280;
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (track) {
            CGSize size = CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform);
            if (fabs(size.width) >= 1 && fabs(size.height) >= 1) {
                w = (int32_t)llround(fabs(size.width));
                h = (int32_t)llround(fabs(size.height));
            }
        }
        TLInt32(items, kLeadTLAttrVideo);
        TLInt32(items, 1 << 1);            // supports_streaming
        TLDouble(items, seconds);
        TLInt32(items, w);
        TLInt32(items, h);
        count++;
        self.mimeType = @"video/mp4";
    } else {
        TLInt32(items, kLeadTLAttrAudio);
        TLInt32(items, 0);                 // regular audio file, not a voice note
        TLInt32(items, (int32_t)llround(seconds));
        count++;
        self.mimeType = @"audio/mp4";
    }
    TLInt32(items, kLeadTLAttrFilename);
    TLString(items, file.lastPathComponent);
    count++;
    self.attributes = items;
    self.attributeCount = count;
    self.fileName = file.lastPathComponent;
}

- (void)begin:(NSURL *)file {
    if (self.finished) return;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:file.path error:nil];
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    if (!file.isFileURL || size == 0) {
        [self finishWithError:@"ملف التسجيل غير موجود أو فارغ."];
        return;
    }
    if (size > 2000ull * 1024 * 1024) {
        [self finishWithError:@"الملف أكبر من 2 GB."];
        return;
    }
    NSError *error = nil;
    self.handle = [NSFileHandle fileHandleForReadingFromURL:file error:&error];
    if (!self.handle) {
        [self finishWithError:error.localizedDescription ?: @"تعذر فتح ملف التسجيل."];
        return;
    }
    [self describeFile:file];
    uint64_t random = 0;
    arc4random_buf(&random, sizeof(random));
    self.fileId = (int64_t)random;
    self.big = size >= kLeadBigFileThreshold;
    self.totalParts = (NSUInteger)((size + kLeadPartSize - 1) / kLeadPartSize);
    [self pump];
}

- (void)pump {
    if (self.finished) return;
    if (self.cancelled) {
        if (self.inFlight == 0) [self finishWithError:@"cancelled"];
        return;
    }
    while (!self.finished && !self.cancelled && self.inFlight < kLeadWindow &&
           self.nextPart < self.totalParts) {
        [self sendPart:self.nextPart++ attempt:0];
    }
}

- (void)sendPart:(NSUInteger)index attempt:(int)attempt {
    NSError *error = nil;
    NSData *chunk = nil;
    if ([self.handle seekToOffset:(unsigned long long)index * kLeadPartSize error:&error])
        chunk = [self.handle readDataUpToLength:kLeadPartSize error:&error];
    if (!chunk.length) {
        [self finishWithError:error.localizedDescription ?: @"تعذرت قراءة ملف التسجيل."];
        return;
    }
    NSMutableData *payload = [NSMutableData dataWithCapacity:chunk.length + 32];
    TLInt32(payload, self.big ? kLeadTLSaveBigFilePart : kLeadTLSaveFilePart);
    TLInt64(payload, self.fileId);
    TLInt32(payload, (int32_t)index);
    if (self.big) TLInt32(payload, (int32_t)self.totalParts);
    TLBytes(payload, chunk);

    self.inFlight++;
    BOOL queued = LeadSendRawRequest(payload, ^(NSData *result, NSString *rpcError) {
        self.inFlight--;
        if (self.finished) return;
        int32_t constructor = 0;
        if (result.length >= 4) [result getBytes:&constructor length:4];
        BOOL ok = !rpcError && constructor == kLeadTLBoolTrue;
        if (!ok) {
            if (!self.cancelled && attempt < kLeadPartRetries &&
                ![rpcError hasPrefix:@"FLOOD_WAIT"] && ![rpcError hasPrefix:@"FILE_PARTS_INVALID"]) {
                [self sendPart:index attempt:attempt + 1];
                return;
            }
            [self finishWithError:rpcError.length ?
                [NSString stringWithFormat:@"رفض Telegram جزء الملف: %@", rpcError] :
                @"فشل رفع جزء من التسجيل."];
            return;
        }
        self.finishedParts++;
        if (self.progress) self.progress((double)self.finishedParts / (double)self.totalParts);
        if (self.cancelled) {
            if (self.inFlight == 0) [self finishWithError:@"cancelled"];
            return;
        }
        if (self.finishedParts == self.totalParts) [self sendMedia];
        else [self pump];
    });
    if (!queued) {
        self.inFlight--;
        [self finishWithError:@"ما كو اتصال Telegram جاهز بعد. افتح أي محادثة وانتظر ثانيتين، وبعدين جرّب."];
    }
}

- (void)sendMedia {
    NSMutableData *p = [NSMutableData data];
    TLInt32(p, kLeadTLSendMedia);
    TLInt32(p, 0);                          // flags: no reply, silent, schedule...
    if(self.targetPeer.length < 4 || self.targetPeer.length > 64 ||
       (self.targetPeer.length % 4) != 0) {
        [self finishWithError:@"وجهة الإرسال غير صالحة."];
        return;
    }
    [p appendData:self.targetPeer];           // chosen InputPeer
    TLInt32(p, kLeadTLUploadedDocument);
    TLInt32(p, 0);                          // flags: no thumb / stickers / ttl
    if (self.big) {
        TLInt32(p, kLeadTLInputFileBig);
        TLInt64(p, self.fileId);
        TLInt32(p, (int32_t)self.totalParts);
        TLString(p, self.fileName);
    } else {
        TLInt32(p, kLeadTLInputFile);
        TLInt64(p, self.fileId);
        TLInt32(p, (int32_t)self.totalParts);
        TLString(p, self.fileName);
        TLString(p, @"");                   // md5_checksum (optional for the server)
    }
    TLString(p, self.mimeType);
    TLInt32(p, kLeadTLVector);
    TLInt32(p, self.attributeCount);
    [p appendData:self.attributes];
    TLString(p, @"");                       // message / caption
    uint64_t random = 0;
    arc4random_buf(&random, sizeof(random));
    TLInt64(p, (int64_t)random);            // random_id

    BOOL queued = LeadSendRawRequest(p, ^(NSData *result, NSString *rpcError) {
        if (self.finished) return;
        if (rpcError || result.length < 4) {
            [self finishWithError:[NSString stringWithFormat:@"رفض Telegram إرسال الرسالة: %@",
                                   rpcError ?: @"رد فارغ"]];
            return;
        }
        if (self.progress) self.progress(1.0);
        [self finishWithError:nil];
    });
    if (!queued) [self finishWithError:@"انقطع اتصال Telegram قبل إرسال الرسالة."];
}

@end
