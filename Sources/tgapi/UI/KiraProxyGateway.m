#import "KiraProxyGateway.h"

// Replace ONLY this origin after deploying the Worker. No trailing slash.
// Public selection endpoint; no activation code, authorization token or proxy list.
static NSString *const kGatewayOrigin = @"https://proxiex.ikiraplus.workers.dev";
static NSMutableDictionary<NSString *, NSString *> *sCursors;

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
// Never follow a redirected gateway response to an untrusted origin.
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
static NSDictionary *GatewayPost(NSString *path, NSDictionary *body, NSInteger *status) {
  if (status) *status = 0;
  NSURL *base = KiraGatewayBase();
  if (!base) return nil;
  NSURL *url = [NSURL URLWithString:path relativeToURL:base];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
  req.HTTPMethod = @"POST";
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
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
// Store only one opaque cursor per pool in memory; no credentials or codes.
NSDictionary *KiraGatewayProxy(NSString *pool, NSString *mode, NSInteger *status) {
  if (status) *status = 0;
  if (![@[@"normal", @"call"] containsObject:pool] ||
      ![@[@"current", @"next"] containsObject:mode]) return nil;
  @synchronized(GatewayLock()) {
    if (!sCursors) sCursors = [NSMutableDictionary new];
    NSMutableDictionary *args = [@{@"pool":pool, @"mode":mode} mutableCopy];
    NSString *cursor = sCursors[pool];
    if (cursor.length) args[@"cursor"] = cursor;
    NSDictionary *reply = GatewayPost(@"/v1/public/proxy", args, status);
    if (!reply) return nil;
    NSNumber *total = reply[@"total"];
    if (![total isKindOfClass:NSNumber.class] || total.integerValue < 0 || total.integerValue > 20) return nil;
    if (total.integerValue == 0 && reply[@"proxy"] == NSNull.null) {
      [sCursors removeObjectForKey:pool]; return reply;
    }
    id entry = reply[@"proxy"];
    NSString *nextCursor = reply[@"cursor"];
    if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"link"] isKindOfClass:NSString.class] ||
        ![entry[@"index"] isKindOfClass:NSNumber.class] || [entry[@"index"] integerValue] < 1 ||
        [entry[@"index"] integerValue] > total.integerValue ||
        ![nextCursor isKindOfClass:NSString.class] || nextCursor.length != 64 ||
        [nextCursor rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound) return nil;
    sCursors[pool] = nextCursor;
    return reply;
  }
}
