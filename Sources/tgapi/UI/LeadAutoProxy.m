#import "LeadMenu.h"
#import "Headers.h"
#import "../Headers.h"
#import <objc/message.h>
#import <sys/socket.h>
#import <netdb.h>
#import <poll.h>
#import <fcntl.h>
#import <errno.h>
#import <unistd.h>

// ============================================================
// Auto proxy
//
// Telegram connects through a proxy without asking. The proxy comes from a JSON list that
// is fetched over HTTPS; the first entry that answers a TCP connect wins, so the list order
// is the priority order. Change the file and every install follows on its next refresh.
//
// How it reaches Telegram: MtProtoKit asks its MTApiEnvironment for socksProxySettings when
// it opens a connection. Hooks.xm answers with our MTSocksProxySettings whenever Telegram
// itself has no proxy set, so a proxy the user switched on in Telegram always wins, and
// Telegram's own proxy screen never sees or changes ours. When the choice changes while the
// app runs, the new settings are pushed into the live MTContext(s) so connections reset.
//
// JSON file — any of these shapes:
//   { "proxies": [ "https://t.me/proxy?server=…&port=443&secret=…",
//                  { "server": "1.2.3.4", "port": 443, "secret": "dd…" },
//                  { "link": "tg://socks?server=…&port=1080&user=…&pass=…" } ] }
//   [ "https://t.me/proxy?…", … ]
// An entry with "enabled": false is skipped.
// ============================================================

// Fixed first-party configuration endpoint. Never use a saved custom URL.
static NSString *const kLeadAutoProxyConfigURLDefault = @"https://ipastore.pages.dev/proxies.json";

// Offline bootstrap, identical to the published list at release time.
static NSArray<NSString *> *LeadProxyBuiltInLinks(void) {
  return @[
    @"tg://proxy?server=mtproto.online&port=443&secret=7hOeDuNhUMHqO_KZeWWGtUV3d3cudnRiLnJ1",
    @"tg://proxy?server=iq.edu2iq.net&port=443&secret=a4d9c2e8b1f6037ea5c8d4b29f1e6a0c",
    @"tg://proxy?server=91.98.97.225&port=8443&secret=79e344818749bd7ac519130220c25d09",
    @"tg://proxy?server=termsnal.co.uk.&port=8443&secret=79e344818749bd7ac519130220c25d09",
    @"tg://proxy?server=nocloudnew.co.uk.&port=8443&secret=79e344818749bd7ac519130220c25d09"
  ];
}

// Kept separate from the normal MTProto pool; these were tested by the owner.
static NSArray<NSString *> *LeadCallProxyBuiltInLinks(void) {
  return @[
    @"tg://socks?server=45.74.31.40&port=4161",
    @"tg://socks?server=176.9.107.170&port=1083",
    @"tg://socks?server=123.58.219.171&port=10808",
    @"tg://socks?server=47.251.166.203&port=1080",
    @"tg://socks?server=82.180.146.251&port=10800",
    @"tg://socks?server=43.134.39.221&port=10000"
  ];
}
static NSString *const kLeadCallProxyCache = @"LeadCallProxyList";
static NSString *const kLeadCallProxyReachable = @"KiraCallProxyReachableV2";

static const NSTimeInterval kLeadAutoProxyRefreshInterval = 20 * 60;
static const NSUInteger kLeadAutoProxyMaxEntries = 20;
static const NSUInteger kLeadAutoProxyMaxBytes = 64 * 1024;

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

#pragma mark - JSON list

static NSString *LeadProxyString(id value) {
  if ([value isKindOfClass:NSString.class]) return value;
  if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
  return nil;
}

