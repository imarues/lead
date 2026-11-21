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

// Use real six-branch crystals with fine side branches instead of solid white disks.
// Distant particles are soft pinpoints; foreground particles have recognizable detail.
static CGFloat LeadSnowRandom(CGFloat low, CGFloat high) {
    return low + (high - low) * ((CGFloat)arc4random_uniform(100000) / 100000.0);
}

static UIImage *LeadSnowMakeTexture(NSInteger depth) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = 2.0;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(36, 36) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef c = context.CGContext;
        CGContextSetAllowsAntialiasing(c, YES);
        CGContextSetShouldAntialias(c, YES);
        CGFloat mid = 18.0;
        if (depth == 0) {
            // Tiny, soft, out-of-focus flakes for the distant depth layer.
            const CGFloat components[] = {1,1,1,0.72, 1,1,1,0.0};
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, NULL, 2);
            CGContextDrawRadialGradient(c, gradient, CGPointMake(mid,mid), 0,
                                        CGPointMake(mid,mid), 10, 0);
            CGGradientRelease(gradient);
            CGColorSpaceRelease(space);
            return;
        }
        CGContextSetLineCap(c, kCGLineCapRound);
        CGContextSetLineJoin(c, kCGLineJoinRound);
        CGContextSetStrokeColorWithColor(c, [UIColor colorWithWhite:1 alpha:0.94].CGColor);
        CGContextSetLineWidth(c, depth == 2 ? 1.50 : 1.85);
        CGFloat radius = depth == 2 ? 14.0 : 12.8;
        for (NSInteger arm = 0; arm < 6; arm++) {
            CGFloat angle = (CGFloat)arm * (CGFloat)M_PI / 3.0;
            CGFloat dx = cos(angle), dy = sin(angle);
            CGContextMoveToPoint(c, mid, mid);
            CGContextAddLineToPoint(c, mid + dx * radius, mid + dy * radius);
            // Two delicate Y-shaped branches per crystal arm.
            for (NSInteger segment = 0; segment < 2; segment++) {
                CGFloat along = radius * (segment == 0 ? 0.50 : 0.76);
                CGFloat length = radius * (segment == 0 ? 0.22 : 0.15);
                CGFloat x = mid + dx * along, y = mid + dy * along;
                for (NSInteger side = -1; side <= 1; side += 2) {
                    CGFloat branch = angle - (CGFloat)side * (CGFloat)M_PI / 3.8;
                    CGContextMoveToPoint(c, x, y);
                    CGContextAddLineToPoint(c, x - cos(branch) * length,
                                              y - sin(branch) * length);
                }
            }
        }
        CGContextStrokePath(c);
        CGContextSetFillColorWithColor(c, UIColor.whiteColor.CGColor);
        CGContextFillEllipseInRect(c, CGRectMake(mid - 1.2, mid - 1.2, 2.4, 2.4));
    }];
}

@interface LeadSnowFlake : NSObject
@property (nonatomic, strong) CALayer *layer;
@property (nonatomic, assign) CGFloat baseX;
@property (nonatomic, assign) CGFloat y;
@property (nonatomic, assign) CGFloat speed;
@property (nonatomic, assign) CGFloat sway;
@property (nonatomic, assign) CGFloat phase;
@property (nonatomic, assign) CGFloat swayFrequency;
@property (nonatomic, assign) CGFloat spin;
@property (nonatomic, assign) CGFloat rotation;
@property (nonatomic, assign) CGFloat size;
@property (nonatomic, assign) NSInteger depth;
@end
@implementation LeadSnowFlake
@end

@interface LeadSnowCanvas : UIView
@property (nonatomic, strong) NSMutableArray<LeadSnowFlake *> *flakes;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval lastTimestamp;
@property (nonatomic, assign) CGSize previousSize;
- (void)start;
- (void)stop;
@end

