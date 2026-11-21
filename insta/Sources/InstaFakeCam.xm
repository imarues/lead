// InstaFakeCam: independent Instagram video-call virtual camera prototype.
// Uses public AVFoundation frame delivery plus Instagram's Direct-call UI coordinator.
// Tested by GitHub CI compilation; actual Instagram/RTC media compatibility requires device tests.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <PhotosUI/PhotosUI.h>
#import <Photos/Photos.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

typedef NS_ENUM(NSInteger, IFMode) {
    IFModeNormal = 0,
    IFModeOutgoing = 1,
    IFModeDual = 2
};

static BOOL gIFResumingNativeCall = NO;
static BOOL gIFCallMenuVisible = NO;
static NSString *const kIFVersion = @"0.4.0";

static UIWindow *IFMainWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *scene = (UIWindowScene *)candidate;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in scene.windows) {
            if (w.hidden || !w.rootViewController) continue;
            if (w.isKeyWindow) return w;
            if (w.windowLevel == UIWindowLevelNormal) fallback = w;
        }
    }
    return fallback ?: UIApplication.sharedApplication.keyWindow;
}

static UIViewController *IFPresenter(void) {
    UIViewController *controller = IFMainWindow().rootViewController;
    while (controller.presentedViewController &&
           !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    return controller;
}

static void IFShowMessage(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = IFPresenter();
        if (!presenter) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                  message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                  style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

// Incoming-camera simulation is strictly LOCAL: it does not change the other
// participant's actual transmission. It visually covers their preview.
@interface IFRemoteSurface : UIView
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@end
@implementation IFRemoteSurface
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.blackColor;
        self.userInteractionEnabled = NO;
        self.layer.cornerRadius = 12;
        self.clipsToBounds = YES;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.playerLayer.frame = self.bounds;
}
- (void)playURL:(NSURL *)url {
    [self.player pause];
    self.player = [AVPlayer playerWithURL:url];
    self.player.muted = YES; // Never interfere with RTC microphone audio.
    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.playerLayer.frame = self.bounds;
    [self.layer addSublayer:self.playerLayer];
    [self.player play];
}
@end

@interface IFRemoteWindow : UIWindow
@end
@implementation IFRemoteWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e { return nil; }
- (BOOL)canBecomeKeyWindow { return NO; }
@end

@interface IFLocalRemotePreview : NSObject
@property (nonatomic, strong) IFRemoteWindow *window;
@property (nonatomic, strong) IFRemoteSurface *surface;
- (void)presentURL:(NSURL *)url;
- (void)hide;
@end
@implementation IFLocalRemotePreview
+ (instancetype)shared {
    static IFLocalRemotePreview *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [IFLocalRemotePreview new]; });
    return s;
}
- (void)presentURL:(NSURL *)url {
    if (!url) return;
    UIWindow *main = IFMainWindow();
    if (!main.windowScene) return;
    [self hide];
    IFRemoteWindow *overlay = [[IFRemoteWindow alloc] initWithWindowScene:main.windowScene];
    overlay.windowLevel = UIWindowLevelNormal + 3;
    overlay.frame = main.bounds;
    overlay.backgroundColor = UIColor.clearColor;
    overlay.userInteractionEnabled = NO;
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.clearColor;
    root.view.userInteractionEnabled = NO;
    overlay.rootViewController = root;
    CGFloat width = CGRectGetWidth(overlay.bounds);
    CGFloat height = CGRectGetHeight(overlay.bounds);
    // Keep Instagram's hang-up and navigation controls uncovered.
    CGFloat top = MAX(96, main.safeAreaInsets.top + 64);
    CGFloat bottom = MAX(172, main.safeAreaInsets.bottom + 125);
    IFRemoteSurface *surface = [[IFRemoteSurface alloc]
      initWithFrame:CGRectMake(8, top, MAX(50,width-16), MAX(80,height-top-bottom))];
    [root.view addSubview:surface];
    [surface playURL:url];
    overlay.hidden = NO; // Do NOT use makeKeyAndVisible.
    self.window = overlay;
    self.surface = surface;
}
- (void)hide {
    [self.surface.player pause];
    [self.surface.playerLayer removeFromSuperlayer];
    self.window.hidden = YES;
    self.surface = nil;
    self.window = nil;
}
@end

