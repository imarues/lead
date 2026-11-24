#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "LeadMenu.h"
#import "../Constants.h"

// The automatic proxy lives below Telegram's own proxy settings; some builds never
// display MTProxy sponsor rows for such connections. This explicitly local Kira
// promotion uses the chat-list controller itself, not fabricated server data.
static char kKiraPromotionView, kKiraPromotionVisible;
static BOOL sKiraPromotionDismissed = NO;

static void LeadRefreshChatListPromotion(UIViewController *host) {
    if (!host.isViewLoaded) return;
    UIView *view = host.view;
    UIView *card = objc_getAssociatedObject(host, &kKiraPromotionView);
    BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:kAutoProxy];
    BOOL visible = [objc_getAssociatedObject(host, &kKiraPromotionVisible) boolValue];
    if (!enabled || !visible || sKiraPromotionDismissed || !view.window || CGRectGetWidth(view.bounds) < 280) {
        card.hidden = YES;
        return;
    }
    if (!card) {
        UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
        panel.layer.cornerRadius = 16;
        panel.clipsToBounds = YES;
        panel.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        panel.layer.borderColor = UIColor.separatorColor.CGColor;
        panel.translatesAutoresizingMaskIntoConstraints = NO;
        UIButton *open = [UIButton buttonWithType:UIButtonTypeSystem];
        [open setTitle:@"iKiraPlus · إعلان" forState:UIControlStateNormal];
        [open setImage:[UIImage systemImageNamed:@"megaphone"] forState:UIControlStateNormal];
        open.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        open.tintColor = UIColor.labelColor;
        open.accessibilityLabel = @"إعلان قناة Kira Plus";
        [open addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            LeadOpenTelegramURL(@"tg://resolve?domain=iKiraPlus");
        }] forControlEvents:UIControlEventTouchUpInside];
        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        [close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
        close.tintColor = UIColor.secondaryLabelColor;
        close.accessibilityLabel = @"إخفاء الإعلان لهذه الجلسة";
        __weak UIView *weakPanel = panel;
        [close addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            sKiraPromotionDismissed = YES;
            weakPanel.hidden = YES;
        }] forControlEvents:UIControlEventTouchUpInside];
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[open,close]];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.alignment = UIStackViewAlignmentFill;
        stack.spacing = 4;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [panel.contentView addSubview:stack];
        [view addSubview:panel];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:8],
            [stack.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-4],
            [stack.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor],
            [stack.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor],
            [close.widthAnchor constraintEqualToConstant:32],
            [panel.heightAnchor constraintEqualToConstant:42],
            [panel.widthAnchor constraintEqualToConstant:188],
            [panel.trailingAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.trailingAnchor constant:-12],
            [panel.bottomAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.bottomAnchor constant:-112]
        ]];
        objc_setAssociatedObject(host, &kKiraPromotionView, panel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        card = panel;
    }
    card.hidden = NO;
    if (view.subviews.lastObject != card) [view bringSubviewToFront:card];
}

static void LeadHookPromotionMethod(Class cls, SEL sel, BOOL animatedArg, BOOL appear, BOOL disappear) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    IMP old = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    IMP replacement;
    if (animatedArg) {
        replacement = imp_implementationWithBlock(^(UIViewController *host, BOOL animated) {
            if (disappear) {
                objc_setAssociatedObject(host, &kKiraPromotionVisible, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [(UIView *)objc_getAssociatedObject(host, &kKiraPromotionView) setHidden:YES];
            }
            ((void (*)(id, SEL, BOOL))old)(host, sel, animated);
            if (appear) {
                objc_setAssociatedObject(host, &kKiraPromotionVisible, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                LeadRefreshChatListPromotion(host);
            }
        });
    } else {
        replacement = imp_implementationWithBlock(^(UIViewController *host) {
            ((void (*)(id, SEL))old)(host, sel);
            LeadRefreshChatListPromotion(host);
        });
    }
    if (!class_addMethod(cls, sel, replacement, types)) class_replaceMethod(cls, sel, replacement, types);
}

static void LeadTryInstallPromotion(void) {
    static NSMutableSet<NSString *> *installed;
    if (!installed) installed = [NSMutableSet set];
    NSArray *names = @[@"ChatListUI.ChatListControllerImpl", @"_TtC10ChatListUI22ChatListControllerImpl",
                       @"TelegramUI.ChatListControllerImpl", @"_TtC10TelegramUI22ChatListControllerImpl",
                       @"TelegramUI.ChatListController", @"_TtC10TelegramUI18ChatListController"];
    for (NSString *name in names) {
        Class cls = NSClassFromString(name);
        if (!cls || ![cls isSubclassOfClass:UIViewController.class]) continue;
        NSString *key = NSStringFromClass(cls);
        if ([installed containsObject:key]) continue;
        [installed addObject:key];
        LeadHookPromotionMethod(cls, @selector(viewDidAppear:), YES, YES, NO);
        LeadHookPromotionMethod(cls, @selector(viewWillDisappear:), YES, NO, YES);
        LeadHookPromotionMethod(cls, @selector(viewDidLayoutSubviews), NO, NO, NO);
    }
}
void LeadChatListPromotionInstall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LeadTryInstallPromotion();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ LeadTryInstallPromotion(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 7*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ LeadTryInstallPromotion(); });
    });
}
