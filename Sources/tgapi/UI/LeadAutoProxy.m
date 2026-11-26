#import "LeadMenu.h"
#import "KiraProxyGateway.h"
#import "Headers.h"
#import "../Headers.h"
#import <objc/message.h>
#import <sys/socket.h>
#import <netdb.h>
#import <poll.h>
#import <fcntl.h>
#import <errno.h>
#import <unistd.h>

// Public gateway: the Worker returns a single selected proxy and its ordinal.
static const NSTimeInterval kLeadAutoProxyRefreshInterval = 20 * 60;
static const NSUInteger kLeadAutoProxyMaxEntries = 20;

#pragma mark - Link parsing

static NSString *LeadProxyEncode(NSString *value) {
  static NSCharacterSet *allowed;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableCharacterSet *set = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [set addCharactersInString:@"-._~"];
    allowed = set;
  });
  return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

static BOOL LeadProxyStringIsMadeOf(NSString *value, NSString *extra) {
  if (value.length == 0) return NO;
  NSMutableCharacterSet *set = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
  [set addCharactersInString:extra];
  return [value rangeOfCharacterFromSet:set.invertedSet].location == NSNotFound;
}

// Telegram's secret formats: hex, or base64 / base64url. The result keeps the leading type
// byte (dd = secure, ee = fake-TLS …), which is what MTSocksProxySettings expects.
static NSData *LeadProxySecretData(NSString *secret) {
  if (secret.length == 0) return nil;
  NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
  if (secret.length % 2 == 0 && [secret rangeOfCharacterFromSet:hexSet.invertedSet].location == NSNotFound) {
    NSMutableData *data = [NSMutableData dataWithCapacity:secret.length / 2];
    for (NSUInteger i = 0; i < secret.length; i += 2) {
      unsigned int byte = 0;
      [[NSScanner scannerWithString:[secret substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&byte];
      uint8_t b = (uint8_t)byte;
      [data appendBytes:&b length:1];
    }
    return data;
  }
  NSString *b64 = [[secret stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
      stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
  while (b64.length % 4) b64 = [b64 stringByAppendingString:@"="];
  return [[NSData alloc] initWithBase64EncodedString:b64 options:0];
}

// -> @{ kind, server, port(NSNumber), secret?, user?, pass? } or nil.
static NSDictionary *LeadProxyParseLink(NSString *link) {
  NSString *text = [link stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (text.length == 0 || text.length > 2048) return nil;
  if ([text rangeOfString:@"://"].location == NSNotFound) text = [@"https://" stringByAppendingString:text];
  NSURLComponents *components = [NSURLComponents componentsWithString:text];
  if (!components) return nil;

  NSString *scheme = components.scheme.lowercaseString;
  NSString *host = components.host.lowercaseString;
  NSString *kind = nil;
  if ([scheme isEqualToString:@"tg"]) {
    kind = host;
  } else if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
    if ([host isEqualToString:@"t.me"] || [host isEqualToString:@"telegram.me"] ||
        [host isEqualToString:@"telegram.dog"]) {
      kind = [components.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]].lowercaseString;
    }
  }
  if (![kind isEqualToString:@"proxy"] && ![kind isEqualToString:@"socks"]) return nil;

  NSMutableDictionary<NSString *, NSString *> *query = [NSMutableDictionary dictionary];
  for (NSURLQueryItem *item in components.queryItems) {
    if (item.name.length && item.value.length) query[item.name.lowercaseString] = item.value;
  }
  NSString *server = query[@"server"];
  if (!LeadProxyStringIsMadeOf(server, @".-:_")) return nil;
  NSInteger port = [query[@"port"] integerValue];
  if (port < 1 || port > 65535) return nil;

  NSMutableDictionary *result = [@{ @"kind" : kind, @"server" : server, @"port" : @(port) } mutableCopy];
  NSString *secret = query[@"secret"];
  if (secret.length && [kind isEqualToString:@"proxy"]) {
    NSData *data = LeadProxySecretData(secret);
    if (data.length < 16 || !LeadProxyStringIsMadeOf(secret, @"-_+/=")) return nil;
    result[@"secret"] = secret;
  }
  if (query[@"user"].length) result[@"user"] = query[@"user"];
  if (query[@"pass"].length) result[@"pass"] = query[@"pass"];
  return result;
}

static NSString *LeadProxyLinkFromParsed(NSDictionary *p) {
  NSMutableString *link = [NSMutableString stringWithFormat:@"tg://%@?server=%@&port=%@",
                                                            p[@"kind"], LeadProxyEncode(p[@"server"]), p[@"port"]];
  if (p[@"secret"]) [link appendFormat:@"&secret=%@", LeadProxyEncode(p[@"secret"])];
  if (p[@"user"]) [link appendFormat:@"&user=%@", LeadProxyEncode(p[@"user"])];
  if (p[@"pass"]) [link appendFormat:@"&pass=%@", LeadProxyEncode(p[@"pass"])];
  return link;
}

NSString *LeadAutoProxyNormalizedLink(NSString *link) {
  NSDictionary *parsed = LeadProxyParseLink(link);
  return parsed ? LeadProxyLinkFromParsed(parsed) : nil;
}

#pragma mark - Reachability

// Plain TCP connect, off the proxy, so a dead server is skipped instead of chosen.
static BOOL LeadProxySOCKSGreeting(int fd, BOOL hasCredentials, int timeoutMs) {
  // The socket is nonblocking and already connected. Check the actual protocol,
  // not just whether an unrelated service happens to listen on the port.
  int noSigPipe = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
  const uint8_t hello[] = { 5, (uint8_t)(hasCredentials ? 2 : 1), 0, 2 };
  size_t length = hasCredentials ? 4 : 3;
  if (send(fd, hello, length, 0) != (ssize_t)length) return NO;
  uint8_t reply[2];
  size_t received = 0;
  while (received < sizeof(reply)) {
    struct pollfd ready = { .fd = fd, .events = POLLIN, .revents = 0 };
    if (poll(&ready, 1, timeoutMs) <= 0) return NO;
    ssize_t n = recv(fd, reply + received, sizeof(reply) - received, 0);
    if (n <= 0) return NO;
    received += (size_t)n;
  }
  return reply[0] == 5 && (reply[1] == 0 || (hasCredentials && reply[1] == 2));
}
static BOOL LeadProxyProbe(NSString *host, int port, int timeoutMs, BOOL socks, BOOL hasCredentials) {
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  struct addrinfo *res = NULL;
  char portString[8];
  snprintf(portString, sizeof(portString), "%d", port);
  if (getaddrinfo(host.UTF8String, portString, &hints, &res) != 0 || !res) return NO;
  BOOL ok = NO;
  for (struct addrinfo *ai = res; ai && !ok; ai = ai->ai_next) {
    int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (fd < 0) continue;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    int rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
    if (rc == 0) {
      ok = YES;
    } else if (errno == EINPROGRESS) {
      struct pollfd pfd = { .fd = fd, .events = POLLOUT, .revents = 0 };
      if (poll(&pfd, 1, timeoutMs) > 0) {
        int err = 0;
        socklen_t len = sizeof(err);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0) ok = YES;
      }
    }
    if (ok && socks) ok = LeadProxySOCKSGreeting(fd, hasCredentials, timeoutMs);
    close(fd);
  }
  freeaddrinfo(res);
  return ok;
}

// First link, in list order, whose server answers; nil when none does.
// WARP remains first for calls; otherwise use only the call server last returned by the gateway.
extern NSDictionary *LeadWarpCallProxy(void);
static NSObject *LeadProxyLock(void);
static NSDictionary *sLeadGatewayCallInfo;
static NSDictionary *LeadCallProxyChoose(void) {
  NSDictionary *warp = LeadWarpCallProxy();
  if (warp) return warp;
  @synchronized(LeadProxyLock()) { return sLeadGatewayCallInfo; }
}

#pragma mark - State

static NSObject *LeadProxyLock(void) {
  static NSObject *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [NSObject new]; });
  return lock;
}

