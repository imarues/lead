#import <Foundation/Foundation.h>

// Public HTTPS gateway. The Worker returns one proxy at a time.
// No activation, device token or authentication is required.
NSString *KiraGatewayHost(void);
// Blocking: call off the main thread. Response contains zero or one proxy.
NSDictionary *KiraGatewayProxy(NSString *pool, NSString *mode, NSInteger *status);
