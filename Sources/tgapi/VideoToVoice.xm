// Video to Voice — send only the audio track of a picked video.
//
// Telegram builds outgoing media in Swift code that is `private` to
// LegacyMediaPickerUI, so there is nothing to hook there. What *is* reachable
// is the seam feeding it: +[TGMediaAssetsController resultSignalsForSelection
// Context:...] takes a `descriptionGenerator` block, and that block receives a
// plain NSDictionary describing each picked item. Rewriting that dictionary
// from {type: "video", asset: ...} to {type: "file", tempFileUrl: <m4a>} makes
// Telegram send our extracted audio instead of the video, using only public
// Objective-C surface.
//
// The dictionary rewrite alone gets the audio sent, but as a plain document:
// Telegram builds `.file` items with nothing but a filename attribute, and the
// voice flag lives in the `.Audio` attribute it never produces. So each
// extraction also measures the track and hands TLParser a duration and a
// waveform, which rewrites the outgoing messages.sendMedia at the MTProto layer
// into a real voice message.

#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <math.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "Headers.h"
#import "Logger/Logger.h"
#import "UI/Headers.h"
#import "VideoNoteCrop.h"
#import "LeadMXMediaCompat.h"

// Minimal redeclarations of LegacyComponents types. Everything is probed with
// -respondsToSelector: before use, so a host app that renamed or dropped a
// property degrades to "leave the video alone" rather than crashing.
@interface TGMediaAsset : NSObject
@property (nonatomic, readonly) PHAsset *backingAsset;
@property (nonatomic, readonly) NSString *fileName;
@end

@interface TGVideoEditAdjustments : NSObject
@property (nonatomic, readonly) NSTimeInterval trimStartValue;
@property (nonatomic, readonly) NSTimeInterval trimEndValue;
- (bool)trimApplied;
@end

@interface TGMediaEditingContext : NSObject
- (id)adjustmentsForItem:(id)item;
@end

// The preview overlay. Only two methods are hooked: -itemFocused:itemView:,
// which fires whenever the visible item changes, and -layoutSubviews.
@interface TGMediaPickerGalleryInterfaceView : UIView
@end

typedef id (^MxDescriptionGenerator)(id, NSAttributedString *, NSString *, NSString *);

// Extraction runs on whatever queue Telegram assembled the item on, and that
// queue is blocked while it waits. A stuck AVFoundation export must not hang
// the send forever.
static const NSTimeInterval kMxExtractionTimeout = 180.0;

static BOOL mxVideoToVoiceEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kVideoToVoice];
}

static BOOL mxVideoToNoteEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kVideoToNote];
}

static NSString *mxVoiceCacheRoot(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"KiraVideoToVoice"];
}

// Every extraction gets a fresh directory and nothing is ever reused. Sending
// the same video twice therefore cannot pick up the previous run's file, which
// is what used to leave the second send stuck in the wrong mode.
//
// The file name carries a random suffix as well, because it is the only thing
// that identifies this extraction once the request reaches the MTProto layer —
// two clips called IMG_0740 would otherwise share one waveform.
static NSURL *mxNewOutputURL(NSString *baseName) {
    NSString *dir = [mxVoiceCacheRoot()
        stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&error]) {
        mxDiag("v2v: cannot create output dir — %{public}s",
                 error.localizedDescription.UTF8String ?: "unknown");
        return nil;
    }
    NSString *stem = baseName.length ? [baseName stringByDeletingPathExtension] : @"voice";
    NSString *tag = [[[NSUUID UUID] UUIDString] substringToIndex:8];
    NSString *name = [NSString stringWithFormat:@"%@_%@.m4a", stem, tag];
    return [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];
}

// Number of bars Telegram draws in a voice bubble. Its own recorder produces
// 100 five-bit samples, and the drawing code scales whatever it gets to the
// bubble width, so matching that count keeps the bars the usual thickness.
static const NSInteger kMxWaveformSamples = 100;

