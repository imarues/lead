// Lead manual call recording: name and save destination prompt after STOP.
// iOS Photos saving is real. Telegram's bundled share extension is attempted
// directly. We must not silently open the iOS activity sheet when unavailable.
// Never claim an upload succeeded merely because the share UI was presented.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
// Attempt the app's own Telegram share extension; report unavailability.
extern void LeadOpenTelegramSharePicker(NSURL *file, UIViewController *presenter,
    void (^fallback)(NSString *reason));

typedef NS_ENUM(NSInteger, LeadRecordingSaveTarget) {
    LeadRecordingSaveTargetArchive=0,
    LeadRecordingSaveTargetGallery=1,
    LeadRecordingSaveTargetSavedMessages=2,
    LeadRecordingSaveTargetAll=3
};

static NSString *LeadRecordingSafeBaseName(NSString *raw,NSString *fallback) {
    NSString *value=[raw stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if(!value.length)value=fallback;
    NSString *ext=value.pathExtension.lowercaseString;
    if([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"m4a"])
        value=[value stringByDeletingPathExtension];
    NSMutableCharacterSet *forbidden=[[NSCharacterSet controlCharacterSet] mutableCopy];
    [forbidden addCharactersInString:@"/\\:"];
    NSMutableString *clean=[NSMutableString new];
    for(NSUInteger i=0;i<value.length;i++) {
        unichar ch=[value characterAtIndex:i];
        [clean appendString:([forbidden characterIsMember:ch]?@"-":
                             [value substringWithRange:NSMakeRange(i,1)])];
    }
    NSString *result=[clean stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@". \t\n\r"]];
    if(!result.length)result=fallback;
    if(result.length>96) {
        NSRange range=[result rangeOfComposedCharacterSequencesForRange:NSMakeRange(0,96)];
        result=[result substringWithRange:range];
    }
    return result;
}

@interface LeadRecordingSavePrompt : NSObject
@property(nonatomic,strong) NSURL *archiveFile;
@property(nonatomic,strong) NSError *recordingWarning;
@property(nonatomic,weak) UIViewController *origin;
@property(nonatomic,copy) NSString *requestedName;
@property(nonatomic,assign) LeadRecordingSaveTarget target;
@property(nonatomic,assign) BOOL gallerySaved;
@property(nonatomic,copy) NSString *galleryFailure;
- (void)presentForFile:(NSURL *)file warning:(NSError *)warning
             presenter:(UIViewController *)presenter;
@end