// One list entry (link string or object) -> canonical link, nil when unusable.
static NSString *LeadProxyLinkFromEntry(id entry) {
  if ([entry isKindOfClass:NSString.class]) return LeadAutoProxyNormalizedLink(entry);
  if (![entry isKindOfClass:NSDictionary.class]) return nil;
  NSDictionary *d = entry;
  if ([d[@"enabled"] isKindOfClass:NSNumber.class] && ![d[@"enabled"] boolValue]) return nil;
  NSString *link = LeadProxyString(d[@"link"]) ?: LeadProxyString(d[@"url"]);
  if (link.length) return LeadAutoProxyNormalizedLink(link);
  NSString *server = LeadProxyString(d[@"server"]) ?: LeadProxyString(d[@"host"]);
  NSString *port = LeadProxyString(d[@"port"]);
  if (!server.length || !port.length) return nil;
  NSString *secret = LeadProxyString(d[@"secret"]);
  NSString *user = LeadProxyString(d[@"user"]) ?: LeadProxyString(d[@"username"]);
  NSString *pass = LeadProxyString(d[@"pass"]) ?: LeadProxyString(d[@"password"]);
  NSMutableString *built = [NSMutableString stringWithFormat:@"tg://%@?server=%@&port=%@",
                                                             secret.length ? @"proxy" : @"socks",
                                                             LeadProxyEncode(server), LeadProxyEncode(port)];
  if (secret.length) [built appendFormat:@"&secret=%@", LeadProxyEncode(secret)];
  if (user.length) [built appendFormat:@"&user=%@", LeadProxyEncode(user)];
  if (pass.length) [built appendFormat:@"&pass=%@", LeadProxyEncode(pass)];
  return LeadAutoProxyNormalizedLink(built);
}

// -> canonical links in file order, or nil when the file isn't a proxy list at all.
static NSArray<NSString *> *LeadProxyLinksFromJSON(NSData *data) {
  if (data.length == 0 || data.length > kLeadAutoProxyMaxBytes) return nil;
  id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  NSArray *entries = nil;
  if ([root isKindOfClass:NSArray.class]) entries = root;
  else if ([root isKindOfClass:NSDictionary.class]) {
    entries = root[@"proxies"] ?: root[@"servers"];
  }
  if (![entries isKindOfClass:NSArray.class]) return nil;
  NSMutableOrderedSet<NSString *> *links = [NSMutableOrderedSet orderedSet];
  for (id entry in entries) {
    NSString *link = LeadProxyLinkFromEntry(entry);
    if (link) [links addObject:link];
    if (links.count >= kLeadAutoProxyMaxEntries) break;
  }
  return links.array;
}

// Only explicitly tagged SOCKS5 entries in the separate call pool are eligible.
static NSArray<NSString *> *LeadCallProxyLinksFromJSON(NSData *data) {
  if (data.length == 0 || data.length > kLeadAutoProxyMaxBytes) return nil;
  id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![root isKindOfClass:NSDictionary.class]) return nil;
  id entries = root[@"call_proxies"];
  if (![entries isKindOfClass:NSArray.class]) return nil;
  NSMutableOrderedSet<NSString *> *links = [NSMutableOrderedSet orderedSet];
  for (id entry in entries) {
    NSString *link = LeadProxyLinkFromEntry(entry);
    NSDictionary *parsed = LeadProxyParseLink(link);
    if ([parsed[@"kind"] isEqualToString:@"socks"]) [links addObject:link];
    if (links.count >= kLeadAutoProxyMaxEntries) break;
  }
  return links.array;
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
static NSArray<NSString *> *LeadProxyReachableLinks(NSArray<NSString *> *links) {
  NSUInteger count = links.count;
  if (count == 0) return @[];
  NSMutableArray<NSNumber *> *answered = [NSMutableArray arrayWithCapacity:count];
  for (NSUInteger i = 0; i < count; i++) [answered addObject:@NO];
  dispatch_group_t group = dispatch_group_create();
  for (NSUInteger i = 0; i < count; i++) {
    NSDictionary *p = LeadProxyParseLink(links[i]);
    if (!p) continue;
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      BOOL ok = LeadProxyProbe(p[@"server"], [p[@"port"] intValue], 2500, [p[@"kind"] isEqual:@"socks"], [p[@"user"] length] > 0);
      @synchronized(answered) { answered[i] = @(ok); }
    });
  }
  dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
  NSMutableArray<NSString *> *reachable = [NSMutableArray array];
  @synchronized(answered) {
    for (NSUInteger i = 0; i < count; i++) {
      if ([answered[i] boolValue]) [reachable addObject:links[i]];
    }
  }
  return reachable;
}
static NSString *LeadProxyFirstReachable(NSArray<NSString *> *links) {
  return LeadProxyReachableLinks(links).firstObject;
}

