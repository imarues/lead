// Lead virtual video call - experimental private call video source.
// Selection occurs before dialing. No virtual frames or audio are sent until
// tgcalls reports OngoingCallStateConnected. No ordinary microphone fallback.
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import "LeadCallRecording.h"
#import <CoreImage/CoreImage.h>
#import <AVFoundation/AVPlayerLayer.h>
#import <CallKit/CallKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#include <atomic>
#include <memory>
#include <vector>
#include <algorithm>
#include <cmath>  // std::tanh used by virtual movie loudness compressor
#include <cstring>

static void LeadCloseGroupMediaControls(void);

namespace {
struct AudioClip { std::vector<int16_t> samples; };
static std::shared_ptr<AudioClip> gPCM;
// Fixed-point 48 kHz media timeline. Advances by rendered AUDIO frames, not wall-clock jitter.
static std::atomic<uint64_t> gAudioPositionQ32{0};
static std::atomic<int> gMode{0}; // 0 normal, 1 armed/ringing, 2 connected/playing, 3 finished/muted
static std::atomic<bool> gExpectCapturer{false};
static std::atomic<bool> gConnected{false};
// The active incoming CallKit video call can be answered before media is
// selected; keep the live WebRTC context distinct from outgoing selection.
static std::atomic<bool> gIncomingChoice{false};
static std::atomic<bool> gIncomingConnected{false};
static std::atomic<int> gPreviousRemoteVideo{-1};
// Incoming camera must never send real frames before an explicit selection.
static std::atomic<bool> gIncomingPrivacyGate{false};
static std::atomic<int> gObservedCallState{-1};
static std::atomic<double> gStartClock{0};
static std::atomic<bool> gExternalAudio{false};
static std::atomic<uint64_t> gMicInjectedFrames{0};
static std::atomic<uint64_t> gExternalAudioBytes{0};
static std::atomic<uint64_t> gFramesSubmitted{0};
static std::atomic<bool> gFullCallMode{false};
static std::atomic<uint64_t> gRemoteLayoutTicks{0};
static std::atomic<double> gFullRemoteDuration{0};
static bool gNativeHooksReady=false;
// ---- Group calls (GroupCallThreadLocalContext) ----
static std::atomic<bool> gGroupMode{false};  // virtual video is live in a group call
static std::atomic<bool> gGroupHold{false};  // camera-choice popup/picker open: real camera stays off
static bool gGroupHooksReady=false;
static char kLeadVideoActiveObserver;
static void (*gNativeSetActiveObserver)(id,SEL,void(^)(bool))=nullptr;
static void (*gNativeSwitchInput)(id,SEL,NSString *)=nullptr;
static __weak id gGroupObservedCapturer=nil;
static std::atomic<bool> gGroupFramesFlowing{false};
static __weak UIView *gGroupCallView=nil;
static BOOL gGroupChoiceBusy=NO;
static BOOL gGroupNormalChosen=NO;
static BOOL gGroupNormalActive=NO;
static BOOL gGroupReplayAction=NO;
static std::atomic<bool> gGroupGalleryPending{false};
static std::atomic<uint32_t> gGroupPreviewLayoutTicks{0};
static void (*gGroupRequestVideo)(id,SEL,id,id)=nullptr;
static void (*gGroupDisableVideo)(id,SEL)=nullptr;
static void (*gGroupDisableVideoCompletion)(id,SEL,id)=nullptr;
static void (*gGroupStop)(id,SEL,id)=nullptr;
static __weak id gGroupContext=nil;
static id gGroupPendingCapturer=nil;
static id gGroupPendingCompletion=nil;
static id (*gNativeInit)(id,SEL,NSString *,bool)=nullptr;
typedef void (^LeadStateBlock)(int32_t,int32_t,int32_t,int32_t,int32_t,float);
static void (*gNativeStateSetter)(id,SEL,LeadStateBlock)=nullptr;
static void (*gNativeRequestVideo)(id,SEL,id)=nullptr;
static void (*gNativeSetVideoEnabled)(id,SEL,bool)=nullptr;
extern "C" void objc_release(id);
extern "C" id objc_retain(id);
}

@interface LeadVirtualClip : NSObject
@property(nonatomic,strong) AVAssetReader *reader;
@property(nonatomic,strong) AVAssetReaderOutput *frames;
@property(nonatomic,assign) CMSampleBufferRef current;
@property(nonatomic,assign) CMSampleBufferRef next;
@property(nonatomic,assign) BOOL exhausted;
@property(nonatomic,assign) NSTimeInterval duration;
@property(nonatomic,assign) double sourceFPS;
@property(nonatomic,assign) NSInteger sourceWidth;
@property(nonatomic,assign) NSInteger sourceHeight;
@property(nonatomic,assign) double lastSubmittedPTS;
@end
@implementation LeadVirtualClip
- (void)dealloc {
    if(_current)CFRelease(_current);
    if(_next)CFRelease(_next);
    [_reader cancelReading];
}
@end

@interface LeadVirtualMedia : NSObject <PHPickerViewControllerDelegate>
@property(nonatomic,copy) void (^pendingCall)(BOOL);
@property(nonatomic,strong) LeadVirtualClip *clip;
@property(nonatomic,strong) id externalCapturer;
@property(nonatomic,strong) id nativeCallContext;
@property(nonatomic,weak) id incomingNativeContext;
@property(nonatomic,weak) UIView *privateCallView;
@property(nonatomic,strong) NSURL *selectedURL;
@property(nonatomic,strong) NSURL *remoteSelectedURL;
@property(nonatomic,assign) BOOL fullCallRequested;
@property(nonatomic,strong) AVPlayer *remotePlayer;
@property(nonatomic,strong) AVPlayerLayer *remoteLayer;
@property(nonatomic,strong) UIView *remoteVideoView;
@property(nonatomic,weak) UIView *nativeVideoContainerView;
@property(nonatomic,strong) AVPlayerItemVideoOutput *remotePixelOutput;
@property(nonatomic,strong) CIContext *remoteRecordingContext;
@property(nonatomic,strong) UIImage *remoteRecordingFrame;
@property(nonatomic,assign) uint64_t nextAudioSample;
@property(nonatomic,strong) dispatch_source_t playbackTimer;
@property(nonatomic,assign) BOOL incomingMenuPresented;
@property(nonatomic,assign) BOOL incomingAwaitingMenu;
@property(nonatomic,assign) NSInteger incomingAttachAttempts;
@property(nonatomic,strong) NSUUID *incomingAnsweredUUID;
@property(nonatomic,weak) id lastPhysicalCamera;
@property(nonatomic,weak) id protectedPhysicalCamera;
@property(nonatomic,strong) UIView *localPreviewView;
@property(nonatomic,strong) UIView *groupPreviewView;
@property(nonatomic,strong) AVPlayer *groupPreviewPlayer;
@property(nonatomic,strong) AVPlayerLayer *groupPreviewLayer;
@property(nonatomic,strong) AVPlayer *localPreviewPlayer;
@property(nonatomic,strong) AVPlayerLayer *localPreviewLayer;
@property(nonatomic,strong) AVPlayerItemVideoOutput *localPreviewPixelOutput;
@property(nonatomic,strong) CIContext *localRecordingCIContext;
@property(nonatomic,strong) UIImage *localRecordingLastFrame;
// Preview-only UI layout. Never used by tgcalls, the video encoder, or audio.
@property(nonatomic,assign) CGFloat localPreviewScale;
@property(nonatomic,assign) CGPoint localPreviewNormalizedCenter;
@property(nonatomic,assign) BOOL localPreviewHasSavedCenter;
+ (instancetype)shared;
- (void)preparePicker:(void(^)(BOOL))completion;
- (void)preparePicker:(void(^)(BOOL))completion fullCall:(BOOL)fullCall;
- (void)startRemotePreview;
- (void)removeRemotePreview;
- (void)releaseStaleCallAudioIfFinished;
- (void)drawRemotePreviewIntoRecording:(UIView *)root;
- (void)resetAll;
- (void)nativeCapturerReady:(id)capturer;
- (void)nativeContextReady:(id)context;
- (void)nativeState:(int32_t)state;
- (BOOL)installNativeHooks;
- (void)showError:(NSString *)message;
- (void)rememberCallView:(UIView *)view;
- (void)forgetCallView:(UIView *)view;
- (void)endTelegramCallWhenFinished;
- (void)incomingVideoAnsweredForUUID:(NSUUID *)uuid;
- (BOOL)hasLiveIncomingVideoCall;
- (void)showIncomingSourceMenu;
- (void)attachIncomingGalleryVideo;
- (void)normalIncomingAnswer;
- (void)installIncomingObservers;
- (void)incomingDidBecomeActive:(NSNotification *)note;
- (void)protectIncomingCamera;
- (void)capturePhysicalCamera:(id)camera;
- (void)startLocalPreview;
- (void)removeLocalPreview;
- (void)startGroupPreview;
- (void)updateGroupPreview;
- (void)removeGroupPreview;
- (void)drawGalleryPreviewIntoRecording:(UIView *)root;
- (void)dragLocalPreview:(UIPanGestureRecognizer *)gesture;
- (void)pinchLocalPreview:(UIPinchGestureRecognizer *)gesture;
- (void)layoutLocalPreviewInHost:(UIView *)host;
- (void)groupSetPhysical:(id)camera enabled:(BOOL)on;
- (void)installGroupHooks;
- (void)groupVideoRequestedOnContext:(id)context capturer:(id)capturer completion:(id)completion;
- (void)groupVideoFinished;
- (void)groupVideoUserStopped;
@end

static id LeadInitNativeVideoCapturer(id self, SEL command, NSString *deviceId, bool keepLandscape) {
    if(gMode.load()==1 && gExpectCapturer.exchange(false)) {
        Class klass=object_getClass(self);
        SEL sel=NSSelectorFromString(@"capturerWithExternalSampleBufferProvider");
        if([klass respondsToSelector:sel]) {
            id custom=((id (*)(id,SEL))objc_msgSend)(klass,sel);
            if(custom) {
                NSLog(@"[LeadVirtualMedia] installed tgcalls external video source");
                [[LeadVirtualMedia shared] nativeCapturerReady:custom];
                // -init replaces the allocated receiver with the custom capturer.
                objc_release(self);
                return objc_retain(custom);
            }
        }
        NSLog(@"[LeadVirtualMedia] external video factory unavailable");
    }
    // A selected group gallery source must never fall back to a physical camera.
    if(gGroupGalleryPending.load()) {
        objc_release(self);
        return nil;
    }
    id camera=gNativeInit ? gNativeInit(self,command,deviceId,keepLandscape) : self;
    if(camera)[[LeadVirtualMedia shared] capturePhysicalCamera:camera];
    return camera;
}
static void LeadSetNativeCallState(id self, SEL command, LeadStateBlock block) {
    // Observe the current WebRTC call even before a gallery movie is chosen.
    // Late hook activation previously lost the incoming call context.
    [[LeadVirtualMedia shared] nativeContextReady:self];
    LeadStateBlock original=[block copy];
    LeadStateBlock wrapped=^(int32_t state,int32_t v,int32_t rv,int32_t ra,int32_t b,float aspect) {
        int oldRemote=gPreviousRemoteVideo.exchange(rv);
        if(oldRemote!=rv)
            NSLog(@"[LeadVirtualMedia] remote-video-state=%d (0=off,1=on,2=paused), local-video=%d",rv,v);
        [[LeadVirtualMedia shared] nativeState:state];
        if(original)original(state,v,rv,ra,b,aspect);
    };
    if(gNativeStateSetter)gNativeStateSetter(self,command,wrapped);
}
// Group participant state subscribes to the Swift-owned capturer's isActive.
// Preserve that subscription even for the legacy, late source-selection path.
static void LeadSetVideoActiveObserver(id self,SEL cmd,void (^observer)(bool)) {
    objc_setAssociatedObject(self,&kLeadVideoActiveObserver,observer,OBJC_ASSOCIATION_COPY_NONATOMIC);
    __weak id source=self;
    void (^wrapped)(bool)=^(bool active){
        id camera=source;
        BOOL virtualSource=gGroupMode.load() &&
            (camera==gGroupObservedCapturer || camera==[LeadVirtualMedia shared].externalCapturer);
        if(virtualSource && gGroupFramesFlowing.load())active=true;
        if(observer)observer(active);
    };
    if(gNativeSetActiveObserver)gNativeSetActiveObserver(self,cmd,observer?wrapped:(void (^)(bool))nil);
}
static void LeadSwitchVideoInput(id self,SEL cmd,NSString *device) {
    // Telegram's rotate control must not turn a gallery source into a camera.
    if((gGroupGalleryPending.load() || gGroupMode.load()) &&
       self==[LeadVirtualMedia shared].externalCapturer)return;
    if(gNativeSwitchInput)gNativeSwitchInput(self,cmd,device);
}
static void LeadGroupFrameDelivered(id capturer) {
    // Completions from the encoder may arrive AFTER EOF. Never resurrect the
    // active-video state or remote participants will retain a frozen frame.
    if(gMode.load()!=2 || !gGroupMode.load() ||
       capturer!=[LeadVirtualMedia shared].externalCapturer ||
       gGroupFramesFlowing.exchange(true))return;
    dispatch_async(dispatch_get_main_queue(),^{
        if(gMode.load()!=2 || !gGroupMode.load() ||
           capturer!=[LeadVirtualMedia shared].externalCapturer)return;
        id observed=gGroupObservedCapturer ?: capturer;
        void (^observer)(bool)=objc_getAssociatedObject(observed,&kLeadVideoActiveObserver);
        if(observer)observer(true);
    });
}

