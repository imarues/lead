#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdint.h>
#import <string.h>

// Standalone private-call transport experiment, no call content inspection,
// no endpoint or credential rewriting, no interception of group calls.
// Matches the public ObjC bridge's initializer at the pinned Telegram-iOS revision.
// MRC is deliberate: the original init-family method retains its ownership ABI.
typedef id (*NativeInit)(id, SEL, NSString *, NSString *, id, id, int32_t, int32_t, NSData *, NSData *, bool,
                         NSArray *, int32_t, BOOL, BOOL, BOOL, NSString *, NSString *, id, id, NSString *, NSString *, id, id);

enum { ModeNative = 0, ModeRelay = 1, ModeTCP = 2 };
static _Atomic int chosenMode = ModeNative;
static _Atomic unsigned int privateStarts = 0;
static _Atomic unsigned int relayStarts = 0;
static _Atomic unsigned int tcpStarts = 0;
static NativeInit originalInit;
static BOOL hookInstalled = NO;
static BOOL initialPromptShown = NO;
static BOOL promptInProgress = NO;

static id NewPrivateInit(id self, SEL cmd, NSString *version, NSString *customParameters, id queue, id proxy,
                         int32_t networkType, int32_t dataSaving, NSData *derivedState, NSData *key, bool isOutgoing,
                         NSArray *connections, int32_t maxLayer, BOOL allowP2P, BOOL allowTCP, BOOL enableStunMarking,
                         NSString *logPath, NSString *statsLogPath, id sendSignalingData, id videoCapturer,
                         NSString *preferredVideoCodec, NSString *audioInputDeviceId, id audioDevice, id directConnection) {
    int mode = atomic_load_explicit(&chosenMode, memory_order_relaxed);
    atomic_fetch_add_explicit(&privateStarts, 1, memory_order_relaxed);
    if (mode == ModeRelay) {
        allowP2P = NO;
        allowTCP = YES;
        atomic_fetch_add_explicit(&relayStarts, 1, memory_order_relaxed);
    } else if (mode == ModeTCP) {
        // Preserve the user's original P2P privacy preference.
        allowTCP = YES;
        atomic_fetch_add_explicit(&tcpStarts, 1, memory_order_relaxed);
    }
    return originalInit(self, cmd, version, customParameters, queue, proxy, networkType, dataSaving, derivedState,
                        key, isOutgoing, connections, maxLayer, allowP2P, allowTCP, enableStunMarking, logPath,
                        statsLogPath, sendSignalingData, videoCapturer, preferredVideoCodec, audioInputDeviceId,
                        audioDevice, directConnection);
}

static BOOL HasType(Method m, unsigned index, const char *allowed) {
    char type[64] = {0};
    method_getArgumentType(m, index, type, sizeof(type));
    const char *p = type;
    while (*p && strchr("rnNoORV", *p)) p++;
    return *p && strchr(allowed, *p) != NULL;
}

static BOOL Install(void) {
    if (hookInstalled) return YES;
    Class target = NSClassFromString(@"OngoingCallThreadLocalContextWebrtc");
    SEL sel = NSSelectorFromString(@"initWithVersion:customParameters:queue:proxy:networkType:dataSaving:derivedState:key:isOutgoing:connections:maxLayer:allowP2P:allowTCP:enableStunMarking:logPath:statsLogPath:sendSignalingData:videoCapturer:preferredVideoCodec:audioInputDeviceId:audioDevice:directConnection:");
    Method method = target ? class_getInstanceMethod(target, sel) : NULL;
    if (!method || method_getNumberOfArguments(method) != 24) return NO;
    char returnType[8] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (returnType[0] != '@') return NO;
    // Verify the ABI before modifying any method. The scalar/object layout must
    // match the complete pinned signature, including block arguments.
    const unsigned objectArgs[] = {2,3,4,5,8,9,11,16,17,18,19,20,21,22,23};
    for (unsigned i=0;i<sizeof(objectArgs)/sizeof(objectArgs[0]);i++)
        if (!HasType(method, objectArgs[i], "@")) return NO;
    if (!HasType(method,6,"i") || !HasType(method,7,"i") || !HasType(method,10,"Bc") ||
        !HasType(method,12,"i") || !HasType(method,13,"Bc") || !HasType(method,14,"Bc") || !HasType(method,15,"Bc")) return NO;
    IMP old = method_getImplementation(method);
    if (!old || old == (IMP)NewPrivateInit) return NO;
    originalInit = (NativeInit)old;
    if (!class_addMethod(target, sel, (IMP)NewPrivateInit, method_getTypeEncoding(method))) {
        method_setImplementation(method, (IMP)NewPrivateInit);
    }
    hookInstalled = YES;
    return YES;
}

static UIViewController *VisibleController(void) {
    UIWindow *w = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *candidate in [(UIWindowScene *)scene windows]) {
            if (candidate.isKeyWindow) { w = candidate; break; }
        }
        if (w) break;
    }
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed)
        vc = vc.presentedViewController;
    return vc.viewIfLoaded.window ? vc : nil;
}

static void ChooseMode(int mode) {
    atomic_store_explicit(&chosenMode, mode, memory_order_relaxed);
    promptInProgress = NO;
}

static void Show(int remaining) {
    if (initialPromptShown || promptInProgress || remaining <= 0) return;
    UIViewController *vc = VisibleController();
    if (!vc || [vc isKindOfClass:[UIAlertController class]]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{Show(remaining-1);});
        return;
    }
    BOOL supported = Install();
    initialPromptShown = YES; promptInProgress = YES;
    NSString *description = supported
        ? @"يتغير اختيار مسار المكالمة الفردية فقط. اختر الاختبار الأول (الخوادم الوسيطة)، ثم جرب مكالمة فردية دون VPN. إذا لم تنجح، أغلق التطبيق بالكامل وأعد فتحه واختر الاختبار الثاني. ليس VPN، ولا يضيف خوادم أو يغيّر مفاتيح الاتصال."
        : @"إصدار التطبيق لا يطابق واجهة المكالمات التي يفحصها هذا الدايلب. لم يتم تعديل أي دالة.";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"اختبار مسار المكالمات الفردية" message:description preferredStyle:UIAlertControllerStyleAlert];
    if (supported) {
        [a addAction:[UIAlertAction actionWithTitle:@"1 — Relay فقط + إتاحة TCP" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){ChooseMode(ModeRelay);}]];
        [a addAction:[UIAlertAction actionWithTitle:@"2 — إتاحة TCP فقط" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){ChooseMode(ModeTCP);}]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"بدون تعديل" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action){ChooseMode(ModeNative);}]];
    [vc presentViewController:a animated:YES completion:nil];
}

__attribute__((constructor)) static void Start(void) {
    @autoreleasepool {
        if ([NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"appex"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *n){Show(24);}];
            Show(24);
        });
    }
}
