#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <stdlib.h>
#import "LeadMenu.h"
#import "Headers.h"

#ifndef LEAD_WARP_EXPERIMENTAL
#define LEAD_WARP_EXPERIMENTAL 0
#endif

#if LEAD_WARP_EXPERIMENTAL
extern int LeadWarpStart(char *, char *, char *);
extern char *LeadWarpRegister(int *status);
extern void LeadWarpStop(void);
extern int LeadWarpHealthCheck(void);
extern void LeadWarpRouteDidChange(void);
#endif

static NSDictionary *sWarpRoute;
#if LEAD_WARP_EXPERIMENTAL
static BOOL sWarpBusy;
static BOOL sWarpStarting;
static BOOL sWarpChecking;
static NSUInteger sWarpFailures;
static NSTimeInterval sWarpNextRetry;
static NSTimeInterval sWarpLastHealth;
static NSString *const kKiraWarpEnabled = @"KiraWarpEnabled";
static BOOL KiraWarpWanted(void) { return [[NSUserDefaults standardUserDefaults] boolForKey:kKiraWarpEnabled]; }
static void KiraWarpSetWanted(BOOL on) { [[NSUserDefaults standardUserDefaults] setBool:on forKey:kKiraWarpEnabled]; }
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
  @synchronized([NSUserDefaults class]) { if (sWarpSessionProfile.length) return sWarpSessionProfile; }
  NSMutableDictionary *query = [LeadWarpKeychainQuery() mutableCopy];
  query[(__bridge id)kSecReturnData] = @YES;
  query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
  CFTypeRef item = NULL;
  if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &item) != errSecSuccess) return nil;
  NSData *data = CFBridgingRelease(item);
  NSString *profile = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  @synchronized([NSUserDefaults class]) { sWarpSessionProfile = profile; }
  return profile;
}
static void LeadWarpSaveProfile(NSString *profile) {
  @synchronized([NSUserDefaults class]) { sWarpSessionProfile = [profile copy]; }
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
  if (status == 429) return LeadL(@"UI_KIRA_WARP_1");
  if (status == 403 || status == 401) return LeadL(@"UI_KIRA_WARP_2");
  if (status == -11) return LeadL(@"UI_KIRA_WARP_3");
  if (status == -12) return LeadL(@"UI_KIRA_WARP_4");
  return [NSString stringWithFormat:LeadL(@"UI_KIRA_WARP_5"), status];
}
#endif


NSDictionary *LeadWarpCallProxy(void) {
  @synchronized([NSUserDefaults class]) { return sWarpRoute; }
}

NSString *LeadWarpStatus(void) {
#if LEAD_WARP_EXPERIMENTAL
  @synchronized([NSUserDefaults class]) {
    if (sWarpBusy) return sWarpStarting ? LeadL(@"UI_KIRA_WARP_6") : LeadL(@"UI_KIRA_WARP_7");
    return sWarpRoute ? LeadL(@"UI_KIRA_WARP_8") : (KiraWarpWanted() ? LeadL(@"UI_KIRA_WARP_18") : LeadL(@"UI_KIRA_WARP_9"));
  }
#else
  return LeadL(@"UI_KIRA_WARP_10");
#endif
}

BOOL LeadWarpIsOn(void) {
#if LEAD_WARP_EXPERIMENTAL
  @synchronized([NSUserDefaults class]) { return KiraWarpWanted() || sWarpRoute != nil || (sWarpBusy && sWarpStarting); }
#else
  return NO;
#endif
}

BOOL LeadWarpCanToggle(void) {
#if LEAD_WARP_EXPERIMENTAL
  @synchronized([NSUserDefaults class]) { return !sWarpBusy; }
#else
  return NO;
#endif
}

static void KiraWarpRefresh(UIViewController *host) {
  if ([host isKindOfClass:UITableViewController.class]) [[(UITableViewController *)host tableView] reloadData];
  [[NSNotificationCenter defaultCenter] postNotificationName:LeadSettingsDidChangeNotification object:nil];
}