static void LeadNativeCameraEnabled(id self,SEL cmd,bool enabled) {
    // Source may already exist when CallKit accepts. Even if Telegram tries
    // to enable the camera again, the incoming-source gate denies it.
    LeadVirtualMedia *m=[LeadVirtualMedia shared];
    if(gIncomingPrivacyGate.load() && self!=m.externalCapturer)enabled=false;
    // Group call: the real camera never turns on while the choice popup is open
    // or while a gallery video is being sent.
    if((gGroupHold.load() || gGroupMode.load()) && self!=m.externalCapturer)enabled=false;
    if(gNativeSetVideoEnabled)gNativeSetVideoEnabled(self,cmd,enabled);
}
static void LeadRequestNativeVideo(id self, SEL command, id capturer) {
    LeadVirtualMedia *m=[LeadVirtualMedia shared];
    [m nativeContextReady:self];
    if(gIncomingPrivacyGate.load(std::memory_order_acquire) &&
       capturer != m.externalCapturer) {
        [m protectIncomingCamera];
        if(capturer && [capturer respondsToSelector:@selector(setIsVideoEnabled:)])
            ((void (*)(id,SEL,bool))objc_msgSend)(
                capturer,@selector(setIsVideoEnabled:),false);
    }
    // The low-level WebRTC request also runs inside group calls. Do not
    // consume the pending group selection here: only the GROUP context can
    // establish the correct transport, video-active observer and EOF owner.
    if(gGroupGalleryPending.load() && capturer && capturer!=m.externalCapturer) {
        [m groupSetPhysical:capturer enabled:NO];
        NSLog(@"[LeadVirtualMedia] rejected physical fallback during gallery handoff");
        return;
    }
    if(gNativeRequestVideo)gNativeRequestVideo(self,command,capturer);
}

// Group call: Telegram hands the camera capturer to the group context when the
// user taps the camera button. Intercept here, ask Normal / Upload video.
static void LeadGroupRequestVideo(id self, SEL command, id capturer, id completion) {
    LeadVirtualMedia *m=[LeadVirtualMedia shared];
    if(capturer && capturer==m.externalCapturer && gGroupGalleryPending.exchange(false)) {
        gGroupContext=self;
        gGroupObservedCapturer=capturer;gGroupFramesFlowing.store(false);
        gGroupMode.store(true);
        gGroupHold.store(false);
        // Set the source to active before the group transport requests it:
        // its initial state is otherwise Paused, propagated to remote peers.
        [m groupSetPhysical:capturer enabled:YES];
        if(gGroupRequestVideo)gGroupRequestVideo(self,command,capturer,completion);
        gConnected.store(true);
        NSLog(@"[LeadVirtualMedia] group external video attached: %@",NSStringFromClass([capturer class]));
        [m nativeCapturerReady:capturer];
        return;
    }
    if(gGroupNormalChosen || !capturer || capturer==m.externalCapturer) {
        if(gGroupNormalChosen)gGroupNormalActive=YES;
        gGroupNormalChosen=NO;
        if(gGroupRequestVideo)gGroupRequestVideo(self,command,capturer,completion);
        return;
    }
    [m groupVideoRequestedOnContext:self capturer:capturer completion:completion];
}
static void LeadGroupDisableVideo(id self, SEL command) {
    gGroupNormalActive=NO;
    // EOF already owns the teardown. Do not asynchronously reset the media
    // context in the middle of Telegram's own high-level disableVideo action.
    if(gGroupMode.load() && gMode.load()!=3)
        [[LeadVirtualMedia shared] groupVideoUserStopped];
    if(gGroupDisableVideo)gGroupDisableVideo(self,command);
}
static void LeadGroupDisableVideoCompletion(id self, SEL command, id completion) {
    gGroupNormalActive=NO;
    if(gGroupMode.load() && gMode.load()!=3)
        [[LeadVirtualMedia shared] groupVideoUserStopped];
    if(gGroupDisableVideoCompletion)gGroupDisableVideoCompletion(self,command,completion);
}
static void LeadGroupStop(id self, SEL command, id completion) {
    gGroupNormalActive=NO;gGroupGalleryPending.store(false);
    if((gGroupMode.load() || gGroupHold.load()) && self==gGroupContext) {
        gGroupMode.store(false);gGroupHold.store(false);gGroupContext=nil;
        gGroupPendingCapturer=nil;gGroupPendingCompletion=nil;
        dispatch_async(dispatch_get_main_queue(),^{[[LeadVirtualMedia shared] resetAll];});
    }
    if(gGroupStop)gGroupStop(self,command,completion);
}