/// One 0…31 amplitude per bar, measured off the exported track.
///
/// Without this the document goes out with no waveform at all, and the bubble
/// falls back to a row of identical dots — every bar the minimum height,
/// because the drawing code reads an empty sample buffer and leaves every
/// bucket at zero.
static NSData *mxComputeWaveform(AVURLAsset *asset) {
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!track) return nil;

    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (!reader) {
        mxDiag("v2v: waveform reader failed — %{public}s",
                 error.localizedDescription.UTF8String ?: "unknown");
        return nil;
    }

    NSDictionary *settings = @{
        (id)AVFormatIDKey : @(kAudioFormatLinearPCM),
        (id)AVLinearPCMBitDepthKey : @16,
        (id)AVLinearPCMIsBigEndianKey : @NO,
        (id)AVLinearPCMIsFloatKey : @NO,
        (id)AVLinearPCMIsNonInterleavedKey : @NO,
    };
    AVAssetReaderTrackOutput *output =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    if (![reader canAddOutput:output]) return nil;
    [reader addOutput:output];
    if (![reader startReading]) return nil;

    // Peaks are collected over small fixed windows first and only folded into
    // the 100 bars at the end. Bucketing straight away would need the total
    // frame count up front, and an estimate that came out high would leave the
    // tail of the waveform empty.
    static const size_t kWindow = 512;
    NSMutableData *windows = [NSMutableData data];
    uint32_t windowPeak = 0;
    size_t windowFill = 0;

    CMSampleBufferRef sample = NULL;
    while ((sample = [output copyNextSampleBuffer])) {
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        if (block) {
            size_t length = CMBlockBufferGetDataLength(block);
            int16_t *frames = (int16_t *)malloc(length);
            if (frames) {
                if (CMBlockBufferCopyDataBytes(block, 0, length, frames) == kCMBlockBufferNoErr) {
                    size_t count = length / sizeof(int16_t);
                    for (size_t i = 0; i < count; i++) {
                        int32_t value = frames[i];
                        uint32_t magnitude = (uint32_t)(value < 0 ? -value : value);
                        if (magnitude > windowPeak) windowPeak = magnitude;
                        if (++windowFill == kWindow) {
                            [windows appendBytes:&windowPeak length:sizeof(windowPeak)];
                            windowPeak = 0;
                            windowFill = 0;
                        }
                    }
                }
                free(frames);
            }
        }
        CMSampleBufferInvalidate(sample);
        CFRelease(sample);
    }
    [reader cancelReading];
    if (windowFill > 0) {
        [windows appendBytes:&windowPeak length:sizeof(windowPeak)];
    }

    NSInteger windowCount = (NSInteger)(windows.length / sizeof(uint32_t));
    if (windowCount == 0) {
        mxDiag("v2v: no audio frames read — no waveform");
        return nil;
    }

    // Reading per bar rather than per window covers both directions: a long
    // clip folds many windows into one bar, and a clip shorter than the bar
    // count reuses windows instead of leaving gaps.
    const uint32_t *windowPeaks = (const uint32_t *)windows.bytes;
    uint32_t peaks[kMxWaveformSamples];
    for (NSInteger bar = 0; bar < kMxWaveformSamples; bar++) {
        NSInteger from = (bar * windowCount) / kMxWaveformSamples;
        NSInteger to = ((bar + 1) * windowCount) / kMxWaveformSamples;
        if (to <= from) to = from + 1;
        if (to > windowCount) to = windowCount;
        uint32_t peak = 0;
        for (NSInteger i = from; i < to; i++) {
            if (windowPeaks[i] > peak) peak = windowPeaks[i];
        }
        peaks[bar] = peak;
    }

    uint32_t loudest = 0;
    for (NSInteger i = 0; i < kMxWaveformSamples; i++) {
        if (peaks[i] > loudest) loudest = peaks[i];
    }
    if (loudest == 0) {
        mxDiag("v2v: track is silent — no waveform");
        return nil;
    }

    // Scaled against the loudest bar rather than against full scale, so a
    // quietly recorded clip still fills the bubble instead of drawing a flat
    // line near the bottom.
    NSMutableData *result = [NSMutableData dataWithLength:kMxWaveformSamples];
    uint8_t *bars = (uint8_t *)result.mutableBytes;
    for (NSInteger i = 0; i < kMxWaveformSamples; i++) {
        bars[i] = (uint8_t)((peaks[i] * 31 + loudest / 2) / loudest);
    }
    return result;
}

/// Resolves the AVAsset behind a picker dictionary, waiting for iCloud if need be.
static AVAsset *mxResolveAVAsset(NSDictionary *dict) {
    id asset = dict[@"asset"];
    if ([asset respondsToSelector:@selector(backingAsset)]) {
        PHAsset *backing = [asset backingAsset];
        if (![backing isKindOfClass:[PHAsset class]]) return nil;

        PHVideoRequestOptions *options = [[PHVideoRequestOptions alloc] init];
        options.networkAccessAllowed = YES;
        options.deliveryMode = PHVideoRequestOptionsDeliveryModeHighQualityFormat;
        options.version = PHVideoRequestOptionsVersionCurrent;

        __block AVAsset *resolved = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [[PHImageManager defaultManager]
            requestAVAssetForVideo:backing
                           options:options
                     resultHandler:^(AVAsset *avAsset, AVAudioMix *mix, NSDictionary *info) {
                         resolved = avAsset;
                         dispatch_semaphore_signal(done);
                     }];
        dispatch_semaphore_wait(
            done, dispatch_time(DISPATCH_TIME_NOW,
                                (int64_t)(kMxExtractionTimeout * NSEC_PER_SEC)));
        return resolved;
    }

    // Camera captures and already-exported clips arrive as a path instead.
    id rawURL = dict[@"url"];
    NSURL *url = nil;
    if ([rawURL isKindOfClass:[NSURL class]]) {
        url = rawURL;
    } else if ([rawURL isKindOfClass:[NSString class]]) {
        NSString *path = rawURL;
        url = [path hasPrefix:@"file://"] ? [NSURL URLWithString:path]
                                          : [NSURL fileURLWithPath:path];
    }
    if (!url) return nil;
    return [AVURLAsset URLAssetWithURL:url options:nil];
}

/// Reads the preview's trim handles, if the user moved them.
static CMTimeRange mxTrimRange(id editingContext, id item, AVAsset *asset) {
    CMTimeRange full = CMTimeRangeMake(kCMTimeZero, asset.duration);
    if (![editingContext respondsToSelector:@selector(adjustmentsForItem:)] || !item) {
        return full;
    }

    id adjustments = nil;
    @try {
        adjustments = [editingContext adjustmentsForItem:item];
    } @catch (NSException *e) {
        return full;
    }
    if (![adjustments respondsToSelector:@selector(trimApplied)] ||
        ![adjustments respondsToSelector:@selector(trimStartValue)] ||
        ![adjustments respondsToSelector:@selector(trimEndValue)]) {
        return full;
    }
    if (![adjustments trimApplied]) return full;

    NSTimeInterval start = [adjustments trimStartValue];
    NSTimeInterval end = [adjustments trimEndValue];
    if (!(end > start)) return full;

    CMTime cmStart = CMTimeMakeWithSeconds(start, NSEC_PER_SEC);
    CMTime cmEnd = CMTimeMakeWithSeconds(end, NSEC_PER_SEC);
    mxDiag("v2v: trim %.2f..%.2f", start, end);
    return CMTimeRangeFromTimeToTime(cmStart, cmEnd);
}