@implementation LeadRecordingSavePrompt
- (UIViewController *)presenter {
    UIViewController *top=self.origin;
    if(!top || !top.view.window) {
        UIWindow *window=UIApplication.sharedApplication.keyWindow;
        if(!window) {
            for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if(![scene isKindOfClass:[UIWindowScene class]])continue;
                if(scene.activationState!=UISceneActivationStateForegroundActive)continue;
                for(UIWindow *candidate in ((UIWindowScene *)scene).windows)
                    if(candidate.isKeyWindow){window=candidate;break;}
                if(window)break;
            }
        }
        top=window.rootViewController;
    }
    while(top.presentedViewController)top=top.presentedViewController;
    return top;
}
- (void)notice:(NSString *)title text:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(),^{
        UIViewController *host=[self presenter];
        if(!host) {
            NSLog(@"[LeadCallSave] %@: %@",title,message);
            return;
        }
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:title
            message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"موافق"
            style:UIAlertActionStyleDefault handler:nil]];
        [host presentViewController:alert animated:YES completion:nil];
    });
}
- (void)presentForFile:(NSURL *)file warning:(NSError *)warning
             presenter:(UIViewController *)presenter {
    self.archiveFile=file;self.recordingWarning=warning;self.origin=presenter;
    if(!file.isFileURL || ![[NSFileManager defaultManager] fileExistsAtPath:file.path]) {
        [self notice:@"فشل حفظ التسجيل" text:@"ملف التسجيل غير موجود."];
        return;
    }
    NSString *extension=file.pathExtension.uppercaseString;
    NSString *message=[NSString stringWithFormat:
        @"اكتب اسم التسجيل فقط، وصيغة %@ تنضاف تلقائياً.\nاختيار الرسائل المحفوظة يحاول فتح منتقي محادثات Telegram من دون قائمة مشاركة iOS.",extension];
    if(warning)message=[message stringByAppendingFormat:@"\nملاحظة: %@",warning.localizedDescription];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"اسم تسجيل المكالمة"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    NSString *defaultName=file.lastPathComponent.stringByDeletingPathExtension;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){
        field.text=defaultName;
        field.placeholder=@"اسم التسجيل";
        field.clearButtonMode=UITextFieldViewModeWhileEditing;
        field.returnKeyType=UIReturnKeyDone;
    }];
    __weak UIAlertController *weakAlert=alert;
    NSArray<NSDictionary *> *options=@[
        @{@"title":@"حفظ في الأرشيف",@"target":@(LeadRecordingSaveTargetArchive)},
        @{@"title":@"حفظ في المعرض",@"target":@(LeadRecordingSaveTargetGallery)},
        @{@"title":@"حفظ في الرسائل المحفوظة",@"target":@(LeadRecordingSaveTargetSavedMessages)},
        @{@"title":@"حفظ بالجميع",@"target":@(LeadRecordingSaveTargetAll)}
    ];
    for(NSDictionary *option in options) {
        LeadRecordingSaveTarget target=(LeadRecordingSaveTarget)[option[@"target"] integerValue];
        [alert addAction:[UIAlertAction actionWithTitle:option[@"title"]
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            self.requestedName=weakAlert.textFields.firstObject.text?:@"";
            self.target=target;
            // Allow the naming alert to finish its dismissal before another
            // controller (Telegram's remote share UI) is presented.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(350*NSEC_PER_MSEC)),
                           dispatch_get_main_queue(),^{[self applyChoice];});
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء (يبقى بالأرشيف)"
        style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *host=[self presenter];
    if(host)[host presentViewController:alert animated:YES completion:nil];
    else NSLog(@"[LeadCallSave] no presenter, original remains archived: %@",file.path);
}
- (NSURL *)renameForArchive:(NSError **)error {
    NSURL *url=self.archiveFile;
    if(![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        if(error)*error=[NSError errorWithDomain:@"Lead.RecordingSave" code:1
             userInfo:@{NSLocalizedDescriptionKey:@"ملف التسجيل الأصلي غير موجود."}];
        return nil;
    }
    NSString *stem=LeadRecordingSafeBaseName(self.requestedName,
                                   url.lastPathComponent.stringByDeletingPathExtension);
    NSString *ext=url.pathExtension.lowercaseString;
    NSFileManager *fm=[NSFileManager defaultManager];
    NSURL *folder=[url URLByDeletingLastPathComponent];
    NSURL *chosen=nil;
    for(NSUInteger suffix=1;suffix<=10000;suffix++) {
        NSString *name=suffix==1?stem:
            [NSString stringWithFormat:@"%@ (%lu)",stem,(unsigned long)suffix];
        NSURL *candidate=[folder URLByAppendingPathComponent:
            [name stringByAppendingPathExtension:ext]];
        if([candidate.path isEqualToString:url.path]){chosen=url;break;}
        if(![fm fileExistsAtPath:candidate.path]){chosen=candidate;break;}
    }
    if(!chosen) {
        if(error)*error=[NSError errorWithDomain:@"Lead.RecordingSave" code:2
            userInfo:@{NSLocalizedDescriptionKey:@"تعذر إيجاد اسم غير مستخدم."}];
        return nil;
    }
    if(![chosen.path isEqualToString:url.path] &&
       ![fm moveItemAtURL:url toURL:chosen error:error])return nil;
    self.archiveFile=chosen;
    return chosen;
}
- (void)applyChoice {
    NSError *error=nil;
    NSURL *file=[self renameForArchive:&error];
    if(!file){
        [self notice:@"تعذر تغيير اسم التسجيل"
                text:[NSString stringWithFormat:@"%@\nالملف الأصلي محفوظ بالأرشيف.",
                    error.localizedDescription?:@"خطأ غير معروف."]];
        return;
    }
    if(self.target==LeadRecordingSaveTargetArchive) {
        [self notice:@"تم حفظ التسجيل" text:
            [NSString stringWithFormat:@"انحفظ بالأرشيف باسم %@",file.lastPathComponent]];
    } else if(self.target==LeadRecordingSaveTargetSavedMessages) {
        [self openSavedMessagesShare];
    } else {
        [self saveToGalleryThenContinue];
    }
}
- (void)saveToGalleryThenContinue {
    NSURL *file=self.archiveFile;
    if(![file.pathExtension.lowercaseString isEqualToString:@"mp4"] &&
       ![file.pathExtension.lowercaseString isEqualToString:@"mov"]) {
        self.galleryFailure=@"معرض الصور ما يقبل تسجيل صوت فقط (M4A).";
        [self afterGallery];
        return;
    }
    NSBundle *bundle=NSBundle.mainBundle;
    if(![bundle objectForInfoDictionaryKey:@"NSPhotoLibraryAddUsageDescription"] &&
       ![bundle objectForInfoDictionaryKey:@"NSPhotoLibraryUsageDescription"]) {
        // Never invoke Photos permissions without Info.plist usage strings.
        self.galleryFailure=@"نسخة Telegram ما بيها إذن إضافة الصور المطلوب. بقي الملف بالأرشيف.";
        [self afterGallery];return;
    }
    void (^save)(void)=^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:file];
        } completionHandler:^(BOOL success,NSError *error) {
            dispatch_async(dispatch_get_main_queue(),^{
                self.gallerySaved=success && !error;
                if(!self.gallerySaved)self.galleryFailure=
                    error.localizedDescription?:@"تعذر نقل الفيديو للمعرض.";
                [self afterGallery];
            });
        }];
    };
    PHAuthorizationStatus status=[PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    if(status==PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
            handler:^(PHAuthorizationStatus result) {
                dispatch_async(dispatch_get_main_queue(),^{
                    if(result==PHAuthorizationStatusAuthorized ||
                       result==PHAuthorizationStatusLimited)save();
                    else {
                        self.galleryFailure=@"ما انطيت إذن إضافة الفيديو للمعرض.";
                        [self afterGallery];
                    }
                });
            }];
    } else if(status==PHAuthorizationStatusAuthorized ||
              status==PHAuthorizationStatusLimited)save();
    else {self.galleryFailure=@"إذن المعرض مرفوض؛ التسجيل باقي بالأرشيف.";[self afterGallery];}
}
- (void)afterGallery {
    if(self.target==LeadRecordingSaveTargetAll) {
        // Even if Photos fails, still offer the Telegram transfer.
        [self openSavedMessagesShare];
        return;
    }
    if(self.gallerySaved) {
        NSError *err=nil;
        BOOL deleted=[[NSFileManager defaultManager] removeItemAtURL:self.archiveFile error:&err];
        [self notice:@"تم الحفظ في المعرض"
             text:deleted?@"انحفظ الفيديو بالمعرض باسم التسجيل المختار.":
                [NSString stringWithFormat:@"الفيديو محفوظ بالمعرض، وبقيت نسخة بالأرشيف: %@",
                    err.localizedDescription?:@"" ]];
    } else {
        [self notice:@"تعذر الحفظ في المعرض"
            text:[NSString stringWithFormat:@"%@\nاحتفظت بالتسجيل في الأرشيف باسم %@.",
                self.galleryFailure?:@"خطأ غير معروف",self.archiveFile.lastPathComponent]];
    }
}
- (void)openSavedMessagesShare {
    // Only request Telegram's own recipient chooser. Never surprise the user
    // with a system-wide iOS sharing sheet if the Telegram extension is absent,
    // not registered by the sideload signer, or rejected by the iOS host.
    NSURL *file=self.archiveFile;
    LeadOpenTelegramSharePicker(file,[self presenter],^(NSString *reason) {
        NSString *detail=reason.length?reason:@"هذه النسخة لا تدعم فتح مشاركة Telegram مباشرة.";
        [self notice:@"تعذّر فتح مشاركة Telegram" text:
           [NSString stringWithFormat:
             @"ما انفتحت قائمة محادثات Telegram. السبب التقني: %@\n\nالتسجيل محفوظ بالأرشيف باسم %@، وما انرسل لأي محادثة. تحتاج نسخة Telegram/VoidGram تحتوي ShareExtension مفعّلة حتى يمكن تجربة الاختيار المباشر.",
             detail,self.archiveFile.lastPathComponent]];
    });
}
- (void)openSavedMessagesSystemShare {
    NSURL *file=self.archiveFile;
    UIActivityViewController *share=[[UIActivityViewController alloc]
        initWithActivityItems:@[file] applicationActivities:nil];
    share.popoverPresentationController.sourceView=[self presenter].view;
    share.popoverPresentationController.sourceRect=CGRectMake(20,20,1,1);
    share.completionWithItemsHandler=^(UIActivityType activity,BOOL completed,
                                      NSArray *returned,NSError *error) {
        dispatch_async(dispatch_get_main_queue(),^{
            BOOL keepArchive=(self.target==LeadRecordingSaveTargetAll);
            if(!completed || error) {
                NSString *message=error.localizedDescription?:
                   @"ما اكتملت المشاركة. التسجيل محفوظ بالأرشيف حتى ما يضيع.";
                if(self.gallerySaved)message=[message stringByAppendingString:
                    @"\nنسخة المعرض محفوظة أيضاً."];
                [self notice:@"المشاركة لم تكتمل" text:message];
                return;
            }
            // An iOS share completion does not prove that the upload has
            // reached Telegram's servers. Keep a non-archived backup copy in
            // app caches for recovery before dropping the visible archive.
            if(!keepArchive) {
                NSString *cache=[NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                    NSUserDomainMask,YES).firstObject
                    stringByAppendingPathComponent:@"Lead/RecentSharedCallRecordings"];
                [[NSFileManager defaultManager] createDirectoryAtPath:cache
                    withIntermediateDirectories:YES attributes:nil error:nil];
                NSURL *backup=[NSURL fileURLWithPath:[cache stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"%@-%@",NSUUID.UUID.UUIDString,
                        file.lastPathComponent]]];
                if([[NSFileManager defaultManager] copyItemAtURL:file toURL:backup error:nil])
                    [[NSFileManager defaultManager] removeItemAtURL:file error:nil];
            }
            NSMutableArray *status=[NSMutableArray array];
            if(keepArchive)[status addObject:@"الأرشيف: محفوظ"];
            if(self.gallerySaved)[status addObject:@"المعرض: محفوظ"];
            if(self.galleryFailure)[status addObject:
                [NSString stringWithFormat:@"المعرض: %@",self.galleryFailure]];
            [status addObject:@"المشاركة: اكتملت من iOS. تأكد من ظهور الملف في رسائلك المحفوظة على Telegram."];
            [self notice:@"نتيجة الحفظ" text:[status componentsJoinedByString:@"\n"]];
        });
    };
    UIViewController *host=[self presenter];
    if(host)[host presentViewController:share animated:YES completion:nil];
    else [self notice:@"تعذر فتح المشاركة" text:
         @"ملف التسجيل محفوظ بالأرشيف. افتح الأرشيف وشاركه إلى رسائلك المحفوظة."];
}
@end

void LeadRecordingPresentSaveOptions(NSURL *file,NSError *warning,UIViewController *presenter) {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{
            LeadRecordingPresentSaveOptions(file,warning,presenter);
        });
        return;
    }
    if(!file.isFileURL)return;
    LeadRecordingSavePrompt *prompt=[LeadRecordingSavePrompt new];
    [prompt presentForFile:file warning:warning presenter:presenter];
}
