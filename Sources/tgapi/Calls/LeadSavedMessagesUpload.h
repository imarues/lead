#import <Foundation/Foundation.h>

// Uploads a finished call recording straight into the signed-in account's
// Saved Messages over Telegram's own MTProto connection. No share sheet and no
// chat picker; the recording stays in the local archive either way.
@interface LeadSavedMessagesUpload : NSObject
// progress: 0...1, main thread. completion: nil error means the message was
// accepted by the server; @"cancelled" means the user cancelled.
+ (instancetype)startWithFile:(NSURL *)file
                     progress:(void (^)(double fraction))progress
                   completion:(void (^)(NSString *error))completion;
- (void)cancel;
@end
