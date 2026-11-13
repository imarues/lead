// Kira — choose how to send an audio file from Telegram's Files picker.
//
// This sits at the UIDocumentPickerDelegate callback BEFORE Telegram's
// LegacyICloudFileController completion sends the file. No Telegram request
// is created until the user selects a choice. Non-audio stays untouched.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import "Headers.h"
#import "KiraOggSupport.h"

typedef void (*KiraOriginalPickMany)(id, SEL, UIDocumentPickerViewController *, NSArray<NSURL *> *);
typedef void (*KiraOriginalPickOne)(id, SEL, UIDocumentPickerViewController *, NSURL *);

static char kKiraAudioPickManyIMPKey;
static char kKiraAudioPickOneIMPKey;
static char kKiraAudioPickHandledKey;

static IMP kiraInheritedOriginalIMP(Class cls, const void *key) {
    for (Class cur = cls; cur != Nil; cur = class_getSuperclass(cur)) {
        NSValue *wrapped = objc_getAssociatedObject((id)cur, key);
        if (wrapped) return reinterpret_cast<IMP>([wrapped pointerValue]);
    }
    return NULL;
}

static BOOL kiraAudioURLHasRecognizedType(NSURL *url) {
    if (!url.isFileURL) return NO;
    NSString *ext = url.pathExtension.lowercaseString;
    static NSSet<NSString *> *audioExtensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        audioExtensions = [NSSet setWithArray:@[
            @"mp3", @"mp2", @"m4a", @"m4b", @"aac", @"wav", @"wave",
            @"flac", @"ogg", @"oga", @"opus", @"aiff", @"aif", @"caf",
            @"amr", @"alac", @"wma", @"ac3", @"ape", @"dsf", @"dff",
            @"pcm", @"3ga"
        ]];
    });
    if ([audioExtensions containsObject:ext]) return YES;
    if (@available(iOS 14.0, *)) {
        UTType *type = [UTType typeWithFilenameExtension:ext];
        if ([type conformsToType:UTTypeAudio]) return YES;
        id metadata = nil;
        if ([url getResourceValue:&metadata forKey:NSURLContentTypeKey error:nil] &&
            [metadata isKindOfClass:[UTType class]] &&
            [(UTType *)metadata conformsToType:UTTypeAudio]) {
            return YES;
        }
    }
    return NO;
}

static UIViewController *kiraAudioPresenter(UIDocumentPickerViewController *picker) {
    UIWindow *window = picker.viewIfLoaded.window;
    if (!window) window = UIApplication.sharedApplication.keyWindow;
    if (!window) {
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (!w.hidden && w.windowLevel == UIWindowLevelNormal) {
                window = w; break;
            }
        }
    }
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
        top = top.presentedViewController;
    }
    return top && top.isViewLoaded && top.view.window ? top : nil;
}

static NSString *kiraAudioText(NSString *ar, NSString *en) {
    // Follow the host's current language when the app has Arabic UI, then the
    // device as a fallback; neither path depends on old MX bundle settings.
    NSArray<NSString *> *languages = NSLocale.preferredLanguages;
    NSString *lang = languages.firstObject.lowercaseString ?: @"en";
    return [lang hasPrefix:@"ar"] ? ar : en;
}

