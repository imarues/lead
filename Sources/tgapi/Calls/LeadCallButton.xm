// Visible, manually controlled call-recording button for private/group calls.
// Recording cannot auto-start: consent is confirmed for each session.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "LeadCallRecording.h"
#import "LeadCallAudio.h"
#import "../UI/LeadDesign.h"

static char kLeadCallRecordButtonKey;
static BOOL leadPrivateHooksInstalled=NO;
static BOOL leadGroupHooksInstalled=NO;

@interface LeadCallRecordButtonTarget : NSObject
+ (instancetype)shared;
- (void)pressed:(UIButton *)button;
- (void)dragged:(UIPanGestureRecognizer *)pan;
- (void)update:(UIButton *)button;
@end

@implementation LeadCallRecordButtonTarget
+ (instancetype)shared {
    static LeadCallRecordButtonTarget *instance;
    static dispatch_once_t once;
    dispatch_once(&once,^{instance=[LeadCallRecordButtonTarget new];});
    return instance;
}
- (void)update:(UIButton *)button {
    if(!button)return;
    BOOL active=[LeadCallRecording shared].isRecording;
    [button setTitle:active?@"● REC":@"REC" forState:UIControlStateNormal];
    button.backgroundColor=active?UIColor.systemRedColor:
       [UIColor colorWithWhite:0.04 alpha:0.78];
    button.layer.borderColor=(active?UIColor.whiteColor:UIColor.systemRedColor).CGColor;
    button.accessibilityLabel=active?@"إيقاف تسجيل المكالمة":@"بدء تسجيل المكالمة";
}
- (void)dragged:(UIPanGestureRecognizer *)pan {
    UIView *v=pan.view,*parent=v.superview;
    if(!parent)return;
    CGPoint delta=[pan translationInView:parent];
    v.center=CGPointMake(MIN(MAX(v.center.x+delta.x,35),parent.bounds.size.width-35),
                         MIN(MAX(v.center.y+delta.y,70),parent.bounds.size.height-70));
    [pan setTranslation:CGPointZero inView:parent];
}
- (void)begin:(UIButton *)button video:(BOOL)video {
    UIView *host=button.superview;
    if(!host || !host.window)return;
    UIAlertController *consent=[UIAlertController alertControllerWithTitle:@"موافقة على التسجيل"
      message:@"يجب إبلاغ جميع المشاركين والحصول على موافقتهم قبل التسجيل. التسجيل راح يكون واضح على الشاشة، وينحفظ محلياً على جهازك."
      preferredStyle:UIAlertControllerStyleAlert];
    [consent addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [consent addAction:[UIAlertAction actionWithTitle:@"أكد موافقتهم"
      style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [[LeadCallRecording shared] startForView:host video:video completion:^(NSError *error) {
            if(error) {
                UIAlertController *notice=[UIAlertController alertControllerWithTitle:@"تعذّر بدء التسجيل"
                    message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                [notice addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleCancel handler:nil]];
                [LeadTopPresenter() presentViewController:notice animated:YES completion:nil];
            }
            [[LeadCallRecordButtonTarget shared] update:button];
        }];
    }]];
    [LeadTopPresenter() presentViewController:consent animated:YES completion:nil];
}
- (void)pressed:(UIButton *)button {
    LeadCallRecording *recorder=[LeadCallRecording shared];
    if(recorder.isRecording) {
        button.enabled=NO;
        [recorder stop:^(NSURL *file,NSError *error){
            button.enabled=YES;
            [self update:button];
            NSString *message=error?error.localizedDescription:
                [NSString stringWithFormat:@"تم حفظ التسجيل: %@",file.lastPathComponent];
            UIAlertController *result=[UIAlertController alertControllerWithTitle:
               (error?@"التسجيل غير مكتمل":@"تم حفظ التسجيل") message:message
               preferredStyle:UIAlertControllerStyleAlert];
            [result addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleCancel handler:nil]];
            UIViewController *top=LeadTopPresenter();
            if(top)[top presentViewController:result animated:YES completion:nil];
        }];
        return;
    }
    if(![[NSUserDefaults standardUserDefaults] boolForKey:LeadCallRecordingEnabledKey]) {
        UIAlertController *off=[UIAlertController alertControllerWithTitle:@"تسجيل المكالمات"
         message:@"فعّل تسجيل المكالمات من Lead ← المكالمات أولاً."
         preferredStyle:UIAlertControllerStyleAlert];
        [off addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleCancel handler:nil]];
        [LeadTopPresenter() presentViewController:off animated:YES completion:nil];
        return;
    }
    UIAlertController *modes=[UIAlertController alertControllerWithTitle:@"نوع التسجيل"
        message:@"اختَر طريقة التسجيل" preferredStyle:UIAlertControllerStyleActionSheet];
    [modes addAction:[UIAlertAction actionWithTitle:@"تسجيل الصوت فقط (M4A)"
         style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[self begin:button video:NO];}]];
    [modes addAction:[UIAlertAction actionWithTitle:@"تسجيل صوت وفيديو (MP4)"
         style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[self begin:button video:YES];}]];
    [modes addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    modes.popoverPresentationController.sourceView=button;
    modes.popoverPresentationController.sourceRect=button.bounds;
    UIViewController *top=LeadTopPresenter();
    if(top)[top presentViewController:modes animated:YES completion:nil];
}
@end

