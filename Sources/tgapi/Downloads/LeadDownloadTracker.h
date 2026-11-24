// Lead download progress monitor (iOS 17+). Does not alter Telegram's MTProto responses.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

FOUNDATION_EXPORT NSString *const LeadDownloadStatusDidChange;

@interface LeadDownloadTracker : NSObject
// An upload.getFile / upload.getCdnFile request returns an opaque token whose
// response parser receives TL data. Track only successful file payloads.
+ (NSString *)tokenForPayload:(NSData *)payload functionID:(int32_t)functionID;
+ (void)receivedResponse:(NSData *)response forToken:(NSString *)token
                payload:(NSData *)payload functionID:(int32_t)functionID;
+ (void)registerDocumentId:(int64_t)documentId size:(int64_t)size
                       name:(NSString *)name datacenter:(NSInteger)dc;
+ (void)registerMediaRoot:(NSString *)root;
+ (NSDictionary *)currentDownload;
+ (NSUInteger)activeDownloadCount;
+ (void)installLifecycle;
@end
