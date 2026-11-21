// Visual-only snowfall for Telegram. Excludes call screens and keyboard geometry.
// A non-key, touch-through window keeps the effect above Telegram's navigation UI.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "LeadDesign.h"
#import "../Constants.h"

@interface LeadSnowWindow : UIWindow
@end

@implementation LeadSnowWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil; // Never intercept Telegram gestures or keyboard input.
}
- (BOOL)canBecomeKeyWindow {
    return NO;
}
@end

// Telegram uses a custom navigation stack, so hooks on its ChatControllerImpl
// give us an exact distinction between a chat and the rest of the application.
static __weak UIViewController *sLeadCurrentChat = nil;

static BOOL LeadSnowIsCallName(NSString *className) {
    NSString *name = className.lowercaseString;
    return [name containsString:@"privatecallscreen"] ||
           [name containsString:@"groupcallscreen"] ||
           [name containsString:@"groupcallcontroller"] ||
           [name containsString:@"voicechatcontroller"] ||
           [name containsString:@"voicechatscreen"] ||
           [name containsString:@"callcontroller"] ||
           [name containsString:@"callscreen"];
}

static BOOL LeadSnowHasVisibleCallView(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.03) return NO;
    if (LeadSnowIsCallName(NSStringFromClass(view.class))) return YES;
    for (UIView *child in view.subviews) {
        if (LeadSnowHasVisibleCallView(child)) return YES;
    }
    return NO;
}

static BOOL LeadSnowHasCallController(UIViewController *controller) {
    if (!controller || !controller.isViewLoaded) return NO;
    UIView *view = controller.view;
    if (!view.window || view.hidden || view.alpha < 0.03) return NO;
    if (LeadSnowIsCallName(NSStringFromClass(controller.class))) return YES;
    if (controller.presentedViewController &&
        LeadSnowHasCallController(controller.presentedViewController)) return YES;
    if ([controller isKindOfClass:[UINavigationController class]]) {
        UIViewController *visible = ((UINavigationController *)controller).visibleViewController;
        if (visible != controller && LeadSnowHasCallController(visible)) return YES;
    }
    if ([controller isKindOfClass:[UITabBarController class]]) {
        UIViewController *selected = ((UITabBarController *)controller).selectedViewController;
        if (selected != controller && LeadSnowHasCallController(selected)) return YES;
    }
    for (UIViewController *child in controller.childViewControllers) {
        if (LeadSnowHasCallController(child)) return YES;
    }
    return NO;
}

static BOOL LeadSnowSceneHasCall(UIWindowScene *scene) {
    for (UIWindow *window in scene.windows) {
        if ([window isKindOfClass:[LeadSnowWindow class]] ||
            window.hidden || window.alpha < 0.03) continue;
        // Keyboard windows are unrelated to Telegram's call UI.
        NSString *name = NSStringFromClass(window.class).lowercaseString;
        if ([name containsString:@"keyboard"] || [name containsString:@"texteffects"]) continue;
        if (LeadSnowHasCallController(window.rootViewController) ||
            LeadSnowHasVisibleCallView(window)) return YES;
    }
    return NO;
}

static UIImage *LeadSnowParticleImage(void) {
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(12, 12)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextSetFillColorWithColor(c, [UIColor colorWithWhite:1 alpha:0.94].CGColor);
        CGContextFillEllipseInRect(c, CGRectMake(2, 2, 8, 8));
    }];
}

