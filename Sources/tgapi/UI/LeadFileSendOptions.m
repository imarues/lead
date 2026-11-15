// Lead custom document send options (iOS 14+).
// Prompts BEFORE passing a selected Files document back to Telegram.
// Never modifies the original file; a thumbnail is uploaded over the active
// Telegram connection and attached to inputMediaUploadedDocument on the wire.
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import "../Headers.h"
#import "LeadDesign.h"

extern BOOL LeadSendRawRequest(NSData *payload, void (^done)(NSData *result, NSString *error));

static char kLeadFilePickerProxyKey;
static NSMutableSet *gLeadActiveFilePickers;
static void (*gLeadOriginalSetDocumentDelegate)(id, SEL, id) = NULL;
static BOOL gLeadCustomFilePickerHookInstalled = NO;
static const int32_t kLeadUploadSaveFilePart = (int32_t)0xb304a621;
static const int32_t kLeadBoolTrue = (int32_t)0x997275b5;

static void LeadFileInt32(NSMutableData *d, int32_t n) { [d appendBytes:&n length:4]; }
static void LeadFileInt64(NSMutableData *d, int64_t n) { [d appendBytes:&n length:8]; }
static void LeadFileBytes(NSMutableData *d, NSData *value) {
    NSUInteger length = value.length;
    NSUInteger headerSize = length < 254 ? 1 : 4;
    if (length < 254) {
        uint8_t l = (uint8_t)length;
        [d appendBytes:&l length:1];
    } else {
        uint8_t h[] = {254, (uint8_t)(length & 255),
                       (uint8_t)((length >> 8) & 255),
                       (uint8_t)((length >> 16) & 255)};
        [d appendBytes:h length:4];
    }
    [d appendData:value];
    uint8_t zero[3] = {0};
    NSUInteger padding = (4 - (length + headerSize) % 4) % 4;
    if (padding) [d appendBytes:zero length:padding];
}

static NSData *LeadJPEGThumbnail(UIImage *image) {
    if (!image || image.size.width <= 0 || image.size.height <= 0) return nil;
    CGFloat ratio = MIN(1.0, 320.0 / MAX(image.size.width, image.size.height));
    CGSize target = CGSizeMake(MAX(1, round(image.size.width * ratio)),
                               MAX(1, round(image.size.height * ratio)));
    UIGraphicsBeginImageContextWithOptions(target, YES, 1.0);
    [[UIColor whiteColor] setFill];
    UIRectFill((CGRect){CGPointZero, target});
    [image drawInRect:(CGRect){CGPointZero, target}];
    UIImage *thumb = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!thumb) return nil;
    for (CGFloat quality = 0.85; quality >= 0.2; quality -= 0.15) {
        NSData *jpeg = UIImageJPEGRepresentation(thumb, quality);
        if (jpeg.length > 0 && jpeg.length < 190 * 1024) return jpeg;
    }
    return nil;
}

@interface LeadFilePickerProxy : NSObject <UIDocumentPickerDelegate, PHPickerViewControllerDelegate>
@property(nonatomic, strong) id<UIDocumentPickerDelegate> originalDelegate;
@property(nonatomic, strong) UIDocumentPickerViewController *picker;
@property(nonatomic, weak) UIViewController *presenter;
@property(nonatomic, strong) NSURL *sourceURL;
@property(nonatomic, copy) NSString *chosenName;
@property(nonatomic, assign) BOOL selected;
- (void)presentNamePrompt;
@end

@implementation LeadFilePickerProxy

- (UIViewController *)presentationHost {
    UIViewController *host = self.presenter;
    if (!host || !host.view.window) host = LeadTopPresenter();
    if (host == self.picker || !host) host = self.picker.presentingViewController ?: LeadTopPresenter();
    while (host.presentedViewController && !host.presentedViewController.isBeingDismissed
           && host.presentedViewController != self.picker) {
        host = host.presentedViewController;
    }
    return host;
}

- (void)presentAlert:(UIAlertController *)alert {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *host = [self presentationHost];
        if (!host) {
            [self deliverOriginal];
            return;
        }
        if (host.presentedViewController == self.picker || host == self.picker) {
            [self.picker dismissViewControllerAnimated:YES completion:^{
                [[self presentationHost] presentViewController:alert animated:YES completion:nil];
            }];
        } else {
            [host presentViewController:alert animated:YES completion:nil];
        }
    });
}

