#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifndef LEAD_WARP_EXPERIMENTAL
#define LEAD_WARP_EXPERIMENTAL 0
#endif

#if LEAD_WARP_EXPERIMENTAL
extern int LeadWarpStart(char *, char *, char *);
extern void LeadWarpStop(void);
#endif

static NSDictionary *sWarpRoute;
static BOOL sWarpBusy;

NSDictionary *LeadWarpCallProxy(void) {
  @synchronized([NSUserDefaults class]) { return sWarpRoute; }
}

NSString *LeadWarpStatus(void) {
#if LEAD_WARP_EXPERIMENTAL
  @synchronized([NSUserDefaults class]) {
    if (sWarpBusy) return @"جاري الفحص…";
    return sWarpRoute ? @"WARP · متصل" : @"متوقف";
  }
#else
  return @"تجريبي · غير مضمّن";
#endif
}

static void LeadWarpMessage(UIViewController *host, NSString *message) {
  if (!host.view.window || host.presentedViewController) return;
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"تجاوز حظر الاتصالات" message:message preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleCancel handler:nil]];
  [host presentViewController:alert animated:YES completion:nil];
}

void LeadWarpShow(UIViewController *host) {
#if LEAD_WARP_EXPERIMENTAL
  @synchronized([NSUserDefaults class]) {
    if (sWarpBusy) return;
  }
  if (LeadWarpCallProxy()) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"تجاوز حظر الاتصالات" message:@"النفق متصل. أوقف المكالمات قبل قطع النفق." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إيقاف WARP" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
      @synchronized([NSUserDefaults class]) {
        if (sWarpBusy) return;
        sWarpBusy = YES;
        sWarpRoute = nil;
      }
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        LeadWarpStop();
        dispatch_async(dispatch_get_main_queue(), ^{
          @synchronized([NSUserDefaults class]) { sWarpBusy = NO; }
          if ([host isKindOfClass:UITableViewController.class]) [[(UITableViewController *)host tableView] reloadData];
        });
      });
    }]];
    [host presentViewController:alert animated:YES completion:nil];
    return;
  }
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"تجاوز حظر الاتصالات" message:@"نسخة تجريبية للمكالمات الفردية عبر TCP. انسخ ملف WireGuard الخاص بحساب WARP إلى الحافظة ثم استورده. لن يحفظ Lead المفتاح أو يشارك بيانات الحساب. شغّل النفق قبل بدء المكالمة." preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:@"استيراد وفحص" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
    NSString *profile = UIPasteboard.generalPasteboard.string;
    if (!profile.length || [profile lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 65536) {
      dispatch_async(dispatch_get_main_queue(), ^{ LeadWarpMessage(host, @"ملف WireGuard غير موجود في الحافظة."); });
      return;
    }
    @synchronized([NSUserDefaults class]) {
      if (sWarpBusy || sWarpRoute) return;
      sWarpBusy = YES;
    }
    NSString *user = NSUUID.UUID.UUIDString;
    NSString *pass = NSUUID.UUID.UUIDString;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      int port = LeadWarpStart((char *)profile.UTF8String, (char *)user.UTF8String, (char *)pass.UTF8String);
      dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized([NSUserDefaults class]) {
          if (port > 0 && port <= 65535) sWarpRoute = @{@"kind":@"socks", @"server":@"127.0.0.1", @"port":@(port), @"user":user, @"pass":pass};
          sWarpBusy = NO;
        }
        if ([host isKindOfClass:UITableViewController.class]) [[(UITableViewController *)host tableView] reloadData];
        LeadWarpMessage(host, port > 0 ? @"تم تأكيد WARP عبر النفق. جرّب مكالمة فردية جديدة. نقل الوسائط الجماعية غير مدعوم بعد." : @"فشل فحص اتصال WARP. لم يتم تغيير مسار البروكسي الحالي.");
      });
    });
  }]];
  [host presentViewController:alert animated:YES completion:nil];
#else
  LeadWarpMessage(host, @"محرك WireGuard التجريبي غير مضمّن في هذا البناء. لم يتم تغيير اتصال تيليجرام.");
#endif
}