// Method names are from the openly available Sparkle Instagram call hooks.
// This UI interception is version-dependent; it does not cover incoming calls.
@interface IFCallCoordinator : NSObject <PHPickerViewControllerDelegate>
@property (nonatomic, assign) IFMode requestedMode;
@property (nonatomic, assign) NSInteger pickerStep;
@property (nonatomic, copy) void (^nativeContinuation)(void);
@property (nonatomic, strong) NSURL *outgoingURL;
@property (nonatomic, strong) NSURL *incomingURL;
@property (nonatomic, weak) id callManager;
@property (nonatomic, weak) id callSession;
@property (nonatomic, strong) NSTimer *stateTimer;
@property (nonatomic, strong) NSTimer *endTimer;
@property (nonatomic, assign) BOOL callConnected;
@property (nonatomic, assign) BOOL participantJoined;
@property (nonatomic, assign) BOOL hangupRequested;
+ (instancetype)shared;
- (void)offerCallOptions:(void (^)(void))nativeContinuation;
- (void)observeManager:(id)manager session:(id)session;
- (void)participantJoinedSession:(id)session;
- (void)callDidEnd;
- (void)fakeClipFinished;
@end

@interface IFFrameEngine : NSObject
@property (nonatomic, strong) NSRecursiveLock *lock;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderVideoCompositionOutput *output;
@property (nonatomic, strong) AVAssetTrack *track;
@property (nonatomic, strong) CIContext *context;
@property (nonatomic, assign) CMSampleBufferRef held;
@property (nonatomic, assign) CMSampleBufferRef next;
@property (nonatomic, assign) CMTime origin;
@property (nonatomic, assign) NSInteger pixelWidth;
@property (nonatomic, assign) NSInteger pixelHeight;
@property (nonatomic, assign) OSType pixelFormat;
@property (nonatomic, assign) CFTimeInterval duration;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL playing;
- (void)arm:(NSURL *)url;
- (void)beginPlayback;
- (BOOL)isArmed;
- (CFTimeInterval)clipDuration;
- (void)stop;
- (CMSampleBufferRef)copyReplacementFor:(CMSampleBufferRef)input;
@end