// Temporary managed signaling override for native group calls; never persisted.
static id sLeadGroupProxySettings = nil;
static NSUInteger sLeadGroupProxyUsers = 0;
static BOOL sLeadCallRPCActive = NO;
static NSUInteger sLeadCallEpoch = 0;
static NSDictionary *sLeadCallProxyInfo = nil;
// Keep manual settings for each context, including an explicit nil.
static NSMapTable *sLeadCallPrevious = nil;
NSDictionary *LeadCallProxyNext(void) {
  @synchronized(LeadProxyLock()) {
    return sLeadCallProxyInfo ?: LeadCallProxyChoose();
  }
}
static id sLeadProxySettings = nil;               // MTSocksProxySettings in use, nil = off
static NSString *sLeadProxyLink = nil;            // canonical link behind it
static NSUInteger sLeadProxyIndex = NSNotFound;   // 0-based ordinal from the gateway
static NSHashTable *sLeadProxyOwn = nil;          // every settings object we ever made (weak)
static NSHashTable *sLeadProxyContexts = nil;     // live MTContexts (weak)

static BOOL LeadProxyEnabled(void) {
  return [[NSUserDefaults standardUserDefaults] boolForKey:kAutoProxy];
}

static id LeadProxyMakeSettings(NSDictionary *p) {
  Class cls = NSClassFromString(@"MTSocksProxySettings");
  SEL sel = NSSelectorFromString(@"initWithIp:port:username:password:secret:");
  if (!cls || ![cls instancesRespondToSelector:sel]) {
    NSLog(@"[Kira] AutoProxy: MTSocksProxySettings not available in this Telegram build");
    return nil;
  }
  NSData *secret = p[@"secret"] ? LeadProxySecretData(p[@"secret"]) : nil;
  typedef id (*InitFn)(id, SEL, NSString *, uint16_t, NSString *, NSString *, NSData *);
  return ((InitFn)objc_msgSend)([cls alloc], sel, p[@"server"], (uint16_t)[p[@"port"] intValue],
                                p[@"user"], p[@"pass"], secret);
}