/// Exports the audio track as m4a. Returns nil and leaves the video untouched
/// on any failure, including a video that has no audio at all.
static NSURL *mxExtractAudio(AVAsset *asset, CMTimeRange range, NSString *baseName) {
    if ([asset tracksWithMediaType:AVMediaTypeAudio].count == 0) {
        mxDiag("v2v: source has no audio track");
        MxShowToast([MxLocalization localizedStringForKey:@"VIDEO_TO_VOICE_NO_AUDIO"]);
        return nil;
    }

    NSURL *output = mxNewOutputURL(baseName);
    if (!output) return nil;

    AVAssetExportSession *session =
        [[AVAssetExportSession alloc] initWithAsset:asset
                                         presetName:AVAssetExportPresetAppleM4A];
    if (!session) {
        mxDiag("v2v: AppleM4A preset unavailable for this asset");
        return nil;
    }
    session.outputURL = output;
    session.outputFileType = AVFileTypeAppleM4A;
    session.timeRange = range;

    MxShowToast([MxLocalization localizedStringForKey:@"VIDEO_TO_VOICE_EXTRACTING"]);

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [session exportAsynchronouslyWithCompletionHandler:^{
        dispatch_semaphore_signal(done);
    }];
    if (dispatch_semaphore_wait(
            done, dispatch_time(DISPATCH_TIME_NOW,
                                (int64_t)(kMxExtractionTimeout * NSEC_PER_SEC))) != 0) {
        mxDiag("v2v: export timed out");
        [session cancelExport];
        MxShowToast([MxLocalization localizedStringForKey:@"VIDEO_TO_VOICE_FAILED"]);
        return nil;
    }

    if (session.status != AVAssetExportSessionStatusCompleted) {
        mxDiag("v2v: export failed status=%ld err=%{public}s",
                 (long)session.status,
                 session.error.localizedDescription.UTF8String ?: "none");
        MxShowToast([MxLocalization localizedStringForKey:@"VIDEO_TO_VOICE_FAILED"]);
        return nil;
    }

    mxDiag("v2v: extracted to %{public}s", output.path.UTF8String);

    // Measure the file that was actually written, not the source: the trim has
    // been applied by now, so this is the duration and the shape the recipient
    // will see.
    AVURLAsset *exported = [AVURLAsset URLAssetWithURL:output options:nil];
    NSInteger duration = (NSInteger)llround(CMTimeGetSeconds(exported.duration));
    if (duration < 1) duration = 1;
    NSData *waveform = mxComputeWaveform(exported);
    [TLParser registerVoiceUploadWithFileName:output.lastPathComponent
                                     duration:duration
                                     waveform:waveform];
    mxDiag("v2v: registered %{public}s duration=%ld waveform=%ld bars",
             output.lastPathComponent.UTF8String, (long)duration,
             (long)waveform.length);

    MxShowToast([MxLocalization localizedStringForKey:@"VIDEO_TO_VOICE_SUCCESS"]);
    return output;
}

/// Turns a video item description into an audio-file item description.
/// Returns nil when the item is not a video we can handle, meaning "send as-is".
static NSDictionary *mxRewriteToVoice(id anyDict, id editingContext) {
    if (![anyDict isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = anyDict;

    NSString *type = dict[@"type"];
    if (![type isKindOfClass:[NSString class]]) return nil;
    if (!([type isEqualToString:@"video"] || [type isEqualToString:@"cameraVideo"])) {
        return nil;
    }

    AVAsset *asset = mxResolveAVAsset(dict);
    if (!asset) {
        mxDiag("v2v: could not resolve AVAsset for type=%{public}s", type.UTF8String);
        return nil;
    }

    id item = dict[@"asset"];
    CMTimeRange range = mxTrimRange(editingContext, item, asset);

    NSString *baseName = nil;
    if ([item respondsToSelector:@selector(fileName)]) baseName = [item fileName];
    if (!baseName.length) baseName = dict[@"fileName"];

    NSURL *audioURL = mxExtractAudio(asset, range, baseName);
    if (!audioURL) return nil;

    NSMutableDictionary *rewritten = [dict mutableCopy];
    rewritten[@"type"] = @"file";
    rewritten[@"tempFileUrl"] = audioURL;
    rewritten[@"mimeType"] = @"audio/mp4";
    rewritten[@"fileName"] = audioURL.lastPathComponent;
    // Keys that only mean something for a video would otherwise steer the
    // generator back into its video branch.
    [rewritten removeObjectForKey:@"asset"];
    [rewritten removeObjectForKey:@"adjustments"];
    [rewritten removeObjectForKey:@"isAnimation"];
    [rewritten removeObjectForKey:@"document"];
    [rewritten removeObjectForKey:@"url"];
    [rewritten removeObjectForKey:@"dimensions"];
    [rewritten removeObjectForKey:@"duration"];
    [rewritten removeObjectForKey:@"coverImage"];
    return rewritten;
}

// ------------------------------------------------------------
// Video to Video Note: convert to a square H.264 MP4, then tag the
// outgoing uploaded document with Telegram's round_message video flag.
// This is a *real* Telegram video note, not a circular-looking preview.
// ------------------------------------------------------------
static NSString *mxNoteCacheRoot(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"KiraVideoNotes"];
}

static NSURL *mxNewNoteOutputURL(NSString *baseName) {
    NSString *dir = [mxNoteCacheRoot()
        stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil]) {
        return nil;
    }
    NSString *stem = [baseName isKindOfClass:[NSString class]] && baseName.length
        ? [baseName stringByDeletingPathExtension] : @"video";
    NSString *name = [NSString stringWithFormat:@"kiranote_%@_%@.mp4",
        stem, [[NSUUID UUID] UUIDString]];
    return [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];
}