// Both signaling and native media must use the same selected server during a call.
extern NSDictionary *LeadWarpCallProxy(void);
static NSDictionary *LeadCallProxyChoose(void) {
  NSDictionary *warp = LeadWarpCallProxy();
  if (warp) return warp; // Activated only after a successful WARP trace.
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSArray<NSString *> *configured = [defaults arrayForKey:kLeadCallProxyCache] ?: LeadCallProxyBuiltInLinks();
  if (!configured.count) return nil;
  NSMutableArray<NSString *> *reachable = [NSMutableArray array];
  NSArray *checked = [defaults arrayForKey:kLeadCallProxyReachable];
  for (NSString *link in checked) {
    if ([configured containsObject:link]) [reachable addObject:link];
  }
  NSArray<NSString *> *pool = checked != nil ? reachable : configured;
  if (!pool.count) return nil;
  static NSUInteger next = 0;
  static NSObject *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [NSObject new]; });
  @synchronized(lock) {
    for (NSUInteger i = 0; i < pool.count; i++) {
      NSDictionary *p = LeadProxyParseLink(pool[next++ % pool.count]);
      if ([p[@"kind"] isEqualToString:@"socks"]) return p;
    }
  }
  return nil;
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
static NSDictionary *sLeadProxyInfo = nil;        // parsed form of that link
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
static BOOL LeadProxyActivate(NSString *link) {
  NSDictionary *p = LeadProxyParseLink(link);
  if (!p) return NO;
  NSString *canonical = LeadProxyLinkFromParsed(p);
  @synchronized(LeadProxyLock()) {
    if (sLeadProxySettings && [sLeadProxyLink isEqualToString:canonical]) return NO;
  }
  id settings = LeadProxyMakeSettings(p);
  if (!settings) return NO;
  @synchronized(LeadProxyLock()) {
    if (!sLeadProxyOwn) sLeadProxyOwn = [NSHashTable weakObjectsHashTable];
    [sLeadProxyOwn addObject:settings];
    sLeadProxySettings = settings;
    sLeadProxyLink = canonical;
    sLeadProxyInfo = p;
  }
  [[NSUserDefaults standardUserDefaults] setObject:canonical forKey:kAutoProxyActive];
  NSLog(@"[Kira] AutoProxy: active server updated");
  return YES;
}

static void LeadProxyDeactivate(void) {
  @synchronized(LeadProxyLock()) {
    sLeadProxySettings = nil;
    sLeadProxyLink = nil;
    sLeadProxyInfo = nil;
  }
}

// What a launch starts with: the last proxy that answered, else the built-in one.
static void LeadProxyActivateCached(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSString *link = [defaults stringForKey:kAutoProxyActive];
  if (link.length && (LeadProxyActivate(link) || LeadAutoProxyCurrentSettings())) return;
  LeadProxyActivate(LeadProxyBuiltInLinks().firstObject);
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
    for (NSString *link in [[NSUserDefaults standardUserDefaults] arrayForKey:kAutoProxyList]) {
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
  NSString *active;
  @synchronized(LeadProxyLock()) { active = sLeadProxyLink; }
  if (!active.length) return nil;
  NSArray<NSString *> *links = [[NSUserDefaults standardUserDefaults] arrayForKey:kAutoProxyList];
  if (!links.count) links = LeadProxyBuiltInLinks();
  return LeadProxyDisplayName([links indexOfObject:active]);
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

static NSString *LeadProxyConfigURLString(void) {
  return kLeadAutoProxyConfigURLDefault;
}

static BOOL LeadProxyURLIsUsable(NSString *urlString) {
  NSURL *url = [NSURL URLWithString:urlString];
  return url && [url.scheme.lowercaseString isEqualToString:@"https"] && url.host.length > 0;
}

NSString *LeadAutoProxyConfigHost(void) {
  NSURL *url = [NSURL URLWithString:LeadProxyConfigURLString()];
  if (!LeadProxyURLIsUsable(LeadProxyConfigURLString())) return nil;
  return url.host;
}

static NSData *LeadProxyFetch(NSString *urlString) {
  if (!LeadProxyURLIsUsable(urlString)) return nil;
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]
                                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                     timeoutInterval:10];
  __block NSData *body = nil;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    if (!error && status == 200) body = data;
    dispatch_semaphore_signal(done);
  }] resume];
  dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)));
  return body;
}