// Makes `link` the proxy in use. NO when nothing changed or it can't be built.
static BOOL LeadProxyActivate(NSString *link, NSUInteger index) {
  NSDictionary *p = LeadProxyParseLink(link);
  if (!p) return NO;
  NSString *canonical = LeadProxyLinkFromParsed(p);
  @synchronized(LeadProxyLock()) {
    if (sLeadProxySettings && [sLeadProxyLink isEqualToString:canonical]) { sLeadProxyIndex = index; return NO; }
  }
  id settings = LeadProxyMakeSettings(p);
  if (!settings) return NO;
  @synchronized(LeadProxyLock()) {
    if (!sLeadProxyOwn) sLeadProxyOwn = [NSHashTable weakObjectsHashTable];
    [sLeadProxyOwn addObject:settings];
    sLeadProxySettings = settings;
    sLeadProxyLink = canonical;
    sLeadProxyIndex = index;
  }
  NSLog(@"[Kira] AutoProxy: active server updated");
  return YES;
}

static void LeadProxyDeactivate(void) {
  @synchronized(LeadProxyLock()) {
    sLeadProxySettings = nil;
    sLeadProxyLink = nil;
    sLeadProxyIndex = NSNotFound;
  }
}

id LeadAutoProxyCurrentSettings(void) {
  @synchronized(LeadProxyLock()) {
    return sLeadProxySettings;
  }
}

// Match the effective settings of this request's account, including manual selections.
NSString *LeadListedProxyForService(id service) {
  @try {
    id settings = [service valueForKeyPath:@"context.apiEnvironment.socksProxySettings"];
    NSString *ip = [settings valueForKey:@"ip"];
    NSNumber *port = [settings valueForKey:@"port"];
    NSData *secret = [settings valueForKey:@"secret"];
    if (!ip.length || !secret.length) return nil;
    NSString *active;
    @synchronized(LeadProxyLock()) { active = sLeadProxyLink; }
    for (NSString *link in (active.length ? @[active] : @[])) {
      NSDictionary *p = LeadProxyParseLink(link);
      if ([p[@"kind"] isEqual:@"proxy"] && [p[@"port"] isEqual:port] &&
          [ip caseInsensitiveCompare:p[@"server"]] == NSOrderedSame &&
          [secret isEqual:LeadProxySecretData(p[@"secret"])]) return link;
    }
  } @catch (__unused NSException *e) {}
  return nil;
}

void LeadAutoProxyRememberContext(id context) {
  if (!context) return;
  @synchronized(LeadProxyLock()) {
    if (!sLeadProxyContexts) sLeadProxyContexts = [NSHashTable weakObjectsHashTable];
    [sLeadProxyContexts addObject:context];
  }
}