// Session-only crop state, locked because export can run off the UI queue.
static CGPoint mxNoteCropCenter = {0.5, 0.5};
static CGFloat mxNoteCropZoom = 1.0;
static NSString *mxNoteSelectedAsset = nil;
static NSObject *mxNoteCropLock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}
static id mxNoteReadProperty(id object, NSString *property) {
    if (!object) return nil;
    SEL getter = NSSelectorFromString(property);
    if (![object respondsToSelector:getter]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, getter); }
    @catch (__unused NSException *exception) { return nil; }
}
// Resolve a stable Photos identifier through TGMediaPickerGalleryItem wrappers.
static NSString *mxNoteItemKey(id item) {
    id node = item;
    for (NSInteger i = 0; node && i < 7; ++i) {
        if ([node isKindOfClass:[PHAsset class]]) return [node localIdentifier];
        if ([node isKindOfClass:[NSURL class]]) return [node absoluteString];
        id backing = mxNoteReadProperty(node, @"backingAsset");
        if ([backing isKindOfClass:[PHAsset class]]) return [backing localIdentifier];
        id url = mxNoteReadProperty(node, @"url");
        if ([url isKindOfClass:[NSURL class]]) return [url absoluteString];
        if ([url isKindOfClass:[NSString class]] && [url length]) return url;
        id next = mxNoteReadProperty(node, @"backingItem");
        if (!next || next == node) next = mxNoteReadProperty(node, @"asset");
        if (!next || next == node) next = mxNoteReadProperty(node, @"mediaItem");
        if (next == node) break;
        node = next;
    }
    return nil;
}
static void mxStoreNoteCrop(CGPoint crop, CGFloat zoom, NSString *assetKey) {
    @synchronized (mxNoteCropLock()) {
        mxNoteCropCenter = crop;
        mxNoteCropZoom = isfinite(zoom) ? fmax(1.0, fmin(5.0, zoom)) : 1.0;
        mxNoteSelectedAsset = [assetKey copy];
    }
}
static NSDictionary *mxNoteCropSnapshot(void) {
    @synchronized (mxNoteCropLock()) {
        return @{@"x": @(mxNoteCropCenter.x), @"y": @(mxNoteCropCenter.y),
                 @"zoom": @(mxNoteCropZoom),
                 @"asset": mxNoteSelectedAsset ?: @""};
    }
}

// iOS does not have a single AVAssetExportSession preset for cropped video
// notes. A video composition applies the natural rotation, centers the crop,
// and renders the actual pixels at 640 x 640 before upload.
static NSURL *mxExportRoundVideo(AVAsset *asset, CMTimeRange selectedRange,
                                 NSString *baseName, CGPoint cropCenter,
                                 CGFloat cropZoom) {
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) {
        MxShowToast([MxLocalization localizedStringForKey:@"VIDEO_TO_NOTE_FAILED"]);
        return nil;
    }

    NSTimeInterval originalLength = CMTimeGetSeconds(selectedRange.duration);
    if (!isfinite(originalLength) || originalLength <= 0.0) {
        MxShowToast([MxLocalization localizedStringForKey:@"VIDEO_TO_NOTE_FAILED"]);
        return nil;
    }
    // Telegram limits round video messages to 60 seconds. Respect the chosen
    // preview trim range first, then cap the exported segment to 60 seconds.
    CMTimeRange range = selectedRange;
    if (originalLength > 60.0) {
        range.duration = CMTimeMakeWithSeconds(60.0, 600);
    }

    CGRect original = CGRectMake(0, 0, track.naturalSize.width, track.naturalSize.height);
    CGRect oriented = CGRectApplyAffineTransform(original, track.preferredTransform);
    CGFloat width = fabs(oriented.size.width);
    CGFloat height = fabs(oriented.size.height);
    if (!isfinite(width) || !isfinite(height) || width < 1.0 || height < 1.0) {
        MxShowToast([MxLocalization localizedStringForKey:@"VIDEO_TO_NOTE_FAILED"]);
        return nil;
    }
    static const CGFloat side = 640.0;
    // The preview's circle diameter is (shorter side / cropZoom).
    // Rendering that region into 640x640 zooms the content itself, and
    // guarantees the exported pixels match the circle drawn in the picker.
    CGFloat safeZoom = isfinite(cropZoom) ? fmax(1.0, fmin(5.0, cropZoom)) : 1.0;
    CGFloat scale = MAX(side / width, side / height) * safeZoom;
    // Match the crop picker: center is normalized in the oriented video.
    CGFloat scaledWidth = width * scale;
    CGFloat scaledHeight = height * scale;
    CGFloat centerX = isfinite(cropCenter.x) ? cropCenter.x : 0.5;
    CGFloat centerY = isfinite(cropCenter.y) ? cropCenter.y : 0.5;
    CGFloat cropX = fmax(0, fmin(scaledWidth - side,
                                 centerX * scaledWidth - side / 2.0));
    CGFloat cropY = fmax(0, fmin(scaledHeight - side,
                                 centerY * scaledHeight - side / 2.0));

    // The preferred transform handles all four device orientations. Normalize
    // its transformed bounding box to (0,0), then scale and center-crop.
    CGAffineTransform t = track.preferredTransform;
    t.tx -= CGRectGetMinX(oriented);
    t.ty -= CGRectGetMinY(oriented);
    t.a *= scale; t.b *= scale; t.c *= scale; t.d *= scale;
    t.tx = t.tx * scale - cropX;
    t.ty = t.ty * scale - cropY;

    AVMutableVideoCompositionLayerInstruction *layer =
        [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:track];
    [layer setTransform:t atTime:kCMTimeZero];
    AVMutableVideoCompositionInstruction *instruction =
        [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);
    instruction.layerInstructions = @[layer];

    AVMutableVideoComposition *composition = [AVMutableVideoComposition videoComposition];
    composition.renderSize = CGSizeMake(side, side);
    composition.frameDuration = CMTimeMake(1, 30);
    composition.instructions = @[instruction];

    NSURL *output = mxNewNoteOutputURL(baseName);
    if (!output) return nil;
    AVAssetExportSession *session =
        [[AVAssetExportSession alloc] initWithAsset:asset
                                         presetName:AVAssetExportPresetHighestQuality];
    if (!session || ![session.supportedFileTypes containsObject:AVFileTypeMPEG4]) {
        MxShowToast([MxLocalization localizedStringForKey:@"VIDEO_TO_NOTE_FAILED"]);
        return nil;
    }
    session.outputURL = output;
    session.outputFileType = AVFileTypeMPEG4;
    session.videoComposition = composition;
    session.timeRange = range;
    session.shouldOptimizeForNetworkUse = YES;

    MxShowToast([MxLocalization localizedStringForKey:@"VIDEO_TO_NOTE_CONVERTING"]);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [session exportAsynchronouslyWithCompletionHandler:^{
        dispatch_semaphore_signal(done);
    }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(kMxExtractionTimeout * NSEC_PER_SEC))) != 0) {
        [session cancelExport];
        MxShowToast([MxLocalization localizedStringForKey:@"VIDEO_TO_NOTE_FAILED"]);
        return nil;
    }
    if (session.status != AVAssetExportSessionStatusCompleted) {
        mxDiag("v2note: export failed status=%ld error=%{public}s",
            (long)session.status, session.error.localizedDescription.UTF8String ?: "unknown");
        MxShowToast([MxLocalization localizedStringForKey:@"VIDEO_TO_NOTE_FAILED"]);
        return nil;
    }

    AVURLAsset *exported = [AVURLAsset URLAssetWithURL:output options:nil];
    NSInteger duration = MAX(1, (NSInteger)llround(CMTimeGetSeconds(exported.duration)));
    // Register synchronously, so the MTProto hook cannot race the upload.
    [TLParser registerRoundVideoUploadWithFileName:output.lastPathComponent
                                          duration:duration];
    mxDiag("v2note: registered %{public}s duration=%ld",
        output.lastPathComponent.UTF8String, (long)duration);
    MxShowToast([MxLocalization localizedStringForKey:@"VIDEO_TO_NOTE_SUCCESS"]);
    return output;
}

