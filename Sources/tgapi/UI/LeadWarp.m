#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <stdlib.h>

#ifndef LEAD_WARP_EXPERIMENTAL
#define LEAD_WARP_EXPERIMENTAL 0
#endif

#if LEAD_WARP_EXPERIMENTAL
extern int LeadWarpStart(char *, char *, char *);
extern char *LeadWarpRegister(int *status);
extern void LeadWarpStop(void);
#endif

static NSDictionary *sWarpRoute;
#if LEAD_WARP_EXPERIMENTAL
static BOOL sWarpBusy;
#endif

#if LEAD_WARP_EXPERIMENTAL
// Access only within the app's own Keychain group; never use a shared profile.
static NSString *sWarpSessionProfile;
static NSDictionary *LeadWarpKeychainQuery(void) {
  return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
           (__bridge id)kSecAttrService:@"com.lead.warp.profile.v1",
           (__bridge id)kSecAttrAccount:@"wireguard"};
}
static NSString *LeadWarpLoadProfile(void) {
  if (sWarpSessionProfile.length) return sWarpSessionProfile;
  NSMutableDictionary *query = [LeadWarpKeychainQuery() mutableCopy];
  query[(__bridge id)kSecReturnData] = @YES;
  query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
  CFTypeRef item = NULL;
  if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &item) != errSecSuccess) return nil;
  NSData *data = CFBridgingRelease(item);
  sWarpSessionProfile = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return sWarpSessionProfile;
}
static void LeadWarpSaveProfile(NSString *profile) {
  sWarpSessionProfile = [profile copy];
  NSData *data = [profile dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *query = LeadWarpKeychainQuery();
  NSDictionary *changes = @{(__bridge id)kSecValueData:data};
  OSStatus result = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)changes);
  if (result == errSecItemNotFound) {
    NSMutableDictionary *item = [query mutableCopy];
    [item addEntriesFromDictionary:changes];
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
    SecItemAdd((__bridge CFDictionaryRef)item, NULL);
  }
  // If signing prevents Keychain access, reuse the profile in this process only.
}
static NSString *LeadWarpRegistrationError(int status) {
  if (status == 429) return @"خدمة WARP حدّت طلبات التسجيل. حاول لاحقاً.";
  if (status == 403 || status == 401) return @"خدمة WARP رفضت التسجيل غير الرسمي.";
  if (status == -11) return @"تعذر الاتصال بخدمة تسجيل WARP.";
  if (status == -12) return @"لم ترسل خدمة WARP إعدادات WireGuard صالحة.";
  return [NSString stringWithFormat:@"فشل تسجيل WARP (%d).", status];
}
#endif


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
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"تجاوز حظر الاتصالات" message:@"سيُنشئ Lead إعدادات WARP لهذا الجهاز تلقائياً باستخدام خدمة تسجيل Cloudflare غير الرسمية. المفتاح الخاص يبقى على الجهاز. هذه نسخة تجريبية للمكالمات الفردية عبر TCP. بالمتابعة توافق على شروط Cloudflare." preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:@"شروط الاستخدام" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://www.cloudflare.com/application/terms/"] options:@{} completionHandler:nil];
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"اتصال" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
    @synchronized([NSUserDefaults class]) {
      if (sWarpBusy || sWarpRoute) return;
      sWarpBusy = YES;
    }
    if ([host isKindOfClass:UITableViewController.class]) [[(UITableViewController *)host tableView] reloadData];
    NSString *user = NSUUID.UUID.UUIDString;
    NSString *pass = NSUUID.UUID.UUIDString;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      NSString *profile = LeadWarpLoadProfile();
      int registrationStatus = 0;
      if (!profile.length) {
        char *raw = LeadWarpRegister(&registrationStatus);
        if (raw) {
          profile = [NSString stringWithUTF8String:raw];
          free(raw);
          if (profile.length) LeadWarpSaveProfile(profile);
        }
      }
      int port = profile.length ? LeadWarpStart((char *)profile.UTF8String, (char *)user.UTF8String, (char *)pass.UTF8String) : -10;
      NSString *message = !profile.length ? LeadWarpRegistrationError(registrationStatus) :
        (port > 0 && port <= 65535 ? @"تم تأكيد اتصال WARP. جرّب مكالمة فردية جديدة." :
          [NSString stringWithFormat:@"فشل فحص النفق (%d). لم يتم تغيير مسار البروكسي الحالي.", port]);
      dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized([NSUserDefaults class]) {
          if (port > 0 && port <= 65535) sWarpRoute = @{@"kind":@"socks", @"server":@"127.0.0.1", @"port":@(port), @"user":user, @"pass":pass};
          sWarpBusy = NO;
        }
        if ([host isKindOfClass:UITableViewController.class]) [[(UITableViewController *)host tableView] reloadData];
        LeadWarpMessage(host, message);
      });
    });
  }]];
  [host presentViewController:alert animated:YES completion:nil];
#else
  LeadWarpMessage(host, @"محرك WireGuard التجريبي غير مضمّن في هذا البناء. لم يتم تغيير اتصال تيليجرام.");
#endif
}
