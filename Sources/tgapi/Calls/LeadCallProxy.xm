#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Telegram-iOS native ObjC WebRTC bridge, verified against VoidGram's
// pinned upstream revision fb0e62ba8a147f0821da6aa63c09da7d79a10111.
// One-to-one media can accept a native SOCKS5 proxy. GroupCallThreadLocalContext
// has no proxy parameter: its lifecycle instead switches Lead-managed MTProto
// signaling temporarily, without intercepting unrelated sockets.
extern "C" NSDictionary *LeadCallProxyNext(void);
extern "C" void LeadGroupCallProxyBegin(void);
extern "C" void LeadGroupCallProxyEnd(void);

static char kLeadGroupProxyLifetime;
@interface LeadGroupProxyLifetime : NSObject
@end
@implementation LeadGroupProxyLifetime
- (instancetype)init {
  if ((self = [super init])) LeadGroupCallProxyBegin();
  return self;
}
- (void)dealloc { LeadGroupCallProxyEnd(); }
@end

static void LeadAttachGroupProxy(id context) {
  @synchronized(context) {
    if (!objc_getAssociatedObject(context, &kLeadGroupProxyLifetime)) {
      objc_setAssociatedObject(context, &kLeadGroupProxyLifetime, [LeadGroupProxyLifetime new], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
  }
}
static void LeadDetachGroupProxy(id context) {
  @synchronized(context) {
    objc_setAssociatedObject(context, &kLeadGroupProxyLifetime, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
}

%group LeadGroupSignalingProxy
%hook GroupCallThreadLocalContext
- (void)emitJoinPayload:(id)completion {
  LeadAttachGroupProxy(self);
  %orig(completion);
}
- (void)setConnectionMode:(int32_t)mode keepBroadcastConnectedIfWasEnabled:(bool)keep isUnifiedBroadcast:(bool)unified {
  if (mode != 0) LeadAttachGroupProxy(self);
  %orig(mode, keep, unified);
}
- (void)stop:(id)completion {
  %orig(completion);
  LeadDetachGroupProxy(self);
}
%end
%end

%group LeadNativeCallProxy
%hook OngoingCallThreadLocalContextWebrtc
- (id)initWithVersion:(NSString *)version customParameters:(NSString *)customParameters queue:(id)queue proxy:(id)proxy networkType:(int32_t)networkType dataSaving:(int32_t)dataSaving derivedState:(NSData *)derivedState key:(NSData *)key isOutgoing:(bool)isOutgoing connections:(NSArray *)connections maxLayer:(int32_t)maxLayer allowP2P:(BOOL)allowP2P allowTCP:(BOOL)allowTCP enableStunMarking:(BOOL)enableStunMarking logPath:(NSString *)logPath statsLogPath:(NSString *)statsLogPath sendSignalingData:(id)sendSignalingData videoCapturer:(id)videoCapturer preferredVideoCodec:(NSString *)preferredVideoCodec audioInputDeviceId:(NSString *)audioInputDeviceId audioDevice:(id)audioDevice directConnection:(id)directConnection {
  NSDictionary *p = LeadCallProxyNext();
  if (p) {
    Class cls = NSClassFromString(@"VoipProxyServerWebrtc");
    SEL init = NSSelectorFromString(@"initWithHost:port:username:password:");
    if (cls && [cls instancesRespondToSelector:init]) {
      id replacement = ((id (*)(id, SEL, NSString *, int32_t, NSString *, NSString *))objc_msgSend)(
          [cls alloc], init, p[@"server"], [p[@"port"] intValue], p[@"user"], p[@"pass"]);
      if (replacement) {
        proxy = replacement;
        allowP2P = NO;
        allowTCP = YES;
        NSLog(@"[Kira] Dedicated call proxy %@:%@", p[@"server"], p[@"port"]);
      }
    }
  }
  return %orig(version, customParameters, queue, proxy, networkType, dataSaving, derivedState, key, isOutgoing, connections, maxLayer, allowP2P, allowTCP, enableStunMarking, logPath, statsLogPath, sendSignalingData, videoCapturer, preferredVideoCodec, audioInputDeviceId, audioDevice, directConnection);
}
%end
%end

%ctor {
  @autoreleasepool {
    if ([NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"appex"]) return;
    Class target = NSClassFromString(@"OngoingCallThreadLocalContextWebrtc");
    SEL selector = NSSelectorFromString(@"initWithVersion:customParameters:queue:proxy:networkType:dataSaving:derivedState:key:isOutgoing:connections:maxLayer:allowP2P:allowTCP:enableStunMarking:logPath:statsLogPath:sendSignalingData:videoCapturer:preferredVideoCodec:audioInputDeviceId:audioDevice:directConnection:");
    if (target && class_getInstanceMethod(target, selector) && NSClassFromString(@"VoipProxyServerWebrtc")) {
      %init(LeadNativeCallProxy);
    }
    Class group = NSClassFromString(@"GroupCallThreadLocalContext");
    if (group &&
        class_getInstanceMethod(group, NSSelectorFromString(@"emitJoinPayload:")) &&
        class_getInstanceMethod(group, NSSelectorFromString(@"setConnectionMode:keepBroadcastConnectedIfWasEnabled:isUnifiedBroadcast:")) &&
        class_getInstanceMethod(group, NSSelectorFromString(@"stop:"))) {
      %init(LeadGroupSignalingProxy);
    }
  }
}
