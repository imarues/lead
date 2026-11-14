// Lead virtual video call - experimental private call video source.
// Selection occurs before dialing. No virtual frames or audio are sent until
// tgcalls reports OngoingCallStateConnected. No ordinary microphone fallback.
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
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
#include <cstring>

namespace {
struct AudioClip { std::vector<int16_t> samples; };
static std::shared_ptr<AudioClip> gPCM;
static std::atomic<int> gMode{0}; // 0 normal, 1 armed/ringing, 2 connected/playing, 3 finished/muted
static std::atomic<bool> gExpectCapturer{false};
static std::atomic<bool> gConnected{false};
static std::atomic<double> gStartClock{0};
static std::atomic<bool> gExternalAudio{false};
static bool gNativeHooksReady=false;
static id (*gNativeInit)(id,SEL,NSString *,bool)=nullptr;
typedef void (^LeadStateBlock)(int32_t,int32_t,int32_t,int32_t,int32_t,float);
static void (*gNativeStateSetter)(id,SEL,LeadStateBlock)=nullptr;
static void (*gNativeRequestVideo)(id,SEL,id)=nullptr;
extern "C" void objc_release(id);
}

@interface LeadVirtualClip : NSObject
@property(nonatomic,strong) AVAssetReader *reader;
@property(nonatomic,strong) AVAssetReaderTrackOutput *frames;
@property(nonatomic,assign) CMSampleBufferRef current;
@property(nonatomic,assign) CMSampleBufferRef next;
@property(nonatomic,assign) BOOL exhausted;
@property(nonatomic,assign) NSTimeInterval duration;
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
@property(nonatomic,strong) NSURL *selectedURL;
@property(nonatomic,assign) uint64_t nextAudioSample;
@property(nonatomic,assign) dispatch_source_t playbackTimer;
+ (instancetype)shared;
- (void)preparePicker:(void(^)(BOOL))completion;
- (void)resetAll;
- (void)nativeCapturerReady:(id)capturer;
- (void)nativeContextReady:(id)context;
- (void)nativeState:(int32_t)state;
- (BOOL)installNativeHooks;
- (void)showError:(NSString *)message;
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
                return custom;
            }
        }
        NSLog(@"[LeadVirtualMedia] external video factory unavailable");
    }
    return gNativeInit ? gNativeInit(self,command,deviceId,keepLandscape) : self;
}
static void LeadSetNativeCallState(id self, SEL command, LeadStateBlock block) {
    LeadStateBlock original=[block copy];
    LeadStateBlock wrapped=^(int32_t state,int32_t v,int32_t rv,int32_t ra,int32_t b,float aspect) {
        [[LeadVirtualMedia shared] nativeState:state];
        if(original)original(state,v,rv,ra,b,aspect);
    };
    if(gNativeStateSetter)gNativeStateSetter(self,command,wrapped);
}
static void LeadRequestNativeVideo(id self, SEL command, id capturer) {
    [[LeadVirtualMedia shared] nativeContextReady:self];
    if(gNativeRequestVideo)gNativeRequestVideo(self,command,capturer);
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
        if(!c || !w || !init || !state || !req || ![c respondsToSelector:factory]) {
            NSLog(@"[LeadVirtualMedia] native capturer/state API not found in installed Telegram");
            return NO;
        }
        gNativeInit=(decltype(gNativeInit))method_setImplementation(init,(IMP)LeadInitNativeVideoCapturer);
        gNativeStateSetter=(decltype(gNativeStateSetter))method_setImplementation(state,(IMP)LeadSetNativeCallState);
        gNativeRequestVideo=(decltype(gNativeRequestVideo))method_setImplementation(req,(IMP)LeadRequestNativeVideo);
        gNativeHooksReady=true;
        return YES;
    }
}
- (void)stopTimer {
    if(self.playbackTimer){dispatch_source_cancel(self.playbackTimer);self.playbackTimer=nil;}
}
- (void)resetAll {
    gMode.store(0);
    gExpectCapturer.store(false);
    gConnected.store(false);
    gStartClock.store(0);
    gExternalAudio.store(false);
    std::atomic_store(&gPCM,std::shared_ptr<AudioClip>());
    [self stopTimer];
    @synchronized(self) {
        self.clip=nil;self.externalCapturer=nil;self.nativeCallContext=nil;self.nextAudioSample=0;
        if(self.selectedURL)[[NSFileManager defaultManager] removeItemAtURL:self.selectedURL error:nil];
        self.selectedURL=nil;
    }
}
- (void)finishPicker:(BOOL)success {
    dispatch_async(dispatch_get_main_queue(),^{
        void (^call)(BOOL)=self.pendingCall;
        self.pendingCall=nil;
        if(!success)[self resetAll];
        if(call)call(success);
    });
}
- (void)preparePicker:(void(^)(BOOL))completion {
    [self resetAll];
    self.pendingCall=[completion copy];
    if(![self installNativeHooks]) {
        [self showError:@"هذا إصدار Telegram ما يعرض واجهة بث الفيديو الخارجية المطلوبة. تم إلغاء الاتصال بدلاً من إرسال كاميرا حقيقية بالغلط."];
        [self finishPicker:NO];
        return;
    }
    UIViewController *host=[self host];
    if(!host){[self finishPicker:NO];return;}
    PHPickerConfiguration *conf=[[PHPickerConfiguration alloc] init];
    conf.filter=[PHPickerFilter videosFilter];conf.selectionLimit=1;
    PHPickerViewController *picker=[[PHPickerViewController alloc] initWithConfiguration:conf];
    picker.delegate=self;
    [host presentViewController:picker animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if(!results.count){[self finishPicker:NO];return;}
    NSItemProvider *item=results.firstObject.itemProvider;
    if(![item hasItemConformingToTypeIdentifier:@"public.movie"]) {
        [self showError:@"اختَر ملف فيديو من المعرض."];
        [self finishPicker:NO];return;
    }
    [item loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *url,NSError *error) {
        if(error || !url) {
            [self showError:error.localizedDescription?:@"فشل قراءة الفيديو."];
            [self finishPicker:NO];return;
        }
        NSURL *copy=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"lead-call-%@.mov",NSUUID.UUID.UUIDString]]];
        NSError *copyError=nil;
        [[NSFileManager defaultManager] copyItemAtURL:url toURL:copy error:&copyError];
        if(copyError) {
            [self showError:copyError.localizedDescription];
            [self finishPicker:NO];return;
        }
        self.selectedURL=copy;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{[self decodeMovie:copy];});
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
    AVAssetReader *vr=[[AVAssetReader alloc] initWithAsset:asset error:&error];
    if(!vr){[self showError:@"فشل فتح مسار الفيديو."];[self finishPicker:NO];return;}
    AVAssetReaderTrackOutput *vo=[[AVAssetReaderTrackOutput alloc] initWithTrack:v
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
    vo.alwaysCopiesSampleData=NO;[vr addOutput:vo];
    if(![vr startReading]){[self showError:@"فشل فك إطارات الفيديو."];[self finishPicker:NO];return;}
    LeadVirtualClip *video=[LeadVirtualClip new];
    video.reader=vr;video.frames=vo;video.duration=duration;
    @synchronized(self) {
        self.clip=video;self.nextAudioSample=0;
        std::atomic_store(&gPCM,clipSound);
        gStartClock.store(0);gConnected.store(false);
        gExpectCapturer.store(true);
        gMode.store(1); // Ready; nothing transmitted until connected.
    }
    NSLog(@"[LeadVirtualMedia] file prepared, now dialing real Telegram video call");
    [self finishPicker:YES];
}
- (void)nativeCapturerReady:(id)capturer {
    @synchronized(self){self.externalCapturer=capturer;}
    [self maybeStart];
}
- (void)nativeContextReady:(id)context {
    if(gMode.load()==0)return;
    @synchronized(self){self.nativeCallContext=context;}
    [self maybeStart];
}
- (void)nativeState:(int32_t)state {
    // WebRTC: 0 initializing, 1 connected (answered), 2 failed, 3 reconnecting.
    if(gMode.load()==0)return;
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
    if(!gConnected.load() || gMode.load()!=1)return;
    id captured=nil;
    @synchronized(self){captured=self.externalCapturer;}
    if(!captured)return;
    int old=1;if(!gMode.compare_exchange_strong(old,2))return;
    gStartClock.store(CACurrentMediaTime());
    gExternalAudio.store(false);
    self.nextAudioSample=0;
    dispatch_queue_t queue=dispatch_queue_create("lead.virtual.call.frames",DISPATCH_QUEUE_SERIAL);
    self.playbackTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
    dispatch_source_set_timer(self.playbackTimer,dispatch_time(DISPATCH_TIME_NOW,0),
        (uint64_t)(0.020*NSEC_PER_SEC),(uint64_t)(0.004*NSEC_PER_SEC));
    dispatch_source_set_event_handler(self.playbackTimer,^{[self playbackTick];});
    dispatch_resume(self.playbackTimer);
}
- (void)playbackTick {
    if(gMode.load()!=2)return;
    LeadVirtualClip *video=nil;id capturer=nil;id context=nil;
    @synchronized(self) {video=self.clip;capturer=self.externalCapturer;context=self.nativeCallContext;}
    if(!video || !capturer)return;
    double elapsed=CACurrentMediaTime()-gStartClock.load();
    if(elapsed>=video.duration) {
        gMode.store(3);[self stopTimer];
        if([capturer respondsToSelector:@selector(setIsVideoEnabled:)]) {
            ((void (*)(id,SEL,bool))objc_msgSend)(capturer,@selector(setIsVideoEnabled:),false);
        }
        NSLog(@"[LeadVirtualMedia] movie completed; outgoing audio remains muted");
        dispatch_async(dispatch_get_main_queue(),^{
           [self showError:@"انتهى الفيديو وتوقف بثه. المكالمة مستمرة والمايك مكتوم."];
        });
        return;
    }
    if(context && [context respondsToSelector:@selector(addExternalAudioData:)]) {
        auto pcm=std::atomic_load(&gPCM);
        if(pcm && !pcm->samples.empty()) {
            // ReplayKit uses the same 48k mono 16-bit PCM for this native method.
            int16_t buffer[960]={};
            const size_t offset=(size_t)self.nextAudioSample;
            const size_t available= offset<pcm->samples.size() ? pcm->samples.size()-offset:0;
            const size_t n=std::min((size_t)960,available);
            if(n)memcpy(buffer,pcm->samples.data()+offset,n*2);
            NSData *data=[NSData dataWithBytes:buffer length:sizeof(buffer)];
            ((void (*)(id,SEL,id))objc_msgSend)(context,@selector(addExternalAudioData:),data);
            self.nextAudioSample+=960;
            gExternalAudio.store(true);
        }
    }
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
        // Native tgcalls custom provider sends this frame to the remote peer.
        ((void (*)(id,SEL,CMSampleBufferRef,int,void(^)(void)))objc_msgSend)(
            capturer,@selector(submitSampleBuffer:rotation:completion:),video.current,0,^{});
    }
}
@end