- (void)releasePicker {
    UIDocumentPickerViewController *picker = self.picker;
    if (picker && gLeadOriginalSetDocumentDelegate) {
        gLeadOriginalSetDocumentDelegate(picker, @selector(setDelegate:), self.originalDelegate);
        objc_setAssociatedObject(picker, &kLeadFilePickerProxyKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [gLeadActiveFilePickers removeObject:self];
    self.originalDelegate = nil;
    self.picker = nil;
    self.sourceURL = nil;
}

- (void)deliverOriginal {
    id<UIDocumentPickerDelegate> delegate = self.originalDelegate;
    UIDocumentPickerViewController *picker = self.picker;
    NSURL *url = self.sourceURL;
    if (delegate && picker && url) {
        if ([delegate respondsToSelector:@selector(documentPicker:didPickDocumentsAtURLs:)]) {
            [delegate documentPicker:picker didPickDocumentsAtURLs:@[url]];
        } else if ([delegate respondsToSelector:@selector(documentPicker:didPickDocumentAtURL:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [delegate documentPicker:picker didPickDocumentAtURL:url];
#pragma clang diagnostic pop
        }
    }
    [self releasePicker];
}

- (void)deliverWithThumbId:(NSNumber *)thumbId {
    NSString *originalName = self.sourceURL.lastPathComponent ?: @"";
    NSString *newName = self.chosenName.length ? self.chosenName : originalName;
    if ((originalName.length && newName.length && ![newName isEqualToString:originalName]) || thumbId) {
        [TLParser registerCustomFileSendForOriginalName:originalName
                                           displayName:newName
                                       thumbnailFileId:thumbId];
    }
    [self deliverOriginal];
}

- (void)stopWithoutSending {
    // The user explicitly cancelled before Telegram received the selection.
    [self releasePicker];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (self.selected) return; // picker was dismissed to show Lead's prompt
    if ([self.originalDelegate respondsToSelector:@selector(documentPickerWasCancelled:)])
        [self.originalDelegate documentPickerWasCancelled:controller];
    [self releasePicker];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    [self documentPicker:controller didPickDocumentsAtURLs:url ? @[url] : @[]];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (self.selected) return;
    if (urls.count != 1 || !urls.firstObject.isFileURL ||
        ![[NSUserDefaults standardUserDefaults] boolForKey:@"LeadCustomFileSend"]) {
        if ([self.originalDelegate respondsToSelector:@selector(documentPicker:didPickDocumentsAtURLs:)])
            [self.originalDelegate documentPicker:controller didPickDocumentsAtURLs:urls];
        else if (urls.firstObject && [self.originalDelegate respondsToSelector:@selector(documentPicker:didPickDocumentAtURL:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [self.originalDelegate documentPicker:controller didPickDocumentAtURL:urls.firstObject];
#pragma clang diagnostic pop
        }
        [self releasePicker];
        return;
    }

    self.selected = YES;
    self.sourceURL = urls.firstObject;
    self.presenter = controller.presentingViewController ?: LeadTopPresenter();
    NSString *name = self.sourceURL.lastPathComponent ?: @"file";
    NSString *ext = self.sourceURL.pathExtension;
    self.chosenName = ext.length ? [name stringByDeletingPathExtension] : name;
    if (!gLeadActiveFilePickers) gLeadActiveFilePickers = [NSMutableSet new];
    [gLeadActiveFilePickers addObject:self];

    // Do not let Telegram process the selection before customization.
    if (controller.presentingViewController) {
        [controller dismissViewControllerAnimated:YES completion:^{ [self presentNamePrompt]; }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ [self presentNamePrompt]; });
    }
}

- (NSString *)validatedFileName:(NSString *)input {
    NSString *stem = [[input ?: @"" stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                      stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    stem = [stem stringByReplacingOccurrencesOfString:@"\\" withString:@"-"];
    if (stem.length == 0 || [stem isEqualToString:@"."] || [stem isEqualToString:@".."])
        return nil;
    if (stem.length > 70) stem = [stem substringToIndex:70];
    NSString *ext = self.sourceURL.pathExtension;
    if (ext.length && [stem.lowercaseString hasSuffix:[[NSString stringWithFormat:@".%@",ext] lowercaseString]])
        stem = [stem substringToIndex:stem.length-ext.length-1];
    if (stem.length == 0) return nil;
    return ext.length ? [NSString stringWithFormat:@"%@.%@",stem,ext] : stem;
}

- (void)presentNamePrompt {
    if (!self.sourceURL) return;
    NSString *ext = self.sourceURL.pathExtension;
    NSString *hint = ext.length ?
        [NSString stringWithFormat:@"غيّر الاسم بدون الامتداد (.%@)، واختر صورة مصغّرة اختيارياً.",ext] :
        @"غيّر اسم الملف واختر صورة مصغّرة اختيارياً.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"إرسال الملف — Lead"
                                                                   message:hint
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = self.chosenName;
        field.placeholder = @"اسم الملف";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) {
        [weakSelf stopWithoutSending];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"الملف كما هو" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [weakSelf deliverOriginal];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إرسال بدون صورة" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *name = [weakSelf validatedFileName:alert.textFields.firstObject.text];
        if (!name) { [weakSelf presentNamePrompt]; return; }
        weakSelf.chosenName = name;
        [weakSelf deliverWithThumbId:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"اختيار صورة مصغّرة" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *name = [weakSelf validatedFileName:alert.textFields.firstObject.text];
        if (!name) { [weakSelf presentNamePrompt]; return; }
        weakSelf.chosenName = name;
        [weakSelf choosePhoto];
    }]];
    [self presentAlert:alert];
}

- (void)choosePhoto {
    if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.filter = [PHPickerFilter imagesFilter];
        config.selectionLimit = 1;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        picker.delegate = self;
        UIViewController *host = [self presentationHost];
        if (host) [host presentViewController:picker animated:YES completion:nil];
        else [self deliverWithThumbId:nil];
    } else {
        [self deliverWithThumbId:nil];
    }
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14.0)) {
    [picker dismissViewControllerAnimated:YES completion:^{
        if (results.count == 0) { [self presentNamePrompt]; return; }
        NSItemProvider *provider = results.firstObject.itemProvider;
        if (![provider canLoadObjectOfClass:UIImage.class]) {
            [self showThumbnailError:@"تعذر قراءة الصورة المختارة."];
            return;
        }
        [provider loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
            UIImage *image = [object isKindOfClass:UIImage.class] ? (UIImage *)object : nil;
            NSData *jpeg = LeadJPEGThumbnail(image);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!jpeg.length) {
                    [self showThumbnailError:error.localizedDescription ?: @"تعذّر تجهيز الصورة المصغّرة."];
                    return;
                }
                [self uploadThumbnail:jpeg];
            });
        }];
    }];
}

