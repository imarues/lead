#import <Foundation/Foundation.h>
// Audio capture API; called only following explicit user confirmation.
#ifdef __cplusplus
extern "C" {
#endif
void LeadCallAudioInstallHooks(void);
BOOL LeadCallAudioStart(NSString *temporaryDirectory);
void LeadCallAudioStop(void (^completion)(NSURL *mixedAudio, NSError *error));
#ifdef __cplusplus
}
#endif
