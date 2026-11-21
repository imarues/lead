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
@property (nonatomic, strong) AVAssetReaderTrackOutput *output;
@property (nonatomic, strong) AVAssetTrack *track;
@property (nonatomic, strong) CIContext *context;
@property (nonatomic, assign) CMSampleBufferRef held;
@property (nonatomic, assign) CMSampleBufferRef next;
@property (nonatomic, assign) CMTime origin;
@property (nonatomic, assign) NSInteger pixelWidth;
@property (nonatomic, assign) NSInteger pixelHeight;
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
    self.pixelWidth=0; self.pixelHeight=0;
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
- (BOOL)prepareForWidth:(size_t)w height:(size_t)h {
    if (self.reader && self.pixelWidth == w && self.pixelHeight == h) return YES;
    if (!self.url) return NO;
    [self clearReaderLocked];
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:self.url options:nil];
    AVAssetTrack *track=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if(!track) { NSLog(@"[InstaFakeCam] clip contains no video track"); return NO; }
    NSError *error=nil;
    AVAssetReader *reader=[AVAssetReader assetReaderWithAsset:asset error:&error];
    if(!reader) { NSLog(@"[InstaFakeCam] asset reader %@",error); return NO; }
    AVAssetReaderTrackOutput *output=[AVAssetReaderTrackOutput
         assetReaderTrackOutputWithTrack:track
         outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
    output.alwaysCopiesSampleData=NO;
    if (![reader canAddOutput:output]) return NO;
    [reader addOutput:output];
    if (![reader startReading]) {
        NSLog(@"[InstaFakeCam] startReading failed %@",reader.error);
        return NO;
    }
    self.reader=reader; self.output=output; self.track=track;
    self.pixelWidth=w; self.pixelHeight=h;
    self.duration=CMTimeGetSeconds(asset.duration);
    self.next=[output copyNextSampleBuffer];
    return self.next != NULL;
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
    BOOL readerReady=[self prepareForWidth:w height:h];
    CMTime captureTime=CMSampleBufferGetPresentationTimeStamp(input);
    CMTime elapsed=kCMTimeInvalid;
    if (self.playing && !self.finished && readerReady) {
        if (!CMTIME_IS_NUMERIC(self.origin)) self.origin=captureTime;
        elapsed=CMTimeSubtract(captureTime,self.origin);
        if (CMTIME_IS_NUMERIC(elapsed)) {
            while (self.next &&
                   CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(self.next),elapsed) <= 0) {
                if(self.held) CFRelease(self.held);
                self.held=self.next;
                self.next=[self.output copyNextSampleBuffer];
            }
            if (!self.held && self.next) {
                self.held=self.next;
                self.next=[self.output copyNextSampleBuffer];
            }
        }
    }
    // If the session was accepted but a sample is temporarily unavailable,
    // output black rather than any authentic camera pixels.
    BOOL renderClip=self.playing && self.held!=NULL;

    // Always output a replacement frame while armed: if decoding fails, use black,
    // rather than briefly leaking the real camera image to the recipient.
    CIImage *image=nil;
    if (renderClip) {
        CVImageBufferRef media=CMSampleBufferGetImageBuffer(self.held);
        if(media) {
            image=[CIImage imageWithCVPixelBuffer:media];
            CGAffineTransform preferred=self.track.preferredTransform;
            image=[image imageByApplyingTransform:preferred];
            CGRect ext=image.extent;
            image=[image imageByApplyingTransform:CGAffineTransformMakeTranslation(-ext.origin.x,-ext.origin.y)];
            ext=image.extent;
            if(ext.size.width>0 && ext.size.height>0) {
                CGFloat scale=MAX((CGFloat)w/ext.size.width,(CGFloat)h/ext.size.height);
                image=[image imageByApplyingTransform:CGAffineTransformMakeScale(scale,scale)];
                CGRect scaled=image.extent;
                image=[image imageByApplyingTransform:
                       CGAffineTransformMakeTranslation(((CGFloat)w-scaled.size.width)/2.0,
                                                        ((CGFloat)h-scaled.size.height)/2.0)];
            }
        }
    }
    if(!image) image=[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]];

    CVPixelBufferRef target=NULL;
    OSType format=CVPixelBufferGetPixelFormatType(source);
    NSDictionary *attributes=@{
       (id)kCVPixelBufferIOSurfacePropertiesKey:@{},
       (id)kCVPixelBufferCGImageCompatibilityKey:@YES,
       (id)kCVPixelBufferCGBitmapContextCompatibilityKey:@YES
    };
    CVReturn result=CVPixelBufferCreate(kCFAllocatorDefault,w,h,format,
                                       (__bridge CFDictionaryRef)attributes,&target);
    if(result!=kCVReturnSuccess || !target) {
        NSLog(@"[InstaFakeCam] CVPixelBufferCreate failed %d",result);
        [self.lock unlock];
        return NULL;
    }
    CGColorSpaceRef rgb=CGColorSpaceCreateDeviceRGB();
    [self.context render:image toCVPixelBuffer:target
                 bounds:CGRectMake(0,0,w,h) colorSpace:rgb];
    CGColorSpaceRelease(rgb);

    CMVideoFormatDescriptionRef description=NULL;
    CMSampleBufferRef outputBuffer=NULL;
    OSStatus status=CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,target,&description);
    if(status==noErr && description) {
        CMSampleTimingInfo timing={kCMTimeInvalid,kCMTimeInvalid,kCMTimeInvalid};
        CMSampleBufferGetSampleTimingInfo(input,0,&timing);
        status=CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,target,YES,NULL,NULL,
                                                  description,&timing,&outputBuffer);
    }
    if(description) CFRelease(description);
    CVPixelBufferRelease(target);

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
    if(self.requestedMode==IFModeNormal && ![[IFFrameEngine shared] isArmed])
        return;
    NSLog(@"[InstaFakeCam] native call ended; resetting media");
    [self reset];
}
- (void)observeManager:(id)manager session:(id)session {
    if(self.requestedMode==IFModeNormal) return;
    if(manager) self.callManager=manager;
    if(session) self.callSession=session;
    [self inspectConnectionState];
}
- (void)participantJoinedSession:(id)session {
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

    // isAnswered belongs to IGVideoCallSession, not local camera capture.
    // The call needs an actual answered state (or the observed remote-join
    // callback on Instagram versions where this selector no longer exists).
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
    [[IFFrameEngine shared] arm:self.outgoingURL];
    [self runNative];
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
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"Instagram Video Call"
                      message:@"Choose your camera source"
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
    id manager=self.callManager;
    if(manager && [manager respondsToSelector:@selector(leaveCallWithReason:)]) {
        ((void(*)(id,SEL,long long))objc_msgSend)(manager,
                       @selector(leaveCallWithReason:), 0);
        NSLog(@"[InstaFakeCam] requested native IGVideoCallManager hangup");
        return;
    }
    UIWindow *main=IFMainWindow();
    UIControl *end=IFFindHangup(main.rootViewController.view);
    if(end) {
        [end sendActionsForControlEvents:UIControlEventTouchUpInside];
        NSLog(@"[InstaFakeCam] sent End Call UI control event");
    } else {
        IFShowMessage(@"Video finished",
          @"Automatic hangup is unavailable in this Instagram version. End the call manually; the real camera stays blocked.");
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
    %orig;
    [[IFCallCoordinator shared] callDidEnd];
}
%end

%hook IGVideoCallSession
- (void)videoCallController:(id)controller didAddParticipant:(id)participant
      isExistingParticipant:(BOOL)existing {
    %orig;
    [[IFCallCoordinator shared] participantJoinedSession:self];
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
        NSLog(@"[InstaFakeCam] injected into Instagram; waiting for Direct video call");
    }
}