static void kiraPickerWasCancelled(id delegate, UIDocumentPickerViewController *picker) {
    SEL selector = @selector(documentPickerWasCancelled:);
    if ([delegate respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(delegate, selector, picker);
    } else {
        [picker dismissViewControllerAnimated:YES completion:nil];
    }
}

static void kiraPresentAudioChoice(id delegate,
                                   UIDocumentPickerViewController *picker,
                                   NSArray<NSURL *> *urls,
                                   BOOL single,
                                   BOOL securityStarted) {
    NSCAssert([NSThread isMainThread], @"Audio choice must run on main thread");
    NSURL *source = urls.firstObject;

    __block BOOL completed = NO;
    void (^releaseScope)(void) = ^{
        if (securityStarted) [source stopAccessingSecurityScopedResource];
    };
    void (^forward)(NSURL *) = ^(NSURL *selected) {
        if (completed) return;
        completed = YES;
        IMP original = kiraInheritedOriginalIMP(object_getClass(delegate),
                            single ? &kKiraAudioPickOneIMPKey : &kKiraAudioPickManyIMPKey);
        if (original) {
            if (single) {
                ((KiraOriginalPickOne)original)(delegate,
                    @selector(documentPicker:didPickDocumentAtURL:), picker, selected);
            } else {
                ((KiraOriginalPickMany)original)(delegate,
                    @selector(documentPicker:didPickDocumentsAtURLs:),
                    picker, @[selected]);
            }
        }
        releaseScope();
    };
    void (^cancel)(void) = ^{
        if (completed) return;
        completed = YES;
        kiraPickerWasCancelled(delegate, picker);
        releaseScope();
    };

    UIViewController *presenter = kiraAudioPresenter(picker);
    if (!presenter) {
        // No trusted way to ask before sending: cancel instead of sending
        // automatically or modifying the file without consent.
        cancel();
        return;
    }

    NSString *title = kiraAudioText(@"طريقة إرسال الملف الصوتي", @"Send audio as");
    UIAlertController *choice = [UIAlertController
        alertControllerWithTitle:title
                         message:source.lastPathComponent
                  preferredStyle:UIAlertControllerStyleAlert];

    [choice addAction:[UIAlertAction actionWithTitle:
        kiraAudioText(@"إرساله كملف صوتي", @"Send as audio file")
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            forward(source); // Byte-for-byte original, no format changes.
        }]];

    [choice addAction:[UIAlertAction actionWithTitle:
        kiraAudioText(@"إرساله كفويس", @"Send as voice")
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            // Telegram uses an audio document tagged as a voice message.
            // Convert first so every supported input has a consistent M4A
            // payload; merely changing flags on an MP3/FLAC would be wrong.
            UIViewController *host = kiraAudioPresenter(picker);
            if (!host) { cancel(); return; }
            UIAlertController *progress = [UIAlertController
                alertControllerWithTitle:kiraAudioText(@"جاري تحويل الصوت إلى فويس",
                                                       @"Converting audio to voice")
                                 message:kiraAudioText(@"لم يتم إرسال الملف بعد.",
                                                       @"Your file has not been sent.")
                          preferredStyle:UIAlertControllerStyleAlert];
            // UIAlertAction handlers run while the choice sheet is dismissing.
            // Present progress only after that transition, if still needed.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                           (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!completed && host.view.window && !host.presentedViewController) {
                    [host presentViewController:progress animated:YES completion:nil];
                }
            });

            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSString *dir = [NSTemporaryDirectory()
                    stringByAppendingPathComponent:[NSString stringWithFormat:
                        @"KiraAudioVoice/%@", [NSUUID UUID].UUIDString]];
                [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                          withIntermediateDirectories:YES
                                                           attributes:nil error:nil];
                NSURL *output = [NSURL fileURLWithPath:
                    [dir stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"%@.m4a", [NSUUID UUID].UUIDString]]];

                // Telegram supports Opus-in-Ogg as a native voice format:
                // copy its bytes to a unique .ogg and register real voice
                // metadata, without attempting an unsupported iOS conversion.
                NSString *ext = source.pathExtension.lowercaseString;
                BOOL oggContainer = [@[@"ogg", @"oga", @"opus"] containsObject:ext];
                NSURL *conversionSource = source;
                if (oggContainer) {
                    NSInteger opusDuration = 0;
                    if (KiraOggOpusDuration(source, &opusDuration)) {
                        NSURL *oggOutput = [NSURL fileURLWithPath:
                            [dir stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"%@.ogg", [NSUUID UUID].UUIDString]]];
                        NSError *copyError = nil;
                        if ([[NSFileManager defaultManager] copyItemAtURL:source
                                                                  toURL:oggOutput error:&copyError]) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                void (^sendOgg)(void) = ^{
                                    if (completed) return;
                                    [TLParser registerVoiceUploadWithFileName:oggOutput.lastPathComponent
                                                                     duration:opusDuration
                                                                     waveform:nil];
                                    forward(oggOutput);
                                };
                                if (progress.presentingViewController) {
                                    [progress dismissViewControllerAnimated:YES completion:sendOgg];
                                } else {
                                    sendOgg();
                                }
                            });
                            return;
                        }
                        // Never mislabelel Opus bytes as M4A on copy errors.
                        conversionSource = nil;
                    } else {
                        // Ogg/OGA may contain Vorbis. Stream-decode to WAV,
                        // then use Apple's existing M4A/AAC exporter.
                        conversionSource = KiraDecodeOggVorbisToWAV(source, dir);
                    }
                }

                AVURLAsset *asset = conversionSource
                    ? [AVURLAsset URLAssetWithURL:conversionSource options:nil] : nil;
                NSArray *audioTracks = asset ? [asset tracksWithMediaType:AVMediaTypeAudio] : @[];
                BOOL audioOnly = audioTracks.count > 0 &&
                                 [asset tracksWithMediaType:AVMediaTypeVideo].count == 0;
                AVAssetExportSession *exporter = audioOnly
                    ? [[AVAssetExportSession alloc] initWithAsset:asset
                                                      presetName:AVAssetExportPresetAppleM4A]
                    : nil;
                if (exporter) {
                    exporter.outputURL = output;
                    exporter.outputFileType = AVFileTypeAppleM4A;
                }
                void (^finish)(BOOL) = ^(BOOL ok) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        void (^proceed)(void) = ^{
                            if (completed) return;
                            if (ok && [[NSFileManager defaultManager]
                                      fileExistsAtPath:output.path]) {
                                AVURLAsset *converted = [AVURLAsset
                                    URLAssetWithURL:output options:nil];
                                double durationSeconds = CMTimeGetSeconds(converted.duration);
                                NSInteger duration = (isfinite(durationSeconds) &&
                                                      durationSeconds > 0.0)
                                    ? MAX(1, (NSInteger)llround(durationSeconds)) : 1;
                                [TLParser registerVoiceUploadWithFileName:output.lastPathComponent
                                                                 duration:duration
                                                                 waveform:nil];
                                forward(output);
                                return;
                            }
                            // Unsupported format / decode failure: do not send
                            // a falsely labeled voice message or auto-send.
                            UIViewController *fallbackHost = kiraAudioPresenter(picker);
                            if (!fallbackHost) { cancel(); return; }
                            UIAlertController *failed = [UIAlertController
                                alertControllerWithTitle:
                                    kiraAudioText(@"تعذّر تحويل الصوت", @"Audio conversion failed")
                                                 message:kiraAudioText(
                                    @"هذه الصيغة غير مدعومة للتحويل بواسطة iOS. تگدر ترسل الملف الأصلي بدون تغيير.",
                                    @"iOS cannot convert this format. You can send the original file unchanged.")
                                          preferredStyle:UIAlertControllerStyleAlert];
                            [failed addAction:[UIAlertAction actionWithTitle:
                                kiraAudioText(@"إرساله كملف صوتي", @"Send original audio file")
                                style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *b) {
                                    forward(source);
                                }]];
                            [failed addAction:[UIAlertAction actionWithTitle:
                                kiraAudioText(@"إلغاء", @"Cancel")
                                style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *b) {
                                    cancel();
                                }]];
                            [fallbackHost presentViewController:failed animated:YES completion:nil];
                        };
                        if (progress.presentingViewController) {
                            [progress dismissViewControllerAnimated:YES completion:proceed];
                        } else {
                            proceed();
                        }
                    });
                };
                if (!exporter) { finish(NO); return; }
                [exporter exportAsynchronouslyWithCompletionHandler:^{
                    finish(exporter.status == AVAssetExportSessionStatusCompleted);
                }];
                // Never leave the document picker blocked forever if a cloud
                // provider or AVFoundation stalls on a malformed source.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(120 * NSEC_PER_SEC)),
                    dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        if (exporter.status == AVAssetExportSessionStatusExporting ||
                            exporter.status == AVAssetExportSessionStatusWaiting) {
                            [exporter cancelExport];
                        }
                    });
            });
        }]];

    [choice addAction:[UIAlertAction actionWithTitle:
        kiraAudioText(@"إلغاء", @"Cancel")
        style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) {
            cancel();
        }]];
    [presenter presentViewController:choice animated:YES completion:nil];
}