@implementation LeadVirtualMedia
+ (instancetype)shared {
    static LeadVirtualMedia *shared=nil;static dispatch_once_t once;
    dispatch_once(&once,^{shared=[LeadVirtualMedia new];});
    return shared;
}
- (UIViewController *)host {
    UIWindow *window=UIApplication.sharedApplication.keyWindow;
    if(!window)for(UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:[UIWindowScene class]])continue;
        if(scene.activationState!=UISceneActivationStateForegroundActive)continue;
        for(UIWindow *w in scene.windows)if(w.isKeyWindow){window=w;break;}
        if(window)break;
    }
    UIViewController *root=window.rootViewController;
    while(root.presentedViewController)root=root.presentedViewController;
    return root;
}
- (void)showError:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(),^{
        UIViewController *host=[self host];if(!host)return;
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Lead — فيديو المكالمة"
            message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"موافق" style:UIAlertActionStyleCancel handler:nil]];
        [host presentViewController:alert animated:YES completion:nil];
    });
}
- (BOOL)installNativeHooks {
    @synchronized(self) {
        if(gNativeHooksReady)return YES;
        Class c=objc_getClass("OngoingCallThreadLocalContextVideoCapturer");
        Class w=objc_getClass("OngoingCallThreadLocalContextWebrtc");
        SEL factory=NSSelectorFromString(@"capturerWithExternalSampleBufferProvider");
        Method init=c?class_getInstanceMethod(c,@selector(initWithDeviceId:keepLandscape:)):NULL;
        Method state=w?class_getInstanceMethod(w,@selector(setStateChanged:)):NULL;
        Method req=w?class_getInstanceMethod(w,@selector(requestVideo:)):NULL;
        Method enabled=c?class_getInstanceMethod(c,@selector(setIsVideoEnabled:)):NULL;
        if(!c || !w || !init || !state || !req || ![c respondsToSelector:factory]) {
            NSLog(@"[LeadVirtualMedia] native capturer/state API not found in installed Telegram");
            return NO;
        }
        gNativeInit=(decltype(gNativeInit))method_setImplementation(init,(IMP)LeadInitNativeVideoCapturer);
        gNativeStateSetter=(decltype(gNativeStateSetter))method_setImplementation(state,(IMP)LeadSetNativeCallState);
        gNativeRequestVideo=(decltype(gNativeRequestVideo))method_setImplementation(req,(IMP)LeadRequestNativeVideo);
        if(enabled)gNativeSetVideoEnabled=(decltype(gNativeSetVideoEnabled))
            method_setImplementation(enabled,(IMP)LeadNativeCameraEnabled);
        Method active=class_getInstanceMethod(c,@selector(setOnIsActiveUpdated:));
        if(active)gNativeSetActiveObserver=(decltype(gNativeSetActiveObserver))
            method_setImplementation(active,(IMP)LeadSetVideoActiveObserver);
        Method rotate=class_getInstanceMethod(c,@selector(switchVideoInput:));
        if(rotate)gNativeSwitchInput=(decltype(gNativeSwitchInput))
            method_setImplementation(rotate,(IMP)LeadSwitchVideoInput);
        gNativeHooksReady=true;
        return YES;
    }
}
- (void)installGroupHooks {
    @synchronized(self) {
        if(gGroupHooksReady)return;
        Class g=objc_getClass("GroupCallThreadLocalContext");
        if(!g)return;
        Method req=class_getInstanceMethod(g,NSSelectorFromString(@"requestVideo:completion:"));
        if(!req) {
            NSLog(@"[LeadVirtualMedia] group requestVideo:completion: not found");
            return;
        }
        gGroupRequestVideo=(decltype(gGroupRequestVideo))method_setImplementation(req,(IMP)LeadGroupRequestVideo);
        Method d0=class_getInstanceMethod(g,NSSelectorFromString(@"disableVideo"));
        if(d0)gGroupDisableVideo=(decltype(gGroupDisableVideo))method_setImplementation(d0,(IMP)LeadGroupDisableVideo);
        Method d1=class_getInstanceMethod(g,NSSelectorFromString(@"disableVideo:"));
        if(d1)gGroupDisableVideoCompletion=(decltype(gGroupDisableVideoCompletion))
            method_setImplementation(d1,(IMP)LeadGroupDisableVideoCompletion);
        Method st=class_getInstanceMethod(g,NSSelectorFromString(@"stop:"));
        if(st)gGroupStop=(decltype(gGroupStop))method_setImplementation(st,(IMP)LeadGroupStop);
        gGroupHooksReady=true;
        NSLog(@"[LeadVirtualMedia] group-call video hooks installed");
    }
}
- (void)groupSetPhysical:(id)camera enabled:(BOOL)on {
    if(camera && [camera respondsToSelector:@selector(setIsVideoEnabled:)])
        ((void (*)(id,SEL,bool))objc_msgSend)(camera,@selector(setIsVideoEnabled:),on);
}
- (void)groupVideoRequestedOnContext:(id)context capturer:(id)capturer completion:(id)completion {
    gGroupHold.store(true);
    gGroupContext=context;
    gGroupPendingCapturer=capturer;
    gGroupObservedCapturer=capturer;gGroupFramesFlowing.store(false);
    gGroupPendingCompletion=[completion copy];
    [self capturePhysicalCamera:capturer];
    [self groupSetPhysical:capturer enabled:NO]; // real camera stays dark until the choice
    dispatch_async(dispatch_get_main_queue(),^{[self groupShowChoice];});
}
- (void)groupShowChoice {
    UIViewController *host=[self host];
    if(!host){[self groupResumeNormal];return;}
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"كاميرا المكالمة"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"اتصال طبيعي" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a){[self groupResumeNormal];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"رفع فيديو" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a){
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.25*NSEC_PER_SEC)),
                dispatch_get_main_queue(),^{[self groupPickVideo];});
        }]];
    [host presentViewController:alert animated:YES completion:nil];
}
- (void)groupResumeNormal {
    id ctx=gGroupContext,cap=gGroupPendingCapturer,comp=gGroupPendingCompletion;
    gGroupPendingCapturer=nil;gGroupPendingCompletion=nil;
    gGroupHold.store(false);
    if(!ctx||!cap)return;
    if(gGroupRequestVideo)
        gGroupRequestVideo(ctx,NSSelectorFromString(@"requestVideo:completion:"),cap,comp);
    [self groupSetPhysical:cap enabled:YES];
}
- (void)groupPickVideo {
    [self preparePicker:^(BOOL ok){
        if(!ok) {
            // Picker cancelled or failed: back to the choice, never to the real camera.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.6*NSEC_PER_SEC)),
                dispatch_get_main_queue(),^{[self groupShowChoice];});
            return;
        }
        [self groupStartVirtualVideo];
    } fullCall:NO];
}
- (void)groupStartVirtualVideo {
    id ctx=gGroupContext,comp=gGroupPendingCompletion;
    gGroupPendingCapturer=nil;gGroupPendingCompletion=nil;
    gExpectCapturer.store(false); // we build the external capturer ourselves here
    Class klass=objc_getClass("OngoingCallThreadLocalContextVideoCapturer");
    SEL factory=NSSelectorFromString(@"capturerWithExternalSampleBufferProvider");
    id custom=(klass && [klass respondsToSelector:factory]) ?
        ((id (*)(id,SEL))objc_msgSend)(klass,factory) : nil;
    if(!ctx || !custom || !gGroupRequestVideo) {
        gGroupHold.store(false);gGroupMode.store(false);
        [self resetAll];
        [self showError:@"تعذر تجهيز مصدر الفيديو الخارجي بالمكالمة الجماعية. ما انرسلت الكاميرا الحقيقية."];
        return;
    }
    @synchronized(self){self.externalCapturer=custom;}
    gGroupMode.store(true);   // keeps the physical camera blocked from now on
    gGroupHold.store(false);
    gConnected.store(true);   // we are already inside the group call
    [self groupSetPhysical:custom enabled:YES];
    gGroupObservedCapturer=custom;gGroupFramesFlowing.store(false);
    gGroupRequestVideo(ctx,NSSelectorFromString(@"requestVideo:completion:"),custom,comp);
    [self nativeCapturerReady:custom]; // maybeStart -> frames + audio begin
}
- (void)groupVideoFinished {
    id ctx=gGroupContext;
    id external=self.externalCapturer;
    id physical=self.lastPhysicalCamera;
    // Block the mic and any more outgoing frames immediately at the movie EOF.
    // Do NOT pause the capturer first: Telegram interprets Paused as "keep the
    // participant's last frame on screen". We want the higher-level
    // PresentationGroupCallImpl.disableVideo() to advertise video OFF instead.
    gMode.store(3);
    gGroupFramesFlowing.store(false);
    [self stopTimer];
    SEL mute=NSSelectorFromString(@"setIsMuted:");
    if(ctx && [ctx respondsToSelector:mute])
        ((void (*)(id,SEL,bool))objc_msgSend)(ctx,mute,true);

    // Trigger Telegram's actual onCameraPressed -> disableVideo first. This
    // updates BOTH local isMyVideoActive and the group server's isVideoMuted
    // participant metadata. Calling the low-level WebRTC method alone only
    // detaches a capturer and may leave a frozen tile visible to peers.
    LeadCloseGroupMediaControls();

    // Native transport fallback, after the Swift state-change request.
    // The active-observer wrapper cannot turn false back into true once EOF
    // has reset gGroupFramesFlowing, even if a final encoder callback arrives.
    [self groupSetPhysical:external enabled:NO];
    if(physical!=external)[self groupSetPhysical:physical enabled:NO];
    if(ctx) {
        if([ctx respondsToSelector:NSSelectorFromString(@"disableVideo:")])
            ((void (*)(id,SEL,id))objc_msgSend)(ctx,NSSelectorFromString(@"disableVideo:"),^(NSString *endpoint,uint32_t ssrc){});
        else if([ctx respondsToSelector:NSSelectorFromString(@"disableVideo")])
            ((void (*)(id,SEL))objc_msgSend)(ctx,NSSelectorFromString(@"disableVideo"));
    }
    NSLog(@"[LeadVirtualMedia] group EOF: Swift camera-off requested before transport shutdown");
    gGroupMode.store(false);gGroupHold.store(false);gGroupGalleryPending.store(false);
    gGroupNormalChosen=NO;gGroupNormalActive=NO;
    gGroupContext=nil;gGroupObservedCapturer=nil;
    gGroupPendingCapturer=nil;gGroupPendingCompletion=nil;
    [self resetAll]; // Mic and camera now stopped, remain inside the voice chat.
}
- (void)groupVideoUserStopped {
    // The user pressed the camera button themselves while the video was playing.
    gGroupMode.store(false);gGroupHold.store(false);gGroupContext=nil;
    dispatch_async(dispatch_get_main_queue(),^{[self resetAll];});
}
- (void)stopTimer {
    if(self.playbackTimer){dispatch_source_cancel(self.playbackTimer);self.playbackTimer=nil;}
}
- (void)resetAll {
    gMode.store(0);
    gGroupFramesFlowing.store(false);
    gExpectCapturer.store(false);
    gConnected.store(false);
    gStartClock.store(0);
    gAudioPositionQ32.store(0);
    gExternalAudio.store(false);
    gExternalAudioBytes.store(0);
    gMicInjectedFrames.store(0);
    gFramesSubmitted.store(0);
    gFullCallMode.store(false);
    gRemoteLayoutTicks.store(0);
    gGroupPreviewLayoutTicks.store(0);
    gFullRemoteDuration.store(0);
    std::atomic_store(&gPCM,std::shared_ptr<AudioClip>());
    [self stopTimer];
    [self removeLocalPreview];
    [self removeGroupPreview];
    [self removeRemotePreview];
    @synchronized(self) {
        self.clip=nil;self.externalCapturer=nil;self.nativeCallContext=nil;self.nextAudioSample=0;
        if(self.selectedURL)[[NSFileManager defaultManager] removeItemAtURL:self.selectedURL error:nil];
        if(self.remoteSelectedURL)[[NSFileManager defaultManager] removeItemAtURL:self.remoteSelectedURL error:nil];
        self.selectedURL=nil;self.remoteSelectedURL=nil;
        self.fullCallRequested=NO;
    }
}
- (void)finishPicker:(BOOL)success {
    dispatch_async(dispatch_get_main_queue(),^{
        void (^call)(BOOL)=self.pendingCall;
        self.pendingCall=nil;
        if(!success) {
            [self resetAll];
            if(gIncomingPrivacyGate.load() && [self hasLiveIncomingVideoCall]) {
                // Gallery cancellation must not activate the real camera.
                gIncomingChoice.store(true);
                self.incomingAwaitingMenu=YES;
                self.incomingMenuPresented=NO;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(0.35*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                    [self showIncomingSourceMenu];
                });
            } else {
                gIncomingChoice.store(false);
                gIncomingConnected.store(false);
                self.incomingNativeContext=nil;
            }
        }
        if(call)call(success);
    });
}
- (void)preparePicker:(void(^)(BOOL))completion {
    [self preparePicker:completion fullCall:NO];
}
- (void)preparePicker:(void(^)(BOOL))completion fullCall:(BOOL)fullCall {
    BOOL incoming=gIncomingChoice.load();
    [self resetAll];
    self.fullCallRequested=fullCall;
    // Keep the real mic suppressed while Photos is open on a live incoming call.
    if(incoming)gMode.store(4);
    self.pendingCall=[completion copy];
    if(![self installNativeHooks]) {
        [self showError:@"هذا إصدار Telegram ما يعرض واجهة بث الفيديو الخارجية المطلوبة. تم إلغاء الاتصال بدلاً من إرسال كاميرا حقيقية بالغلط."];
        [self finishPicker:NO];
        return;
    }
    UIViewController *host=[self host];
    if(!host){[self finishPicker:NO];return;}
    PHPickerConfiguration *conf=[[PHPickerConfiguration alloc] init];
    conf.filter=[PHPickerFilter videosFilter];
    conf.selectionLimit=fullCall?2:1;
    if(@available(iOS 15.0,*)) conf.selection=PHPickerConfigurationSelectionOrdered;
    // Prefer the untouched original video asset instead of a Photos export.
    conf.preferredAssetRepresentationMode=PHPickerConfigurationAssetRepresentationModeCurrent;
    PHPickerViewController *picker=[[PHPickerViewController alloc] initWithConfiguration:conf];
    picker.delegate=self;
    [host presentViewController:picker animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    const BOOL full=self.fullCallRequested;
    if(results.count!=(full?2:1)) {
        if(full && results.count) [self showError:@"بوضع اتصال كامل لازم تختار مقطعين بالترتيب: الأول من عندك والثاني بدل كاميرا المقابل."];
        [self finishPicker:NO];return;
    }
    NSItemProvider *outgoing=results.firstObject.itemProvider;
    NSItemProvider *remote=full?results[1].itemProvider:nil;
    if(![outgoing hasItemConformingToTypeIdentifier:@"public.movie"] ||
       (full && ![remote hasItemConformingToTypeIdentifier:@"public.movie"])) {
        [self showError:@"اختَر مقطعين فيديو صحيحين من المعرض."];
        [self finishPicker:NO];return;
    }
    // NSItemProvider's temporary file must be copied before returning from
    // its callback. The ordered second item is never sent to the peer.
    [outgoing loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *url,NSError *error) {
        if(error || !url) {
            [self showError:error.localizedDescription?:@"فشل قراءة الفيديو الأول."];
            [self finishPicker:NO];return;
        }
        NSURL *first=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"lead-outgoing-%@.mov",NSUUID.UUID.UUIDString]]];
        NSError *copyError=nil;
        [[NSFileManager defaultManager] copyItemAtURL:url toURL:first error:&copyError];
        if(copyError) {
            [self showError:copyError.localizedDescription];
            [self finishPicker:NO];return;
        }
        self.selectedURL=first;
        if(!full) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{[self decodeMovie:first];});
            return;
        }
        [remote loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *remoteURL,NSError *remoteError) {
            if(remoteError || !remoteURL) {
                [self showError:remoteError.localizedDescription?:@"فشل قراءة الفيديو الثاني."];
                [self finishPicker:NO];return;
            }
            NSURL *second=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                 [NSString stringWithFormat:@"lead-remote-%@.mov",NSUUID.UUID.UUIDString]]];
            NSError *e=nil;
            [[NSFileManager defaultManager] copyItemAtURL:remoteURL toURL:second error:&e];
            if(e){[self showError:e.localizedDescription];[self finishPicker:NO];return;}
            AVURLAsset *asset=[AVURLAsset URLAssetWithURL:second options:nil];
            const double duration=CMTimeGetSeconds(asset.duration);
            if(![asset tracksWithMediaType:AVMediaTypeVideo].count ||
               ![asset tracksWithMediaType:AVMediaTypeAudio].count ||
               !isfinite(duration) || duration<=0 || duration>600) {
                [[NSFileManager defaultManager] removeItemAtURL:second error:nil];
                [self showError:@"الفيديو الثاني لازم يحتوي على صوت وصورة، ومدته أقل من 10 دقائق."];
                [self finishPicker:NO];return;
            }
            self.remoteSelectedURL=second;
            gFullRemoteDuration.store(duration,std::memory_order_release);
            gFullCallMode.store(true,std::memory_order_release);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{[self decodeMovie:first];});
        }];
    }];
}
- (void)decodeMovie:(NSURL *)url {
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *v=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *a=[asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    NSTimeInterval duration=CMTimeGetSeconds(asset.duration);
    if(!v || !a || !isfinite(duration) || duration<=0 || duration>600) {
        [self showError:@"الفيديو لازم يحتوي على صورة وصوت، ومدته أقل من 10 دقائق بالتجربة الحالية."];
        [self finishPicker:NO];return;
    }
    NSError *error=nil;
    AVAssetReader *ar=[[AVAssetReader alloc] initWithAsset:asset error:&error];
    if(!ar){[self showError:@"فشل فتح المسار الصوتي."];[self finishPicker:NO];return;}
    NSDictionary *audio=@{AVFormatIDKey:@(kAudioFormatLinearPCM),
       AVSampleRateKey:@48000,AVNumberOfChannelsKey:@1,
       AVLinearPCMBitDepthKey:@16,AVLinearPCMIsFloatKey:@NO,
       AVLinearPCMIsBigEndianKey:@NO,AVLinearPCMIsNonInterleavedKey:@NO};
    AVAssetReaderTrackOutput *ao=[[AVAssetReaderTrackOutput alloc] initWithTrack:a outputSettings:audio];
    [ar addOutput:ao];
    if(![ar startReading]){[self showError:@"فشل استخراج صوت الفيديو."];[self finishPicker:NO];return;}
    NSMutableData *pcmData=[NSMutableData data];
    CMSampleBufferRef packet=NULL;
    while((packet=[ao copyNextSampleBuffer])) {
        CMBlockBufferRef block=CMSampleBufferGetDataBuffer(packet);
        size_t length=block?CMBlockBufferGetDataLength(block):0;
        if(length && pcmData.length+length <= 62000000) {
            NSUInteger offset=pcmData.length;
            [pcmData increaseLengthBy:length];
            CMBlockBufferCopyDataBytes(block,0,length,(uint8_t *)pcmData.mutableBytes+offset);
        }
        CFRelease(packet);
        if(pcmData.length >= 61900000)break;
    }
    if(pcmData.length<2 || ar.status==AVAssetReaderStatusFailed) {
        [self showError:@"ما تم استخراج بيانات صوت صحيحة."];
        [self finishPicker:NO];return;
    }
    auto clipSound=std::make_shared<AudioClip>();
    clipSound->samples.resize(pcmData.length/2);
    memcpy(clipSound->samples.data(),pcmData.bytes,pcmData.length);
    // Video source: hardware NV12 straight into Telegram's encoder, which avoids
    // BGRA->YUV conversions. Two cases get an AVFoundation composition pass
    // (hardware accelerated) instead of the raw track:
    //  - rotation: portrait phone videos are stored sideways and flagged with
    //    preferredTransform, which the raw track ignores (sideways picture);
    //  - more than 1920x1080: WebRTC downsizes anything it can't send, in software,
    //    and 4K frames at 30 fps cost enough CPU to drop frames, which the other
    //    side sees as stutter. Everything up to 1080p keeps its exact resolution.
    const CGSize oriented=CGSizeApplyAffineTransform(v.naturalSize,v.preferredTransform);
    const CGFloat srcW=std::max((CGFloat)1,(CGFloat)fabs(oriented.width));
    const CGFloat srcH=std::max((CGFloat)1,(CGFloat)fabs(oriented.height));
    const CGFloat scale=std::min((CGFloat)1,std::min((CGFloat)1920/std::max(srcW,srcH),
                                                   (CGFloat)1080/std::min(srcW,srcH)));
    const bool rotated=!CGAffineTransformIsIdentity(v.preferredTransform);
    const bool wantComposition=rotated || scale<1;
    const NSInteger outW=std::max((NSInteger)2,(NSInteger)(floor(srcW*scale/2.0)*2.0));
    const NSInteger outH=std::max((NSInteger)2,(NSInteger)(floor(srcH*scale/2.0)*2.0));
    const double sourceRate=(v.nominalFrameRate>0 && isfinite(v.nominalFrameRate))
                             ? (double)v.nominalFrameRate : 30.0;
    // WebRTC doesn't send more than 30 fps; 60 fps sources are thinned evenly.
    const double outRate=std::max(12.0,std::min(30.0,sourceRate));
    __block AVAssetReader *vr=nil;
    __block AVAssetReaderOutput *vo=nil;
    __block BOOL composed=NO;
    BOOL (^openVideo)(BOOL,OSType)=^BOOL(BOOL useComposition,OSType format) {
        AVAssetReader *reader=[[AVAssetReader alloc] initWithAsset:asset error:nil];
        if(!reader)return NO;
        NSDictionary *settings=@{(id)kCVPixelBufferPixelFormatTypeKey:@(format)};
        AVAssetReaderOutput *output=nil;
        if(useComposition) {
            AVMutableVideoComposition *comp=[AVMutableVideoComposition videoComposition];
            comp.renderSize=CGSizeMake(outW,outH);
            comp.frameDuration=CMTimeMake(1,(int32_t)llround(outRate));
            AVMutableVideoCompositionInstruction *instruction=
                [AVMutableVideoCompositionInstruction videoCompositionInstruction];
            instruction.timeRange=CMTimeRangeMake(kCMTimeZero,asset.duration);
            AVMutableVideoCompositionLayerInstruction *layer=
                [AVMutableVideoCompositionLayerInstruction
                    videoCompositionLayerInstructionWithAssetTrack:v];
            [layer setTransform:CGAffineTransformConcat(v.preferredTransform,
                CGAffineTransformMakeScale(scale,scale)) atTime:kCMTimeZero];
            instruction.layerInstructions=@[layer];
            comp.instructions=@[instruction];
            AVAssetReaderVideoCompositionOutput *co=[AVAssetReaderVideoCompositionOutput
                assetReaderVideoCompositionOutputWithVideoTracks:@[v] videoSettings:settings];
            co.videoComposition=comp;
            output=co;
        } else {
            output=[[AVAssetReaderTrackOutput alloc] initWithTrack:v outputSettings:settings];
        }
        output.alwaysCopiesSampleData=NO;
        if(![reader canAddOutput:output])return NO;
        [reader addOutput:output];
        if(![reader startReading])return NO;
        vr=reader;vo=output;composed=useComposition;
        return YES;
    };
    BOOL opened=NO;
    if(wantComposition)opened=openVideo(YES,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    if(!opened) {
        if(wantComposition)NSLog(@"[LeadVirtualMedia] composition unavailable; using raw frames");
        opened=openVideo(NO,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    }
    if(!opened) {
        NSLog(@"[LeadVirtualMedia] NV12 decode unsupported; falling back to BGRA");
        opened=openVideo(NO,kCVPixelFormatType_32BGRA);
    }
    if(!opened){[self showError:@"فشل فك إطارات الفيديو."];[self finishPicker:NO];return;}
    LeadVirtualClip *video=[LeadVirtualClip new];
    video.reader=vr;video.frames=vo;video.duration=duration;
    video.sourceWidth=composed?outW:(NSInteger)fabs(v.naturalSize.width);
    video.sourceHeight=composed?outH:(NSInteger)fabs(v.naturalSize.height);
    video.sourceFPS=outRate;
    video.lastSubmittedPTS=-1.0;
    // The FIRST movie is transmitted to the other participant at high,
    // safely compressed/normalized WebRTC loudness. Its LOCAL preview has a
    // separate, quiet AVPlayer volume; do not attenuate this outgoing PCM.
    // The SECOND simulated-peer movie is heard loudly only on this device.
    int32_t peak=0;
    for(const int16_t sample:clipSound->samples)
        peak=std::max(peak,(int32_t)std::abs((int)sample));
    double gain=1.0;
    if(peak>0) {
        gain=std::min(6.0,(0.94*32767.0)/(double)peak);
        const double knee=2.25;
        const double scale=0.965/std::tanh(knee);
        for(int16_t &sample:clipSound->samples) {
            const double normalized=std::max(-1.0,std::min(1.0,
                ((double)sample/32768.0)*gain));
            const double boosted=scale*std::tanh(knee*normalized);
            sample=(int16_t)std::lrint(boosted*32767.0);
        }
    }
    NSLog(@"[LeadVirtualMedia] video %ldx%ld ~%.1ffps (composed=%d); audio samples=%lu, peak=%d, gain=%.2f",
          (long)video.sourceWidth,(long)video.sourceHeight,video.sourceFPS,(int)composed,
          (unsigned long)clipSound->samples.size(),(int)peak,gain);
    @synchronized(self) {
        self.clip=video;self.nextAudioSample=0;
        std::atomic_store(&gPCM,clipSound);
        gStartClock.store(0);
        const bool incoming=gIncomingChoice.load();
        gConnected.store(incoming && gIncomingConnected.load());
        gExpectCapturer.store(!incoming);
        gMode.store(1); // Incoming attaches to its connected call; outgoing awaits answer.
    }
    if(gIncomingChoice.load()) {
        NSLog(@"[LeadVirtualMedia] incoming gallery file prepared; attaching to already answered call");
        dispatch_async(dispatch_get_main_queue(),^{[self attachIncomingGalleryVideo];});
    } else {
        NSLog(@"[LeadVirtualMedia] outgoing gallery file prepared; now dialing");
        [self finishPicker:YES];
    }
}
- (void)nativeCapturerReady:(id)capturer {
    @synchronized(self){self.externalCapturer=capturer;}
    [self maybeStart];
}
- (void)nativeContextReady:(id)context {
    // Keep a weak reference to the actual private-call transport, independent
    // of any selected media. Do not hold terminated calls alive.
    self.incomingNativeContext=context;
    if(gMode.load()==0 || gMode.load()==4)return;
    @synchronized(self){self.nativeCallContext=context;}
    [self maybeStart];
}
- (void)nativeState:(int32_t)state {
    // WebRTC: 0 initializing, 1 connected (answered), 2 failed, 3 reconnecting.
    gObservedCallState.store(state);
    if(gIncomingChoice.load()) {
        if(state==1)gIncomingConnected.store(true);
        else if(state==2)gIncomingConnected.store(false);
    }
    if(gMode.load()==0 || gMode.load()==4)return;
    if(state==1) {
        NSLog(@"[LeadVirtualMedia] remote connected; starting virtual camera");
        gConnected.store(true);
        [self maybeStart];
    } else if(state==2) {
        NSLog(@"[LeadVirtualMedia] call connection failed");
        dispatch_async(dispatch_get_main_queue(),^{[self resetAll];});
    }
}
- (void)maybeStart {
    if(gIncomingChoice.load() && gIncomingConnected.load())
        gConnected.store(true);
    if(gGroupGalleryPending.load())return;
    if(!gConnected.load() || gMode.load()!=1)return;
    id captured=nil;
    @synchronized(self){captured=self.externalCapturer;}
    if(!captured)return;
    int old=1;if(!gMode.compare_exchange_strong(old,2))return;
    gStartClock.store(CACurrentMediaTime());
    gAudioPositionQ32.store(0);
    gExternalAudio.store(false);
    self.nextAudioSample=0;
    dispatch_queue_t queue=dispatch_queue_create("lead.virtual.call.frames",DISPATCH_QUEUE_SERIAL);
    self.playbackTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
    LeadVirtualClip *clip=nil;
    @synchronized(self){clip=self.clip;}
    // Tick at 60 Hz whatever the clip's rate: a frame goes out the moment it is due
    // (see playbackTick), so 24/25/30 fps sources keep an even cadence instead of
    // being resampled by a timer that doesn't match them (visible as judder).
    (void)clip;
    uint64_t step=(uint64_t)(NSEC_PER_SEC/60.0);
    dispatch_source_set_timer(self.playbackTimer,dispatch_time(DISPATCH_TIME_NOW,0),
        step,(uint64_t)(0.002*NSEC_PER_SEC));
    dispatch_source_set_event_handler(self.playbackTimer,^{[self playbackTick];});
    dispatch_resume(self.playbackTimer);
    dispatch_async(dispatch_get_main_queue(),^{
        if(gGroupMode.load()) [self startGroupPreview];
        else [self startLocalPreview];
        if(gFullCallMode.load()) [self startRemotePreview];
    });
}
- (void)playbackTick {
    if(gMode.load()!=2)return;
    // The native remote video layer can be created, resized, replaced or
    // swapped after connection. Follow Telegram's own live layout every
    // ~0.5 second without allocating/decompressing a new preview each tick.
    if(gFullCallMode.load() &&
       (gRemoteLayoutTicks.fetch_add(1,std::memory_order_relaxed)%30)==0)
        dispatch_async(dispatch_get_main_queue(),^{
            if(gMode.load()==2)[self startRemotePreview];
        });
    if(gGroupMode.load() &&
       (gGroupPreviewLayoutTicks.fetch_add(1,std::memory_order_relaxed)%30)==0)
        dispatch_async(dispatch_get_main_queue(),^{
            if(gMode.load()==2 && gGroupMode.load())[self updateGroupPreview];
        });
    LeadVirtualClip *video=nil;id capturer=nil;
    @synchronized(self) {video=self.clip;capturer=self.externalCapturer;}
    if(!video || !capturer)return;
    double elapsed=CACurrentMediaTime()-gStartClock.load();
    const double other=gFullCallMode.load(std::memory_order_acquire)?
        gFullRemoteDuration.load(std::memory_order_acquire):0;
    // End the actual call at whichever of the two chosen movie lengths
    // is shorter; this is independent of view minimization.
    if(elapsed>=video.duration || (other>0 && elapsed>=other)) {
        gMode.store(3);
        [self stopTimer];
        dispatch_async(dispatch_get_main_queue(),^{
            [self removeLocalPreview];
            [self removeGroupPreview];
            [self removeRemotePreview];
        });
        NSLog(@"[LeadVirtualMedia] EOF: video=%llu, microphone-replaced=%llu, external bytes=%llu",
             (unsigned long long)gFramesSubmitted.load(),
             (unsigned long long)gMicInjectedFrames.load(),
             (unsigned long long)gExternalAudioBytes.load());
        if(gGroupMode.load()) {
            // Group call: close the camera, do not hang up.
            dispatch_async(dispatch_get_main_queue(),^{[self groupVideoFinished];});
            return;
        }
        dispatch_async(dispatch_get_main_queue(),^{[self endTelegramCallWhenFinished];});
        return;
    }
    // Private call HQ audio: ONE transport path only. Previous builds sent
    // both native external audio and microphone-injected PCM, potentially
    // causing doubling/comb filtering. Use the proven microphone PCM bridge
    // exclusively; its sample cursor is continuous and independent of video.
    @synchronized(video) {
        for(int i=0;i<8;i++) {
            if(!video.next && !video.exhausted) {
                video.next=[video.frames copyNextSampleBuffer];
                if(!video.next)video.exhausted=YES;
            }
            if(!video.next)break;
            double t=CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(video.next));
            if(isfinite(t) && t>elapsed+0.010)break;
            if(video.current)CFRelease(video.current);
            video.current=video.next;video.next=NULL;
        }
        if(!video.current)return;
        double pts=CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(video.current));
        if(isfinite(pts) && pts<=video.lastSubmittedPTS)return;
        // 60 fps sources: send every second frame (an even 30 fps).
        if(isfinite(pts) && video.lastSubmittedPTS>=0 && pts-video.lastSubmittedPTS<(1.0/30.0)-0.004)return;
        if(!CMSampleBufferGetImageBuffer(video.current))return;
        if(isfinite(pts))video.lastSubmittedPTS=pts;
        gFramesSubmitted.fetch_add(1);
        // Mark the source active when we submit the FIRST actual decoded frame,
        // not from submitSampleBuffer's completion. On some Telegram builds
        // that completion only executes after the paused track is consumed.
        // Waiting for it causes a paused-video/first-frame deadlock.
        LeadGroupFrameDelivered(capturer);
        ((void (*)(id,SEL,CMSampleBufferRef,int,void(^)(void)))objc_msgSend)(
            capturer,@selector(submitSampleBuffer:rotation:completion:),video.current,0,^{LeadGroupFrameDelivered(capturer);});
    }
}

- (void)rememberCallView:(UIView *)view {
    if([NSStringFromClass(view.class) containsString:@"VideoChatScreenComponent"]) {
        gGroupCallView=view;
        if(gMode.load()==2 && gGroupMode.load()) [self startGroupPreview];
    }
    if(view && [NSStringFromClass(view.class) containsString:@"PrivateCallScreen"]) {
        self.privateCallView=view;
        if(gMode.load()==2) {
            [self startLocalPreview];
            if(gFullCallMode.load()) [self startRemotePreview];
        }
    }
}
- (void)forgetCallView:(UIView *)view {
    if(view==gGroupCallView) {
        gGroupCallView=nil;
        [self.groupPreviewView removeFromSuperview];
    }
    if(self.privateCallView==view) {
        self.privateCallView=nil;
        [self.localPreviewView removeFromSuperview];
        [self.remoteVideoView removeFromSuperview];
        self.nativeVideoContainerView=nil;
        // The recording upload never uses the microphone. If the call ended
        // but Telegram left a voice-chat audio session open, release it only
        // after CallKit confirms there is no active phone/VoIP call.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2*NSEC_PER_SEC)),
            dispatch_get_main_queue(),^{[self releaseStaleCallAudioIfFinished];});
    }
}
- (void)releaseStaleCallAudioIfFinished {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{[self releaseStaleCallAudioIfFinished];});
        return;
    }
    if([CXCallObserver new].calls.count>0 || [LeadCallRecording shared].isRecording) return;
    if(gMode.load()!=3 && gMode.load()!=0)return;
    AVAudioSession *session=AVAudioSession.sharedInstance;
    if(![session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord] &&
       ![session.category isEqualToString:AVAudioSessionCategoryRecord])return;
    NSError *err=nil;
    [session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                 error:&err];
    if(err)NSLog(@"[LeadVirtualMedia] idle microphone session release failed: %@",err);
}
- (UIView *)findButtonsGroup:(UIView *)root {
    if(!root)return nil;
    if([NSStringFromClass(root.class) containsString:@"ButtonGroupView"])
        return root;
    for(UIView *sub in root.subviews) {
        UIView *group=[self findButtonsGroup:sub];
        if(group)return group;
    }
    return nil;
}
- (UIControl *)endButtonInView:(UIView *)view {
    UIView *group=[self findButtonsGroup:view];
    if(!group || group.hidden || group.alpha<0.1)return nil;
    // In Telegram's PrivateCallScreen the final ContentOverlayButton
    // is the red End Call button (same action as a user tapping it).
    UIControl *end=nil;
    CGFloat right=-CGFLOAT_MAX;
    NSUInteger count=0;
    for(UIView *button in group.subviews) {
        if(![NSStringFromClass(button.class) containsString:@"ContentOverlayButton"])continue;
        if(button.hidden || button.alpha<0.1 || !button.userInteractionEnabled)continue;
        if(![button isKindOfClass:[UIControl class]])continue;
        count++;
        CGRect frame=[button convertRect:button.bounds toView:group];
        if(CGRectGetMidX(frame)>right){right=CGRectGetMidX(frame);end=(UIControl *)button;}
    }
    return count>=3 ? end : nil;
}
- (void)endTelegramCallWhenFinished {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{[self endTelegramCallWhenFinished];});
        return;
    }
    UIView *screen=self.privateCallView;
    UIControl *button=[self endButtonInView:screen];
    if(!button) {
        // Resolve the live Telegram screen if its UIView has been recreated.
        for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if(![scene isKindOfClass:[UIWindowScene class]])continue;
            for(UIWindow *w in ((UIWindowScene *)scene).windows) {
                NSMutableArray<UIView *> *stack=[NSMutableArray arrayWithObject:w];
                while(stack.count && !button) {
                    UIView *candidate=stack.lastObject;[stack removeLastObject];
                    if([NSStringFromClass(candidate.class) containsString:@"PrivateCallScreen"] &&
                       candidate.window && !candidate.hidden) {
                        button=[self endButtonInView:candidate];
                        if(button)break;
                    }
                    [stack addObjectsFromArray:candidate.subviews];
                }
                if(button)break;
            }
            if(button)break;
        }
    }
    if(button) {
        NSLog(@"[LeadVirtualMedia] EOF; performing Telegram end-call control");
        [button sendActionsForControlEvents:UIControlEventTouchUpInside];
        // Keep gMode=3 until the next call choice resets us; never expose
        // the real microphone if Telegram takes longer to disconnect.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3*NSEC_PER_SEC)),
            dispatch_get_main_queue(),^{[self releaseStaleCallAudioIfFinished];});
    } else {
        // CallKit fallback when Telegram's view is minimized. Only use a
        // unique, outgoing, connected call; never terminate unrelated calls
        // when there is any ambiguity.
        CXCallObserver *observer=[CXCallObserver new];
        NSArray<CXCall *> *calls=observer.calls;
        if(calls.count==1) {
            CXCall *call=calls.firstObject;
            if(call.hasConnected && !call.hasEnded) {
                CXCallController *controller=[CXCallController new];
                CXEndCallAction *action=[[CXEndCallAction alloc] initWithCallUUID:call.UUID];
                CXTransaction *transaction=[[CXTransaction alloc] initWithAction:action];
                NSLog(@"[LeadVirtualMedia] EOF; requesting CallKit end-call transaction");
                [controller requestTransaction:transaction completion:^(NSError *error){
                    if(error) {
                        NSLog(@"[LeadVirtualMedia] CallKit hangup failed: %@",error);
                        // The previous build displayed a modal here; now log only.
                        // Never interrupt the user's next screen with an EOF popup.
                    } else {
                        NSLog(@"[LeadVirtualMedia] CallKit end-call request accepted");
                        // Preserve microphone suppression until new call setup.
                    }
                }];
                return;
            }
        }
        NSLog(@"[LeadVirtualMedia] EOF; hangup UI and unique CallKit call not found");
        // No intrusive EOF alert. Do not terminate an unrelated CallKit call.
    }
}