@implementation IFFrameEngine
+ (instancetype)shared {
    static IFFrameEngine *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s=[IFFrameEngine new]; });
    return s;
}
- (instancetype)init {
    if ((self=[super init])) {
        _lock=[NSRecursiveLock new];
        _context=[CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer:@NO }];
        _origin=kCMTimeInvalid;
    }
    return self;
}
- (void)clearReaderLocked {
    [self.reader cancelReading];
    self.reader=nil;
    self.output=nil;
    self.track=nil;
    if(self.held) { CFRelease(self.held); self.held=NULL; }
    if(self.next) { CFRelease(self.next); self.next=NULL; }
    self.origin=kCMTimeInvalid;
    self.pixelWidth=0; self.pixelHeight=0; self.pixelFormat=0;
}
- (void)arm:(NSURL *)url {
    [self.lock lock];
    [self clearReaderLocked];
    self.url=[url copy];
    self.duration=0; self.started=NO; self.finished=NO; self.playing=NO;
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:nil];
    CFTimeInterval seconds=CMTimeGetSeconds(asset.duration);
    self.duration=(isfinite(seconds) && seconds>0) ? seconds : 0;
    [self.lock unlock];
    NSLog(@"[InstaFakeCam] armed clip %@ (%.2fs); playback gated by remote acceptance",
          url.lastPathComponent, self.duration);
}
- (void)stop {
    [self.lock lock];
    self.url=nil;
    [self clearReaderLocked];
    self.started=NO; self.finished=NO; self.playing=NO; self.duration=0;
    [self.lock unlock];
}
- (BOOL)isArmed {
    [self.lock lock]; BOOL result=(self.url!=nil); [self.lock unlock]; return result;
}
- (CFTimeInterval)clipDuration {
    [self.lock lock]; CFTimeInterval result=self.duration; [self.lock unlock]; return result;
}
- (void)beginPlayback {
    [self.lock lock];
    if(self.url && !self.playing) {
        // First frame starts ONLY after the remote participant joins.
        self.playing=YES;
        self.finished=NO;
        self.origin=kCMTimeInvalid;
        NSLog(@"[InstaFakeCam] remote answered; starting video clock from frame zero");
    }
    [self.lock unlock];
}
- (BOOL)prepareForWidth:(size_t)w height:(size_t)h format:(OSType)format {
    if(self.reader && self.pixelWidth==(NSInteger)w && self.pixelHeight==(NSInteger)h &&
       self.pixelFormat==format) return YES;
    if(!self.url) return NO;
    [self clearReaderLocked];
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:self.url options:nil];
    AVAssetTrack *track=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if(!track) {
        NSLog(@"[InstaFakeCam v%@] no video track in clip %@",kIFVersion,self.url.lastPathComponent);
        return NO;
    }
    // Based on the public Sparkle Instants reader architecture: output is
    // already composited into the capture stream's exact pixel format and size.
    // The previous build rendered CIImage into 420f/420v pixel buffers without
    // validating that destination, which can produce solid black frames.
    CGSize transformed=CGSizeApplyAffineTransform(track.naturalSize,track.preferredTransform);
    CGSize natural=CGSizeMake(fabs(transformed.width),fabs(transformed.height));
    if(natural.width<=0 || natural.height<=0) {
        NSLog(@"[InstaFakeCam v%@] invalid video geometry",kIFVersion);
        return NO;
    }
    CGFloat scale=MAX((CGFloat)w/natural.width,(CGFloat)h/natural.height);
    CGAffineTransform xform=track.preferredTransform;
    xform=CGAffineTransformConcat(xform,CGAffineTransformMakeScale(scale,scale));
    xform=CGAffineTransformConcat(xform,CGAffineTransformMakeTranslation(
        ((CGFloat)w-natural.width*scale)/2.0,((CGFloat)h-natural.height*scale)/2.0));
    AVMutableVideoCompositionLayerInstruction *layer=
        [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:track];
    [layer setTransform:xform atTime:kCMTimeZero];
    AVMutableVideoCompositionInstruction *instruction=[AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange=CMTimeRangeMake(kCMTimeZero,asset.duration);
    instruction.layerInstructions=@[layer];
    instruction.backgroundColor=UIColor.blackColor.CGColor;
    AVMutableVideoComposition *composition=[AVMutableVideoComposition videoComposition];
    composition.renderSize=CGSizeMake(w,h);
    CMTime frameDuration=track.minFrameDuration;
    if(!CMTIME_IS_NUMERIC(frameDuration)||CMTimeCompare(frameDuration,kCMTimeZero)<=0)
        frameDuration=CMTimeMake(1,30);
    composition.frameDuration=frameDuration;
    composition.instructions=@[instruction];

    NSError *error=nil;
    AVAssetReader *reader=[AVAssetReader assetReaderWithAsset:asset error:&error];
    if(!reader) {
        NSLog(@"[InstaFakeCam v%@] reader create error %@",kIFVersion,error);
        return NO;
    }
    AVAssetReaderVideoCompositionOutput *output=
        [AVAssetReaderVideoCompositionOutput assetReaderVideoCompositionOutputWithVideoTracks:@[track]
            videoSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(format)}];
    output.videoComposition=composition;
    output.alwaysCopiesSampleData=NO;
    if(![reader canAddOutput:output]) {
        NSLog(@"[InstaFakeCam v%@] unsupported camera pixel format %u",kIFVersion,(unsigned)format);
        return NO;
    }
    [reader addOutput:output];
    if(![reader startReading]) {
        NSLog(@"[InstaFakeCam v%@] reader start error %@ format=%u",
            kIFVersion,reader.error,(unsigned)format);
        return NO;
    }
    self.reader=reader; self.output=output; self.track=track;
    self.pixelWidth=w; self.pixelHeight=h; self.pixelFormat=format;
    self.next=[output copyNextSampleBuffer];
    if(!self.next) {
        NSLog(@"[InstaFakeCam v%@] no decoded frames; reader status=%ld error=%@",
              kIFVersion,(long)reader.status,reader.error);
        [self clearReaderLocked];
        return NO;
    }
    // Hold the first real frame while the call is ringing. This prevents
    // a black local camera preview without consuming the video duration.
    self.held=self.next;
    self.next=[output copyNextSampleBuffer];
    NSLog(@"[InstaFakeCam v%@] decoded first frame %zux%zu fmt=%u",kIFVersion,w,h,(unsigned)format);
    return YES;
}
- (CMSampleBufferRef)copyReplacementFor:(CMSampleBufferRef)input {
    [self.lock lock];
    // NEVER stop replacing frames merely because the clip ended:
    // otherwise the live camera would become visible before hangup completes.
    if (!self.url) { [self.lock unlock]; return NULL; }
    CVImageBufferRef source=CMSampleBufferGetImageBuffer(input);
    if(!source) { [self.lock unlock]; return NULL; }
    size_t w=CVPixelBufferGetWidth(source),h=CVPixelBufferGetHeight(source);
    if(!w||!h) { [self.lock unlock]; return NULL; }

    // Prepare/hold a frame while ringing but render BLACK until accepted.
    // This protects against consuming the clip early and against the real-camera
    // fallback seen in the previous test build.
    OSType cameraFormat=CVPixelBufferGetPixelFormatType(source);
    BOOL readerReady=[self prepareForWidth:w height:h format:cameraFormat];
    CMTime captureTime=CMSampleBufferGetPresentationTimeStamp(input);
    CMTime elapsed=kCMTimeInvalid;
    if(self.playing && !self.finished && readerReady) {
        if(!CMTIME_IS_NUMERIC(self.origin)) self.origin=captureTime;
        elapsed=CMTimeSubtract(captureTime,self.origin);
        if(CMTIME_IS_NUMERIC(elapsed)) {
            while(self.next &&
               CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(self.next),elapsed)<=0) {
                if(self.held) CFRelease(self.held);
                self.held=self.next;
                self.next=[self.output copyNextSampleBuffer];
            }
        }
    }
    // The first actual frame is retained before acceptance. After acceptance,
    // frame advancement starts at t=0. At EOF, the last frame is held until
    // the end-call action is acknowledged.
    CVPixelBufferRef target=self.held ? CMSampleBufferGetImageBuffer(self.held) : NULL;
    if(!target) {
        // Report the error instead of silently switching to real camera.
        static CFTimeInterval previousWarning=0;
        CFTimeInterval now=CFAbsoluteTimeGetCurrent();
        if(now-previousWarning>10) {
            previousWarning=now;
            NSLog(@"[InstaFakeCam v%@] no frame; reader status=%ld error=%@",
                  kIFVersion,(long)self.reader.status,self.reader.error);
        }
        [self.lock unlock];
        return NULL;
    }
    CMVideoFormatDescriptionRef desc=NULL;
    CMSampleBufferRef outputBuffer=NULL;
    OSStatus status=CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,target,&desc);
    if(status==noErr && desc) {
        CMSampleTimingInfo timing={kCMTimeInvalid,kCMTimeInvalid,kCMTimeInvalid};
        CMSampleBufferGetSampleTimingInfo(input,0,&timing);
        status=CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,target,YES,NULL,NULL,
                                                  desc,&timing,&outputBuffer);
    }
    if(desc) CFRelease(desc);
    if(status!=noErr) NSLog(@"[InstaFakeCam v%@] output frame status=%d",kIFVersion,(int)status);
    if(self.playing && self.duration>0 && CMTIME_IS_NUMERIC(elapsed) &&
       CMTimeGetSeconds(elapsed)>=self.duration && !self.finished) {
        self.finished=YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[IFCallCoordinator shared] fakeClipFinished];
        });
    }
    [self.lock unlock];
    return outputBuffer;
}
@end