static void kiraPicked(id delegate, UIDocumentPickerViewController *picker,
                       NSArray<NSURL *> *urls, BOOL single) {
    IMP original = kiraInheritedOriginalIMP(object_getClass(delegate),
                       single ? &kKiraAudioPickOneIMPKey : &kKiraAudioPickManyIMPKey);
    if (!original) return;

    // Show a choice for audio only while the setting is enabled.
    // With the setting off, use Telegram's ordinary document picker.
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kSendAsVoice]) {
        if (single) {
            ((KiraOriginalPickOne)original)(delegate,
                @selector(documentPicker:didPickDocumentAtURL:), picker, urls.firstObject);
        } else {
            ((KiraOriginalPickMany)original)(delegate,
                @selector(documentPicker:didPickDocumentsAtURLs:), picker, urls);
        }
        return;
    }

    if (single && urls.count == 0) { kiraPickerWasCancelled(delegate, picker); return; }
    if (urls.count != 1 || ![urls.firstObject isKindOfClass:[NSURL class]] ||
        ![(NSURL *)urls.firstObject isFileURL]) {
        if (single) {
            ((KiraOriginalPickOne)original)(delegate,
                @selector(documentPicker:didPickDocumentAtURL:), picker, urls.firstObject);
        } else {
            ((KiraOriginalPickMany)original)(delegate,
                @selector(documentPicker:didPickDocumentsAtURLs:), picker, urls);
        }
        return;
    }
    // One result per picker; double notifications must not send twice.
    if (objc_getAssociatedObject(picker, &kKiraAudioPickHandledKey)) return;
    objc_setAssociatedObject(picker, &kKiraAudioPickHandledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSURL *url = urls.firstObject;
    BOOL securityStarted = [url startAccessingSecurityScopedResource];

    // Detect supported UTI/extensions immediately; for unfamiliar extensions,
    // inspect the actual media streams without blocking the UI.
    void (^handle)(BOOL) = ^(BOOL recognized) {
        if (!recognized) {
            if (single) {
                ((KiraOriginalPickOne)original)(delegate,
                    @selector(documentPicker:didPickDocumentAtURL:), picker, url);
            } else {
                ((KiraOriginalPickMany)original)(delegate,
                    @selector(documentPicker:didPickDocumentsAtURLs:), picker, urls);
            }
            if (securityStarted) [url stopAccessingSecurityScopedResource];
            return;
        }
        kiraPresentAudioChoice(delegate, picker, urls, single, securityStarted);
    };
    if (kiraAudioURLHasRecognizedType(url)) {
        handle(YES);
    } else {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
            BOOL recognized = [asset tracksWithMediaType:AVMediaTypeAudio].count > 0 &&
                              [asset tracksWithMediaType:AVMediaTypeVideo].count == 0;
            dispatch_async(dispatch_get_main_queue(), ^{ handle(recognized); });
        });
    }
}