- (void)showThumbnailError:(NSString *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"تعذر إرسال الصورة المصغّرة"
                                                                   message:error ?: @"تعذر رفع الصورة."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"إرسال بدون صورة" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self deliverWithThumbId:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"اختيار صورة ثانية" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self choosePhoto];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) {
        [self stopWithoutSending];
    }]];
    [self presentAlert:alert];
}

- (void)uploadThumbnail:(NSData *)jpeg {
    int64_t fileId = 0;
    arc4random_buf(&fileId, sizeof(fileId));
    NSMutableData *payload = [NSMutableData dataWithCapacity:jpeg.length + 32];
    LeadFileInt32(payload, kLeadUploadSaveFilePart);
    LeadFileInt64(payload, fileId);
    LeadFileInt32(payload, 0); // small JPEG: one part
    LeadFileBytes(payload, jpeg);

    BOOL accepted = LeadSendRawRequest(payload, ^(NSData *result, NSString *error) {
        int32_t signature = 0;
        if (result.length >= 4) [result getBytes:&signature length:4];
        if (error.length || signature != kLeadBoolTrue) {
            [self showThumbnailError:error ?: @"السيرفر رفض رفع الصورة المصغّرة."];
            return;
        }
        [self deliverWithThumbId:@(fileId)];
    });
    if (!accepted) [self showThumbnailError:@"اتصال تيليگرام غير جاهز لرفع الصورة. ممكن ترسل بدون صورة أو تعيد المحاولة."];
}

@end

static void LeadInterceptDocumentDelegate(id picker, SEL selector, id delegate) {
    if (!gLeadOriginalSetDocumentDelegate) return;
    if (!delegate || [delegate isKindOfClass:LeadFilePickerProxy.class] ||
        (NSClassFromString(@"LeadConversionPDFPicker") && [picker isKindOfClass:NSClassFromString(@"LeadConversionPDFPicker")]) ||
        ![[NSUserDefaults standardUserDefaults] boolForKey:@"LeadCustomFileSend"]) {
        gLeadOriginalSetDocumentDelegate(picker, selector, delegate);
        return;
    }

    LeadFilePickerProxy *proxy = [LeadFilePickerProxy new];
    proxy.originalDelegate = delegate;
    proxy.picker = picker;
    objc_setAssociatedObject(picker, &kLeadFilePickerProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gLeadOriginalSetDocumentDelegate(picker, selector, proxy);
}

void LeadInstallFileSendOptions(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = UIDocumentPickerViewController.class;
        SEL selector = @selector(setDelegate:);
        Method m = class_getInstanceMethod(cls, selector);
        if (!m) return;
        IMP original = method_getImplementation(m);
        const char *type = method_getTypeEncoding(m);
        // Ensure an inherited UIKit setter isn't globally replaced.
        if (class_addMethod(cls, selector, original, type))
            m = class_getInstanceMethod(cls, selector);
        gLeadOriginalSetDocumentDelegate = (void (*)(id, SEL, id))method_setImplementation(
            m, (IMP)LeadInterceptDocumentDelegate);
        gLeadCustomFilePickerHookInstalled = gLeadOriginalSetDocumentDelegate != NULL;
        NSLog(@"[Lead] custom file send picker: %@", gLeadCustomFilePickerHookInstalled ? @"on" : @"unavailable");
    });
}
