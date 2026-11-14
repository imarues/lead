// Experimental Telegram-only recording share picker.
// Telegram's actual ShareController is Swift-only and cannot be constructed
// safely from a Logos/ObjC dylib without its AccountContext Swift types.
// Try the application's OWN ShareExtension UI via the guarded iOS extension
// host interface, falling back to the previous iOS activity sheet if not
// available. No messages are sent without the user's explicit confirmation.
// This is private iOS host API and is intentionally isolated in one file.
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

@interface LeadTelegramNativeShareAttempt : NSObject
@property(nonatomic,strong) NSURL *file;
@property(nonatomic,weak) UIViewController *origin;
@property(nonatomic,strong) id extension;
@property(nonatomic,strong) UIViewController *remote;
@property(nonatomic,copy) void (^fallback)(NSString *reason);
@property(nonatomic,assign) BOOL finished;
@property(nonatomic,assign) BOOL presented;
- (void)begin;
@end

static LeadTelegramNativeShareAttempt *gActiveTelegramShare=nil;

@implementation LeadTelegramNativeShareAttempt

- (void)finishWithFallback:(NSString *)reason {
    if(self.finished)return;
    self.finished=YES;
    NSLog(@"[LeadTelegramShare] direct extension host unavailable: %@",reason);
    @synchronized([LeadTelegramNativeShareAttempt class]) {
        if(gActiveTelegramShare==self)gActiveTelegramShare=nil;
    }
    void (^callback)(NSString *)=self.fallback;
    self.fallback=nil;
    self.extension=nil;
    if(callback)dispatch_async(dispatch_get_main_queue(),^{callback(reason?:@"تعذّر تشغيل إضافة مشاركة Telegram");});
}
- (void)complete:(BOOL)success {
    if(self.finished)return;
    self.finished=YES;
    NSLog(@"[LeadTelegramShare] Telegram share UI completed=%d; actual upload must be checked in Telegram",success);
    // Do not delete the call recording on extension UI completion.
    // A completed UI request does not prove a server-side upload.
    @synchronized([LeadTelegramNativeShareAttempt class]) {
        if(gActiveTelegramShare==self)gActiveTelegramShare=nil;
    }
    if(self.remote.presentingViewController) {
        [self.remote dismissViewControllerAnimated:YES completion:nil];
    }
    self.remote=nil;
    self.extension=nil;
    self.fallback=nil;
}
- (NSBundle *)findOwnShareExtension {
    // Inspect only the Telegram/VoidGram application's bundled extension.
    // Never launch arbitrary system-registered third-party share extensions.
    NSString *path=NSBundle.mainBundle.builtInPlugInsPath;
    if(!path.length)return nil;
    NSArray<NSString *> *names=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
    for(NSString *name in names) {
        if(![name.pathExtension.lowercaseString isEqualToString:@"appex"])continue;
        NSBundle *bundle=[NSBundle bundleWithPath:[path stringByAppendingPathComponent:name]];
        NSDictionary *ext=bundle.infoDictionary[@"NSExtension"];
        if(![ext isKindOfClass:NSDictionary.class])continue;
        if(![ext[@"NSExtensionPointIdentifier"] isEqualToString:@"com.apple.share-services"])
            continue;
        NSString *identifier=bundle.bundleIdentifier;
        if(!identifier.length)continue;
        NSLog(@"[LeadTelegramShare] matched bundled share UI %@",identifier);
        return bundle;
    }
    return nil;
}
- (void)begin {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{[self begin];});
        return;
    }
    if(!self.file.isFileURL ||
       ![[NSFileManager defaultManager] fileExistsAtPath:self.file.path] ||
       !self.origin || !self.origin.view.window) {
        [self finishWithFallback:@"recording URL or presentation host missing"];
        return;
    }
    NSBundle *bundle=[self findOwnShareExtension];
    // The extension-host class is in a system private framework on some iOS
    // versions and is not necessarily registered when Telegram first launches.
    // Loading it is an optional capability probe, not a dependency on any
    // particular third-party share application.
    Class klass=NSClassFromString(@"NSExtension");
    if(!klass) {
        dlopen("/System/Library/PrivateFrameworks/PlugInKit.framework/PlugInKit",RTLD_LAZY|RTLD_LOCAL);
        klass=NSClassFromString(@"NSExtension");
    }
    SEL create=NSSelectorFromString(@"extensionWithIdentifier:error:");
    SEL instantiate=NSSelectorFromString(@"instantiateViewControllerWithInputItems:listenerEndpoint:connectionHandler:");
    if(!bundle || !klass || ![klass respondsToSelector:create]) {
        [self finishWithFallback:!bundle?@"This Telegram build has no bundled ShareExtension":
            (!klass?@"iOS did not expose its extension host class":
                    @"iOS has no supported extension lookup selector")];
        return;
    }
    NSError *err=nil;
    id ext=nil;
    @try {
        ext=((id (*)(id,SEL,id,NSError **))objc_msgSend)(
            klass,create,bundle.bundleIdentifier,&err);
    } @catch(NSException *exception) {
        NSLog(@"[LeadTelegramShare] extension lookup exception: %@",exception);
    }
    if(!ext || ![ext respondsToSelector:instantiate]) {
        [self finishWithFallback:err.localizedDescription?:@"extension-host API not provided by this iOS"];
        return;
    }
    self.extension=ext;
    NSItemProvider *provider=[[NSItemProvider alloc] initWithContentsOfURL:self.file];
    if(!provider) {
        [self finishWithFallback:@"could not create file item provider"];
        return;
    }
    NSExtensionItem *item=[NSExtensionItem new];
    item.attributedTitle=[[NSAttributedString alloc] initWithString:self.file.lastPathComponent];
    item.attachments=@[provider];
    if([ext respondsToSelector:NSSelectorFromString(@"setRequestCompletionBlock:")]) {
        void (^complete)(id,id)=^(id requestId,id output) {
            dispatch_async(dispatch_get_main_queue(),^{[self complete:YES];});
        };
        ((void (*)(id,SEL,id))objc_msgSend)(
            ext,NSSelectorFromString(@"setRequestCompletionBlock:"),complete);
    }
    if([ext respondsToSelector:NSSelectorFromString(@"setRequestCancellationBlock:")]) {
        void (^cancel)(id,id)=^(id requestId,id error) {
            dispatch_async(dispatch_get_main_queue(),^{[self complete:NO];});
        };
        ((void (*)(id,SEL,id))objc_msgSend)(
            ext,NSSelectorFromString(@"setRequestCancellationBlock:"),cancel);
    }
    if([ext respondsToSelector:NSSelectorFromString(@"setRequestInterruptionBlock:")]) {
        void (^interrupt)(id)=^(id requestId) {
            dispatch_async(dispatch_get_main_queue(),^{
                if(!self.presented)[self finishWithFallback:@"share extension interrupted"];
                else [self complete:NO];
            });
        };
        ((void (*)(id,SEL,id))objc_msgSend)(
            ext,NSSelectorFromString(@"setRequestInterruptionBlock:"),interrupt);
    }
    // This API is not public; guard selector availability and always retain
    // the recording. The remote controller belongs to Telegram itself.
    NSLog(@"[LeadTelegramShare] requesting in-app Telegram recipient picker");
    @try {
        void (^handler)(id,id)=^(id controller,id error) {
            dispatch_async(dispatch_get_main_queue(),^{
                if(self.finished)return;
                if(![controller isKindOfClass:UIViewController.class]) {
                    NSString *reason=[error isKindOfClass:NSError.class]?
                        [(NSError *)error localizedDescription]:@"no remote Telegram share controller";
                    [self finishWithFallback:reason];
                    return;
                }
                UIViewController *host=self.origin;
                while(host.presentedViewController)host=host.presentedViewController;
                if(!host.view.window) {
                    [self finishWithFallback:@"app is no longer in foreground"];
                    return;
                }
                UIViewController *remoteController=(UIViewController *)controller;
                self.remote=remoteController;
                self.presented=YES;
                remoteController.modalPresentationStyle=UIModalPresentationFormSheet;
                [host presentViewController:remoteController animated:YES completion:nil];
            });
        };
        ((void (*)(id,SEL,id,id,id))objc_msgSend)(
            ext,instantiate,@[item],nil,handler);
    } @catch(NSException *exception) {
        [self finishWithFallback:exception.reason?:@"in-app share request rejected"];
        return;
    }
    // Avoid trapping the user if a sideloaded Telegram build has no usable
    // share extension process. The regular system activity sheet still works.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(12*NSEC_PER_SEC)),
        dispatch_get_main_queue(),^{
            if(!self.finished && !self.presented)
                [self finishWithFallback:@"direct share view did not appear"];
        });
}
@end

void LeadOpenTelegramSharePicker(NSURL *file,
    UIViewController *presenter,void (^fallback)(NSString *reason)) {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{
            LeadOpenTelegramSharePicker(file,presenter,fallback);
        });
        return;
    }
    if(!file.isFileURL || ![[NSFileManager defaultManager] fileExistsAtPath:file.path]) {
        if(fallback)fallback(@"Recording file is unavailable");
        return;
    }
    @synchronized([LeadTelegramNativeShareAttempt class]) {
        if(gActiveTelegramShare && !gActiveTelegramShare.finished) {
            NSLog(@"[LeadTelegramShare] second request ignored while picker is already open");
            if(fallback)fallback(@"Telegram recipient picker is already opening");
            return;
        }
        LeadTelegramNativeShareAttempt *attempt=[LeadTelegramNativeShareAttempt new];
        attempt.file=file;
        attempt.origin=presenter;
        attempt.fallback=[fallback copy];
        gActiveTelegramShare=attempt;
        [attempt begin];
    }
}
