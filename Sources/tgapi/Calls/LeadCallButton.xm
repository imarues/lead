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

@interface LeadRecordingHUDWindow : UIWindow
@end
@implementation LeadRecordingHUDWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *result=[super hitTest:point withEvent:event];
    // Let Telegram's chats and controls receive all touches outside REC.
    if(result==self || result==self.rootViewController.view)return nil;
    return result;
}
@end

@interface LeadCallRecordButtonTarget : NSObject
@property(nonatomic,weak) UIButton *currentCallButton;
@property(nonatomic,strong) LeadRecordingHUDWindow *hudWindow;
@property(nonatomic,strong) UIButton *hudButton;
@property(nonatomic,strong) NSTimer *elapsedTimer;
@property(nonatomic,assign) BOOL hudMovedByUser;
+ (instancetype)shared;
- (void)pressed:(UIButton *)button;
- (void)dragged:(UIPanGestureRecognizer *)pan;
- (void)update:(UIButton *)button;
- (void)refreshRecordingUI;
- (void)recordingChanged:(NSNotification *)note;
@end

@implementation LeadCallRecordButtonTarget
+ (instancetype)shared {
    static LeadCallRecordButtonTarget *instance;
    static dispatch_once_t once;
    dispatch_once(&once,^{instance=[LeadCallRecordButtonTarget new];});
    return instance;
}
- (NSString *)timeLabel {
    NSUInteger seconds=(NSUInteger)floor([LeadCallRecording shared].elapsedSeconds);
    if(seconds>=3600)
        return [NSString stringWithFormat:@"%02lu:%02lu:%02lu",
                (unsigned long)(seconds/3600),
                (unsigned long)((seconds/60)%60),
                (unsigned long)(seconds%60)];
    return [NSString stringWithFormat:@"%02lu:%02lu",
            (unsigned long)(seconds/60),(unsigned long)(seconds%60)];
}
- (void)update:(UIButton *)button {
    if(!button)return;
    BOOL active=[LeadCallRecording shared].isRecording;
    [button setTitle:active?[NSString stringWithFormat:@"■ %@",[self timeLabel]]:@"REC"
           forState:UIControlStateNormal];
    button.backgroundColor=active?UIColor.systemGreenColor:UIColor.systemRedColor;
    button.layer.borderColor=UIColor.whiteColor.CGColor;
    button.layer.cornerRadius=12;
    button.accessibilityLabel=active?@"تسجيل المكالمة مستمر، اضغط للإيقاف":@"بدء تسجيل المكالمة";
    CGRect frame=button.frame;
    frame.size.width=active?115:68;
    frame.size.height=44;
    if(button.superview)frame.origin.x=MAX(5,MIN(frame.origin.x,
                          button.superview.bounds.size.width-frame.size.width-5));
    button.frame=frame;
    // The floating badge is the primary stop control while recording.
    button.hidden=active && self.hudWindow && !self.hudWindow.hidden;
}
- (UIWindowScene *)activeScene {
    UIWindowScene *fallback=nil;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:[UIWindowScene class]])continue;
        if(scene.activationState==UISceneActivationStateForegroundActive)
            return (UIWindowScene *)scene;
        if(!fallback)fallback=(UIWindowScene *)scene;
    }
    return fallback;
}
- (void)installHUDIfNeeded {
    if(self.hudWindow)return;
    UIWindowScene *scene=[self activeScene];
    if(!scene)return;
    LeadRecordingHUDWindow *window=[[LeadRecordingHUDWindow alloc] initWithWindowScene:scene];
    window.frame=scene.coordinateSpace.bounds;
    window.windowLevel=UIWindowLevelStatusBar+2;
    window.backgroundColor=UIColor.clearColor;
    window.opaque=NO;
    window.accessibilityIdentifier=@"LeadVisibleCallRecordingHUDWindow";
    UIViewController *controller=[UIViewController new];
    controller.view.backgroundColor=UIColor.clearColor;
    window.rootViewController=controller;
    UIButton *badge=[UIButton buttonWithType:UIButtonTypeCustom];
    badge.frame=CGRectMake(0,0,115,44);
    badge.backgroundColor=UIColor.systemGreenColor;
    badge.layer.cornerRadius=12;
    badge.layer.borderWidth=1;
    badge.layer.borderColor=UIColor.whiteColor.CGColor;
    badge.titleLabel.font=[UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightBold];
    [badge setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    badge.accessibilityIdentifier=@"LeadRecordingTimerAndStop";
    badge.accessibilityLabel=@"إيقاف تسجيل المكالمة";
    [badge addTarget:self action:@selector(pressed:)
        forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *move=[[UIPanGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(dragged:)];
    move.maximumNumberOfTouches=1;
    [badge addGestureRecognizer:move];
    [controller.view addSubview:badge];
    self.hudWindow=window;
    self.hudButton=badge;
    // Never makeKeyAndVisible: Telegram keeps its key window and keyboard.
    window.hidden=NO;
}
- (void)refreshRecordingUI {
    BOOL active=[LeadCallRecording shared].isRecording;
    if(active) {
        [self installHUDIfNeeded];
        UIWindow *window=self.hudWindow;
        UIButton *badge=self.hudButton;
        if(window && badge) {
            window.hidden=NO;
            CGRect bounds=window.bounds;
            UIEdgeInsets insets=window.safeAreaInsets;
            CGFloat top=MAX(insets.top+10,60.0);
            if(!self.hudMovedByUser)
                badge.frame=CGRectMake(MAX(8,bounds.size.width-128),top,115,44);
            else {
                // Keep a dragged badge at its selected position on every tick,
                // clamping it back on screen after a device rotation.
                CGPoint center=badge.center;
                center.x=MAX(badge.bounds.size.width/2+5,MIN(bounds.size.width-badge.bounds.size.width/2-5,center.x));
                center.y=MAX(top+badge.bounds.size.height/2,MIN(bounds.size.height-MAX(insets.bottom,10)-badge.bounds.size.height/2,center.y));
                badge.center=center;
            }
            [badge setTitle:[NSString stringWithFormat:@"■ %@",[self timeLabel]]
                   forState:UIControlStateNormal];
        }
        if(!self.elapsedTimer) {
            self.elapsedTimer=[NSTimer timerWithTimeInterval:1.0 target:self
                                  selector:@selector(timerFired:) userInfo:nil repeats:YES];
            [[NSRunLoop mainRunLoop] addTimer:self.elapsedTimer forMode:NSRunLoopCommonModes];
        }
    } else {
        [self.elapsedTimer invalidate];
        self.elapsedTimer=nil;
        self.hudWindow.hidden=YES;
        self.hudButton=nil;
        self.hudWindow=nil;
        self.hudMovedByUser=NO;
    }
    [self update:self.currentCallButton];
}
- (void)timerFired:(__unused NSTimer *)timer {[self refreshRecordingUI];}
- (void)recordingChanged:(__unused NSNotification *)note {
    if(NSThread.isMainThread)[self refreshRecordingUI];
    else dispatch_async(dispatch_get_main_queue(),^{[self refreshRecordingUI];});
}
- (void)dragged:(UIPanGestureRecognizer *)pan {
    UIView *v=pan.view,*parent=v.superview;
    if(!parent)return;
    CGPoint delta=[pan translationInView:parent];
    UIEdgeInsets insets=UIEdgeInsetsZero;
    if(v==self.hudButton) {
        self.hudMovedByUser=YES;
        insets=self.hudWindow.safeAreaInsets;
    }
    CGFloat halfWidth=v.bounds.size.width/2.0;
    CGFloat halfHeight=v.bounds.size.height/2.0;
    CGFloat minY=MAX(halfHeight+10,insets.top+halfHeight+5);
    CGFloat maxY=MAX(minY,parent.bounds.size.height-MAX(insets.bottom,10)-halfHeight);
    v.center=CGPointMake(MAX(halfWidth+5,MIN(parent.bounds.size.width-halfWidth-5,v.center.x+delta.x)),
                         MAX(minY,MIN(maxY,v.center.y+delta.y)));
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
            NSString *message=(file && error)?
                [NSString stringWithFormat:@"تم حفظ الصوت فقط في: %@\n%@",file.lastPathComponent,error.localizedDescription]:
                (error?error.localizedDescription:
                [NSString stringWithFormat:@"تم حفظ التسجيل: %@",file.lastPathComponent]);
            UIAlertController *result=[UIAlertController alertControllerWithTitle:
               (file && error?@"تم حفظ الصوت فقط":error?@"التسجيل غير مكتمل":@"تم حفظ التسجيل") message:message
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
    button.layer.cornerRadius=12;
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
    [LeadCallRecordButtonTarget shared].currentCallButton=button;
    [[LeadCallRecordButtonTarget shared] refreshRecordingUI];
}

static void LeadDetachCallControl(UIView *view) {
    UIButton *button=objc_getAssociatedObject(view,&kLeadCallRecordButtonKey);
    if(!button)return;
    if([LeadCallRecordButtonTarget shared].currentCallButton==button)
        [LeadCallRecordButtonTarget shared].currentCallButton=nil;
    [button removeFromSuperview];
    objc_setAssociatedObject(view,&kLeadCallRecordButtonKey,nil,OBJC_ASSOCIATION_ASSIGN);
    // IMPORTANT: minimizing the call to browse Telegram chats destroys this
    // view, but the underlying call and CoreAudio capture are still active.
    // Recording is owned by LeadCallRecording, not this temporary call UI.
    [[LeadCallRecordButtonTarget shared] refreshRecordingUI];
}

%group LeadPrivateCallScreenHooks
%hook UIView
- (void)didMoveToWindow {
    %orig;
    UIView *callView=(UIView *)self;
    if(callView.window)LeadInstallCallControl(callView);
}
- (void)willMoveToWindow:(UIWindow *)window {
    if(!window)LeadDetachCallControl((UIView *)self);
    %orig;
}
%end
%end

%group LeadGroupCallScreenHooks
%hook UIView
- (void)didMoveToWindow {
    %orig;
    UIView *callView=(UIView *)self;
    if(callView.window)LeadInstallCallControl(callView);
}
- (void)willMoveToWindow:(UIWindow *)window {
    if(!window)LeadDetachCallControl((UIView *)self);
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
        [[NSNotificationCenter defaultCenter] addObserver:
            [LeadCallRecordButtonTarget shared]
            selector:@selector(recordingChanged:)
            name:LeadCallRecordingChangedNotification object:nil];
        LeadTryInstallCallScreenHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),
                       dispatch_get_main_queue(),^{LeadTryInstallCallScreenHooks();});
        [[NSNotificationCenter defaultCenter] addObserverForName:
           UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
           usingBlock:^(__unused NSNotification *note){LeadTryInstallCallScreenHooks();}];
    });
}