- (void)incomingVideoAnsweredForUUID:(NSUUID *)uuid {
    self.incomingAnsweredUUID=uuid;
    // IMPORTANT: Run *after* CallKit's original answer handler. Do not touch
    // audio, disable camera, or reset the WebRTC context during the handshake.
    // The user can continue the already connected call normally.
    if(gMode.load()==3)[self resetAll];
    gIncomingChoice.store(true);
    gIncomingPrivacyGate.store(true);
    [self protectIncomingCamera];
    gIncomingConnected.store(gObservedCallState.load()==1);
    self.incomingAwaitingMenu=YES;
    self.incomingMenuPresented=NO;
    self.incomingAttachAttempts=0;
    (void)[self installNativeHooks];
    NSLog(@"[LeadVirtualMedia] incoming video answered; normal call remains active");
}
- (void)normalIncomingAnswer {
    // A user explicitly choosing "رد طبيعي" is the only action that
    // re-enables the physical camera while an incoming call is active.
    BOOL resume=gIncomingPrivacyGate.load() && [self hasLiveIncomingVideoCall];
    id camera=self.protectedPhysicalCamera ?: self.lastPhysicalCamera;
    gIncomingPrivacyGate.store(false);
    if(resume && camera && [camera respondsToSelector:@selector(setIsVideoEnabled:)])
        ((void (*)(id,SEL,bool))objc_msgSend)(
            camera,@selector(setIsVideoEnabled:),true);
    self.protectedPhysicalCamera=nil;
    [self resetAll];
    gIncomingChoice.store(false);
    gIncomingConnected.store(false);
    self.incomingMenuPresented=NO;
    self.incomingAwaitingMenu=NO;
    self.incomingAttachAttempts=0;
    self.incomingNativeContext=nil;
    self.incomingAnsweredUUID=nil;
}
- (BOOL)hasLiveIncomingVideoCall {
    NSUUID *expected=self.incomingAnsweredUUID;
    if(!expected)return NO;
    for(CXCall *call in [CXCallObserver new].calls) {
        if([call.UUID isEqual:expected] && !call.outgoing && !call.hasEnded)return YES;
    }
    return NO;
}
- (void)installIncomingObservers {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(incomingDidBecomeActive:)
            name:UIApplicationDidBecomeActiveNotification object:nil];
    });
}
- (void)incomingDidBecomeActive:(__unused NSNotification *)note {
    if(self.incomingAwaitingMenu)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.45*NSEC_PER_SEC)),
            dispatch_get_main_queue(),^{[self showIncomingSourceMenu];});
}
- (void)showIncomingSourceMenu {
    if(!gIncomingChoice.load() || !self.incomingAwaitingMenu || self.incomingMenuPresented)return;
    if(!NSThread.isMainThread){
        dispatch_async(dispatch_get_main_queue(),^{[self showIncomingSourceMenu];});
        return;
    }
    // iOS may show its CallKit answer UI while Telegram is backgrounded.
    // Defer the optional menu; never reject or interrupt the accepted call.
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    if(![self hasLiveIncomingVideoCall]) {
        [self normalIncomingAnswer];
        return;
    }
    UIViewController *host=[self host];
    if(!host)return;
    self.incomingMenuPresented=YES;
    self.incomingAwaitingMenu=NO;
    UIAlertController *choices=[UIAlertController
        alertControllerWithTitle:@"الرد على مكالمة الفيديو"
        message:@"المكالمة تم قبولها. اختر كامرتك الطبيعية أو فيديو من المعرض"
        preferredStyle:UIAlertControllerStyleAlert];
    [choices addAction:[UIAlertAction actionWithTitle:@"رد طبيعي"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){
            [self normalIncomingAnswer];
        }]];
    [choices addAction:[UIAlertAction actionWithTitle:@"اختيار فيديو من المعرض"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){
            // Let the alert close before presenting PHPicker.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(0.30*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                [self preparePicker:^(__unused BOOL ready) {}];
            });
        }]];
    [host presentViewController:choices animated:YES completion:nil];
}
- (void)attachIncomingGalleryVideo {
    if(!gIncomingChoice.load() || gMode.load()!=1)return;
    id native=self.incomingNativeContext;
    if(!native || gObservedCallState.load()!=1) {
        if(self.incomingAttachAttempts++<12) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.5*NSEC_PER_SEC)),
                dispatch_get_main_queue(),^{[self attachIncomingGalleryVideo];});
            return;
        }
        NSLog(@"[LeadVirtualMedia] incoming call never connected; no gallery injection");
        [self finishPicker:NO];
        return;
    }
    Class cls=objc_getClass("OngoingCallThreadLocalContextVideoCapturer");
    SEL factory=NSSelectorFromString(@"capturerWithExternalSampleBufferProvider");
    if(!native || !cls || ![cls respondsToSelector:factory] ||
       ![native respondsToSelector:@selector(requestVideo:)]) {
        NSLog(@"[LeadVirtualMedia] incoming WebRTC context unavailable; source not changed");
        [self resetAll];
        gIncomingChoice.store(false);
        [self showError:@"تعذر ربط فيديو المعرض بالمكالمة الواردة. الاتصال يستمر طبيعياً."];
        [self finishPicker:NO];
        return;
    }
    id custom=((id (*)(id,SEL))objc_msgSend)(cls,factory);
    if(!custom) {
        [self finishPicker:NO];
        return;
    }
    // RequestVideo: does nothing while a previous camera capturer exists.
    // Remove only the *outgoing* camera track, preserving incoming video.
    if([native respondsToSelector:@selector(disableVideo)])
        ((void (*)(id,SEL))objc_msgSend)(native,@selector(disableVideo));
    @synchronized(self) {
        self.externalCapturer=custom;
        self.nativeCallContext=native;
    }
    ((void (*)(id,SEL,id))objc_msgSend)(native,@selector(requestVideo:),custom);
    gExpectCapturer.store(false);
    gConnected.store(true);
    // The original remote incoming video track is untouched.
    [self maybeStart];
    [self finishPicker:YES];
}