static BOOL IFIsEndCallButton(UIView *view) {
    if(![view isKindOfClass:[UIControl class]] || view.hidden || view.alpha<.10)
        return NO;
    NSString *label=[NSString stringWithFormat:@"%@ %@ %@",
                        view.accessibilityLabel?:@"",view.accessibilityIdentifier?:@"",
                        [view isKindOfClass:[UIButton class]]?((UIButton *)view).currentTitle?:@"":@""].lowercaseString;
    for(NSString *token in @[@"end call",@"hang up",@"hangup",@"end video call",
                             @"endcall",@"إنهاء المكالمة",@"إنهاء الاتصال",
                             @"قطع الاتصال",@"terminar llamada",@"raccrocher"]) {
        if([label containsString:token]) return YES;
    }
    // Recent Instagram may omit an accessibility label on the red hang-up
    // circle. Accept this visual fallback only in the call control-bar area.
    UIWindow *win=view.window;
    if(win) {
        CGRect box=[view convertRect:view.bounds toView:win];
        CGFloat cx=CGRectGetMidX(box), cy=CGRectGetMidY(box);
        CGFloat sw=CGRectGetWidth(win.bounds), sh=CGRectGetHeight(win.bounds);
        if(cx>sw*.64 && cy>sh*.58 && box.size.width>=35 && box.size.width<=125 &&
           box.size.height>=35 && box.size.height<=125) {
            NSMutableArray<UIView *> *queue=[NSMutableArray arrayWithObject:view];
            NSInteger inspected=0;
            while(queue.count && inspected++<12) {
                UIView *candidate=queue.firstObject;
                [queue removeObjectAtIndex:0];
                CGFloat red=0,green=0,blue=0,alpha=0;
                if([candidate.backgroundColor getRed:&red green:&green blue:&blue alpha:&alpha]
                   && red>.68 && green<.38 && blue<.48 && alpha>.65)
                    return YES;
                [queue addObjectsFromArray:candidate.subviews];
            }
        }
    }
    return NO;
}
static UIControl *IFFindHangup(UIView *view) {
    if(!view || view.hidden) return nil;
    if(IFIsEndCallButton(view)) return (UIControl *)view;
    for(UIView *child in view.subviews) {
        UIControl *match=IFFindHangup(child);
        if(match) return match;
    }
    return nil;
}