static NSDictionary *mxRewriteToRoundVideo(id anyDict, id editingContext,
                                             CGPoint cropCenter, CGFloat cropZoom,
                                             NSString *chosenAsset) {
    if (![anyDict isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = anyDict;
    NSString *type = dict[@"type"];
    if (![type isKindOfClass:[NSString class]] ||
        !([type isEqualToString:@"video"] || [type isEqualToString:@"cameraVideo"])) {
        return nil;
    }
    if (chosenAsset.length) {
        NSString *candidate = mxNoteItemKey(dict[@"asset"] ?: dict[@"url"]);
        if (candidate.length && ![candidate isEqualToString:chosenAsset]) {
            return nil; // Different gallery item: do not crop another video.
        }
    }
    AVAsset *asset = mxResolveAVAsset(dict);
    if (!asset) return nil;
    id item = dict[@"asset"];
    CMTimeRange range = mxTrimRange(editingContext, item, asset);
    NSString *baseName = nil;
    if ([item respondsToSelector:@selector(fileName)]) baseName = [item fileName];
    if (!baseName.length) baseName = dict[@"fileName"];

    NSURL *output = mxExportRoundVideo(asset, range, baseName, cropCenter, cropZoom);
    if (!output) return nil; // On failure Telegram sends the original video.

    NSMutableDictionary *rewritten = [dict mutableCopy];
    rewritten[@"type"] = @"file";
    rewritten[@"tempFileUrl"] = output;
    rewritten[@"mimeType"] = @"video/mp4";
    rewritten[@"fileName"] = output.lastPathComponent;
    for (NSString *key in @[@"asset", @"adjustments", @"isAnimation",
                            @"document", @"url", @"dimensions", @"duration",
                            @"coverImage"]) {
        [rewritten removeObjectForKey:key];
    }
    return rewritten;
}

// ============================================================
// The toggle, in the video preview itself.
//
// It used to live only in the Kira menu, which meant turning the feature on
// converted every video sent afterwards until you remembered to turn it back
// off. Here you decide per video, with the clip in front of you.
//
// Placed in the top-left corner, mirroring Telegram's own selection checkmark
// on the right. Everything the picker puts on screen besides that checkmark —
// mute, cover, group, camera — sits along the bottom toolbar, and so does the
// round-video button Swiftgram adds. Nothing can overlap up here.
// ============================================================

#define kMxVoiceButtonTag 8877
#define kMxNoteButtonTag 8878
static const CGFloat kMxVoiceButtonSide = 40.0;

static const void *kMxItemIsVideoKey = &kMxItemIsVideoKey;
static const void *kMxGalleryModeInitializedKey = &kMxGalleryModeInitializedKey;
static const void *kMxFocusedVideoItemKey = &kMxFocusedVideoItemKey;

/// True for a picked video. Fetch-result items wrap the real one, so the
/// backing item is checked too.
static BOOL mxItemIsVideo(id item) {
    if (!item) return NO;
    if ([NSStringFromClass([item class]) containsString:@"Video"]) return YES;

    SEL backing = NSSelectorFromString(@"backingItem");
    if ([item respondsToSelector:backing]) {
        id inner = ((id (*)(id, SEL))objc_msgSend)(item, backing);
        if (inner) return [NSStringFromClass([inner class]) containsString:@"Video"];
    }
    return NO;
}

static void mxStyleVoiceButton(UIButton *button, BOOL enabled) {
    UIImage *icon = [UIImage systemImageNamed:@"waveform"];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:18
                                                        weight:UIImageSymbolWeightSemibold];
    if (cfg && icon) icon = [icon imageByApplyingSymbolConfiguration:cfg];
    [button setImage:icon forState:UIControlStateNormal];
    button.tintColor = [UIColor whiteColor];
    button.backgroundColor = enabled ? [UIColor systemBlueColor]
                                     : [UIColor colorWithWhite:0.0 alpha:0.5];
}

static void mxStyleNoteButton(UIButton *button, BOOL enabled) {
    if (!button) return;
    UIImage *icon = [UIImage systemImageNamed:@"video.circle"];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:21
                                                        weight:UIImageSymbolWeightSemibold];
    if (cfg && icon) icon = [icon imageByApplyingSymbolConfiguration:cfg];
    [button setImage:icon forState:UIControlStateNormal];
    button.tintColor = [UIColor whiteColor];
    button.backgroundColor = enabled ? [UIColor systemBlueColor]
                                     : [UIColor colorWithWhite:0.0 alpha:0.5];
}