static void LeadInstallCallControl(UIView *callView) {
    if(!callView.window || ![[NSUserDefaults standardUserDefaults] boolForKey:LeadCallRecordingEnabledKey])
        return;
    UIButton *button=objc_getAssociatedObject(callView,&kLeadCallRecordButtonKey);
    if(button)return;
    button=[UIButton buttonWithType:UIButtonTypeCustom];
    button.frame=CGRectMake(MAX(4,callView.bounds.size.width-82),
                            MAX(100,callView.bounds.size.height*0.46),68,44);
    button.layer.cornerRadius=22;
    button.layer.borderWidth=1.5;
    button.titleLabel.font=[UIFont boldSystemFontOfSize:14];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.layer.zPosition=99998;
    button.accessibilityIdentifier=@"LeadCallVisibleRecordingControl";
    [button addTarget:[LeadCallRecordButtonTarget shared] action:@selector(pressed:)
                 forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc] initWithTarget:
        [LeadCallRecordButtonTarget shared] action:@selector(dragged:)];
    pan.maximumNumberOfTouches=1;
    [button addGestureRecognizer:pan];
    [callView addSubview:button];
    objc_setAssociatedObject(callView,&kLeadCallRecordButtonKey,button,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [[LeadCallRecordButtonTarget shared] update:button];
}

static void LeadDetachCallControl(UIView *view) {
    UIButton *button=objc_getAssociatedObject(view,&kLeadCallRecordButtonKey);
    if(button){[button removeFromSuperview];objc_setAssociatedObject(view,&kLeadCallRecordButtonKey,nil,OBJC_ASSOCIATION_ASSIGN);}
    // The indicator cannot remain invisible while audio is captured.
    if([LeadCallRecording shared].isRecording)
        [[LeadCallRecording shared] stop:^(NSURL *file,NSError *error) {
            NSLog(@"[LeadCalls] screen detached; stopped %@ %@",file,error);
        }];
}

%group LeadPrivateCallScreenHooks
%hook UIView
- (void)didMoveToWindow {
    %orig;
    if(self.window)LeadInstallCallControl(self);
}
- (void)willMoveToWindow:(UIWindow *)window {
    if(!window)LeadDetachCallControl(self);
    %orig;
}
%end
%end

%group LeadGroupCallScreenHooks
%hook UIView
- (void)didMoveToWindow {
    %orig;
    if(self.window)LeadInstallCallControl(self);
}
- (void)willMoveToWindow:(UIWindow *)window {
    if(!window)LeadDetachCallControl(self);
    %orig;
}
%end
%end

static void LeadTryInstallCallScreenHooks(void) {
    if(!leadPrivateHooksInstalled) {
        Class cls=objc_getClass("_TtC10CallScreen17PrivateCallScreen");
        if(cls) {
            %init(LeadPrivateCallScreenHooks,UIView=cls);
            leadPrivateHooksInstalled=YES;
        }
    }
    if(!leadGroupHooksInstalled) {
        Class cls=objc_getClass("_TtCC15TelegramCallsUI24VideoChatScreenComponent4View");
        if(cls) {
            %init(LeadGroupCallScreenHooks,UIView=cls);
            leadGroupHooksInstalled=YES;
        }
    }
}
%ctor {
    NSString *process=NSProcessInfo.processInfo.processName.lowercaseString;
    if([process containsString:@"notificationservice"])return;
    LeadCallAudioInstallHooks();
    dispatch_async(dispatch_get_main_queue(),^{
        LeadTryInstallCallScreenHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),
                       dispatch_get_main_queue(),^{LeadTryInstallCallScreenHooks();});
        [[NSNotificationCenter defaultCenter] addObserverForName:
           UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
           usingBlock:^(__unused NSNotification *note){LeadTryInstallCallScreenHooks();}];
    });
}