// The name is the permanent list position, not the order of the reachability results.
// Keep the actual host, port and token internal; never use them as UI text.
static NSString *LeadProxyDisplayName(NSUInteger index) {
  NSArray<NSString *> *ordinals = @[
    @"الأول", @"الثاني", @"الثالث", @"الرابع", @"الخامس", @"السادس",
    @"السابع", @"الثامن", @"التاسع", @"العاشر", @"الحادي عشر", @"الثاني عشر",
    @"الثالث عشر", @"الرابع عشر", @"الخامس عشر", @"السادس عشر", @"السابع عشر",
    @"الثامن عشر", @"التاسع عشر", @"العشرون"
  ];
  if (index >= ordinals.count) return @"الخادم غير المدرج";
  return [@"الخادم " stringByAppendingString:ordinals[index]];
}

NSString *LeadAutoProxySummary(void) {
  @synchronized(LeadProxyLock()) {
    return sLeadProxySettings ? LeadProxyDisplayName(sLeadProxyIndex) : nil;
  }
}

// Pushes the current choice into every live MTContext so open connections are rebuilt.
// Returns NO when no context has been seen yet (the choice then applies on the next launch).
static BOOL LeadProxyPushToContexts(void) {
  NSArray *contexts;
  @synchronized(LeadProxyLock()) { contexts = sLeadProxyContexts.allObjects; }
  if (contexts.count == 0) return NO;
  SEL update = NSSelectorFromString(@"updateApiEnvironment:");
  SEL withProxy = NSSelectorFromString(@"withUpdatedSocksProxySettings:");
  for (id context in contexts) {
    if (![context respondsToSelector:update]) continue;
    id (^block)(id) = ^id(id environment) {
      if (!environment || ![environment respondsToSelector:withProxy]) return nil;
      // Read the real property, not the fallback injected by Hooks.xm.
      NSMutableDictionary *thread = NSThread.currentThread.threadDictionary;
      id oldFlag = thread[@"LeadRawProxyRead"];
      thread[@"LeadRawProxyRead"] = @YES;
      id current = nil;
      @try { current = [environment valueForKey:@"socksProxySettings"]; }
      @catch (__unused NSException *e) { return nil; }
      @finally {
        if (oldFlag) thread[@"LeadRawProxyRead"] = oldFlag;
        else [thread removeObjectForKey:@"LeadRawProxyRead"];
      }
      id desired = nil;
      @synchronized(LeadProxyLock()) {
        BOOL currentIsOurs = current && [sLeadProxyOwn containsObject:current];
        if (sLeadGroupProxySettings) {
          if (!sLeadCallPrevious) sLeadCallPrevious = [NSMapTable weakToStrongObjectsMapTable];
          if (![sLeadCallPrevious objectForKey:context]) {
            [sLeadCallPrevious setObject:(current && !currentIsOurs ? current : NSNull.null) forKey:context];
          }
          desired = sLeadGroupProxySettings;
        } else {
          id previous = [sLeadCallPrevious objectForKey:context];
          if (previous) {
            [sLeadCallPrevious removeObjectForKey:context];
            // Restore explicit manual choice; otherwise the current ordinary auto choice.
            desired = previous == NSNull.null ? sLeadProxySettings : previous;
          } else {
            if (current && !currentIsOurs) return nil;
            desired = sLeadProxySettings;
          }
        }
      }
      if (current == desired || (current && [current isEqual:desired])) return nil;
      return ((id (*)(id, SEL, id))objc_msgSend)(environment, withProxy, desired);
    };
    ((void (*)(id, SEL, id))objc_msgSend)(context, update, block);
  }
  return YES;
}