static CAEmitterLayer *LeadSnowEmitter(void) {
    CAEmitterLayer *layer = [CAEmitterLayer layer];
    layer.emitterShape = kCAEmitterLayerLine;
    layer.emitterMode = kCAEmitterLayerSurface;
    layer.renderMode = kCAEmitterLayerUnordered;
    UIImage *particle = LeadSnowParticleImage();
    NSMutableArray<CAEmitterCell *> *cells = [NSMutableArray array];
    for (NSInteger i = 0; i < 3; i++) {
        CAEmitterCell *cell = [CAEmitterCell emitterCell];
        cell.contents = (__bridge id)particle.CGImage;
        cell.birthRate = i == 0 ? 9.0 : (i == 1 ? 5.0 : 3.0);
        cell.lifetime = 15.0;
        cell.lifetimeRange = 3.0;
        cell.velocity = i == 0 ? 65.0 : (i == 1 ? 85.0 : 48.0);
        cell.velocityRange = 22.0;
        cell.emissionLongitude = (CGFloat)M_PI_2;
        cell.emissionRange = (CGFloat)M_PI / 10.0;
        cell.yAcceleration = 7.0;
        cell.scale = i == 0 ? 0.28 : (i == 1 ? 0.40 : 0.54);
        cell.scaleRange = 0.11;
        cell.alphaRange = 0.28;
        cell.spinRange = 0.40;
        [cells addObject:cell];
    }
    layer.emitterCells = cells;
    return layer;
}

@interface LeadSnowManager : NSObject
@property (nonatomic, strong) NSMapTable<UIWindowScene *, LeadSnowWindow *> *windows;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) CGRect keyboardScreenFrame;
@property (nonatomic, assign) BOOL keyboardVisible;
@property (nonatomic, assign) BOOL appActive;
- (void)refresh;
@end

@implementation LeadSnowManager

+ (instancetype)shared {
    static LeadSnowManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [LeadSnowManager new]; });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _windows = [NSMapTable weakToStrongObjectsMapTable];
    _keyboardScreenFrame = CGRectNull;
    _appActive = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(settingsChanged:)
                  name:LeadSettingsDidChangeNotification object:nil];
    for (NSString *event in @[ UIApplicationDidBecomeActiveNotification,
                               UIApplicationWillResignActiveNotification,
                               UISceneDidActivateNotification,
                               UISceneWillDeactivateNotification,
                               UIWindowDidBecomeKeyNotification ]) {
        [center addObserver:self selector:@selector(lifecycleChanged:)
                      name:event object:nil];
    }
    for (NSString *event in @[ UIKeyboardWillShowNotification,
                               UIKeyboardWillChangeFrameNotification,
                               UIKeyboardDidChangeFrameNotification ]) {
        [center addObserver:self selector:@selector(keyboardChanged:)
                      name:event object:nil];
    }
    [center addObserver:self selector:@selector(keyboardHidden:)
                  name:UIKeyboardWillHideNotification object:nil];
    [center addObserver:self selector:@selector(keyboardHidden:)
                  name:UIKeyboardDidHideNotification object:nil];
    return self;
}

- (void)settingsChanged:(NSNotification *)note {
    if (note.object &&
        ![note.object isEqual:kLeadSnowEnabled] &&
        ![note.object isEqual:kLeadSnowHideInChats]) return;
    [self refresh];
}

- (void)lifecycleChanged:(NSNotification *)note {
    if ([note.name isEqualToString:UIApplicationWillResignActiveNotification]) {
        self.appActive = NO;
    } else if ([note.name isEqualToString:UIApplicationDidBecomeActiveNotification]) {
        self.appActive = YES;
    }
    [self refresh];
}

- (void)keyboardChanged:(NSNotification *)note {
    NSValue *value = note.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (value) {
        self.keyboardScreenFrame = value.CGRectValue;
        self.keyboardVisible = YES;
    }
    [self refresh];
}

- (void)keyboardHidden:(NSNotification *)note {
    self.keyboardVisible = NO;
    self.keyboardScreenFrame = CGRectNull;
    [self refresh];
}

- (void)tick:(NSTimer *)timer {
    [self refresh];
}