static void LeadAutoProxyRefreshInternal(BOOL rotate, void (^done)(NSString *summary, BOOL reachable)) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ queue = dispatch_queue_create("kira.autoproxy.refresh", DISPATCH_QUEUE_SERIAL); });
  dispatch_async(queue, ^{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (!LeadProxyEnabled()) {
      if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(nil, NO); });
      return;
    }

    // 1. The list: fresh from the file, else the last good one, else the built-in proxy.
    NSData *configData = LeadProxyFetch(LeadProxyConfigURLString());
    NSArray<NSString *> *callLinks = LeadCallProxyLinksFromJSON(configData);
    if (callLinks != nil) [defaults setObject:callLinks forKey:kLeadCallProxyCache];
    else callLinks = [defaults arrayForKey:kLeadCallProxyCache] ?: LeadCallProxyBuiltInLinks();
    // Probe calls independently so ordinary connection selection is not delayed.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      NSArray *reachableCalls = LeadProxyReachableLinks(callLinks);
      NSArray *current = [defaults arrayForKey:kLeadCallProxyCache] ?: LeadCallProxyBuiltInLinks();
      if ([current isEqualToArray:callLinks]) [defaults setObject:reachableCalls forKey:kLeadCallProxyReachable];
    });
    NSArray<NSString *> *links = LeadProxyLinksFromJSON(configData);
    if (links != nil) {
      [defaults setObject:links forKey:kAutoProxyList];
    } else {
      links = [defaults arrayForKey:kAutoProxyList];
    }
    if (links.count == 0) links = LeadProxyBuiltInLinks();

    // Prefer the last selected proxy on ordinary refreshes; rotate only on request.
    NSString *active = [defaults stringForKey:kAutoProxyActive];
    NSMutableArray<NSString *> *ordered = [NSMutableArray array];
    NSUInteger current = active.length ? [links indexOfObject:active] : NSNotFound;
    if (rotate) {
      for (NSUInteger i = 0; i < links.count; i++) {
        NSUInteger index = current == NSNotFound ? i : (current + 1 + i) % links.count;
        if (![links[index] isEqualToString:active]) [ordered addObject:links[index]];
      }
    } else {
      if (current != NSNotFound) [ordered addObject:active];
      for (NSString *link in links) if (![link isEqualToString:active]) [ordered addObject:link];
    }
    NSString *chosen = LeadProxyFirstReachable(ordered);
    BOOL reachable = chosen != nil;
    if (!chosen && !rotate) chosen = active.length ? active : links.firstObject;
    [defaults setDouble:[NSDate date].timeIntervalSince1970 forKey:kAutoProxyChecked];

    // 3. Apply it (and tell Telegram's live connections).
    dispatch_async(dispatch_get_main_queue(), ^{
      BOOL enabled = LeadProxyEnabled();
      if (enabled && chosen.length && LeadProxyActivate(chosen)) LeadProxyPushToContexts();
      if (done) done(LeadAutoProxySummary(), enabled && reachable);
    });
  });
}

void LeadAutoProxyRefresh(void (^done)(NSString *summary, BOOL reachable)) { LeadAutoProxyRefreshInternal(NO, done); }
void LeadAutoProxyRotate(void (^done)(NSString *summary, BOOL reachable)) { LeadAutoProxyRefreshInternal(YES, done); }

#pragma mark - Menu

void LeadAutoProxySetEnabled(BOOL on) {
  if (on) {
    LeadProxyActivateCached();
    BOOL pushed = LeadProxyPushToContexts();
    LeadAutoProxyRefresh(nil);
    if (!pushed) LeadNotifySettingsChanged(); // no connection seen yet: applies after a restart
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
  // Discard caches from the developer's previous endpoint on first upgrade.
  NSString *sourceKey = @"LeadAutoProxyCacheSource";
  if (![[defaults stringForKey:sourceKey] isEqualToString:kLeadAutoProxyConfigURLDefault]) {
    for (NSString *key in @[kAutoProxyConfigURL, kAutoProxyList, kAutoProxyActive, kAutoProxyChecked]) {
      [defaults removeObjectForKey:key];
    }
    [defaults setObject:kLeadAutoProxyConfigURLDefault forKey:sourceKey];
  }

  // Synchronously, before Telegram opens its first connection: that one already goes through the proxy.
  if (LeadProxyEnabled()) LeadProxyActivateCached();

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
