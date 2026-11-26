#import "KiraProxyGateway.h"
#import <Security/Security.h>

// Replace ONLY this origin after deploying the Worker. No trailing slash.
// Do not insert an admin token, activation code or proxy link here.
static NSString *const kGatewayOrigin = @"https://proxiex.ikiraplus.workers.dev";
static NSString *sSession;
static NSTimeInterval sSessionUntil;

static NSURL *KiraGatewayBase(void) {
  NSURL *url = [NSURL URLWithString:kGatewayOrigin];
  if (![url.scheme.lowercaseString isEqualToString:@"https"] || !url.host.length ||
      [url.host.lowercaseString isEqualToString:@"replace-me.workers.dev"] ||
      url.user || url.password || url.query || url.fragment ||
      (url.path.length && ![url.path isEqualToString:@"/"])) return nil;
  return url;
}
NSString *KiraGatewayHost(void) { return KiraGatewayBase().host; }

static NSObject *GatewayLock(void) {
  static NSObject *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [NSObject new]; });
  return lock;
}
static NSDictionary *TokenQuery(void) {
  return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
           (__bridge id)kSecAttrService:@"com.kira.proxy.gateway.v1",
           (__bridge id)kSecAttrAccount:(KiraGatewayHost() ?: @"unconfigured")};
}
static NSString *ReadDeviceToken(void) {
  NSMutableDictionary *query = [TokenQuery() mutableCopy];
  query[(__bridge id)kSecReturnData] = @YES;
  query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
  CFTypeRef result = NULL;
  if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess) return nil;
  NSData *data = CFBridgingRelease(result);
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
static BOOL SaveDeviceToken(NSString *token) {
  NSDictionary *base = TokenQuery();
  NSData *data = [token dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *attrs = @{(__bridge id)kSecValueData:data};
  OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)base, (__bridge CFDictionaryRef)attrs);
  if (status == errSecSuccess) return YES;
  if (status != errSecItemNotFound) return NO;
  NSMutableDictionary *entry = [base mutableCopy];
  [entry addEntriesFromDictionary:attrs];
  entry[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
  return SecItemAdd((__bridge CFDictionaryRef)entry, NULL) == errSecSuccess;
}
static void ForgetDeviceToken(void) {
  SecItemDelete((__bridge CFDictionaryRef)TokenQuery());
  sSession = nil; sSessionUntil = 0;
}
BOOL KiraGatewayIsActivated(void) { return ReadDeviceToken().length > 0; }

// Never forward authorization headers to a redirected origin.
@interface KiraGatewaySessionDelegate : NSObject <NSURLSessionTaskDelegate>
@end
@implementation KiraGatewaySessionDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
  completionHandler(nil);
}
@end
static NSURLSession *GatewaySession(void) {
  static NSURLSession *session;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.URLCache = nil;
    config.HTTPCookieStorage = nil;
    config.URLCredentialStorage = nil;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.timeoutIntervalForRequest = 8;
    config.timeoutIntervalForResource = 10;
    session = [NSURLSession sessionWithConfiguration:config delegate:[KiraGatewaySessionDelegate new] delegateQueue:nil];
  });
  return session;
}
static NSDictionary *GatewayPost(NSString *path, NSString *token, NSDictionary *body, NSInteger *status) {
  if (status) *status = 0;
  NSURL *base = KiraGatewayBase();
  if (!base) return nil;
  NSURL *url = [NSURL URLWithString:path relativeToURL:base];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
  req.HTTPMethod = @"POST";
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  if (token.length) [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
  req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body ?: @{} options:0 error:nil];
  __block NSDictionary *result = nil;
  __block NSInteger code = 0;
  dispatch_semaphore_t gate = dispatch_semaphore_create(0);
  NSURLSessionDataTask *task = [GatewaySession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    if (!error && [response isKindOfClass:NSHTTPURLResponse.class]) {
      code = [(NSHTTPURLResponse *)response statusCode];
      if (code == 200 && data.length && data.length < 65536) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([json isKindOfClass:NSDictionary.class]) result = json;
      }
    }
    dispatch_semaphore_signal(gate);
  }];
  [task resume];
  if (dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, 11 * NSEC_PER_SEC)) != 0) {
    [task cancel];
    return nil;
  }
  if (status) *status = code;
  return result;
}
static BOOL UseSession(NSDictionary *response) {
  NSString *token = response[@"sessionToken"];
  NSNumber *expires = response[@"expiresIn"];
  if (![token isKindOfClass:NSString.class] || token.length != 64 ||
      ![expires isKindOfClass:NSNumber.class] || expires.integerValue < 30) return NO;
  sSession = token;
  sSessionUntil = NSDate.date.timeIntervalSince1970 + MIN(expires.integerValue, 600) - 15;
  return YES;
}
void KiraGatewayActivate(NSString *code, void (^completion)(NSInteger status)) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSInteger status = 0;
    @synchronized(GatewayLock()) {
      NSDictionary *reply = GatewayPost(@"/v1/activate", nil, @{@"code":code ?: @""}, &status);
      NSString *token = reply[@"deviceToken"];
      if (status == 200) {
        if (![token isKindOfClass:NSString.class] || token.length != 64 || !UseSession(reply) || !SaveDeviceToken(token)) {
          sSession = nil; sSessionUntil = 0; status = -1;
        }
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(status); });
  });
}
static BOOL RefreshSession(NSInteger *status) {
  NSString *device = ReadDeviceToken();
  if (!device.length) { if (status) *status = 401; return NO; }
  NSInteger code = 0;
  NSDictionary *reply = GatewayPost(@"/v1/session", device, @{}, &code);
  if (code == 401) ForgetDeviceToken();
  if (status) *status = code;
  if (!UseSession(reply)) { sSession = nil; sSessionUntil = 0; return NO; }
  return YES;
}
NSDictionary *KiraGatewayProxy(NSString *pool, NSString *mode, NSInteger *status) {
  @synchronized(GatewayLock()) {
    if (!sSession.length || sSessionUntil <= NSDate.date.timeIntervalSince1970) {
      if (!RefreshSession(status)) return nil;
    }
    NSInteger code = 0;
    NSDictionary *args = @{@"pool":pool, @"mode":mode};
    NSDictionary *reply = GatewayPost(@"/v1/proxy", sSession, args, &code);
    if (code == 401) {
      sSession = nil; sSessionUntil = 0;
      if (!RefreshSession(status)) return nil;
      reply = GatewayPost(@"/v1/proxy", sSession, args, &code);
    }
    if (status) *status = code;
    return reply;
  }
}
