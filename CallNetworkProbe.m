#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <poll.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

// Standalone opt-in connection tests. No hooks into calls or traffic capture.
// Nothing is sent until the person taps Run Test.
static NSString *const TCPHost = @"telegram.org";
static NSString *const STUNHost = @"stun.l.google.com";
static const uint16_t TCPPort = 443, STUNPort = 19302;
static const int DelayMS = 4500;

static NSString *SocketError(void) {
    return [NSString stringWithUTF8String:strerror(errno)] ?: @"socket error";
}
static void SetTimeouts(int fd) {
    struct timeval v = {DelayMS / 1000, (DelayMS % 1000) * 1000};
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &v, sizeof(v));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &v, sizeof(v));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
}
static BOOL WriteAll(int fd, const void *ptr, size_t n) {
    const uint8_t *p = ptr;
    while (n) {
        ssize_t k = send(fd, p, n, 0);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) return NO;
        p += k; n -= (size_t)k;
    }
    return YES;
}
static BOOL ReadAll(int fd, void *ptr, size_t n) {
    uint8_t *p = ptr;
    while (n) {
        ssize_t k = recv(fd, p, n, 0);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) return NO;
        p += k; n -= (size_t)k;
    }
    return YES;
}
static int OpenConnected(NSString *host, uint16_t port, int socketType, int family, NSString **failure) {
    struct addrinfo hints = {0}, *result = NULL;
    hints.ai_family = family; hints.ai_socktype = socketType;
    char portText[8]; snprintf(portText, sizeof(portText), "%u", (unsigned)port);
    int error = getaddrinfo(host.UTF8String, portText, &hints, &result);
    if (error) {
        if (failure) *failure = [NSString stringWithFormat:@"DNS: %s", gai_strerror(error)];
        return -1;
    }
    int fd = -1, attempts = 0;
    NSString *last = @"no route";
    for (struct addrinfo *a = result; a && attempts < 3; a = a->ai_next, ++attempts) {
        fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0) { last = SocketError(); continue; }
        SetTimeouts(fd);
        int flags = fcntl(fd, F_GETFL, 0);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            last = SocketError(); close(fd); fd = -1; continue;
        }
        int c = connect(fd, a->ai_addr, (socklen_t)a->ai_addrlen);
        if (c < 0 && errno == EINPROGRESS) {
            struct pollfd p = {.fd = fd, .events = POLLOUT};
            if (poll(&p, 1, DelayMS) > 0) {
                int e = 0; socklen_t len = sizeof(e);
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &len) == 0 && e == 0) c = 0;
                else errno = e ?: errno;
            } else errno = ETIMEDOUT;
        }
        if (c == 0 && fcntl(fd, F_SETFL, flags) == 0) break;
        last = SocketError(); close(fd); fd = -1;
    }
    freeaddrinfo(result);
    if (fd < 0 && failure) *failure = last;
    return fd;
}
static NSData *Endpoint(NSString *host, uint16_t port) {
    NSMutableData *b = [NSMutableData data];
    uint8_t type, ip[16];
    if (inet_pton(AF_INET, host.UTF8String, ip) == 1) {
        type = 1; [b appendBytes:&type length:1]; [b appendBytes:ip length:4];
    } else if (inet_pton(AF_INET6, host.UTF8String, ip) == 1) {
        type = 4; [b appendBytes:&type length:1]; [b appendBytes:ip length:16];
    } else {
        NSData *name = [host dataUsingEncoding:NSASCIIStringEncoding];
        if (!name.length || name.length > 255) return nil;
        uint8_t header[2] = {3, (uint8_t)name.length};
        [b appendBytes:header length:2]; [b appendData:name];
    }
    uint16_t be = htons(port); [b appendBytes:&be length:2];
    return b;
}
static BOOL SocksAuth(int fd, NSString *user, NSString *password, NSString **error) {
    uint8_t hello[4] = {5, (uint8_t)(user.length ? 2 : 1), 0, 2}, response[2];
    if (!WriteAll(fd, hello, user.length ? 4 : 3) || !ReadAll(fd, response, 2) || response[0] != 5) {
        *error = @"SOCKS negotiation failed"; return NO;
    }
    if (response[1] == 0) return YES;
    if (response[1] != 2 || !user.length) { *error = @"SOCKS authentication required/rejected"; return NO; }
    NSData *u = [user dataUsingEncoding:NSUTF8StringEncoding], *p = [password dataUsingEncoding:NSUTF8StringEncoding];
    if (!u.length || u.length > 255 || p.length > 255) { *error = @"Invalid credential length"; return NO; }
    uint8_t header[2] = {1, (uint8_t)u.length}, plen = (uint8_t)p.length;
    NSMutableData *request = [NSMutableData dataWithBytes:header length:2];
    [request appendData:u]; [request appendBytes:&plen length:1]; if (p.length) [request appendData:p];
    BOOL ok = WriteAll(fd, request.bytes, request.length) && ReadAll(fd, response, 2) && response[0] == 1 && response[1] == 0;
    if (!ok) *error = @"SOCKS authentication failed";
    return ok;
}
static BOOL SocksCommand(int fd, uint8_t cmd, NSString *host, uint16_t port, NSString **relayHost, uint16_t *relayPort, NSString **error) {
    NSData *ep = Endpoint(host, port);
    if (!ep) { *error = @"Invalid target address"; return NO; }
    uint8_t h[3] = {5, cmd, 0};
    NSMutableData *req = [NSMutableData dataWithBytes:h length:3]; [req appendData:ep];
    uint8_t r[4];
    if (!WriteAll(fd, req.bytes, req.length) || !ReadAll(fd, r, 4) || r[0] != 5 || r[2] != 0) {
        *error = @"SOCKS command reply missing/invalid"; return NO;
    }
    if (r[1] != 0) {
        *error = r[1] == 7 ? @"SOCKS reply 7: command not supported" : [NSString stringWithFormat:@"SOCKS reply %u", r[1]];
        return NO;
    }
    NSString *address = nil;
    uint8_t raw[256] = {0}; char ip[INET6_ADDRSTRLEN];
    if (r[3] == 1 || r[3] == 4) {
        size_t n = r[3] == 1 ? 4 : 16;
        if (ReadAll(fd, raw, n) && inet_ntop(r[3] == 1 ? AF_INET : AF_INET6, raw, ip, sizeof(ip))) address = [NSString stringWithUTF8String:ip];
    } else if (r[3] == 3) {
        uint8_t n;
        if (ReadAll(fd, &n, 1) && n && ReadAll(fd, raw, n)) address = [[NSString alloc] initWithBytes:raw length:n encoding:NSASCIIStringEncoding];
    }
    uint16_t be;
    if (!address.length || !ReadAll(fd, &be, 2)) { *error = @"Invalid SOCKS bound address"; return NO; }
    if (relayHost) *relayHost = address;
    if (relayPort) *relayPort = ntohs(be);
    return YES;
}
static void NewStun(uint8_t p[20]) {
    const uint8_t prefix[8] = {0, 1, 0, 0, 0x21, 0x12, 0xA4, 0x42};
    memcpy(p, prefix, 8); arc4random_buf(p + 8, 12);
}
static BOOL VerifyStun(const uint8_t *p, size_t n, const uint8_t req[20]) {
    if (n < 20 || p[0] != 1 || p[1] != 1 || memcmp(p+4, req+4, 16)) return NO;
    size_t len = ((size_t)p[2] << 8) | p[3];
    return !(len % 4) && n == 20 + len;
}
static NSString *DirectTCP(void) {
    NSString *e = nil; int fd = OpenConnected(TCPHost, TCPPort, SOCK_STREAM, AF_UNSPEC, &e);
    if (fd < 0) return [@"FAIL — " stringByAppendingString:e ?: @"TCP connect failed"];
    close(fd); return @"PASS — TCP connected";
}
static NSString *DirectUDP(void) {
    NSString *e = nil; int fd = OpenConnected(STUNHost, STUNPort, SOCK_DGRAM, AF_UNSPEC, &e);
    if (fd < 0) return [@"FAIL — " stringByAppendingString:e ?: @"UDP socket failed"];
    uint8_t req[20], reply[2048]; NewStun(req);
    ssize_t n = -1;
    if (send(fd, req, sizeof(req), 0) == sizeof(req)) n = recv(fd, reply, sizeof(reply), 0);
    NSString *answer = n >= 0 && VerifyStun(reply, (size_t)n, req) ? @"PASS — matching STUN response" : @"FAIL — no matching STUN response";
    close(fd); return answer;
}
static NSString *ProxyTest(NSString *host, uint16_t port, NSString *user, NSString *password, BOOL udp) {
    NSString *error = nil; int control = OpenConnected(host, port, SOCK_STREAM, AF_UNSPEC, &error);
    if (control < 0) return [@"FAIL — " stringByAppendingString:error ?: @"proxy connect failed"];
    NSString *result = nil;
    if (!SocksAuth(control, user, password, &error)) result = error;
    else if (!udp) {
        if (SocksCommand(control, 1, TCPHost, TCPPort, NULL, NULL, &error)) result = @"PASS — SOCKS TCP CONNECT";
        else result = error;
    } else {
        struct sockaddr_storage peer = {0}; socklen_t peerLen = sizeof(peer);
        if (getpeername(control, (struct sockaddr *)&peer, &peerLen)) result = @"Cannot resolve proxy peer";
        else {
            NSString *bindHost = peer.ss_family == AF_INET6 ? @"::" : @"0.0.0.0";
            NSString *relay = nil; uint16_t relayPort = 0;
            if (!SocksCommand(control, 3, bindHost, 0, &relay, &relayPort, &error)) result = error;
            else if (!relayPort) result = @"SOCKS returned no UDP relay port";
            else {
                if ([relay isEqual:@"0.0.0.0"] || [relay isEqual:@"::"]) {
                    char ip[INET6_ADDRSTRLEN];
                    void *addr = peer.ss_family == AF_INET6 ? (void *)&((struct sockaddr_in6 *)&peer)->sin6_addr : (void *)&((struct sockaddr_in *)&peer)->sin_addr;
                    if (inet_ntop(peer.ss_family, addr, ip, sizeof(ip))) relay = [NSString stringWithUTF8String:ip];
                }
                int fd = OpenConnected(relay, relayPort, SOCK_DGRAM, AF_UNSPEC, &error);
                if (fd < 0) result = error;
                else {
                    uint8_t req[20], reply[2048], reserved[3] = {0}; NewStun(req);
                    NSMutableData *packet = [NSMutableData dataWithBytes:reserved length:3];
                    NSData *target = Endpoint(STUNHost, STUNPort);
                    [packet appendData:target]; [packet appendBytes:req length:20];
                    ssize_t n = -1;
                    if (send(fd, packet.bytes, packet.length, 0) == (ssize_t)packet.length) n = recv(fd, reply, sizeof(reply), 0);
                    size_t offset = 0;
                    if (n >= 4 && reply[0] == 0 && reply[1] == 0 && reply[2] == 0) {
                        if (reply[3] == 1) offset = 10;
                        else if (reply[3] == 4) offset = 22;
                        else if (reply[3] == 3 && n >= 5) offset = 7 + reply[4];
                    }
                    result = offset && (size_t)n >= offset && VerifyStun(reply+offset, (size_t)n-offset, req) ? @"PASS — relayed UDP STUN response" : @"UDP ASSOCIATE accepted; no matching STUN response";
                    close(fd);
                }
            }
        }
    }
    close(control);
    if ([result hasPrefix:@"PASS"]) return result;
    return [@"FAIL — " stringByAppendingString:result ?: @"unknown failure"];
}
static BOOL ParseProxy(NSString *s, NSString **host, uint16_t *port) {
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSRange sep = [s rangeOfString:@":" options:NSBackwardsSearch];
    if (sep.location == NSNotFound || sep.location == 0) return NO;
    NSString *h = [s substringToIndex:sep.location], *p = [s substringFromIndex:sep.location+1];
    if ([h hasPrefix:@"["] && [h hasSuffix:@"]"]) h = [h substringWithRange:NSMakeRange(1,h.length-2)];
    if (!h.length || !p.length || [p rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return NO;
    NSInteger value = p.integerValue;
    if (value <= 0 || value > 65535) return NO;
    *host = h; *port = (uint16_t)value; return YES;
}
static UIViewController *Presenter(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) { window = w; break; }
        if (window) break;
    }
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController;
    return vc.viewIfLoaded.window ? vc : nil;
}
static void ShowProbe(void);
static void ShowReport(NSString *message) {
    UIViewController *vc = Presenter();
    if (!vc) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"نتيجة فحص الاتصال" message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"نسخ النتيجة" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { UIPasteboard.generalPasteboard.string = message; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"إعادة الفحص" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ShowProbe();}); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"إغلاق" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}