@interface MxVoiceToggleTarget : NSObject
+ (instancetype)shared;
@end

@implementation MxVoiceToggleTarget

+ (instancetype)shared {
    static MxVoiceToggleTarget *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [self new]; });
    return instance;
}

- (void)handleTap:(UIButton *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL enabled = ![defaults boolForKey:kVideoToVoice];
    [defaults setBool:enabled forKey:kVideoToVoice];
    [defaults setBool:NO forKey:kVideoToNote];
    mxStoreNoteCrop(CGPointMake(0.5, 0.5), 1.0, nil);
    mxStyleVoiceButton(sender, enabled);
    mxStyleNoteButton((UIButton *)[sender.superview viewWithTag:kMxNoteButtonTag], NO);
    mxDiag("v2v: preview toggle -> %d", enabled);

    MxShowToast([MxLocalization localizedStringForKey:
        enabled ? @"VIDEO_TO_VOICE_ON_TOAST" : @"VIDEO_TO_VOICE_OFF_TOAST"]);

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];
}

// The crop must be approved before note mode is enabled. Telegram's existing
// send button remains the only thing that actually sends the video.
- (void)handleNoteTap:(UIButton *)sender {
    UIView *gallery = sender.superview;
    id item = objc_getAssociatedObject(gallery, kMxFocusedVideoItemKey);
    if (!item) return;
    BOOL selected = mxVideoToNoteEnabled();
    NSDictionary *oldCrop = mxNoteCropSnapshot();
    CGPoint initial = selected
        ? CGPointMake([oldCrop[@"x"] doubleValue], [oldCrop[@"y"] doubleValue])
        : CGPointMake(0.5, 0.5);
    CGFloat initialZoom = selected ? [oldCrop[@"zoom"] doubleValue] : 1.0;
    NSString *assetKey = mxNoteItemKey(item);
    __weak UIView *weakGallery = gallery;

    MxPresentVideoNoteCrop(gallery, item, initial, initialZoom, selected,
                           ^(CGPoint crop, CGFloat zoom) {
        mxStoreNoteCrop(crop, zoom, assetKey);
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:YES forKey:kVideoToNote];
        [defaults setBool:NO forKey:kVideoToVoice];
        UIView *view = weakGallery;
        mxStyleNoteButton((UIButton *)[view viewWithTag:kMxNoteButtonTag], YES);
        mxStyleVoiceButton((UIButton *)[view viewWithTag:kMxVoiceButtonTag], NO);
        MxShowToast([MxLocalization localizedStringForKey:@"VIDEO_TO_NOTE_ON_TOAST"]);
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc]
            initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
    }, ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:NO forKey:kVideoToNote];
        mxStoreNoteCrop(CGPointMake(0.5, 0.5), 1.0, nil);
        UIView *view = weakGallery;
        mxStyleNoteButton((UIButton *)[view viewWithTag:kMxNoteButtonTag], NO);
        MxShowToast([MxLocalization localizedStringForKey:@"VIDEO_TO_NOTE_OFF_TOAST"]);
    });
}

@end

static UIView *mxFindSubviewByClassSubstring(UIView *root, NSString *needle, int depth) {
    if (!root || depth > 6) return nil;
    for (UIView *sub in root.subviews) {
        if ([NSStringFromClass([sub class]) containsString:needle]) return sub;
        UIView *found = mxFindSubviewByClassSubstring(sub, needle, depth + 1);
        if (found) return found;
    }
    return nil;
}