// RPC entry points run before the outgoing request; native contexts keep the
// same selected server alive. Only normal MTProto routing is restored afterward.
static BOOL LeadEnsureCallProxy(void) {
  @synchronized(LeadProxyLock()) {
    if (sLeadGroupProxySettings) return YES;
    NSDictionary *p = LeadCallProxyChoose();
    id settings = p ? LeadProxyMakeSettings(p) : nil;
    if (!settings) return NO;
    if (!sLeadProxyOwn) sLeadProxyOwn = [NSHashTable weakObjectsHashTable];
    [sLeadProxyOwn addObject:settings];
    sLeadGroupProxySettings = settings;
    sLeadCallProxyInfo = p;
    NSLog(@"[Kira] Call route SOCKS5 %@:%@", p[@"server"], p[@"port"]);
    return YES;
  }
}
static void LeadRestoreCallProxyIfIdle(void) {
  BOOL changed = NO;
  @synchronized(LeadProxyLock()) {
    if (!sLeadCallRPCActive && !sLeadGroupProxyUsers && sLeadGroupProxySettings) {
      sLeadGroupProxySettings = nil;
      sLeadCallProxyInfo = nil;
      changed = YES;
    }
  }
  if (changed) LeadProxyPushToContexts();
}
BOOL LeadCallSignalingBegin(id service) {
  @try {
    id context = [service valueForKey:@"context"];
    if (context) LeadAutoProxyRememberContext(context);
  } @catch (__unused NSException *e) {}
  NSUInteger epoch;
  @synchronized(LeadProxyLock()) {
    if (!LeadEnsureCallProxy()) return NO;
    sLeadCallRPCActive = YES;
    epoch = ++sLeadCallEpoch;
  }
  LeadProxyPushToContexts();
  // An abandoned pre-connect attempt must not leave a SOCKS5 override forever.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150LL * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    @synchronized(LeadProxyLock()) {
      if (epoch != sLeadCallEpoch || sLeadGroupProxyUsers) return;
      sLeadCallRPCActive = NO;
    }
    LeadRestoreCallProxyIfIdle();
  });
  return YES;
}
// A restarted local tunnel receives a different port and credentials.
 // Discard only the managed call override and rebuild it for an active call.
 void LeadWarpRouteDidChange(void) {
   BOOL rebuild = NO;
   @synchronized(LeadProxyLock()) {
     if (sLeadGroupProxySettings) {
       sLeadGroupProxySettings = nil;
       sLeadCallProxyInfo = nil;
       rebuild = YES;
     }
     if (sLeadCallRPCActive || sLeadGroupProxyUsers) {
       rebuild = LeadEnsureCallProxy() || rebuild;
     }
   }
   if (rebuild) LeadProxyPushToContexts();
 }
 void LeadCallSignalingEnd(void) {
  @synchronized(LeadProxyLock()) { sLeadCallRPCActive = NO; ++sLeadCallEpoch; }
  LeadRestoreCallProxyIfIdle();
}
void LeadGroupCallProxyBegin(void) {
  @synchronized(LeadProxyLock()) {
    ++sLeadGroupProxyUsers;
    if (!LeadEnsureCallProxy()) return;
  }
  LeadProxyPushToContexts();
}
void LeadGroupCallProxyEnd(void) {
  @synchronized(LeadProxyLock()) {
    if (sLeadGroupProxyUsers) --sLeadGroupProxyUsers;
    if (!sLeadGroupProxyUsers) { sLeadCallRPCActive = NO; ++sLeadCallEpoch; }
  }
  LeadRestoreCallProxyIfIdle();
}

#pragma mark - Refresh

NSString *LeadAutoProxyConfigHost(void) { return KiraGatewayHost(); }

static BOOL LeadGatewayProbe(NSDictionary *p) {
  return p && LeadProxyProbe(p[@"server"], [p[@"port"] intValue], 2500,
                             [p[@"kind"] isEqual:@"socks"], [p[@"user"] length] > 0);
}

// Refresh the separate call pool without disclosing a list. An empty pool is
// intentional; WARP continues to be selected independently when enabled.
static void LeadGatewayRefreshCallPool(void) {
  NSInteger status = 0;
  NSDictionary *response = KiraGatewayProxy(@"call", @"current", &status);
  if (response && [response[@"total"] integerValue] == 0) {
    @synchronized(LeadProxyLock()) { sLeadGatewayCallInfo = nil; }
    return;
  }
  if (!response) return;
  NSUInteger total = MIN([response[@"total"] unsignedIntegerValue], kLeadAutoProxyMaxEntries);
  for (NSUInteger i = 0; i < total; i++) {
    id entry = response[@"proxy"];
    if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"link"] isKindOfClass:NSString.class]) break;
    NSDictionary *p = LeadProxyParseLink(entry[@"link"]);
    if ([p[@"kind"] isEqual:@"socks"] && LeadGatewayProbe(p)) {
      @synchronized(LeadProxyLock()) { sLeadGatewayCallInfo = p; }
      return;
    }
    if (i + 1 < total) response = KiraGatewayProxy(@"call", @"next", &status);
    if (!response) break;
  }
  @synchronized(LeadProxyLock()) { sLeadGatewayCallInfo = nil; }
}