#if LEAD_WARP_EXPERIMENTAL
static void KiraWarpStart(UIViewController *host) {
  @synchronized([NSUserDefaults class]) {
    if (sWarpBusy || sWarpRoute) { KiraWarpRefresh(host); return; }
    sWarpBusy = YES;
    sWarpStarting = YES;
  }
  KiraWarpRefresh(host);
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
    BOOL ok = port > 0 && port <= 65535;
    NSString *message = !profile.length ? LeadWarpRegistrationError(registrationStatus) :
      [NSString stringWithFormat:LeadL(@"UI_KIRA_WARP_11"), port];
    dispatch_async(dispatch_get_main_queue(), ^{
      @synchronized([NSUserDefaults class]) {
        sWarpFailures = 0;
        sWarpLastHealth = NSDate.date.timeIntervalSince1970;
        // Back off registration failures as well as tunnel failures.
        sWarpNextRetry = sWarpLastHealth + (profile.length ? 30 : 120);
        sWarpRoute = ok ? @{@"kind":@"socks", @"server":@"127.0.0.1", @"port":@(port), @"user":user, @"pass":pass} : nil;
        sWarpBusy = NO;
        sWarpStarting = NO;
      }
      if (ok) LeadWarpRouteDidChange();
      KiraWarpRefresh(host);
      if (host.viewIfLoaded.window) [LeadToast showText:ok ? LeadL(@"UI_KIRA_WARP_12") : message symbol:ok ? @"checkmark.circle" : @"exclamationmark.circle" inView:host.view];
    });
  });
}

static void KiraWarpMaintain(void) {
  if (!KiraWarpWanted() || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  BOOL start = NO;
  NSDictionary *route;
  @synchronized([NSUserDefaults class]) {
    if (sWarpBusy || sWarpChecking) return;
    route = sWarpRoute;
    if (!route) {
      if (now < sWarpNextRetry) return;
      start = YES;
    } else {
      if (now - sWarpLastHealth < 25) return;
      sWarpChecking = YES;
      sWarpLastHealth = now;
    }
  }
  if (start) { KiraWarpStart(nil); return; }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    BOOL healthy = LeadWarpHealthCheck() == 1;
    dispatch_async(dispatch_get_main_queue(), ^{
      BOOL restart = NO;
      @synchronized([NSUserDefaults class]) {
        sWarpChecking = NO;
        if (!KiraWarpWanted() || sWarpBusy || sWarpRoute != route) return;
        if (healthy) { sWarpFailures = 0; return; }
        // Tolerate one temporary error rather than losing an ongoing call.
        if (++sWarpFailures < 2) return;
        sWarpRoute = nil;
        sWarpBusy = YES;
        sWarpStarting = YES;
        restart = YES;
      }
      if (restart) {
        LeadWarpRouteDidChange();
        KiraWarpRefresh(nil);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
          LeadWarpStop();
          dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized([NSUserDefaults class]) { sWarpBusy = NO; sWarpStarting = NO; }
            if (KiraWarpWanted() && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) KiraWarpStart(nil);
            else KiraWarpRefresh(nil);
          });
        });
      }
    });
  });
}
static void KiraWarpInstall(void) {
  if ([NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"appex"]) return;
  // Opt in only: a fresh installation must not start the tunnel automatically.
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{kKiraWarpEnabled: @NO}];
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
      @synchronized([NSUserDefaults class]) { sWarpLastHealth = 0; }
      KiraWarpMaintain();
    }];
    [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(__unused NSTimer *timer) { KiraWarpMaintain(); }];
    KiraWarpMaintain();
  });
}
__attribute__((constructor)) static void KiraWarpInit(void) {
  @autoreleasepool { KiraWarpInstall(); }
}

#endif

void LeadWarpSetEnabled(BOOL enabled, UIViewController *host) {
#if LEAD_WARP_EXPERIMENTAL
  if (!LeadWarpCanToggle()) { KiraWarpRefresh(host); return; }
  if (!enabled) {
    KiraWarpSetWanted(NO);
    @synchronized([NSUserDefaults class]) {
      if (!sWarpRoute) { KiraWarpRefresh(host); return; }
      sWarpBusy = YES;
      sWarpStarting = NO;
      sWarpRoute = nil;
    }
    LeadWarpRouteDidChange();
    KiraWarpRefresh(host);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      LeadWarpStop();
      dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized([NSUserDefaults class]) { sWarpBusy = NO; }
        KiraWarpRefresh(host);
      });
    });
    return;
  }
  if (LeadWarpCallProxy()) { KiraWarpSetWanted(YES); KiraWarpRefresh(host); return; }
  // Cached profiles were registered with the user's consent. Only first
  // registration requires an explicit choice; normal ON/OFF is immediate.
  if (LeadWarpLoadProfile().length) { KiraWarpSetWanted(YES); KiraWarpStart(host); return; }
  KiraWarpRefresh(host);
  if (!host.viewIfLoaded.window || host.presentedViewController) return;
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:LeadL(@"UI_KIRA_WARP_13")
    message:LeadL(@"UI_KIRA_WARP_14")
    preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:LeadL(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:LeadL(@"UI_KIRA_WARP_16") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://www.cloudflare.com/application/terms/"] options:@{} completionHandler:nil];
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:LeadL(@"UI_KIRA_WARP_17") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { KiraWarpSetWanted(YES); KiraWarpStart(host); }]];
  [host presentViewController:alert animated:YES completion:nil];
#else
  KiraWarpRefresh(host);
#endif
}
