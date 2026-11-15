#import <Foundation/Foundation.h>

// Uploads a finished call recording over the signed-in Telegram MTProto
// connection to the chosen recipient. Keeps the recording in local archive.
@interface LeadSavedMessagesUpload : NSObject
// progress: 0...1, main thread. completion: nil error means the message was
// accepted by the server; @"cancelled" means the user cancelled.
+ (instancetype)startWithFile:(NSURL *)file
                     progress:(void (^)(double fraction))progress
                   completion:(void (^)(NSString *error))completion;
// peerData: boxed TL InputPeer from LeadDialogResponseParser, or the boxed
// inputPeerSelf constructor for Saved Messages.
+ (instancetype)startWithFile:(NSURL *)file
                    peerData:(NSData *)peerData
                    progress:(void (^)(double fraction))progress
                  completion:(void (^)(NSString *error))completion;
// Generic documents: correct PDF MIME and filename, optional 320px JPEG thumbnail.
+ (instancetype)sendDocumentToSavedMessages:(NSURL *)file
                             thumbnailJPEG:(NSData *)thumbnailJPEG
                                  progress:(void (^)(double fraction))progress
                                completion:(void (^)(NSString *error))completion;
// Native photo message (not a document attachment) for extracted PDF pages.
+ (instancetype)sendPhotoToSavedMessages:(NSURL *)file
                               progress:(void (^)(double fraction))progress
                             completion:(void (^)(NSString *error))completion;
- (void)cancel;
@end