// The privacy gate can be armed before CallKit accepts. Keep an early weak
// reference to Telegram's physical camera, even if it was constructed during
// the incoming ringtone. Disable production of frames before any track sends.
- (void)capturePhysicalCamera:(id)camera {
    if(!camera)return;
    @synchronized(self) {
        self.lastPhysicalCamera=camera;
        if(gIncomingPrivacyGate.load())self.protectedPhysicalCamera=camera;
    }
    if(gIncomingPrivacyGate.load() &&
       [camera respondsToSelector:@selector(setIsVideoEnabled:)]) {
        ((void (*)(id,SEL,bool))objc_msgSend)(
            camera,@selector(setIsVideoEnabled:),false);
        NSLog(@"[LeadVirtualMedia] physical camera held until source choice");
    }
}
- (void)protectIncomingCamera {
    if(!gIncomingPrivacyGate.load())return;
    id camera=self.protectedPhysicalCamera ?: self.lastPhysicalCamera;
    if(!camera)return;
    self.protectedPhysicalCamera=camera;
    if([camera respondsToSelector:@selector(setIsVideoEnabled:)])
        ((void (*)(id,SEL,bool))objc_msgSend)(
            camera,@selector(setIsVideoEnabled:),false);
}
// Show exactly the selected outgoing movie on the broadcaster's own screen.
// This is a muted, hardware-decoded LOCAL mirror only; the frames transmitted to
// the room continue to come from playbackTick -> submitSampleBuffer.
- (void)removeGroupPreview {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{[self removeGroupPreview];});
        return;
    }
    [self.groupPreviewPlayer pause];
    [self.groupPreviewView removeFromSuperview];
    self.groupPreviewLayer=nil;
    self.groupPreviewPlayer=nil;
    self.groupPreviewView=nil;
}
- (void)startGroupPreview {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{[self startGroupPreview];});
        return;
    }
    if(!gGroupMode.load() || gMode.load()!=2 || !self.selectedURL)return;
    if(!self.groupPreviewView) {
        AVPlayerItem *item=[AVPlayerItem playerItemWithURL:self.selectedURL];
        self.groupPreviewPlayer=[AVPlayer playerWithPlayerItem:item];
        self.groupPreviewPlayer.muted=YES;
        self.groupPreviewPlayer.volume=0.0f;
        self.groupPreviewPlayer.actionAtItemEnd=AVPlayerActionAtItemEndPause;
        self.groupPreviewLayer=[AVPlayerLayer playerLayerWithPlayer:self.groupPreviewPlayer];
        // AspectFit: a portrait movie remains completely visible even in a
        // wide group video tile, with letterboxing instead of cropping.
        self.groupPreviewLayer.videoGravity=AVLayerVideoGravityResizeAspect;
        UIView *preview=[[UIView alloc] initWithFrame:CGRectZero];
        preview.backgroundColor=UIColor.blackColor;
        preview.layer.cornerRadius=12;
        preview.layer.masksToBounds=YES;
        preview.userInteractionEnabled=NO;
        preview.layer.zPosition=80000;
        [preview.layer addSublayer:self.groupPreviewLayer];
        UILabel *caption=[[UILabel alloc] initWithFrame:CGRectZero];
        caption.text=@"معاينة بثك";
        caption.textColor=UIColor.whiteColor;
        caption.font=[UIFont boldSystemFontOfSize:12];
        caption.backgroundColor=[UIColor colorWithWhite:0 alpha:0.5];
        caption.layer.cornerRadius=5;
        caption.layer.masksToBounds=YES;
        caption.textAlignment=NSTextAlignmentCenter;
        caption.tag=90879;
        [preview addSubview:caption];
        self.groupPreviewView=preview;
        const double start=gStartClock.load();
        double elapsed=start>0?MAX(0.0,CACurrentMediaTime()-start):0.0;
        [self.groupPreviewPlayer seekToTime:CMTimeMakeWithSeconds(elapsed,600)
           toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero
           completionHandler:^(BOOL finished) {
            if(finished && gMode.load()==2 && gGroupMode.load())
                dispatch_async(dispatch_get_main_queue(),^{[self.groupPreviewPlayer play];});
        }];
    }
    [self updateGroupPreview];
}
- (void)updateGroupPreview {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{[self updateGroupPreview];});
        return;
    }
    if(!gGroupMode.load() || gMode.load()!=2)return;
    if(!self.groupPreviewView) {
        [self startGroupPreview];
        return;
    }
    UIView *root=gGroupCallView;
    if(!root || !root.window)return;
    // Prefer Telegram's large outgoing participant-video tile, not a global
    // window overlay that could hide call controls or another participant.
    UIView *best=nil;
    CGFloat bestArea=0;
    NSMutableArray<UIView *> *stack=[NSMutableArray arrayWithObject:root];
    while(stack.count) {
        UIView *v=stack.lastObject;
        [stack removeLastObject];
        if(v.hidden || v.alpha<0.05)continue;
        NSString *name=NSStringFromClass(v.class);
        if([name containsString:@"VideoChatParticipantVideoComponent"] &&
           v.bounds.size.width>root.bounds.size.width*0.55 &&
           v.bounds.size.height>100) {
            CGRect rect=[v convertRect:v.bounds toView:root];
            if(CGRectGetMaxY(rect)<root.bounds.size.height*0.80 &&
               CGRectGetMinY(rect)>=0 && CGRectGetWidth(rect)>0 &&
               CGRectGetHeight(rect)>0) {
                CGFloat area=rect.size.width*rect.size.height;
                if(area>bestArea){bestArea=area;best=v;}
            }
        }
        [stack addObjectsFromArray:v.subviews];
    }
    CGRect frame=CGRectZero;
    if(best) {
        CGRect rect=[best convertRect:best.bounds toView:root];
        frame=CGRectInset(rect,0,0);
    } else {
        // The group's tile can be lazily instantiated while the video
        // participant joins. Keep a small unambiguous preview in that case.
        CGFloat width=MIN(132,root.bounds.size.width*0.34);
        CGFloat height=width*1.5;
        frame=CGRectMake(MAX(8,root.bounds.size.width-width-16),
                         MAX(95,root.safeAreaInsets.top+55),width,height);
    }
    if(frame.size.width<=0 || frame.size.height<=0)return;
    self.groupPreviewView.frame=frame;
    self.groupPreviewLayer.frame=self.groupPreviewView.bounds;
    UILabel *caption=(UILabel *)[self.groupPreviewView viewWithTag:90879];
    caption.frame=CGRectMake(8,MAX(4,frame.size.height-29),100,23);
    if(self.groupPreviewView.superview!=root) {
        [self.groupPreviewView removeFromSuperview];
        [root addSubview:self.groupPreviewView];
    }
}
- (void)removeLocalPreview {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{[self removeLocalPreview];});
        return;
    }
    [self.localPreviewPlayer pause];
    [self.localPreviewView removeFromSuperview];
    self.localPreviewPlayer=nil;
    self.localPreviewLayer=nil;
    self.localPreviewPixelOutput=nil;
    self.localRecordingLastFrame=nil;
    self.localRecordingCIContext=nil;
    self.localPreviewView=nil;
    self.localPreviewScale=1.0;
    self.localPreviewNormalizedCenter=CGPointZero;
    self.localPreviewHasSavedCenter=NO;
}
- (void)dragLocalPreview:(UIPanGestureRecognizer *)gesture {
    UIView *preview=self.localPreviewView;
    UIView *host=self.privateCallView;
    if(!preview || !host || ![preview isDescendantOfView:host])return;
    if(gesture.state==UIGestureRecognizerStateBegan ||
       gesture.state==UIGestureRecognizerStateChanged) {
        CGPoint movement=[gesture translationInView:host];
        CGPoint newCenter=CGPointMake(preview.center.x+movement.x,
                                       preview.center.y+movement.y);
        const CGFloat margin=6.0;
        const CGFloat minY=MAX(60.0,host.safeAreaInsets.top+6.0);
        const CGFloat maxY=host.bounds.size.height-MAX(40.0,host.safeAreaInsets.bottom+10.0);
        newCenter.x=MAX(margin+preview.bounds.size.width*0.5,
                        MIN(host.bounds.size.width-margin-preview.bounds.size.width*0.5,newCenter.x));
        newCenter.y=MAX(minY+preview.bounds.size.height*0.5,
                        MIN(maxY-preview.bounds.size.height*0.5,newCenter.y));
        preview.center=newCenter;
        [gesture setTranslation:CGPointZero inView:host];
        self.localPreviewHasSavedCenter=YES;
        self.localPreviewNormalizedCenter=CGPointMake(
            newCenter.x/MAX(1.0,host.bounds.size.width),
            newCenter.y/MAX(1.0,host.bounds.size.height));
    }
}
- (void)pinchLocalPreview:(UIPinchGestureRecognizer *)gesture {
    if(gesture.state!=UIGestureRecognizerStateBegan &&
       gesture.state!=UIGestureRecognizerStateChanged)return;
    if(!self.localPreviewView || !self.privateCallView)return;
    const CGFloat multiplier=gesture.scale;
    if(!isfinite((double)multiplier) || multiplier<=0)return;
    // A simple on-screen thumbnail zoom, not a change to the sent video.
    self.localPreviewScale=MAX(0.52,MIN(2.6,
        (self.localPreviewScale>0?self.localPreviewScale:1.0)*multiplier));
    gesture.scale=1.0;
    UIView *host=self.privateCallView;
    if(!self.localPreviewHasSavedCenter) {
        self.localPreviewNormalizedCenter=CGPointMake(
            self.localPreviewView.center.x/MAX(1.0,host.bounds.size.width),
            self.localPreviewView.center.y/MAX(1.0,host.bounds.size.height));
        self.localPreviewHasSavedCenter=YES;
    }
    [self layoutLocalPreviewInHost:host];
}
- (void)layoutLocalPreviewInHost:(UIView *)host {
    if(!host || !self.localPreviewView)return;
    const CGFloat baseWidth=MIN(126.0,host.bounds.size.width*0.30);
    const CGFloat ratio=1.48;
    const CGFloat maxHeight=MAX(70.0,host.bounds.size.height
        -MAX(60.0,host.safeAreaInsets.top+6.0)
        -MAX(40.0,host.safeAreaInsets.bottom+10.0)-12.0);
    const CGFloat maxWidth=MIN(host.bounds.size.width-12.0,maxHeight/ratio);
    const CGFloat effectiveScale=self.localPreviewScale>0?self.localPreviewScale:1.0;
    const CGFloat width=MIN(MAX(64.0,baseWidth*effectiveScale),maxWidth);
    const CGFloat height=width*ratio;
    CGPoint center;
    if(self.localPreviewHasSavedCenter) {
        center=CGPointMake(self.localPreviewNormalizedCenter.x*host.bounds.size.width,
                           self.localPreviewNormalizedCenter.y*host.bounds.size.height);
    } else {
        center=CGPointMake(host.bounds.size.width-width*0.5-15.0,
            MAX(74.0,host.bounds.size.height-height-190.0)+height*0.5);
    }
    const CGFloat minY=MAX(60.0,host.safeAreaInsets.top+6.0);
    const CGFloat maxY=host.bounds.size.height
        -MAX(40.0,host.safeAreaInsets.bottom+10.0);
    center.x=MAX(6.0+width*0.5,MIN(host.bounds.size.width-6.0-width*0.5,center.x));
    center.y=MAX(minY+height*0.5,MIN(maxY-height*0.5,center.y));
    self.localPreviewView.bounds=CGRectMake(0,0,width,height);
    self.localPreviewView.center=center;
    self.localPreviewLayer.frame=self.localPreviewView.bounds;
    self.localPreviewNormalizedCenter=CGPointMake(
        center.x/MAX(1.0,host.bounds.size.width),
        center.y/MAX(1.0,host.bounds.size.height));
}
- (void)startLocalPreview {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{[self startLocalPreview];});
        return;
    }
    if(gMode.load()!=2 || !self.selectedURL)return;
    UIView *host=self.privateCallView;
    if(!host || !host.window)return;
    if(host.bounds.size.width<130 || host.bounds.size.height<300) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.15*NSEC_PER_SEC)),
            dispatch_get_main_queue(),^{if(gMode.load()==2)[self startLocalPreview];});
        return;
    }
    if(!self.localPreviewPlayer) {
        // The AVPlayerLayer is hardware-composited and is not reliably
        // included in UIKit drawViewHierarchyInRect or CALayer snapshots.
        // Feed the recorder a second pixel-buffer tap from this same player.
        AVPlayerItem *item=[AVPlayerItem playerItemWithURL:self.selectedURL];
        NSDictionary *pixelAttributes=@{
            (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferIOSurfacePropertiesKey:@{}
        };
        self.localPreviewPixelOutput=[[AVPlayerItemVideoOutput alloc]
            initWithPixelBufferAttributes:pixelAttributes];
        [item addOutput:self.localPreviewPixelOutput];
        self.localPreviewPlayer=[AVPlayer playerWithPlayerItem:item];
        // LOCAL playback ONLY: first preview is low volume when two movies
        // are selected. Telegram sends the original decoded PCM independently
        // through the virtual microphone at the FULL outgoing level.
        // In one-movie mode keep local playback muted to prevent doubled sound.
        self.localPreviewPlayer.volume=gFullCallMode.load(std::memory_order_relaxed)
            ? 0.12f : 0.0f;
        self.localPreviewPlayer.muted=!gFullCallMode.load(std::memory_order_relaxed);
        self.localPreviewPlayer.actionAtItemEnd=AVPlayerActionAtItemEndPause;
        AVPlayerLayer *layer=[AVPlayerLayer playerLayerWithPlayer:self.localPreviewPlayer];
        layer.videoGravity=AVLayerVideoGravityResizeAspectFill;
        self.localPreviewLayer=layer;
        UIView *preview=[[UIView alloc] initWithFrame:CGRectZero];
        preview.userInteractionEnabled=YES;
        preview.multipleTouchEnabled=YES;
        UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(dragLocalPreview:)];
        pan.minimumNumberOfTouches=1;
        pan.maximumNumberOfTouches=1;
        [preview addGestureRecognizer:pan];
        UIPinchGestureRecognizer *pinch=[[UIPinchGestureRecognizer alloc]
            initWithTarget:self action:@selector(pinchLocalPreview:)];
        [preview addGestureRecognizer:pinch];
        self.localPreviewScale=1.0;
        self.localPreviewHasSavedCenter=NO;
        preview.layer.cornerRadius=12;
        preview.layer.masksToBounds=YES;
        preview.layer.borderWidth=1.5;
        preview.layer.borderColor=UIColor.whiteColor.CGColor;
        preview.layer.zPosition=90000;
        [preview.layer addSublayer:layer];
        self.localPreviewView=preview;
        // Playback and uplink volumes are independent: this little preview
        // is quiet locally, but its WebRTC track is sent at full loudness.
        double elapsed=std::max(0.0,CACurrentMediaTime()-gStartClock.load());
        CMTime time=CMTimeMakeWithSeconds(elapsed,600);
        [self.localPreviewPlayer seekToTime:time toleranceBefore:kCMTimeZero
            toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished){
            if(finished && gMode.load()==2)
                dispatch_async(dispatch_get_main_queue(),^{[self.localPreviewPlayer play];});
        }];
    }
    [self layoutLocalPreviewInHost:host];
    // The thumbnail handles its own position/size after gestures.
    self.localPreviewView.autoresizingMask=UIViewAutoresizingNone;
    if(self.localPreviewView.superview!=host) {
        [self.localPreviewView removeFromSuperview];
        [host addSubview:self.localPreviewView];
    }
}


