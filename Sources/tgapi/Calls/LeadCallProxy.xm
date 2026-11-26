#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdlib.h>

#ifndef LEAD_WARP_EXPERIMENTAL
#define LEAD_WARP_EXPERIMENTAL 0
#endif
#if LEAD_WARP_EXPERIMENTAL
extern "C" char *LeadWarpGroupRewrite(char *, char *);
extern "C" void LeadWarpGroupClose(char *);
extern "C" NSDictionary *LeadWarpCallProxy(void);
#endif

// Telegram-iOS native ObjC WebRTC bridge, verified against VoidGram's
// pinned upstream revision fb0e62ba8a147f0821da6aa63c09da7d79a10111.
// Use managed MTProto signaling temporarily. GroupCallThreadLocalContext
// has an additional WARP UDP relay; private calls retain native media routing.
extern "C" NSDictionary *LeadCallProxyNext(void);
extern "C" void LeadGroupCallProxyBegin(void);
extern "C" void LeadGroupCallProxyEnd(void);

#if LEAD_WARP_EXPERIMENTAL
static char kLeadWarpGroupToken;
#endif
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
#if LEAD_WARP_EXPERIMENTAL
  @synchronized(self) {
    objc_setAssociatedObject(self, &kLeadWarpGroupToken, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
#endif
}
%end
%end


#if LEAD_WARP_EXPERIMENTAL
// A separate lifetime for each native group context. No process-wide socket
// interception: only remote ICE candidates in the group join response are changed.
@interface LeadWarpGroupLifetime : NSObject
@property (nonatomic, copy) NSString *token;
@end
@implementation LeadWarpGroupLifetime
- (instancetype)init {
  if ((self = [super init])) _token = NSUUID.UUID.UUIDString;
  return self;
}
- (void)dealloc {
  if (_token.length) LeadWarpGroupClose((char *)_token.UTF8String);
}
@end

%group LeadWarpGroupMedia
%hook GroupCallThreadLocalContext
- (void)setJoinResponsePayload:(NSString *)payload {
  if (!LeadWarpCallProxy() || ![payload isKindOfClass:NSString.class] || !payload.length) {
    %orig(payload);
    return;
  }
  NSString *rewritten = nil;
  @synchronized(self) {
    LeadWarpGroupLifetime *lifetime = objc_getAssociatedObject(self, &kLeadWarpGroupToken);
    if (!lifetime) {
      lifetime = [LeadWarpGroupLifetime new];
      objc_setAssociatedObject(self, &kLeadWarpGroupToken, lifetime, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    char *result = LeadWarpGroupRewrite((char *)lifetime.token.UTF8String, (char *)payload.UTF8String);
    if (result) {
      rewritten = [NSString stringWithUTF8String:result];
      free(result);
    }
  }
  if (rewritten.length) {
    NSLog(@"[Kira] WARP group UDP candidates installed");
    %orig(rewritten);
  } else {
    // Preserve the client's normal call behavior on an unsupported payload.
    NSLog(@"[Kira] WARP group UDP unavailable; using native candidates");
    %orig(payload);
  }
}
%end
%end
#endif

%group LeadNativeCallProxy
%hook OngoingCallThreadLocalContextWebrtc
- (id)initWithVersion:(NSString *)version customParameters:(NSString *)customParameters queue:(id)queue proxy:(id)proxy networkType:(int32_t)networkType dataSaving:(int32_t)dataSaving derivedState:(NSData *)derivedState key:(NSData *)key isOutgoing:(bool)isOutgoing connections:(NSArray *)connections maxLayer:(int32_t)maxLayer allowP2P:(BOOL)allowP2P allowTCP:(BOOL)allowTCP enableStunMarking:(BOOL)enableStunMarking logPath:(NSString *)logPath statsLogPath:(NSString *)statsLogPath sendSignalingData:(id)sendSignalingData videoCapturer:(id)videoCapturer preferredVideoCodec:(NSString *)preferredVideoCodec audioInputDeviceId:(NSString *)audioInputDeviceId audioDevice:(id)audioDevice directConnection:(id)directConnection {
  // Signaling still uses the managed call proxy. Never force a TCP-only
  // SOCKS route into native WebRTC: doing so disables UDP/STUN without
  // guaranteeing a media path in Telegram's pinned native engine.
  // Preserve the original proxy, transport flags and endpoint metadata.
  id context = %orig(version, customParameters, queue, proxy, networkType, dataSaving, derivedState, key, isOutgoing, connections, maxLayer, allowP2P, allowTCP, enableStunMarking, logPath, statsLogPath, sendSignalingData, videoCapturer, preferredVideoCodec, audioInputDeviceId, audioDevice, directConnection);
  if (context) LeadAttachGroupProxy(context);
  return context;
}
- (void)stop:(id)completion {
  %orig(completion);
  LeadDetachGroupProxy(self);
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
#if LEAD_WARP_EXPERIMENTAL
    if (group && class_getInstanceMethod(group, NSSelectorFromString(@"setJoinResponsePayload:")) &&
        class_getInstanceMethod(group, NSSelectorFromString(@"stop:"))) {
      %init(LeadWarpGroupMedia);
    }
#endif
  }
}