static void ShowProbe(void) {
    UIViewController *vc = Presenter();
    if (!vc || [vc isKindOfClass:UIAlertController.class]) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"فحص اتصال المكالمات" message:@"يفحص TCP إلى telegram.org:443 وUDP إلى خادم STUN العام stun.l.google.com:19302. البروكسي اختياري. الفحص لا يقرأ الرسائل أو المكالمات ولا يغير الاتصال." preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) {t.placeholder=@"SOCKS 127.0.0.1:PORT (اختياري)"; t.autocorrectionType=UITextAutocorrectionTypeNo; t.autocapitalizationType=UITextAutocapitalizationTypeNone;}];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) {t.placeholder=@"Username (اختياري)"; t.autocorrectionType=UITextAutocorrectionTypeNo; t.autocapitalizationType=UITextAutocapitalizationTypeNone;}];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) {t.placeholder=@"Password (اختياري)"; t.secureTextEntry=YES;}];
    __weak UIAlertController *weakAlert = a;
    [a addAction:[UIAlertAction actionWithTitle:@"ابدأ الفحص" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIAlertController *alert=weakAlert;
        NSString *proxy=[alert.textFields[0].text copy] ?: @"", *user=[alert.textFields[1].text copy] ?: @"", *pass=[alert.textFields[2].text copy] ?: @"";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
            @autoreleasepool {
                NSMutableString *message=[NSMutableString stringWithFormat:@"Direct TCP: %@\nDirect UDP: %@",DirectTCP(),DirectUDP()];
                if (proxy.length) {
                    NSString *host=nil; uint16_t port=0;
                    if (ParseProxy(proxy,&host,&port)) {
                        [message appendFormat:@"\nSOCKS TCP: %@\nSOCKS UDP: %@",ProxyTest(host,port,user,pass,NO),ProxyTest(host,port,user,pass,YES)];
                    } else [message appendString:@"\nProxy address: invalid"];
                }
                [message appendString:@"\n\nTCP web reachability and STUN do not guarantee Telegram call compatibility."];
                dispatch_async(dispatch_get_main_queue(),^{ShowReport(message);});
            }
        });
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}
static BOOL didShow = NO;
static void TryPresent(int tries) {
    if (didShow || tries <= 0) return;
    UIViewController *vc = Presenter();
    if (vc && ![vc isKindOfClass:UIAlertController.class]) {
        didShow = YES; ShowProbe(); return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{TryPresent(tries-1);});
}
__attribute__((constructor)) static void StartProbe(void) {
    @autoreleasepool {
        if ([NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"appex"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){TryPresent(20);}];
            TryPresent(20);
        });
    }
}