// Full-call mode has a second local video, rendered where the remote camera
// normally appears. It never replaces/transmits the peer's actual incoming
// video; the outward Telegram stream remains the first selected movie.
- (void)removeRemotePreview {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{[self removeRemotePreview];});
        return;
    }
    [self.remotePlayer pause];
    [self.remoteVideoView removeFromSuperview];
    self.nativeVideoContainerView=nil;
    self.remotePlayer=nil;
    self.remoteLayer=nil;
    self.remoteVideoView=nil;
    self.remotePixelOutput=nil;
    self.remoteRecordingFrame=nil;
    self.remoteRecordingContext=nil;
}
// Match the Telegram call screen's own *UIView* video layout, not a manually
// computed "header/footer" rectangle. On forks whose native video container
// isn't present yet (for example a remote avatar or disabled camera), retain a
// fallback attached to PrivateCallScreen itself. Never omit the selected movie.
- (UIView *)nativeMainVideoContainerInCallScreen:(UIView *)screen {
    UIView *chosen=nil;
    CGFloat largest=0;
    for(UIView *view in screen.subviews) {
        if(view.hidden || view.alpha<0.01)continue;
        NSString *name=NSStringFromClass(view.class);
        if([name rangeOfString:@"VideoContainerView"].location==NSNotFound)continue;
        CGRect bounds=view.bounds;
        CGFloat area=bounds.size.width*bounds.size.height;
        if(area>largest && bounds.size.width>100 && bounds.size.height>100) {
            chosen=view;largest=area;
        }
    }
    return chosen;
}
- (void)startRemotePreview {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{[self startRemotePreview];});
        return;
    }
    if(gMode.load()!=2 || !gFullCallMode.load() || !self.remoteSelectedURL)return;
    UIView *host=self.privateCallView;
    if(!host || !host.window || CGRectIsEmpty(host.bounds))return;
    // A private call with video off has no VideoContainerView at all. That is
    // precisely when the previous build displayed only the contact avatar.
    UIView *native=[self nativeMainVideoContainerInCallScreen:host];
    UIView *target=native?:host;
    if(!self.remotePlayer) {
        AVPlayerItem *item=[AVPlayerItem playerItemWithURL:self.remoteSelectedURL];
        NSDictionary *attrs=@{
            (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferIOSurfacePropertiesKey:@{}
        };
        self.remotePixelOutput=[[AVPlayerItemVideoOutput alloc]
            initWithPixelBufferAttributes:attrs];
        [item addOutput:self.remotePixelOutput];
        self.remotePlayer=[AVPlayer playerWithPlayerItem:item];
        // The SECOND movie is the user's locally simulated remote speaker.
        // Keep it at the maximum AVPlayer volume; real peer audio remains
        // muted through the separate Telegram CoreAudio downlink hook.
        self.remotePlayer.volume=1.0f;
        self.remotePlayer.muted=NO;
        self.remotePlayer.actionAtItemEnd=AVPlayerActionAtItemEndPause;
        AVPlayerLayer *layer=[AVPlayerLayer playerLayerWithPlayer:self.remotePlayer];
        layer.videoGravity=AVLayerVideoGravityResizeAspectFill;
        self.remoteLayer=layer;
        UIView *overlay=[[UIView alloc] initWithFrame:target.bounds];
        overlay.userInteractionEnabled=NO;
        overlay.backgroundColor=UIColor.blackColor;
        overlay.clipsToBounds=YES;
        overlay.autoresizingMask=UIViewAutoresizingFlexibleWidth|
                                  UIViewAutoresizingFlexibleHeight;
        [overlay.layer addSublayer:layer];
        self.remoteVideoView=overlay;
        double elapsed=MAX(0.0,CACurrentMediaTime()-gStartClock.load());
        [self.remotePlayer seekToTime:CMTimeMakeWithSeconds(elapsed,600)
             toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero
             completionHandler:^(BOOL ok) {
            if(ok && gMode.load()==2 && gFullCallMode.load())
                dispatch_async(dispatch_get_main_queue(),^{
                    if(gMode.load()==2 && self.remotePlayer)[self.remotePlayer play];
                });
        }];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if(self.remoteVideoView.superview!=target) {
        [self.remoteVideoView removeFromSuperview];
        if(target==host) {
            // Telegram's PrivateCallScreen subviews normally start with
            // background, overlayContents, then controls/title/status.
            // Insert the picture between background and native UI so the
            // controls stay natural and tappable across different forks.
            [host insertSubview:self.remoteVideoView
                        atIndex:MIN((NSUInteger)1,host.subviews.count)];
            self.nativeVideoContainerView=nil;
            NSLog(@"[LeadVirtualMedia] using full-screen remote movie fallback");
        } else {
            // A native VideoContainerView already clips/rotates the picture.
            // Its own movie layer is behind UIKit subviews, so this AVPlayer
            // behaves like the native feed, without a fake visible border.
            [target addSubview:self.remoteVideoView];
            self.nativeVideoContainerView=target;
            NSLog(@"[LeadVirtualMedia] attached remote movie to native video view");
        }
    }
    self.remoteVideoView.frame=target.bounds;
    self.remoteLayer.frame=self.remoteVideoView.bounds;
    [CATransaction commit];
}
- (void)drawRemotePreviewIntoRecording:(UIView *)root {
    // AVPlayerLayer is hardware-backed: UIKit screenshot alone captures a
    // blank video view. Draw the actual decoded pixels in the recording.
    if(!NSThread.isMainThread || gMode.load()!=2 || !gFullCallMode.load() ||
       !UIGraphicsGetCurrentContext() || !root)return;
    UIView *visible=self.remoteVideoView;
    AVPlayerItemVideoOutput *output=self.remotePixelOutput;
    if(!visible || !visible.window || !output || !self.remotePlayer ||
       !root.window || ![visible isDescendantOfView:root])return;
    // Use exactly the visible player view's transformed on-screen bounds;
    // no fabricated header/footer crop in either preview or exported MP4.
    CGRect rect=[visible convertRect:visible.bounds toView:root];
    rect=CGRectIntersection(rect,root.bounds);
    if(CGRectIsNull(rect) || rect.size.width<8 || rect.size.height<8)return;
    CVPixelBufferRef buffer=[output copyPixelBufferForItemTime:self.remotePlayer.currentTime
                                      itemTimeForDisplay:NULL];
    if(buffer) {
        if(!self.remoteRecordingContext)
            self.remoteRecordingContext=[CIContext contextWithOptions:
                @{kCIContextUseSoftwareRenderer:@NO}];
        CIImage *image=[CIImage imageWithCVPixelBuffer:buffer];
        CGFloat size=MAX(image.extent.size.width,image.extent.size.height);
        CGFloat factor=MIN(1.0,1920.0/MAX(1.0,size));
        if(factor<1.0)image=[image imageByApplyingTransform:
            CGAffineTransformMakeScale(factor,factor)];
        CGImageRef picture=[self.remoteRecordingContext
            createCGImage:image fromRect:image.extent];
        if(picture) {
            self.remoteRecordingFrame=[UIImage imageWithCGImage:picture];
            CGImageRelease(picture);
        }
        CVPixelBufferRelease(buffer);
    }
    UIImage *frame=self.remoteRecordingFrame;
    if(!frame)return;
    CGSize native=frame.size;
    CGFloat scale=MAX(rect.size.width/MAX(native.width,1),
                      rect.size.height/MAX(native.height,1));
    CGRect full=CGRectMake(CGRectGetMidX(rect)-native.width*scale/2.0,
                           CGRectGetMidY(rect)-native.height*scale/2.0,
                           native.width*scale,native.height*scale);
    CGContextRef context=UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    CGContextClipToRect(context,rect);
    [frame drawInRect:full];
    CGContextRestoreGState(context);
    // The hardware player can be missing from UIKit snapshots. Restore
    // foreground call controls over this manually composited video frame.
    UIView *call=self.privateCallView;
    if(call && call.window && (call==root || [call isDescendantOfView:root])) {
        for(UIView *child in call.subviews) {
            if(child.hidden || child.alpha<0.01)continue;
            NSString *type=NSStringFromClass(child.class);
            BOOL foreground=
                [type rangeOfString:@"ButtonGroupView"].location!=NSNotFound ||
                [type rangeOfString:@"BackButtonView"].location!=NSNotFound ||
                [type rangeOfString:@"TitleView"].location!=NSNotFound ||
                [type rangeOfString:@"StatusView"].location!=NSNotFound;
            if(!foreground)continue;
            CGRect frame=[child convertRect:child.bounds toView:root];
            CGContextSaveGState(context);
            CGContextTranslateCTM(context,frame.origin.x,frame.origin.y);
            [child.layer renderInContext:context];
            CGContextRestoreGState(context);
        }
    }
}

- (void)drawGalleryPreviewIntoRecording:(UIView *)root {
    // Called on the main-thread CADisplayLink while UIGraphics holds the
    // recorder's pixel-buffer context (already scaled to the capture root).
    // Only composite the visible, user-owned preview and never change the
    // outgoing Telegram frames or the receiver's display.
    if(!NSThread.isMainThread || gMode.load()!=2 || !root ||
       !UIGraphicsGetCurrentContext())return;
    UIView *preview=self.localPreviewView;
    AVPlayerItemVideoOutput *output=self.localPreviewPixelOutput;
    AVPlayer *player=self.localPreviewPlayer;
    if(!preview || !preview.window || !output || !player ||
       ![preview isDescendantOfView:root])return;
    CGRect rect=[preview convertRect:preview.bounds toView:root];
    rect=CGRectIntersection(rect,root.bounds);
    if(CGRectIsNull(rect) || rect.size.width<8 || rect.size.height<8)return;
    // The output returns exactly the composited AVPlayer video frame.
    CMTime time=player.currentTime;
    CVPixelBufferRef buffer=[output copyPixelBufferForItemTime:time
                                      itemTimeForDisplay:NULL];
    if(buffer) {
        if(!self.localRecordingCIContext)
            self.localRecordingCIContext=[CIContext contextWithOptions:
                @{kCIContextUseSoftwareRenderer:@NO}];
        CIImage *image=[CIImage imageWithCVPixelBuffer:buffer];
        // Bound GPU readback to the preview size. A 4K source would otherwise
        // force a full-resolution readback 30x per second.
        CGFloat maxDimension=MAX(image.extent.size.width,image.extent.size.height);
        CGFloat factor=MIN(1.0,850.0/MAX(1.0,maxDimension));
        if(factor<1.0)
            image=[image imageByApplyingTransform:
                   CGAffineTransformMakeScale(factor,factor)];
        CGImageRef picture=[self.localRecordingCIContext
                           createCGImage:image fromRect:image.extent];
        if(picture) {
            self.localRecordingLastFrame=[UIImage imageWithCGImage:picture];
            CGImageRelease(picture);
        }
        CVPixelBufferRelease(buffer);
    }
    UIImage *frame=self.localRecordingLastFrame;
    if(!frame)return;
    const CGSize size=frame.size;
    CGFloat scale=MAX(rect.size.width/MAX(1.0,size.width),
                      rect.size.height/MAX(1.0,size.height));
    CGRect imageRect=CGRectMake(CGRectGetMidX(rect)-size.width*scale/2.0,
                              CGRectGetMidY(rect)-size.height*scale/2.0,
                              size.width*scale,size.height*scale);
    CGContextRef context=UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:12] addClip];
    [frame drawInRect:imageRect];
    CGContextRestoreGState(context);
    [[UIColor colorWithWhite:1.0 alpha:0.85] setStroke];
    UIBezierPath *outline=[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:12];
    outline.lineWidth=1.0;
    [outline stroke];
}