static void kiraDidPickMany(id delegate, SEL selector,
                            UIDocumentPickerViewController *picker,
                            NSArray<NSURL *> *urls) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            kiraDidPickMany(delegate, selector, picker, urls);
        });
        return;
    }
    kiraPicked(delegate, picker, urls, NO);
}

static void kiraDidPickOne(id delegate, SEL selector,
                           UIDocumentPickerViewController *picker, NSURL *url) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            kiraDidPickOne(delegate, selector, picker, url);
        });
        return;
    }
    kiraPicked(delegate, picker, url ? @[url] : @[], YES);
}

static void kiraInstallPickerDelegateHooks(Class cls) {
    if (!cls) return;
    NSString *name = NSStringFromClass(cls);
    // Only Telegram's Files attachment delegate. Other document pickers,
    // including certificate/file utilities, are intentionally unaffected.
    // MX uses "LegacyICloudFileController"; Lead's current picker is
    // "LegacyMediaPickerUIICloudFileController". Accept both, but do not
    // touch unrelated system/document pickers.
    BOOL mxLegacy = [name containsString:@"LegacyICloudFileController"];
    BOOL leadLegacy = [name containsString:@"LegacyMediaPickerUI"] &&
                      [name containsString:@"ICloudFileController"];
    if (!mxLegacy && !leadLegacy)
        return;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        Method method = methods[i];
        SEL selector = method_getName(method);
        if (sel_isEqual(selector, @selector(documentPicker:didPickDocumentsAtURLs:)) &&
            !objc_getAssociatedObject((id)cls, &kKiraAudioPickManyIMPKey)) {
            IMP original = method_setImplementation(method, (IMP)kiraDidPickMany);
            objc_setAssociatedObject((id)cls, &kKiraAudioPickManyIMPKey,
                                     [NSValue valueWithPointer:reinterpret_cast<const void *>(original)],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (sel_isEqual(selector, @selector(documentPicker:didPickDocumentAtURL:)) &&
                   !objc_getAssociatedObject((id)cls, &kKiraAudioPickOneIMPKey)) {
            IMP original = method_setImplementation(method, (IMP)kiraDidPickOne);
            objc_setAssociatedObject((id)cls, &kKiraAudioPickOneIMPKey,
                                     [NSValue valueWithPointer:reinterpret_cast<const void *>(original)],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    free(methods);
}

%hook UIDocumentPickerViewController
- (void)setDelegate:(id<UIDocumentPickerDelegate>)delegate {
    // Install before delivering the first picked URL; the real Swift delegate
    // remains intact and is called exactly once after user confirmation.
    kiraInstallPickerDelegateHooks(object_getClass(delegate));
    %orig;
}
%end