@implementation LeadSnowCanvas

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.userInteractionEnabled = NO;
    self.clipsToBounds = YES;
    self.flakes = [NSMutableArray arrayWithCapacity:96];
    self.previousSize = frame.size;
    static NSArray<UIImage *> *textures;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        textures = @[LeadSnowMakeTexture(0), LeadSnowMakeTexture(1), LeadSnowMakeTexture(2)];
    });
    // Seed snow over the FULL viewport immediately, not just from the top.
    // 48 distant + 36 middle + 12 near flakes = gentle, layered snowfall.
    for (NSInteger i = 0; i < 96; i++) {
        NSInteger depth = i < 48 ? 0 : (i < 84 ? 1 : 2);
        LeadSnowFlake *flake = [LeadSnowFlake new];
        flake.depth = depth;
        flake.layer = [CALayer layer];
        flake.layer.contents = (__bridge id)textures[depth].CGImage;
        flake.layer.contentsGravity = kCAGravityResizeAspect;
        flake.layer.contentsScale = UIScreen.mainScreen.scale;
        flake.layer.opacity = depth == 0 ? LeadSnowRandom(.33, .58) :
                              (depth == 1 ? LeadSnowRandom(.52, .83) : LeadSnowRandom(.67, .93));
        flake.size = depth == 0 ? LeadSnowRandom(6.0, 9.0) :
                     (depth == 1 ? LeadSnowRandom(9.0, 12.5) : LeadSnowRandom(13.0, 17.0));
        flake.layer.bounds = CGRectMake(0, 0, flake.size, flake.size);
        flake.baseX = LeadSnowRandom(0, MAX(1, frame.size.width));
        flake.y = LeadSnowRandom(0, MAX(1, frame.size.height));
        flake.speed = depth == 0 ? LeadSnowRandom(24, 43) :
                      (depth == 1 ? LeadSnowRandom(40, 66) : LeadSnowRandom(58, 89));
        flake.sway = depth == 0 ? LeadSnowRandom(5, 12) :
                     (depth == 1 ? LeadSnowRandom(9, 18) : LeadSnowRandom(13, 26));
        flake.phase = LeadSnowRandom(0, (CGFloat)M_PI * 2);
        flake.swayFrequency = LeadSnowRandom(.50, 1.10);
        flake.rotation = LeadSnowRandom(0, (CGFloat)M_PI * 2);
        flake.spin = LeadSnowRandom(-.25, .25);
        [self.layer addSublayer:flake.layer];
        [self.flakes addObject:flake];
    }
    [self updateFlakePositions];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat oldWidth = self.previousSize.width, oldHeight = self.previousSize.height;
    CGSize newSize = self.bounds.size;
    if (oldWidth > 1 && oldHeight > 1 &&
        (fabs(oldWidth - newSize.width) > 1 || fabs(oldHeight - newSize.height) > 1)) {
        for (LeadSnowFlake *flake in self.flakes) {
            flake.baseX *= newSize.width / oldWidth;
            flake.y *= newSize.height / oldHeight;
        }
    }
    self.previousSize = newSize;
    [self updateFlakePositions];
}

- (void)updateFlakePositions {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (LeadSnowFlake *flake in self.flakes) {
        CGFloat x = flake.baseX + sin(flake.phase) * flake.sway;
        flake.layer.position = CGPointMake(x, flake.y);
        flake.layer.transform = CATransform3DMakeRotation(flake.rotation, 0, 0, 1);
    }
    [CATransaction commit];
}

- (void)tick:(CADisplayLink *)link {
    if (self.bounds.size.width <= 1 || self.bounds.size.height <= 1) return;
    CFTimeInterval dt = self.lastTimestamp > 0 ? MIN(.065, link.timestamp - self.lastTimestamp) : (1.0 / 30.0);
    self.lastTimestamp = link.timestamp;
    if (dt <= 0) return;
    CGFloat width = CGRectGetWidth(self.bounds), height = CGRectGetHeight(self.bounds);
    for (LeadSnowFlake *flake in self.flakes) {
        flake.y += flake.speed * dt;
        flake.phase += flake.swayFrequency * dt;
        flake.rotation += flake.spin * dt;
        if (flake.y > height + 22) {
            // Re-enter anywhere across the screen after drifting past the bottom.
            flake.y = -LeadSnowRandom(8, height * .26 + 8);
            flake.baseX = LeadSnowRandom(0, width);
            flake.phase = LeadSnowRandom(0, (CGFloat)M_PI * 2);
        }
    }
    [self updateFlakePositions];
}

- (void)start {
    if (self.displayLink) return;
    self.lastTimestamp = 0;
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    link.preferredFramesPerSecond = 30;
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    self.displayLink = link;
}
- (void)stop {
    [self.displayLink invalidate];
    self.displayLink = nil;
    self.lastTimestamp = 0;
}
- (void)dealloc {
    [self stop];
}
@end

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
    root.view = [[LeadSnowCanvas alloc] initWithFrame:window.bounds];
    window.rootViewController = root;
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
        for (LeadSnowWindow *window in self.windows.objectEnumerator) {
            [(LeadSnowCanvas *)window.rootViewController.view stop];
            window.hidden = YES;
        }
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
            if (window) {
                [(LeadSnowCanvas *)window.rootViewController.view stop];
                window.hidden = YES;
            }
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
            if (window) {
                [(LeadSnowCanvas *)window.rootViewController.view stop];
                window.hidden = YES;
            }
            continue;
        }
        if (!window) window = [self windowForScene:scene];
        CGRect bounds = scene.coordinateSpace.bounds;
        if (!CGRectEqualToRect(window.frame, bounds)) window.frame = bounds;
        LeadSnowCanvas *canvas = (LeadSnowCanvas *)window.rootViewController.view;
        [self applyKeyboardExclusionToWindow:window];
        if (window.hidden) window.hidden = NO; // Never become a key window.
        [canvas start];
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