// A secondary guard: the outgoing call's "Calling..." screen must be gone
// even if a version reports its transport as connected before anyone answers.
static BOOL IFViewHasRingingText(UIView *root, NSInteger depth, NSUInteger *visited) {
    if(!root || root.hidden || root.alpha<.02 || depth>22 || (*visited)++>2200)
        return NO;
    NSString *value=nil;
    if([root isKindOfClass:UILabel.class]) value=((UILabel *)root).text;
    if(value.length) {
        NSString *label=value.lowercaseString;
        for(NSString *needle in @[@"calling...",@"calling…",@"ringing...",
                    @"ringing…",@"connecting...",@"connecting…",
                    @"جاري الاتصال",@"جار الاتصال",@"يتصل...",@"الاتصال جار"]) {
            if([label containsString:needle]) return YES;
        }
    }
    for(UIView *child in root.subviews)
        if(IFViewHasRingingText(child,depth+1,visited)) return YES;
    return NO;
}
static BOOL IFOutgoingCallStillRinging(void) {
    UIWindow *window=IFMainWindow();
    NSUInteger visited=0;
    return window.rootViewController ?
           IFViewHasRingingText(window.rootViewController.view,0,&visited) : NO;
}

@implementation IFCallCoordinator
+ (instancetype)shared {
    static IFCallCoordinator *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s=[IFCallCoordinator new]; });
    return s;
}
- (void)reset {
    [self.stateTimer invalidate]; self.stateTimer=nil;
    [self.endTimer invalidate]; self.endTimer=nil;
    self.callConnected=NO;
    self.participantJoined=NO;
    self.hangupRequested=NO;
    self.callSession=nil; self.callManager=nil;
    self.requestedMode=IFModeNormal;
    self.pickerStep=0;
    self.nativeContinuation=nil;
    self.outgoingURL=nil; self.incomingURL=nil;
    [[IFLocalRemotePreview shared] hide];
    [[IFFrameEngine shared] stop];
}
- (void)callDidEnd {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self callDidEnd]; });
        return;
    }
    if(self.requestedMode==IFModeNormal && ![[IFFrameEngine shared] isArmed])
        return;
    NSLog(@"[InstaFakeCam] native call ended; resetting media");
    [self reset];
}
- (void)observeManager:(id)manager session:(id)session {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self observeManager:manager session:session]; });
        return;
    }
    if(self.requestedMode==IFModeNormal) return;
    if(manager) self.callManager=manager;
    if(session) self.callSession=session;
    [self inspectConnectionState];
}
- (void)participantJoinedSession:(id)session {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self participantJoinedSession:session]; });
        return;
    }
    if(self.requestedMode==IFModeNormal || self.hangupRequested) return;
    if(session) self.callSession=session;
    self.participantJoined=YES;
    [self inspectConnectionState];
}
- (void)markConnected {
    if(self.callConnected || self.requestedMode==IFModeNormal || self.hangupRequested) return;
    self.callConnected=YES;
    NSLog(@"[InstaFakeCam] remote connection confirmed; playback permitted");
    [[IFFrameEngine shared] beginPlayback];
    if(self.requestedMode==IFModeDual && self.incomingURL)
        [[IFLocalRemotePreview shared] presentURL:self.incomingURL];
    CFTimeInterval duration=[[IFFrameEngine shared] clipDuration];
    if(isfinite(duration) && duration>0.1) {
        [self.endTimer invalidate];
        self.endTimer=[NSTimer scheduledTimerWithTimeInterval:duration
                       target:self selector:@selector(fakeClipFinished)
                       userInfo:nil repeats:NO];
    }
}
- (void)inspectConnectionState {
    if(self.requestedMode==IFModeNormal || self.callConnected || self.hangupRequested) return;
    id session=self.callSession;
    id manager=self.callManager;
    if(!session && manager && [manager respondsToSelector:@selector(currentSession)]) {
        session=((id(*)(id,SEL))objc_msgSend)(manager,@selector(currentSession));
        if(session) self.callSession=session;
    }
    if(!session) return;

    // Never start during the visible outgoing dial/ring UI.
    if(IFOutgoingCallStillRinging()) return;
    // Restore the previous working session gating path. A remote-join event
    // is used if available; isAnswered plus disappearance of Calling UI is
    // the version-compatible fallback.
    if([session respondsToSelector:@selector(isAnswered)]) {
        BOOL answered=((BOOL(*)(id,SEL))objc_msgSend)(session,@selector(isAnswered));
        if(answered) [self markConnected];
    } else if(self.participantJoined) {
        [self markConnected];
    }
}
- (void)pollConnection:(NSTimer *)timer {
    if(self.requestedMode==IFModeNormal) { [timer invalidate]; self.stateTimer=nil; return; }
    [self inspectConnectionState];
    id manager=self.callManager;
    if(manager && [manager respondsToSelector:@selector(hasActiveCall)]) {
        BOOL active=((BOOL(*)(id,SEL))objc_msgSend)(manager,@selector(hasActiveCall));
        if(!active && (self.callConnected || self.hangupRequested)) {
            [self callDidEnd];
        }
    }
}
- (void)runNative {
    void (^continuation)(void)=[self.nativeContinuation copy];
    self.nativeContinuation=nil;
    gIFCallMenuVisible=NO;
    if(continuation) {
        gIFResumingNativeCall=YES;
        continuation();
        gIFResumingNativeCall=NO;
    }
    if(self.requestedMode!=IFModeNormal) {
        [self.stateTimer invalidate];
        self.stateTimer=[NSTimer scheduledTimerWithTimeInterval:0.25
                   target:self selector:@selector(pollConnection:)
                   userInfo:nil repeats:YES];
    }
}
- (void)beginPicking {
    UIViewController *host=IFPresenter();
    if(!host) { [self reset]; gIFCallMenuVisible=NO; return; }
    PHPickerConfiguration *config=[[PHPickerConfiguration alloc] initWithPhotoLibrary:PHPhotoLibrary.sharedPhotoLibrary];
    config.filter=[PHPickerFilter videosFilter];
    config.selectionLimit=1;
    config.preferredAssetRepresentationMode=PHPickerConfigurationAssetRepresentationModeCurrent;
    PHPickerViewController *picker=[[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate=self;
    [host presentViewController:picker animated:YES completion:nil];
}
- (void)handleSelectedVideoURL:(NSURL *)url error:(NSError *)error {
    if(!url) {
        NSLog(@"[InstaFakeCam] Photos picker copy failed %@",error);
        [self reset]; gIFCallMenuVisible=NO;
        IFShowMessage(@"Video import failed",
                      error.localizedDescription?:@"Please select a video from Photos.");
        return;
    }
    if(self.pickerStep==0) {
        self.outgoingURL=url;
        if(self.requestedMode==IFModeDual) {
            self.pickerStep=1;
            [self beginPicking];
            return;
        }
    } else {
        self.incomingURL=url;
    }
    // Verify the imported video independently of the live camera's format.
    // A malformed/iCloud-incomplete clip must produce a clear error, not a
    // mysteriously black call. Do not block the UI/capture thread during decode.
    NSURL *videoURL=[self.outgoingURL copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        AVURLAsset *asset=[AVURLAsset URLAssetWithURL:videoURL options:nil];
        AVAssetTrack *track=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        NSError *error=nil;
        CGImageRef firstFrame=NULL;
        if(track) {
            AVAssetImageGenerator *generator=[[AVAssetImageGenerator alloc] initWithAsset:asset];
            generator.appliesPreferredTrackTransform=YES;
            generator.requestedTimeToleranceBefore=kCMTimePositiveInfinity;
            generator.requestedTimeToleranceAfter=kCMTimePositiveInfinity;
            firstFrame=[generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:&error];
        }
        BOOL ready=(track && firstFrame);
        if(firstFrame) CGImageRelease(firstFrame);
        dispatch_async(dispatch_get_main_queue(), ^{
            if(!ready) {
                NSLog(@"[InstaFakeCam v%@] invalid selected clip: %@",kIFVersion,error);
                [self reset];
                gIFCallMenuVisible=NO;
                IFShowMessage(@"Selected video cannot be decoded",
                    error.localizedDescription?:@"Try a saved H.264 MP4 video from your Photos library.");
                return;
            }
            NSLog(@"[InstaFakeCam v%@] video import preflight OK: %@",kIFVersion,videoURL.lastPathComponent);
            [[IFFrameEngine shared] arm:videoURL];
            [self runNative];
        });
    });
}
- (void)picker:(PHPickerViewController *)picker
didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:^{
        PHPickerResult *chosen=results.firstObject;
        if(!chosen) { [self reset]; gIFCallMenuVisible=NO; return; }
        NSItemProvider *item=chosen.itemProvider;
        NSString *movieType=UTTypeMovie.identifier;
        if(![item hasItemConformingToTypeIdentifier:movieType]) {
            [self handleSelectedVideoURL:nil error:nil];
            return;
        }
        [item loadFileRepresentationForTypeIdentifier:movieType
                                   completionHandler:^(NSURL *temporary, NSError *error) {
            NSURL *saved=nil;
            if(temporary && !error) {
                NSString *dir=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/InstaFakeCam"];
                [[NSFileManager defaultManager] createDirectoryAtPath:dir
                    withIntermediateDirectories:YES attributes:nil error:NULL];
                NSString *ext=temporary.pathExtension.length?temporary.pathExtension:@"mov";
                saved=[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"%@.%@",NSUUID.UUID.UUIDString,ext]]];
                NSError *copyError=nil;
                if(![[NSFileManager defaultManager] copyItemAtURL:temporary toURL:saved error:&copyError]) {
                    saved=nil;
                    error=copyError;
                }
            }
            NSURL *finalURL=saved;
            NSError *finalError=error;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleSelectedVideoURL:finalURL error:finalError];
            });
        }];
    }];
}
- (void)offerCallOptions:(void (^)(void))nativeContinuation {
    if(gIFCallMenuVisible) return;
    UIViewController *host=IFPresenter();
    if(!host) { if(nativeContinuation)nativeContinuation(); return; }
    gIFCallMenuVisible=YES;
    [self reset];
    self.nativeContinuation=nativeContinuation;
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"InstaFakeCam v0.4.0"
                      message:@"Real video-frame conversion · Photos gallery"
                      preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf=self;
    [menu addAction:[UIAlertAction actionWithTitle:@"Normal video call"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        weakSelf.requestedMode=IFModeNormal;
        [weakSelf runNative];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Fake my camera (Photos)"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        weakSelf.requestedMode=IFModeOutgoing;
        weakSelf.pickerStep=0;
        [weakSelf beginPicking];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Fake both cameras (Photos)"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        weakSelf.requestedMode=IFModeDual;
        weakSelf.pickerStep=0;
        [weakSelf beginPicking];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel"
            style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) {
        [weakSelf reset]; gIFCallMenuVisible=NO;
    }]];
    menu.popoverPresentationController.sourceView=host.view;
    menu.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(host.view.bounds),32,1,1);
    [host presentViewController:menu animated:YES completion:nil];
}
- (void)fakeClipFinished {
    if(self.requestedMode==IFModeNormal || !self.callConnected || self.hangupRequested) return;
    self.hangupRequested=YES;
    [self.endTimer invalidate]; self.endTimer=nil;
    NSLog(@"[InstaFakeCam] selected clip reached its duration; requesting hangup");
    [[IFLocalRemotePreview shared] hide];
    // IMPORTANT: DO NOT call reset here. Keep replacing camera frames with
    // the last video frame or black until native call teardown is confirmed.
    // Discover the LIVE call controller, not just the main scene root.
    // Instagram's 166.0 class-dump exposes _leaveCallWithReason: and
    // videoCallControlsViewDidTapHangUpButton:. Modern versions may rename them.
    BOOL submitted=NO;
    NSMutableArray<UIViewController *> *controllers=[NSMutableArray array];
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class]) continue;
        for(UIWindow *win in ((UIWindowScene *)scene).windows) {
            if(win.hidden || !win.rootViewController) continue;
            [controllers addObject:win.rootViewController];
        }
    }
    for(NSUInteger i=0;i<controllers.count && i<250;i++) {
        UIViewController *vc=controllers[i];
        if(vc.presentedViewController) [controllers addObject:vc.presentedViewController];
        [controllers addObjectsFromArray:vc.childViewControllers];
        NSString *className=NSStringFromClass(vc.class);
        if([className containsString:@"IGVideoCallViewController"] &&
           [vc respondsToSelector:@selector(_leaveCallWithReason:)]) {
            ((void(*)(id,SEL,long long))objc_msgSend)(vc,@selector(_leaveCallWithReason:),0);
            NSLog(@"[InstaFakeCam] requested hangup via %@ _leaveCallWithReason:",className);
            submitted=YES;
            break;
        }
    }
    id manager=self.callManager;
    if(!submitted && manager && [manager respondsToSelector:@selector(leaveCallWithReason:)]) {
        ((void(*)(id,SEL,long long))objc_msgSend)(manager,@selector(leaveCallWithReason:),0);
        NSLog(@"[InstaFakeCam] requested native IGVideoCallManager hangup");
        submitted=YES;
    }
    if(!submitted && manager && [manager respondsToSelector:@selector(callKitCoordinator)]) {
        id coordinator=((id(*)(id,SEL))objc_msgSend)(manager,@selector(callKitCoordinator));
        if([coordinator respondsToSelector:@selector(endCurrentCall)]) {
            ((void(*)(id,SEL))objc_msgSend)(coordinator,@selector(endCurrentCall));
            NSLog(@"[InstaFakeCam] requested CallKit endCurrentCall");
            submitted=YES;
        }
    }
    if(!submitted) {
        for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if(![scene isKindOfClass:UIWindowScene.class]) continue;
            for(UIWindow *win in ((UIWindowScene *)scene).windows) {
                if(win.hidden || !win.rootViewController) continue;
                UIControl *end=IFFindHangup(win.rootViewController.view);
                if(end) {
                    [end sendActionsForControlEvents:UIControlEventTouchUpInside];
                    NSLog(@"[InstaFakeCam] requested hangup from native call button");
                    submitted=YES;
                    break;
                }
            }
            if(submitted) break;
        }
    }
    if(!submitted) {
        IFShowMessage(@"Clip ended — hang up manually",
          @"This Instagram build has a different call-ending API. Camera replacement remains armed to prevent exposure.");
    }
}
@end