- (void)applyKeyboardExclusionToWindow:(LeadSnowWindow *)window {
    UIView *view = window.rootViewController.view;
    if (!self.keyboardVisible || CGRectIsNull(self.keyboardScreenFrame)) {
        view.layer.mask = nil;
        return;
    }
    CGRect keyboard = [window convertRect:self.keyboardScreenFrame fromWindow:nil];
    CGRect overlap = CGRectIntersection(view.bounds, keyboard);
    if (CGRectIsNull(overlap) || CGRectIsEmpty(overlap)) {
        view.layer.mask = nil;
        return;
    }
    // An even-odd mask cuts out exactly the keyboard, including floating keyboards.
    UIBezierPath *path = [UIBezierPath bezierPathWithRect:view.bounds];
    [path appendPath:[UIBezierPath bezierPathWithRect:overlap]];
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.frame = view.bounds;
    mask.path = path.CGPath;
    mask.fillRule = kCAFillRuleEvenOdd;
    view.layer.mask = mask;
}

- (LeadSnowWindow *)windowForScene:(UIWindowScene *)scene {
    LeadSnowWindow *window = [self.windows objectForKey:scene];
    if (window) return window;
    window = [[LeadSnowWindow alloc] initWithWindowScene:scene];
    window.frame = scene.coordinateSpace.bounds;
    window.windowLevel = UIWindowLevelAlert + 1;
    window.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = NO;
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.clearColor;
    root.view.userInteractionEnabled = NO;
    root.view.clipsToBounds = YES;
    window.rootViewController = root;
    CAEmitterLayer *emitter = LeadSnowEmitter();
    emitter.name = @"LeadSnowEmitter";
    [root.view.layer addSublayer:emitter];
    window.hidden = YES;
    [self.windows setObject:window forKey:scene];
    return window;
}

- (void)refresh {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
        return;
    }
    BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:kLeadSnowEnabled];
    if (!enabled) {
        [self.timer invalidate];
        self.timer = nil;
        for (LeadSnowWindow *window in self.windows.objectEnumerator) window.hidden = YES;
        return;
    }
    if (!self.timer) {
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.45
                             target:self selector:@selector(tick:)
                           userInfo:nil repeats:YES];
    }
    BOOL hideInChats = [[NSUserDefaults standardUserDefaults] boolForKey:kLeadSnowHideInChats];
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *scene = (UIWindowScene *)candidate;
        LeadSnowWindow *window = [self.windows objectForKey:scene];
        BOOL active = self.appActive &&
                      scene.activationState == UISceneActivationStateForegroundActive;
        if (!active) {
            if (window) window.hidden = YES;
            continue;
        }
        BOOL isChat = NO;
        if (hideInChats && sLeadCurrentChat && sLeadCurrentChat.isViewLoaded) {
            UIView *chatView = sLeadCurrentChat.view;
            isChat = chatView.window && chatView.window.windowScene == scene &&
                     !chatView.hidden && chatView.alpha > 0.03;
        }
        BOOL show = !isChat && !LeadSnowSceneHasCall(scene);
        if (!show) {
            if (window) window.hidden = YES;
            continue;
        }
        if (!window) window = [self windowForScene:scene];
        CGRect bounds = scene.coordinateSpace.bounds;
        if (!CGRectEqualToRect(window.frame, bounds)) window.frame = bounds;
        UIView *view = window.rootViewController.view;
        CAEmitterLayer *emitter = (CAEmitterLayer *)[view.layer.sublayers firstObject];
        emitter.frame = view.bounds;
        emitter.emitterPosition = CGPointMake(CGRectGetMidX(view.bounds), -12);
        emitter.emitterSize = CGSizeMake(CGRectGetWidth(view.bounds), 1);
        [self applyKeyboardExclusionToWindow:window];
        if (window.hidden) window.hidden = NO; // Do not call makeKeyAndVisible.
    }
}
@end

void LeadSnowInstall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[LeadSnowManager shared] refresh];
    });
}

void LeadSnowChatDidAppear(UIViewController *chat) {
    sLeadCurrentChat = chat;
    [[LeadSnowManager shared] refresh];
}

void LeadSnowChatWillDisappear(UIViewController *chat) {
    if (sLeadCurrentChat == chat) sLeadCurrentChat = nil;
    [[LeadSnowManager shared] refresh];
}