// Retain existing CoreAudio audio path only as fallback when native external
// audio cannot be obtained. Any selected file suppresses genuine microphone.
extern "C" bool LeadVirtualMediaReplaceMic(AudioBufferList *buffers,
                 const AudioStreamBasicDescription *format, UInt32 frames) {
    if(gMode.load()==0)return false;
    if(!buffers || !format)return true;
    const bool flt=(format->mFormatFlags & kAudioFormatFlagIsFloat)!=0;
    const bool integer=(format->mFormatFlags & kAudioFormatFlagIsSignedInteger)!=0;
    const bool planar=(format->mFormatFlags & kAudioFormatFlagIsNonInterleaved)!=0;
    const unsigned bits=format->mBitsPerChannel;
    const unsigned channels=std::max(1u,format->mChannelsPerFrame);
    const double rate=format->mSampleRate;
    const bool supported=(flt && bits==32)||(integer && (bits==16 || bits==32));
    auto pcm=std::atomic_load(&gPCM);
    const double start=gStartClock.load();
    bool play=(gMode.load()==2 && !gExternalAudio.load() && start>0 &&
        isfinite(rate) && rate>=8000 && rate<=192000 && pcm && !pcm->samples.empty());
    double position=play?std::max(0.0,CACurrentMediaTime()-start):0;
    for(UInt32 b=0;b<buffers->mNumberBuffers;b++) {
        AudioBuffer &buf=buffers->mBuffers[b];
        if(!buf.mData)continue;
        if(!play || !supported){memset(buf.mData,0,buf.mDataByteSize);continue;}
        const unsigned countPerFrame=planar?1:channels;
        const unsigned unit=bits/8;
        const UInt32 limit=std::min(frames,buf.mDataByteSize/std::max(1u,countPerFrame*unit));
        for(UInt32 i=0;i<limit;i++) {
            uint64_t idx=(uint64_t)((position+i/rate)*48000.0);
            float f=(idx<pcm->samples.size())?pcm->samples[(size_t)idx]/32768.0f:0;
            for(unsigned c=0;c<countPerFrame;c++) {
                size_t j=(size_t)i*countPerFrame+c;
                if(flt)((float *)buf.mData)[j]=f;
                else if(bits==16)((int16_t *)buf.mData)[j]=(int16_t)lrintf(f*32767);
                else ((int32_t *)buf.mData)[j]=(int32_t)llrint((double)f*2147483647.0);
            }
        }
        size_t bytes=(size_t)limit*countPerFrame*unit;
        if(bytes<buf.mDataByteSize)memset((uint8_t *)buf.mData+bytes,0,buf.mDataByteSize-bytes);
    }
    return true;
}

extern "C" void LeadVirtualMediaPrepareVideoCall(void (^completion)(BOOL)) {
    dispatch_async(dispatch_get_main_queue(),^{[[LeadVirtualMedia shared] preparePicker:completion];});
}
extern "C" void LeadVirtualMediaReset(void) {
    dispatch_async(dispatch_get_main_queue(),^{[[LeadVirtualMedia shared] resetAll];});
}
// Remove the old VID overlay. All selection is now before the outgoing call.
extern "C" void LeadVirtualMediaInstallButton(__unused UIView *view) {}
extern "C" void LeadVirtualMediaRemoveButton(__unused UIView *view) {}