// Intercept AVCaptureVideoDataOutput without taking over recording/story cameras
// while the fake-call mode is disabled. Delegate receives a CMSampleBuffer that
// preserves live camera timing and pixel format, but carries frames from a file.
@interface IFCaptureProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) id<AVCaptureVideoDataOutputSampleBufferDelegate> original;
@end
@implementation IFCaptureProxy
- (void)captureOutput:(AVCaptureOutput *)output
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    IFFrameEngine *engine=[IFFrameEngine shared];
    BOOL armed=[engine isArmed];
    CMSampleBufferRef fake=armed?[engine copyReplacementFor:sampleBuffer]:NULL;
    id<AVCaptureVideoDataOutputSampleBufferDelegate> recipient=self.original;
    if([recipient respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        if(!armed) {
            [recipient captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        } else if(fake) {
            [recipient captureOutput:output didOutputSampleBuffer:fake fromConnection:connection];
        } else {
            // Fail CLOSED. Never send the real camera frame when fake is armed
            // even if a video file cannot be decoded or the buffer creation fails.
            NSLog(@"[InstaFakeCam] dropped camera frame because fake output was unavailable");
        }
    }
    if(fake) CFRelease(fake);
}
- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> recipient=self.original;
    if([recipient respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)])
        [recipient captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
}
@end

