#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Call recording is always opt-in and visibly indicated; never auto-starts.
FOUNDATION_EXPORT NSString *const LeadCallRecordingEnabledKey;
FOUNDATION_EXPORT NSString *const LeadCallRecordingChangedNotification;

@interface LeadCallRecording : NSObject
+ (instancetype)shared;
@property(nonatomic,readonly,getter=isRecording) BOOL recording;
+ (NSString *)recordingsDirectory;
+ (NSArray<NSURL *> *)recordings;
- (void)startForView:(UIView *)view
              video:(BOOL)video
         completion:(void (^)(NSError *error))completion;
- (void)stop:(void (^)(NSURL *output, NSError *error))completion;
@end

@interface LeadCallRecordingsViewController : UITableViewController
@end