/// Where the button goes.
///
/// Two attempts got this wrong before the source settled it.
///
/// The first placed it at the view's own safeAreaInsets, which come back as
/// zero — the gallery lays its overlay out against insets the controller hands
/// it, not against the view hierarchy — so the button landed under the Dynamic
/// Island and could not be tapped.
///
/// The second mirrored Telegram's selection checkmark onto the opposite edge.
/// That reads well in portrait and is exactly backwards in landscape: the
/// checkmark sits opposite the landscape toolbar, which fills a whole side
/// edge, so "the other side" is precisely the side that is already occupied.
/// Rotating the phone dropped the button on top of the toolbar.
///
/// So: the checkmark's own side, directly below it. That corner is the one
/// Telegram keeps clear in every orientation — the toolbar, the photo counter
/// and the selected-photos strip all cluster on the far side of it.
static CGRect mxVoiceButtonFrame(UIView *interfaceView) {
    CGFloat side = kMxVoiceButtonSide;
    UIWindow *window = interfaceView.window;
    CGRect bounds = interfaceView.bounds;

    UIEdgeInsets safe = interfaceView.safeAreaInsets;
    if (safe.top < 1.0 && window) safe = window.safeAreaInsets;

    // Only reached if the checkmark is gone; the corner opposite the portrait
    // toolbar is the least bad guess.
    CGFloat x = bounds.size.width - safe.right - 8.0 - side;
    CGFloat y = safe.top + 5.0 + side + 8.0;

    UIView *check = mxFindSubviewByClassSubstring(interfaceView, @"CheckButton", 0);
    if (check && !check.hidden && check.bounds.size.height > 0) {
        CGRect frame = [interfaceView convertRect:check.bounds fromView:check];
        x = CGRectGetMidX(frame) - side / 2.0;
        y = CGRectGetMaxY(frame) + 8.0;
    }

    // Whatever the two paths above decided, the result still has to be inside
    // the window's safe area — an overlay taller than the screen would push a
    // perfectly reasonable local coordinate up behind the status bar.
    if (window) {
        CGPoint inWindow = [interfaceView convertPoint:CGPointMake(x, y) toView:window];
        CGFloat minY = window.safeAreaInsets.top + 5.0;
        if (inWindow.y < minY) y += (minY - inWindow.y);
    }

    // And inside the view, so a checkmark near an edge cannot push it off.
    x = MAX(safe.left + 8.0, MIN(x, bounds.size.width - safe.right - 8.0 - side));
    y = MAX(safe.top + 5.0, MIN(y, bounds.size.height - safe.bottom - 8.0 - side));

    return CGRectMake(x, y, side, side);
}

/// Creates the button on first use and keeps its position and state current.
/// Called from -layoutSubviews, so it runs again on every rotation and on every
/// caption-panel resize.
static void mxUpdateVoiceButton(UIView *interfaceView) {
    if (!interfaceView) return;

    BOOL isVideo = [objc_getAssociatedObject(interfaceView, kMxItemIsVideoKey) boolValue];
    UIButton *button = (UIButton *)[interfaceView viewWithTag:kMxVoiceButtonTag];
    UIButton *noteButton = (UIButton *)[interfaceView viewWithTag:kMxNoteButtonTag];

    if (!isVideo) {
        button.hidden = YES;
        noteButton.hidden = YES;
        return;
    }

    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = kMxVoiceButtonTag;
        button.layer.cornerRadius = kMxVoiceButtonSide / 2.0;
        button.clipsToBounds = YES;
        [button addTarget:[MxVoiceToggleTarget shared]
                   action:@selector(handleTap:)
         forControlEvents:UIControlEventTouchUpInside];
        [interfaceView addSubview:button];
    }

    if (!noteButton) {
        noteButton = [UIButton buttonWithType:UIButtonTypeSystem];
        noteButton.tag = kMxNoteButtonTag;
        noteButton.layer.cornerRadius = kMxVoiceButtonSide / 2.0;
        noteButton.clipsToBounds = YES;
        noteButton.accessibilityLabel = @"Send as circular video note";
        [noteButton addTarget:[MxVoiceToggleTarget shared]
                       action:@selector(handleNoteTap:)
             forControlEvents:UIControlEventTouchUpInside];
        [interfaceView addSubview:noteButton];
    }

    button.hidden = NO;
    noteButton.hidden = NO;
    mxStyleVoiceButton(button, mxVideoToVoiceEnabled());
    mxStyleNoteButton(noteButton, mxVideoToNoteEnabled());
    CGRect voiceFrame = mxVoiceButtonFrame(interfaceView);
    CGRect noteFrame = CGRectOffset(voiceFrame, 0, kMxVoiceButtonSide + 8.0);
    UIEdgeInsets safe = interfaceView.safeAreaInsets;
    if (CGRectGetMaxY(noteFrame) > CGRectGetHeight(interfaceView.bounds) - safe.bottom - 8.0) {
        noteFrame.origin.y = MAX(safe.top + 5.0,
                                CGRectGetMinY(voiceFrame) - kMxVoiceButtonSide - 8.0);
    }
    button.frame = voiceFrame;
    noteButton.frame = noteFrame;
    [interfaceView bringSubviewToFront:button];
    [interfaceView bringSubviewToFront:noteButton];

#if MX_DIAG
    // Printed once per placement decision, not per layout pass — layoutSubviews
    // runs on every scrub of the trim handles.
    static CGRect lastFrame = {{0, 0}, {0, 0}};
    if (!CGRectEqualToRect(lastFrame, button.frame)) {
        lastFrame = button.frame;
        UIEdgeInsets viewSafe = interfaceView.safeAreaInsets;
        UIEdgeInsets winSafe = interfaceView.window.safeAreaInsets;
        mxDiag("v2v: button at %.0f,%.0f — viewSafeTop=%.0f windowSafeTop=%.0f",
                 button.frame.origin.x, button.frame.origin.y,
                 viewSafe.top, winSafe.top);
    }
#endif
}

%hook TGMediaPickerGalleryInterfaceView