@end

// Retain existing CoreAudio audio path only as fallback when native external
// audio cannot be obtained. Any selected file suppresses genuine microphone.
// Exposed to the early AudioUnit setup hook. HQ bypass is limited to a
// user-chosen virtual-video private call, never ordinary microphone calls.
extern "C" bool LeadVirtualMediaHighQualityEnabled(void) {
    const int mode=gMode.load(std::memory_order_relaxed);
    return mode==1 || mode==2;
}

// Silence the original peer voice while sending gallery media. Never
// touch ordinary calls, and reset automatically when virtual playback ends.
extern "C" bool LeadVirtualMediaMuteRemoteVoice(void) {
    // In a group call keep hearing the other participants.
    return gMode.load(std::memory_order_relaxed)==2 && !gGroupMode.load(std::memory_order_relaxed);
}

// Direct 48k PCM injection at CoreAudio's outgoing mic boundary.
// No volume boost, no limiter and no intermediate resampling to 8/16 kHz.
// Audio output callbacks consume consecutive samples at exactly the target
// format rate; linear interpolation only applies when rates differ.
extern "C" bool LeadVirtualMediaReplaceMic(AudioBufferList *buffers,
                 const AudioStreamBasicDescription *format, UInt32 frames) {
    const int mode=gMode.load(std::memory_order_acquire);
    if(mode==0)return false;
    if(!buffers || !format)return true;
    const bool flt=(format->mFormatFlags & kAudioFormatFlagIsFloat)!=0;
    const bool integer=(format->mFormatFlags & kAudioFormatFlagIsSignedInteger)!=0;
    const bool planar=(format->mFormatFlags & kAudioFormatFlagIsNonInterleaved)!=0;
    const unsigned bits=format->mBitsPerChannel;
    const unsigned channels=std::max(1u,format->mChannelsPerFrame);
    const double rate=format->mSampleRate;
    const bool supported=(format->mFormatID==kAudioFormatLinearPCM) &&
        ((flt && bits==32)||(integer && (bits==16||bits==32)));
    const auto pcm=std::atomic_load(&gPCM);
    const bool playing=(mode==2 && supported && rate>=8000 && rate<=192000 &&
       isfinite(rate) && pcm && !pcm->samples.empty());
    const uint64_t scale=UINT64_C(4294967296);
    const uint64_t step=playing ? std::max(UINT64_C(1),
        (uint64_t)llround((48000.0/rate)*(double)scale)) : 0;
    const uint64_t origin=playing ? gAudioPositionQ32.fetch_add(
        step*(uint64_t)frames,std::memory_order_relaxed) : 0;
    for(UInt32 b=0;b<buffers->mNumberBuffers;b++) {
        AudioBuffer &buf=buffers->mBuffers[b];
        if(!buf.mData)continue;
        if(!playing) {
            memset(buf.mData,0,buf.mDataByteSize);
            continue;
        }
        const unsigned channelsInBuffer=planar?1:channels;
        const unsigned sampleBytes=bits/8;
        const UInt32 count=std::min(frames,buf.mDataByteSize/
                  std::max(1u,channelsInBuffer*sampleBytes));
        for(UInt32 i=0;i<count;i++) {
            const uint64_t qpos=origin+(uint64_t)i*step;
            const uint64_t ix=qpos>>32;
            const float frac=(float)(uint32_t)qpos*(1.0f/4294967296.0f);
            float value=0.0f;
            if(ix<pcm->samples.size()) {
                const float x=(float)pcm->samples[(size_t)ix];
                const float y=(float)pcm->samples[std::min((size_t)ix+1,pcm->samples.size()-1)];
                value=(x+(y-x)*frac)*(1.0f/32768.0f);
            }
            for(unsigned c=0;c<channelsInBuffer;c++) {
                const size_t j=(size_t)i*channelsInBuffer+c;
                if(flt)((float *)buf.mData)[j]=value;
                else if(bits==16)
                    ((int16_t *)buf.mData)[j]=(int16_t)lrintf(value*32767.0f);
                else ((int32_t *)buf.mData)[j]=(int32_t)llrint((double)value*2147483647.0);
            }
        }
        size_t filled=(size_t)count*channelsInBuffer*sampleBytes;
        if(filled<buf.mDataByteSize)
            memset((uint8_t *)buf.mData+filled,0,buf.mDataByteSize-filled);
    }
    if(playing)gMicInjectedFrames.fetch_add(frames,std::memory_order_relaxed);
    return true;
}

// Proactively hook native media before calls appear, so Telegram's physical
// capturer can be retained even when constructed during the ringtone.
extern "C" void LeadVirtualMediaInstallEarlyHooks(void) {
    (void)[[LeadVirtualMedia shared] installNativeHooks];
    [[LeadVirtualMedia shared] installGroupHooks];
}
extern "C" void LeadVirtualMediaPrepareVideoCall(void (^completion)(BOOL)) {
    dispatch_async(dispatch_get_main_queue(),^{
        LeadVirtualMedia *m=[LeadVirtualMedia shared];
        [m normalIncomingAnswer];
        [m preparePicker:completion fullCall:NO];
    });
}
extern "C" void LeadVirtualMediaPrepareFullVideoCall(void (^completion)(BOOL)) {
    dispatch_async(dispatch_get_main_queue(),^{
        LeadVirtualMedia *m=[LeadVirtualMedia shared];
        [m normalIncomingAnswer];
        [m preparePicker:completion fullCall:YES];
    });
}
extern "C" void LeadVirtualMediaReset(void) {
    if(NSThread.isMainThread)[[LeadVirtualMedia shared] normalIncomingAnswer];
    else dispatch_async(dispatch_get_main_queue(),^{[[LeadVirtualMedia shared] normalIncomingAnswer];});
}
// Remove the old VID overlay. All selection is now before the outgoing call.
extern "C" void LeadVirtualMediaInstallButton(UIView *view) {
    if(NSThread.isMainThread)[[LeadVirtualMedia shared] rememberCallView:view];
    else dispatch_async(dispatch_get_main_queue(),^{[[LeadVirtualMedia shared] rememberCallView:view];});
}
extern "C" void LeadVirtualMediaRemoveButton(UIView *view) {
    if(NSThread.isMainThread)[[LeadVirtualMedia shared] forgetCallView:view];
    else dispatch_async(dispatch_get_main_queue(),^{[[LeadVirtualMedia shared] forgetCallView:view];});
}

// Incoming video choices are attached to Telegram's CallKit provider, not to
// its outgoing "Video call" button. A CallKit answer action must be fulfilled
// promptly; delay only the optional gallery picker, never the real answer.
static NSMutableSet<NSUUID *> *LeadIncomingVideoIDs(void) {
    static NSMutableSet<NSUUID *> *ids=nil;
    static dispatch_once_t once;
    dispatch_once(&once,^{ids=[NSMutableSet set];});
    return ids;
}
static void (*gTelegramOriginalAnswer)(id,SEL,CXProvider *,CXAnswerCallAction *)=nullptr;
static void LeadTelegramAnswer(id delegate,SEL selector,CXProvider *provider,CXAnswerCallAction *action) {
    BOOL incomingVideo=NO;
    @synchronized(LeadIncomingVideoIDs()) {
        incomingVideo=[LeadIncomingVideoIDs() containsObject:action.callUUID];
        [LeadIncomingVideoIDs() removeObject:action.callUUID];
    }
    // Gate VIDEO frames only; do not block or delay CallKit's actual
    // synchronous Answer. A video track can be initialized during acceptance.
    if(incomingVideo) {
        gIncomingPrivacyGate.store(true,std::memory_order_release);
        [[LeadVirtualMedia shared] protectIncomingCamera];
    }
    if(gTelegramOriginalAnswer)gTelegramOriginalAnswer(delegate,selector,provider,action);
    if(incomingVideo) {
        dispatch_async(dispatch_get_main_queue(),^{
            LeadVirtualMedia *m=[LeadVirtualMedia shared];
            [m incomingVideoAnsweredForUUID:action.callUUID];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.65*NSEC_PER_SEC)),
                dispatch_get_main_queue(),^{[m showIncomingSourceMenu];});
        });
    } else if(gMode.load()!=0 && gMode.load()!=2) {
        dispatch_async(dispatch_get_main_queue(),^{
            [[LeadVirtualMedia shared] normalIncomingAnswer];
        });
    }
}
static void LeadHookIncomingAnswerDelegate(id delegate) {
    if(!delegate || ![NSStringFromClass([delegate class]) containsString:@"CallKitProviderDelegate"])return;
    @synchronized([LeadVirtualMedia shared]) {
        if(gTelegramOriginalAnswer)return;
        Method method=class_getInstanceMethod([delegate class],
                    NSSelectorFromString(@"provider:performAnswerCallAction:"));
        if(!method) {
            NSLog(@"[LeadVirtualMedia] Telegram CallKit answer handler unavailable");
            return;
        }
        gTelegramOriginalAnswer=(decltype(gTelegramOriginalAnswer))
            method_setImplementation(method,(IMP)LeadTelegramAnswer);
        NSLog(@"[LeadVirtualMedia] incoming video answer options installed");
    }
}