static void LeadAutoProxyRefreshInternal(BOOL rotate, void (^done)(NSString *summary, BOOL reachable)) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ queue = dispatch_queue_create("kira.autoproxy.refresh", DISPATCH_QUEUE_SERIAL); });
  dispatch_async(queue, ^{
    if (!LeadProxyEnabled()) {
      if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(nil, NO); });
      return;
    }
    NSString *active;
    @synchronized(LeadProxyLock()) { active = sLeadProxyLink; }
    NSString *chosen = nil;
    NSUInteger chosenIndex = NSNotFound;
    NSInteger status = 0;
    NSDictionary *response = KiraGatewayProxy(@"normal", rotate ? @"next" : @"current", &status);
    BOOL empty = response && [response[@"total"] integerValue] == 0;
    NSUInteger total = MIN([response[@"total"] unsignedIntegerValue], kLeadAutoProxyMaxEntries);
    for (NSUInteger i = 0; i < total; i++) {
      id entry = response[@"proxy"];
      if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"link"] isKindOfClass:NSString.class]) break;
      NSString *link = LeadAutoProxyNormalizedLink(entry[@"link"]);
      NSUInteger index = [entry[@"index"] unsignedIntegerValue];
      if (link.length && index >= 1 && index <= total &&
          !(rotate && [link isEqualToString:active]) &&
          LeadGatewayProbe(LeadProxyParseLink(link))) {
        chosen = link; chosenIndex = index - 1; break;
      }
      if (i + 1 < total) response = KiraGatewayProxy(@"normal", @"next", &status);
      if (!response) break;
    }
    [[NSUserDefaults standardUserDefaults] setDouble:NSDate.date.timeIntervalSince1970 forKey:kAutoProxyChecked];

    dispatch_async(dispatch_get_main_queue(), ^{
      BOOL applied = NO;
      if (LeadProxyEnabled()) {
        if (empty) {
          LeadProxyDeactivate();
          @synchronized(LeadProxyLock()) { sLeadGatewayCallInfo = nil; }
          LeadProxyPushToContexts();
        } else if (chosen.length) {
          if (LeadProxyActivate(chosen, chosenIndex)) LeadProxyPushToContexts();
          @synchronized(LeadProxyLock()) { applied = [sLeadProxyLink isEqualToString:chosen]; }
        }
      }
      if (done) done(LeadAutoProxySummary(), applied);
    });

    // A proxy rotation does not need to refresh the call pool.
    if (!rotate && status != 429) LeadGatewayRefreshCallPool();
  });
}

void LeadAutoProxyRefresh(void (^done)(NSString *summary, BOOL reachable)) { LeadAutoProxyRefreshInternal(NO, done); }
void LeadAutoProxyRotate(void (^done)(NSString *summary, BOOL reachable)) { LeadAutoProxyRefreshInternal(YES, done); }

#pragma mark - Menu

void LeadAutoProxySetEnabled(BOOL on) {
  if (on) {
    LeadAutoProxyRefresh(nil);
  } else {
    LeadProxyDeactivate();
    if (!LeadProxyPushToContexts()) LeadNotifySettingsChanged();
  }
}

#pragma mark - Launch

void LeadAutoProxyInstall(void) {
  static BOOL installed = NO;
  if (installed) return;
  installed = YES;

  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  // Purge publicly distributed list data left in preferences by older versions.
  for (NSString *key in @[kAutoProxyConfigURL, kAutoProxyList, kAutoProxyActive,
                          @"LeadAutoProxyCacheSource", @"LeadCallProxyList", @"KiraCallProxyReachableV2"]) {
    [defaults removeObjectForKey:key];
  }

  // Refresh every launch, and periodically while foregrounded (no background polling).
  if (LeadProxyEnabled()) {
    [defaults setDouble:[NSDate date].timeIntervalSince1970 forKey:kAutoProxyChecked];
    LeadAutoProxyRefresh(nil);
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSTimer scheduledTimerWithTimeInterval:kLeadAutoProxyRefreshInterval repeats:YES block:^(__unused NSTimer *timer) {
      if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive && LeadProxyEnabled()) {
        LeadAutoProxyRefresh(nil);
      }
    }];
  });
  [[NSNotificationCenter defaultCenter]
      addObserverForName:UIApplicationDidBecomeActiveNotification
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(__unused NSNotification *note) {
    if (!LeadProxyEnabled()) return;
    NSTimeInterval last = [[NSUserDefaults standardUserDefaults] doubleForKey:kAutoProxyChecked];
    if ([NSDate date].timeIntervalSince1970 - last < kLeadAutoProxyRefreshInterval) return;
    LeadAutoProxyRefresh(nil);
  }];
}
