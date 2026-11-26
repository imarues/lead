#import <Foundation/Foundation.h>

// Only the HTTPS gateway origin is compiled in. Device token is stored in Keychain;
// the short-lived session and received proxy are never written to defaults.
NSString *KiraGatewayHost(void);
BOOL KiraGatewayIsActivated(void);
void KiraGatewayActivate(NSString *code, void (^completion)(NSInteger status));
// Blocking: call off the main thread. Response contains zero or one proxy.
NSDictionary *KiraGatewayProxy(NSString *pool, NSString *mode, NSInteger *status);