static const void *kIFCaptureProxyKey=&kIFCaptureProxyKey;

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (!delegate || [delegate isKindOfClass:[IFCaptureProxy class]]) {
        %orig;
        return;
    }
    IFCaptureProxy *proxy=[IFCaptureProxy new];
    proxy.original=delegate;
    objc_setAssociatedObject(self,kIFCaptureProxyKey,proxy,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(proxy,queue);
}
%end

// Calls are connected independently of camera capture. Classes/selectors are
// derived from public Instagram class-dumped headers; availability varies by build.
%hook IGVideoCallManager
- (void)startCallSession:(id)session completion:(id)completion {
    [[IFCallCoordinator shared] observeManager:self session:session];
    %orig;
}
- (void)startCallWithActivity:(id)activity {
    [[IFCallCoordinator shared] observeManager:self session:nil];
    %orig;
}
- (void)videoCallSession:(id)session participantDidJoin:(id)participant
             isFirstJoin:(BOOL)first videoView:(id)view
             videoState:(long long)state audioEnabled:(BOOL)enabled
             isExistingParticipant:(BOOL)existing {
    %orig;
    [[IFCallCoordinator shared] observeManager:self session:session];
    [[IFCallCoordinator shared] participantJoinedSession:session];
}
- (void)videoCallControllerDidEnd:(id)controller reasonCallEnded:(BOOL)reason {
    %orig;
    [[IFCallCoordinator shared] callDidEnd];
}
- (void)leaveCallWithReason:(long long)reason {
    // A call-end request is asynchronous. Keep substituting virtual frames
    // until actual RTC teardown; resetting here exposes the real camera.
    %orig;
}
%end

// Session's didAddParticipant can include the local user or signaling-only
// participants. It is intentionally NOT treated as remote acceptance.
%hook IGVideoCallViewController
- (void)videoCallSession:(id)session participantDidJoin:(id)participant
             isFirstJoin:(BOOL)first videoView:(id)view
             videoState:(long long)state audioEnabled:(BOOL)enabled
             isExistingParticipant:(BOOL)existing {
    %orig;
    [[IFCallCoordinator shared] participantJoinedSession:session];
}
%end

// Confirmed open-source Instagram hook points from sparkle-ig's CallConfirm.x.
// Both signatures occur across Instagram versions.
%hook IGDirectThreadCallButtonsCoordinator
- (void)_didTapVideoButton {
    if(gIFResumingNativeCall) { %orig; return; }
    [[IFCallCoordinator shared] offerCallOptions:^{ %orig; }];
}
- (void)_didTapVideoButton:(id)button {
    if(gIFResumingNativeCall) { %orig; return; }
    [[IFCallCoordinator shared] offerCallOptions:^{ %orig; }];
}
%end

%ctor {
    if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.burbn.instagram"]) {
        NSLog(@"[InstaFakeCam v%@] injected into Instagram; menu must show v0.4.0",kIFVersion);
    }
}
