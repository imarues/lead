#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Telegram-iOS native ObjC WebRTC bridge, verified against VoidGram's
// pinned upstream revision fb0e62ba8a147f0821da6aa63c09da7d79a10111.
// This affects one-to-one incoming and outgoing media only. GroupCallThreadLocalContext
// has no proxy parameter; do not intercept process-wide sockets or claim group support.
extern "C" NSDictionary *LeadCallProxyNext(void);

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
  }
}
