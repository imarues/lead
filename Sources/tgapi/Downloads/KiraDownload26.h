#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface KiraDownload26 : NSObject
+ (BOOL)supported;
+ (void)install;
+ (void)registerMediaRoot:(NSString *)root;
+ (NSString *)tokenForPayload:(NSData *)payload functionID:(int32_t)functionID;
+ (void)receivedResponse:(NSData *)response forToken:(NSString *)token payload:(NSData *)payload functionID:(int32_t)functionID;
+ (void)associateService:(id)service withProto:(id)proto;
+ (void)noteRequest:(NSData *)payload functionID:(int32_t)functionID service:(id)service;
+ (BOOL)deferPause:(id)proto;
+ (void)noteResume:(id)proto;
+ (void)showOptions:(UIViewController *)host;
+ (NSString *)status;
@end