// Telegram creates its preview capturer BEFORE requestVideo:completion:.
// Intercept the actual camera control action, before onCameraPressed executes.
static BOOL LeadGroupCameraLabel(UIView *view) {
    NSString *label=view.accessibilityLabel;
    if([view isKindOfClass:UILabel.class])label=((UILabel *)view).text;
    SEL nodeSelector=NSSelectorFromString(@"asyncdisplaykit_node");
    if(!label.length && [view respondsToSelector:nodeSelector]) {
        id node=((id (*)(id,SEL))objc_msgSend)(view,nodeSelector);
        SEL textSelector=NSSelectorFromString(@"attributedText");
        if([node respondsToSelector:textSelector]) {
            id text=((id (*)(id,SEL))objc_msgSend)(node,textSelector);
            if([text isKindOfClass:NSAttributedString.class])label=[text string];
        }
    }
    NSString *clean=[[label stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if([@[@"الكاميرا",@"كاميرا",@"camera",@"video",@"الفيديو",@"فيديو"] containsObject:clean?:@""])return YES;
    for(UIView *child in view.subviews)if(LeadGroupCameraLabel(child))return YES;
    return NO;
}
static BOOL LeadIsGroupCameraControl(UIControl *control) {
    if(![NSStringFromClass(control.class) containsString:@"PlainButtonComponent"])return NO;
    UIView *screen=nil;
    for(UIView *parent=control.superview;parent;parent=parent.superview) {
        if([NSStringFromClass(parent.class) containsString:@"VideoChatScreenComponent"]) {
            screen=parent;break;
        }
    }
    if(!screen)return NO;
    if(LeadGroupCameraLabel(control))return YES;

    // Telegram's VideoChatActionButtonComponent renders its caption through
    // MultilineTextComponent, NOT UILabel. In non-VoiceOver layouts its
    // PlainButtonComponent accessibilityLabel can also be nil, so the old
    // text-only matcher missed the tap and opened the native camera preview.
    // Match the second button in the five-action bottom row as a fallback.
    // Restrict this to the same parent, row and screen to avoid toolbar taps.
    if(control.hidden || control.alpha<0.1 || !control.userInteractionEnabled ||
       !control.superview || screen.bounds.size.height<240)return NO;
    CGPoint p=[control.superview convertPoint:control.center toView:screen];
    if(p.y < screen.bounds.size.height*0.67 || p.y > screen.bounds.size.height*0.96)
        return NO;
    NSMutableArray<UIControl *> *row=[NSMutableArray array];
    for(UIView *v in control.superview.subviews) {
        if(![v isKindOfClass:UIControl.class] ||
           ![NSStringFromClass(v.class) containsString:@"PlainButtonComponent"] ||
           v.hidden || v.alpha<0.1 || !v.userInteractionEnabled)continue;
        CGPoint q=[v.superview convertPoint:v.center toView:screen];
        if(fabs(q.y-p.y)<24.0 && v.bounds.size.width>=44.0)
            [row addObject:(UIControl *)v];
    }
    if(row.count<4 || row.count>6)return NO;
    [row sortUsingComparator:^NSComparisonResult(UIControl *a,UIControl *b) {
        CGFloat ax=[a.superview convertPoint:a.center toView:screen].x;
        CGFloat bx=[b.superview convertPoint:b.center toView:screen].x;
        return ax<bx?NSOrderedAscending:(ax>bx?NSOrderedDescending:NSOrderedSame);
    }];
    return row[1]==control;
}
static BOOL LeadViewHasMuteTitle(UIView *view) {
    NSString *label=view.accessibilityLabel;
    if([view isKindOfClass:UILabel.class])label=((UILabel *)view).text;
    SEL nodeSelector=NSSelectorFromString(@"asyncdisplaykit_node");
    if(!label.length && [view respondsToSelector:nodeSelector]) {
        id node=((id (*)(id,SEL))objc_msgSend)(view,nodeSelector);
        SEL textSelector=NSSelectorFromString(@"attributedText");
        if([node respondsToSelector:textSelector]) {
            id text=((id (*)(id,SEL))objc_msgSend)(node,textSelector);
            if([text isKindOfClass:NSAttributedString.class])label=[text string];
        }
    }
    NSString *clean=[[label stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if([@[@"كتم",@"كتم الصوت",@"mute"] containsObject:clean?:@""])return YES;
    for(UIView *child in view.subviews)if(LeadViewHasMuteTitle(child))return YES;
    return NO;
}
static BOOL LeadGroupGreenMicGlow(UIView *root) {
    if([NSStringFromClass(root.class) containsString:@"GlowView"]) {
        for(CALayer *layer in root.layer.sublayers) {
            if(![layer isKindOfClass:CAGradientLayer.class])continue;
            NSArray *colors=((CAGradientLayer *)layer).colors;
            if(!colors.count)continue;
            UIColor *color=[UIColor colorWithCGColor:(__bridge CGColorRef)colors.firstObject];
            CGFloat r=0,g=0,b=0,a=0;
            if([color getRed:&r green:&g blue:&b alpha:&a] &&
               g>0.48 && g>r*1.25 && g>b*1.20)return YES;
        }
    }
    for(UIView *child in root.subviews)if(LeadGroupGreenMicGlow(child))return YES;
    return NO;
}
static void LeadFindGroupControls(UIView *root,UIControl **camera,UIControl **mic) {
    if(!root)return;
    if([root isKindOfClass:UIControl.class]) {
        if(LeadIsGroupCameraControl((UIControl *)root))*camera=(UIControl *)root;
        if([NSStringFromClass(root.class) containsString:@"VideoChatMicButtonComponent"])
            *mic=(UIControl *)root;
    }
    for(UIView *child in root.subviews)LeadFindGroupControls(child,camera,mic);
}
static void LeadCloseGroupMediaControls(void) {
    UIControl *camera=nil,*mic=nil;
    LeadFindGroupControls(gGroupCallView,&camera,&mic);
    // Telegram's native VideoChatMicButtonComponent calls setIsMuted(.muted)
    // inside endTracking, which ALSO refreshes the visible green microphone.
    // Only invoke it when native green glow (or a mute caption) says unmuted.
    if(mic && (LeadGroupGreenMicGlow(mic) || LeadViewHasMuteTitle(mic))) {
        [mic endTrackingWithTouch:nil withEvent:nil];
        NSLog(@"[LeadVirtualMedia] EOF: requested native group UI microphone mute");
    } else {
        NSLog(@"[LeadVirtualMedia] EOF: microphone already muted or control not found");
    }
    if(camera) {
        BOOL previous=gGroupReplayAction;
        gGroupReplayAction=YES;
        [camera sendActionsForControlEvents:UIControlEventTouchUpInside];
        gGroupReplayAction=previous;
    }
}

%hook UIControl
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    if(gGroupReplayAction || !LeadIsGroupCameraControl(self) || gGroupMode.load() || gGroupNormalActive) {
        %orig;
        return;
    }
    if(gGroupChoiceBusy)return;
    LeadVirtualMedia *media=[LeadVirtualMedia shared];
    UIViewController *host=[media host];
    if(!host)return; // Do not open the real camera without a choice.
    gGroupChoiceBusy=YES;
    gGroupNormalChosen=NO;
    gGroupGalleryPending.store(false);
    [media installGroupHooks];
    __weak UIControl *button=self;
    __weak id originalTarget=target;
    void (^resume)(void)=^{
        UIControl *control=button;
        if(!control.window || !originalTarget) {
            gGroupGalleryPending.store(false);gGroupHold.store(false);
            [media resetAll];return;
        }
        gGroupReplayAction=YES;
        [control sendAction:action to:originalTarget forEvent:nil];
        gGroupReplayAction=NO;
    };
    UIAlertController *choice=[UIAlertController alertControllerWithTitle:@"كاميرا المكالمة"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [choice addAction:[UIAlertAction actionWithTitle:@"اتصال طبيعي" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *a){
            gGroupChoiceBusy=NO;gGroupNormalChosen=YES;
            gGroupHold.store(false);
            dispatch_async(dispatch_get_main_queue(),resume);
        }]];
    [choice addAction:[UIAlertAction actionWithTitle:@"رفع فيديو" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *a){
            gGroupHold.store(true);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.35*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                [media preparePicker:^(BOOL ok){
                    gGroupChoiceBusy=NO;
                    if(!ok){gGroupHold.store(false);return;}
                    gGroupGalleryPending.store(true);
                    resume();
                } fullCall:NO];
            });
        }]];
    [choice addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel
        handler:^(__unused UIAlertAction *a){gGroupChoiceBusy=NO;gGroupHold.store(false);}]];
    [host presentViewController:choice animated:YES completion:nil];
}
%end

// The proven group uplink currently needs Telegram's shareCamera callback
// to set its Swift PresentationGroupCallImpl state. Instead of showing a real
// camera preview and making the user tap Continue, invoke that SAME callback
// via its existing SolidRoundedButtonNode as soon as the preview is ready.
// This preserves Build 98's working video handoff and skips its extra step.
static BOOL LeadAcceptNativeGroupGalleryPreview(UIView *root) {
    if(!root)return NO;
    NSMutableArray<UIView *> *stack=[NSMutableArray arrayWithObject:root];
    SEL nodeSel=NSSelectorFromString(@"asyncdisplaykit_node");
    SEL pressSel=NSSelectorFromString(@"buttonPressed");
    while(stack.count) {
        UIView *view=stack.lastObject;
        [stack removeLastObject];
        if([view respondsToSelector:nodeSel]) {
            id node=((id (*)(id,SEL))objc_msgSend)(view,nodeSel);
            if(node && [NSStringFromClass([node class]) containsString:@"SolidRoundedButtonNode"] &&
               [node respondsToSelector:pressSel]) {
                ((void (*)(id,SEL))objc_msgSend)(node,pressSel);
                NSLog(@"[LeadVirtualMedia] group gallery: native shareCamera continued automatically");
                return YES;
            }
        }
        [stack addObjectsFromArray:view.subviews];
    }
    return NO;
}
static void LeadTryAutoContinueGalleryPreview(UIViewController *controller,NSInteger attempts) {
    if(!gGroupGalleryPending.load())return;
    if(!controller || !controller.isViewLoaded)return;
    if(LeadAcceptNativeGroupGalleryPreview(controller.view))return;
    if(attempts>0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.065*NSEC_PER_SEC)),
          dispatch_get_main_queue(),^{LeadTryAutoContinueGalleryPreview(controller,attempts-1);});
    } else {
        // Fail open to the manual Continue UI rather than silently abandon
        // the user's selected video on a newer/unsupported Telegram version.
        controller.view.alpha=1.0;
        NSLog(@"[LeadVirtualMedia] automatic group Continue unavailable; manual native fallback");
    }
}

%hook UIViewController
- (void)viewWillAppear:(BOOL)animated {
    if(gGroupGalleryPending.load() &&
       [NSStringFromClass(self.class) containsString:@"VoiceChatCameraPreviewController"])
        self.view.alpha=0.0;
    %orig(animated);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    if(gGroupGalleryPending.load() &&
       [NSStringFromClass(self.class) containsString:@"VoiceChatCameraPreviewController"]) {
        self.view.alpha=0.0;
        dispatch_async(dispatch_get_main_queue(),^{LeadTryAutoContinueGalleryPreview(self,12);});
    }
}
%end

%hook CXProvider
- (void)setDelegate:(id<CXProviderDelegate>)delegate queue:(dispatch_queue_t)queue {
    LeadHookIncomingAnswerDelegate(delegate);
    %orig(delegate,queue);
}
- (void)reportNewIncomingCallWithUUID:(NSUUID *)uuid update:(CXCallUpdate *)update
    completion:(void (^)(NSError *))completion {
    [[LeadVirtualMedia shared] installIncomingObservers];
    (void)[[LeadVirtualMedia shared] installNativeHooks];
    gObservedCallState.store(-1);
    // Reset the PREVIOUS terminated virtual clip before protecting the
    // incoming camera, otherwise the reset would immediately disarm the gate.
    if(gMode.load()==3)
        [[LeadVirtualMedia shared] normalIncomingAnswer];
    if(uuid && update.hasVideo) {
        // This runs before the user taps Answer and before the WebRTC
        // outgoing video track can start from the incoming call.
        gIncomingPrivacyGate.store(true,std::memory_order_release);
        [[LeadVirtualMedia shared] protectIncomingCamera];
        @synchronized(LeadIncomingVideoIDs()) {
            [LeadIncomingVideoIDs() addObject:uuid];
        }
    }
    %orig(uuid,update,completion);
}
%end

// Draw the actual media frame over the hardware-backed preview which UIKit
// screen capture would otherwise render as blank. Must be called while the
// recording CG bitmap context is current on the main thread.
// Used only by manually requested recording: expose the two original movies
// and their shared timeline so saved audio can match the chosen, locally
// simulated remote side rather than accidentally mixing the real peer's mic.
extern "C" NSArray<NSURL *> *LeadVirtualMediaFullCallAudioSources(void) {
    LeadVirtualMedia *m=[LeadVirtualMedia shared];
    if(!gFullCallMode.load() || !m.selectedURL || !m.remoteSelectedURL)return nil;
    return @[m.selectedURL,m.remoteSelectedURL];
}
extern "C" double LeadVirtualMediaFullCallElapsed(void) {
    double start=gStartClock.load();
    return (start>0 && gFullCallMode.load())?
        MAX(0.0,CACurrentMediaTime()-start):0.0;
}
extern "C" void LeadVirtualMediaDrawRecordingPreview(UIView *captureRoot) {
    LeadVirtualMedia *m=[LeadVirtualMedia shared];
    [m drawRemotePreviewIntoRecording:captureRoot];
    [m drawGalleryPreviewIntoRecording:captureRoot];
}