- (void)itemFocused:(id)item itemView:(id)itemView {
    %orig;
    // Voice and round-note are per-preview choices. The previous build kept
    // both toggles in NSUserDefaults forever; the next clip inherited the
    // prior mode, and tapping the blue voice icon would turn it OFF instead
    // of selecting voice. Start each newly opened gallery in normal mode.
    if (!objc_getAssociatedObject(self, kMxGalleryModeInitializedKey)) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:NO forKey:kVideoToVoice];
        [defaults setBool:NO forKey:kVideoToNote];
        objc_setAssociatedObject(self, kMxGalleryModeInitializedKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    id previous = objc_getAssociatedObject(self, kMxFocusedVideoItemKey);
    NSString *previousKey = mxNoteItemKey(previous);
    NSString *newKey = mxNoteItemKey(item);
    if (previous && previous != item &&
        (!previousKey.length || ![previousKey isEqualToString:newKey])) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:NO forKey:kVideoToVoice];
        [defaults setBool:NO forKey:kVideoToNote];
        mxStoreNoteCrop(CGPointMake(0.5, 0.5), 1.0, nil);
    }
    BOOL isVideo = mxItemIsVideo(item);
    objc_setAssociatedObject(self, kMxFocusedVideoItemKey, isVideo ? item : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kMxItemIsVideoKey, @(isVideo),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    mxUpdateVoiceButton(self);
}

- (void)layoutSubviews {
    %orig;
    mxUpdateVoiceButton(self);
}

// The overlay answers -hitTest: from an explicit allow-list of its own controls
// and returns nil for everything else, so the rest of the screen stays
// transparent to touches and the gallery underneath receives them. A subview
// added from outside is not on that list: the button drew fine and swallowed
// nothing, because every touch on it was handed straight past.
//
// Only points genuinely inside the button are claimed here; everything else
// goes to the original.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIButton *noteButton = (UIButton *)[self viewWithTag:kMxNoteButtonTag];
    if (noteButton && !noteButton.hidden && noteButton.alpha > 0.01) {
        if ([noteButton pointInside:[self convertPoint:point toView:noteButton] withEvent:event]) {
            return noteButton;
        }
    }
    UIButton *button = (UIButton *)[self viewWithTag:kMxVoiceButtonTag];
    if (button && !button.hidden && button.alpha > 0.01) {
        if ([button pointInside:[self convertPoint:point toView:button] withEvent:event]) {
            return button;
        }
    }
    return %orig;
}

%end

%hook TGMediaAssetsController

+ (NSArray *)resultSignalsForSelectionContext:(id)selectionContext
                               editingContext:(id)editingContext
                                       intent:(NSInteger)intent
                                  currentItem:(id)currentItem
                                  storeAssets:(bool)storeAssets
                                convertToJpeg:(bool)convertToJpeg
                         descriptionGenerator:(MxDescriptionGenerator)descriptionGenerator
                             saveEditedPhotos:(bool)saveEditedPhotos {
    BOOL noteMode = mxVideoToNoteEnabled();
    BOOL voiceMode = mxVideoToVoiceEnabled();
    if ((!voiceMode && !noteMode) || !descriptionGenerator) return %orig;
    // Freeze mode and crop for this send; the gallery may close while exporting.
    NSDictionary *noteSelection = noteMode ? mxNoteCropSnapshot() : nil;
    CGPoint crop = CGPointMake([noteSelection[@"x"] doubleValue],
                               [noteSelection[@"y"] doubleValue]);
    CGFloat zoom = noteMode ? [noteSelection[@"zoom"] doubleValue] : 1.0;
    NSString *chosenAsset = noteSelection[@"asset"];

    MxDescriptionGenerator wrapped =
        ^id(id dict, NSAttributedString *caption, NSString *hash, NSString *uniqueId) {
            NSDictionary *rewritten = nil;
            @try {
                rewritten = noteMode
                    ? mxRewriteToRoundVideo(dict, editingContext, crop, zoom, chosenAsset)
                    : mxRewriteToVoice(dict, editingContext);
            } @catch (NSException *e) {
                mxDiag("v2v: rewrite threw — %{public}s", e.reason.UTF8String ?: "?");
            }
            return descriptionGenerator(rewritten ?: dict, caption, hash, uniqueId);
        };

    return %orig(selectionContext, editingContext, intent, currentItem, storeAssets,
                 convertToJpeg, wrapped, saveEditedPhotos);
}

%end

%ctor {
    // Deleting the leftovers is disk work, and a tweak constructor runs inside
    // dyld — before the app has drawn a single frame. Nothing needs the folder
    // gone until the user actually picks a video, so it happens off the launch
    // path. Anything left in there belongs to a previous launch, so no upload
    // can still be reading it.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[NSFileManager defaultManager] removeItemAtPath:mxVoiceCacheRoot() error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:mxNoteCacheRoot() error:nil];
    });

    Class cls = objc_getClass("TGMediaAssetsController");
    if (!cls) {
        mxDiag("v2v: TGMediaAssetsController absent — feature inert in this app");
        return;
    }

    // Reported separately: the preview toggle can be missing while the send
    // path still works, and a silently absent button is otherwise indis-
    // tinguishable from one that never got laid out.
    if (!objc_getClass("TGMediaPickerGalleryInterfaceView")) {
        mxDiag("v2v: TGMediaPickerGalleryInterfaceView absent — no preview button");
    }

#if MX_DIAG
    // The hook below pins one exact selector. If the host app ships a different
    // arity, %hook silently does nothing, so list what is actually there —
    // that turns a silent no-op into a one-line answer in the log. Diagnostic
    // only: copying the method list is not worth doing on every launch.
    unsigned int count = 0;
    Method *methods = class_copyMethodList(object_getClass(cls), &count);
    BOOL matched = NO;
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if (![name hasPrefix:@"resultSignalsForSelectionContext:"]) continue;
        matched = YES;
        mxDiag("v2v: found %{public}s", name.UTF8String);
    }
    free(methods);
    if (!matched) {
        mxDiag("v2v: no resultSignalsForSelectionContext: on TGMediaAssetsController");
    }
#endif

    %init;
}
