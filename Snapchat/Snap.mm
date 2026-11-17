#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#include <atomic>
#include <algorithm>
#include <cmath>
#import "Media.h"

// Adapter verified against the supplied executable, CFBundleVersion 12.81.0.47.
// All real camera/audio buffers pass through unchanged outside a selected call.
static std::atomic<int> mode{0}; // idle, waiting for answer, playing, ending
static std::atomic<unsigned> audioReaders{0};
static std::atomic<double> startTime{0};
static std::atomic<unsigned long> videoHits{0}, audioHits{0};
static const int16_t *pcm = nullptr;
static size_t pcmCount = 0;
static os_unfair_lock pixelLock = OS_UNFAIR_LOCK_INIT;
static CVPixelBufferRef currentPixel = nullptr, blackPixel = nullptr;
static void PublishPixel(CVPixelBufferRef pixel) {
    if(pixel) CVPixelBufferRetain(pixel);
    os_unfair_lock_lock(&pixelLock);
    CVPixelBufferRef previous=currentPixel; currentPixel=pixel;
    os_unfair_lock_unlock(&pixelLock);
    if(previous) CVPixelBufferRelease(previous);
}
static id Obj(id x, NSString *s) {
    SEL sel=NSSelectorFromString(s);
    return x && [x respondsToSelector:sel] ? ((id(*)(id,SEL))objc_msgSend)(x,sel) : nil;
}
static NSInteger Num(id x, NSString *s) {
    SEL sel=NSSelectorFromString(s);
    return x && [x respondsToSelector:sel] ? ((NSInteger(*)(id,SEL))objc_msgSend)(x,sel) : 0;
}
static BOOL Flag(id x, NSString *s) {
    SEL sel=NSSelectorFromString(s);
    return x && [x respondsToSelector:sel] ? ((BOOL(*)(id,SEL))objc_msgSend)(x,sel) : NO;
}
static void Void(id x, NSString *s) {
    SEL sel=NSSelectorFromString(s);
    if(x && [x respondsToSelector:sel]) ((void(*)(id,SEL))objc_msgSend)(x,sel);
}
static UIViewController *Host(void) {
    UIWindow *window=nil;
    for(UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if(s.activationState!=UISceneActivationStateForegroundActive || ![s isKindOfClass:UIWindowScene.class])continue;
        for(UIWindow *w in ((UIWindowScene *)s).windows)if(w.isKeyWindow){window=w;break;}
    }
    UIViewController *v=window.rootViewController;
    while(v) {
        if(v.presentedViewController){v=v.presentedViewController;continue;}
        if([v isKindOfClass:UINavigationController.class]){v=((UINavigationController*)v).visibleViewController;continue;}
        if([v isKindOfClass:UITabBarController.class]){v=((UITabBarController*)v).selectedViewController;continue;}
        break;
    }
    return v;
}
static void Alert(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *h=Host(); if(!h)return;
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Snap" message:message preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleDefault handler:nil]];
        [h presentViewController:a animated:YES completion:nil];
    });
}
@interface SnapMedia : NSObject <PHPickerViewControllerDelegate>
@property(nonatomic) BOOL busy;
@property(nonatomic,copy) void (^launch)(void);
@property(nonatomic,copy) NSString *conversation;
@property(nonatomic,strong) id wrapper;
@property(nonatomic,strong) NSURL *movieURL;
@property(nonatomic,strong) NSURL *pcmURL;
@property(nonatomic,strong) AVAssetReader *reader;
@property(nonatomic,strong) AVAssetReaderVideoCompositionOutput *video;
@property(nonatomic,strong) dispatch_queue_t decodeQueue;
@property(nonatomic,strong) dispatch_source_t timer;
@property(nonatomic,strong) dispatch_source_t watchdog;
@property(nonatomic) double duration;
@property(nonatomic) BOOL everActive;
- (void)choose:(void(^)(void))launch conversation:(NSString *)conversation;
- (void)prepare:(NSURL *)url;
- (void)state:(id)state wrapper:(id)wrapper;
- (void)beginPlayback;
- (void)endCall;
- (void)reset;
- (void)failed:(NSString *)message;
@end
static SnapMedia *Media(void) {static SnapMedia *m;static dispatch_once_t once;dispatch_once(&once,^{m=[SnapMedia new];m.decodeQueue=dispatch_queue_create("plus.ikira.snap.decode",DISPATCH_QUEUE_SERIAL);});return m;}

bool SnapReplaceMic(AudioBufferList *buffers,const AudioStreamBasicDescription *f,UInt32 frames) {
    audioReaders.fetch_add(1);
    int state=mode.load();
    if(!state || !buffers){audioReaders.fetch_sub(1);return false;}
    audioHits.fetch_add(1,std::memory_order_relaxed);
    const bool valid=f && f->mFormatID==kAudioFormatLinearPCM && f->mSampleRate>=8000 && f->mSampleRate<=192000;
    const bool flt=valid && (f->mFormatFlags&kAudioFormatFlagIsFloat) && f->mBitsPerChannel==32;
    const bool sint=valid && (f->mFormatFlags&kAudioFormatFlagIsSignedInteger) && (f->mBitsPerChannel==16 || f->mBitsPerChannel==32);
    double t=state==2?std::max(0.0,CACurrentMediaTime()-startTime.load()):0;
    for(UInt32 j=0;j<buffers->mNumberBuffers;j++) {
        AudioBuffer &b=buffers->mBuffers[j];if(!b.mData)continue;
        memset(b.mData,0,b.mDataByteSize);
        if(state!=2 || !pcm || !(flt||sint))continue;
        UInt32 channels=std::max(1u,b.mNumberChannels), bytes=f->mBitsPerChannel/8;
        UInt32 count=std::min(frames,b.mDataByteSize/(channels*bytes));
        for(UInt32 i=0;i<count;i++) {
            double at=(t+(double)i/f->mSampleRate)*48000.0;
            size_t index=(size_t)at;
            float value=0;
            if(index<pcmCount) {
                float a=pcm[index]/32768.f,b2=index+1<pcmCount?pcm[index+1]/32768.f:a;
                value=a+(b2-a)*(float)(at-index);
            }
            for(UInt32 c=0;c<channels;c++) {
                size_t n=(size_t)i*channels+c;
                if(flt)((float*)b.mData)[n]=value;
                else if(bytes==2)((int16_t*)b.mData)[n]=(int16_t)lrintf(value*32767.f);
                else ((int32_t*)b.mData)[n]=(int32_t)llrint((double)value*2147483647.0);
            }
        }
    }
    audioReaders.fetch_sub(1);return true;
}

@implementation SnapMedia
- (void)choose:(void(^)(void))launch conversation:(NSString *)conversation {
    if(self.busy || mode.load())return;
    self.busy=YES; self.launch=launch;self.conversation=conversation;
    PHPickerConfiguration *config=[[PHPickerConfiguration alloc] init];
    config.filter=PHPickerFilter.videosFilter;config.selectionLimit=1;
    config.preferredAssetRepresentationMode=PHPickerConfigurationAssetRepresentationModeCurrent;
    PHPickerViewController *picker=[[PHPickerViewController alloc] initWithConfiguration:config];picker.delegate=self;
    UIViewController *h=Host();if(!h){[self reset];return;}
    [h presentViewController:picker animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    if(!results.count){[picker dismissViewControllerAnimated:YES completion:^{[self reset];}];return;}
    NSItemProvider *provider=results.firstObject.itemProvider;
    [provider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL *url,NSError *error){
        NSURL *copy=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"snap-%@.mov",NSUUID.UUID.UUIDString]]];
        NSError *copyError=nil;
        BOOL ok=url && [[NSFileManager defaultManager] copyItemAtURL:url toURL:copy error:&copyError];
        dispatch_async(dispatch_get_main_queue(),^{
            [picker dismissViewControllerAnimated:YES completion:^{
                if(!ok){[self reset];Alert(@"تعذر فتح الفيديو. حاول اختيار ملف محمّل على الجهاز.");return;}
                self.movieURL=copy;
                UIAlertController *progress=[UIAlertController alertControllerWithTitle:@"جارٍ تجهيز الفيديو…" message:@"يبدأ الاتصال بعد التجهيز" preferredStyle:UIAlertControllerStyleAlert];
                UIViewController *host=Host();
                [host presentViewController:progress animated:YES completion:^{
                    dispatch_async(self.decodeQueue,^{[self prepare:copy];});
                }];
                if(!host){[self reset];}
            }];
        });
    }];
}
- (void)prepare:(NSURL *)url {
    @autoreleasepool {
        NSError *error=nil;
        AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:nil];
        AVAssetTrack *track=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        double duration=CMTimeGetSeconds(asset.duration);
        if(!track || !std::isfinite(duration) || duration<=0 || duration>3600){[self failed:@"اختار فيديو صالح مدته أقل من ساعة."];return;}
        AVAssetReader *reader=[[AVAssetReader alloc] initWithAsset:asset error:&error];
        AVMutableVideoComposition *composition=[AVMutableVideoComposition videoCompositionWithPropertiesOfAsset:asset];
        CGSize size=composition.renderSize;
        if(size.width<2 || size.height<2 || size.width>8192 || size.height>8192){[self failed:@"أبعاد الفيديو غير مدعومة."];return;}
        composition.renderSize=CGSizeMake(floor(size.width/2)*2,floor(size.height/2)*2);
        AVAssetReaderVideoCompositionOutput *output=[[AVAssetReaderVideoCompositionOutput alloc] initWithVideoTracks:@[track] videoSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
        output.videoComposition=composition;output.alwaysCopiesSampleData=NO;
        if(![reader canAddOutput:output]){[self failed:@"تعذر تجهيز صورة الفيديو."];return;}
        [reader addOutput:output];
        if(![reader startReading]){[self failed:@"تعذر فك ترميز الفيديو."];return;}
        CMSampleBufferRef first=[output copyNextSampleBuffer];
        if(!first){[self failed:@"الفيديو ما يحتوي إطارات قابلة للقراءة."];return;}
        CVPixelBufferRef p=CMSampleBufferGetImageBuffer(first);PublishPixel(p);
        CVPixelBufferRef black=nullptr;
        CVReturn cv=CVPixelBufferCreate(kCFAllocatorDefault,CVPixelBufferGetWidth(p),CVPixelBufferGetHeight(p),kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}},&black);
        if(cv==kCVReturnSuccess) {
            CVPixelBufferLockBaseAddress(black,0);
            for(size_t plane=0;plane<CVPixelBufferGetPlaneCount(black);plane++)memset(CVPixelBufferGetBaseAddressOfPlane(black,plane),plane?128:16,CVPixelBufferGetBytesPerRowOfPlane(black,plane)*CVPixelBufferGetHeightOfPlane(black,plane));
            CVPixelBufferUnlockBaseAddress(black,0);
            os_unfair_lock_lock(&pixelLock);blackPixel=black;os_unfair_lock_unlock(&pixelLock);
        }
        CFRelease(first);
        self.reader=reader;self.video=output;self.duration=duration;
        AVAssetTrack *audio=[asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
        if(audio) {
            NSURL *pcmURL=[url URLByAppendingPathExtension:@"pcm"];
            self.pcmURL=pcmURL;
            int fd=open(pcmURL.fileSystemRepresentation,O_CREAT|O_TRUNC|O_RDWR,0600);
            if(fd<0){[self failed:@"ماكو مساحة كافية لتجهيز الصوت."];return;}
            AVAssetReader *ar=[[AVAssetReader alloc] initWithAsset:asset error:&error];
            AVAssetReaderTrackOutput *ao=[[AVAssetReaderTrackOutput alloc] initWithTrack:audio outputSettings:@{AVFormatIDKey:@(kAudioFormatLinearPCM),AVSampleRateKey:@48000,AVNumberOfChannelsKey:@1,AVLinearPCMBitDepthKey:@16,AVLinearPCMIsFloatKey:@NO,AVLinearPCMIsBigEndianKey:@NO,AVLinearPCMIsNonInterleaved:@NO}];
            BOOL ok=[ar canAddOutput:ao];if(ok){[ar addOutput:ao];ok=[ar startReading];}
            size_t end=0;
            while(ok && ar.status==AVAssetReaderStatusReading) {
                CMSampleBufferRef sample=[ao copyNextSampleBuffer];if(!sample)break;
                CMBlockBufferRef block=CMSampleBufferGetDataBuffer(sample);
                size_t length=block?CMBlockBufferGetDataLength(block):0;
                double seconds=CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
                size_t offset=std::isfinite(seconds)?(size_t)llround(std::max(0.0,seconds)*48000)*2:end;
                if(offset+length>3601ULL*48000*2){ok=NO;CFRelease(sample);break;}
                NSMutableData *chunk=[NSMutableData dataWithLength:length];
                if(length && CMBlockBufferCopyDataBytes(block,0,length,chunk.mutableBytes)==noErr) {
                    size_t written=0;
                    while(written<length){ssize_t n=pwrite(fd,(const char*)chunk.bytes+written,length-written,offset+written);if(n<=0){ok=NO;break;}written+=(size_t)n;}
                    end=std::max(end,offset+written);
                } else if(length)ok=NO;
                CFRelease(sample);
            }
            ok=ok && ar.status==AVAssetReaderStatusCompleted && end>0;
            if(ok){void *map=mmap(nullptr,end,PROT_READ,MAP_PRIVATE,fd,0);ok=map!=MAP_FAILED;if(ok){pcm=(const int16_t*)map;pcmCount=end/2;}}
            close(fd);
            if(!ok){[self failed:@"تعذر تجهيز صوت الفيديو."];return;}
        }
        dispatch_async(dispatch_get_main_queue(),^{
            UIViewController *h=Host();
            void (^ready)(void)=^{
                self.everActive=NO;videoHits=0;audioHits=0;mode=1;
                void (^launch)(void)=self.launch;self.launch=nil;
                if(!launch){[self reset];return;}
                self.watchdog=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
                __block int ticks=0;
                dispatch_source_set_timer(self.watchdog,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,100*NSEC_PER_MSEC);
                dispatch_source_set_event_handler(self.watchdog,^{
                    ticks++;
                    if(mode.load()==1 && ticks>120){[self endCall];return;}
                    if(mode.load()==2 && CACurrentMediaTime()-startTime.load()>4 && (!videoHits.load() || !audioHits.load())){
                        [self endCall];Alert(@"توقّف الاتصال لأن مسار إرسال الفيديو أو الصوت ما اشتغل بهالنسخة.");
                    }
                });
                dispatch_resume(self.watchdog);
                launch();
            };
            if([h isKindOfClass:UIAlertController.class])[h dismissViewControllerAnimated:YES completion:ready];else ready();
        });
    }
}
- (void)failed:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(),^{
        UIViewController *h=Host();
        void (^done)(void)=^{[self reset];Alert(message);};
        if([h isKindOfClass:UIAlertController.class])[h dismissViewControllerAnimated:YES completion:done];else done();
    });
}
- (void)state:(id)state wrapper:(id)wrapper {
    if(!mode.load() || ![Obj(wrapper,@"convoId") isEqual:self.conversation])return;
    self.wrapper=wrapper;
    NSInteger local=Num(Obj(state,@"localUser"),@"callingState");
    if(local)self.everActive=YES;
    // Matches Snapchat's outgoingCallConnectedForHeadlessSession condition.
    if(mode.load()==1 && local==1 && !Flag(state,@"connecting")) [self beginPlayback];
    else if(self.everActive && local==0)[self reset];
}
- (void)beginPlayback {
    if(mode.load()!=1)return;
    startTime=CACurrentMediaTime();mode=2;
    dispatch_async(self.decodeQueue,^{
        if(mode.load()!=2)return;
        self.timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self.decodeQueue);
        dispatch_source_set_timer(self.timer,DISPATCH_TIME_NOW,NSEC_PER_SEC/60,2*NSEC_PER_MSEC);
        __block CMSampleBufferRef next=nullptr;
        dispatch_source_set_event_handler(self.timer,^{
            @autoreleasepool {
                if(mode.load()!=2)return;
                double t=CACurrentMediaTime()-startTime.load();
                if(t>=self.duration){mode=3;dispatch_async(dispatch_get_main_queue(),^{[self endCall];});return;}
                if(!next)next=[self.video copyNextSampleBuffer];
                while(next && CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(next))<=t) {
                    PublishPixel(CMSampleBufferGetImageBuffer(next));CFRelease(next);next=[self.video copyNextSampleBuffer];
                }
                if(self.reader.status==AVAssetReaderStatusFailed){mode=3;dispatch_async(dispatch_get_main_queue(),^{[self endCall];Alert(@"توقف تشغيل الفيديو بسبب خطأ بالملف.");});}
            }
        });
        dispatch_source_set_cancel_handler(self.timer,^{if(next){CFRelease(next);next=nullptr;}});
        dispatch_resume(self.timer);
    });
}
- (void)endCall {
    if(!mode.load())return;
    mode=3;
    id wrapper=self.wrapper;
    if(wrapper)Void(wrapper,@"dismissCall");
    // Keep both outgoing media paths muted while the native call disconnects.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(mode.load()==3 && self.wrapper==wrapper){
            Void(wrapper,@"dismissCall");
            // Never exit the Snapchat process or reactivate real media on failure.
            if(Num(Obj(Obj(wrapper,@"state"),@"localUser"),@"callingState")==0)[self reset];
        }
    });
}
- (void)reset {
    mode=0;
    if(self.watchdog){dispatch_source_cancel(self.watchdog);self.watchdog=nil;}
    self.launch=nil;self.wrapper=nil;self.conversation=nil;
    dispatch_async(self.decodeQueue,^{
        if(self.timer){dispatch_source_cancel(self.timer);self.timer=nil;}
        [self.reader cancelReading];self.reader=nil;self.video=nil;
        // No audio render can acquire the previous mapping after mode=0.
        while(audioReaders.load()!=0)usleep(100);
        if(pcm){munmap((void*)pcm,pcmCount*2);pcm=nullptr;pcmCount=0;}
        PublishPixel(nullptr);
        os_unfair_lock_lock(&pixelLock);CVPixelBufferRef black=blackPixel;blackPixel=nullptr;os_unfair_lock_unlock(&pixelLock);
        if(black)CVPixelBufferRelease(black);
        if(self.movieURL)[[NSFileManager defaultManager] removeItemAtURL:self.movieURL error:nil];
        if(self.pcmURL)[[NSFileManager defaultManager] removeItemAtURL:self.pcmURL error:nil];
        self.movieURL=nil;self.pcmURL=nil;
        dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;});
    });
}
@end

static void (*originalTap)(id,SEL,int);
static void (*originalCamera)(id,SEL,id,CMSampleBufferRef);
static void (*originalState)(id,SEL,id,NSInteger);
static bool compatible=false;
static void Tap(id self,SEL cmd,int media) {
    // Composer values 2/4 map to native video media 2; 1/3 are audio.
    if(media!=2 && media!=4){originalTap(self,cmd,media);return;}
    if(Media().busy || mode.load())return;
    UIViewController *host=Host();if(!host)return;
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"مكالمة فيديو" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"اتصال طبيعي" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){originalTap(self,cmd,media);}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"رفع فيديو" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        if(!compatible || !SnapAudioReady()){Alert(@"هذه النسخة ما تدعم مسار البث المطلوب. استخدم نسخة Snapchat Nobel المرفقة.");return;}
        NSString *conversation=Obj(self,@"convoId");
        if(!conversation.length){Alert(@"تعذر تحديد المحادثة.");return;}
        [Media() choose:^{originalTap(self,cmd,media);} conversation:conversation];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    if(sheet.popoverPresentationController){sheet.popoverPresentationController.sourceView=host.view;sheet.popoverPresentationController.sourceRect=CGRectMake(host.view.bounds.size.width/2,host.view.bounds.size.height/2,1,1);}
    [host presentViewController:sheet animated:YES completion:nil];
}
static void Camera(id self,SEL cmd,id provider,CMSampleBufferRef incoming) {
    int state=mode.load();
    if(!state){originalCamera(self,cmd,provider,incoming);return;}
    os_unfair_lock_lock(&pixelLock);
    CVPixelBufferRef pixel=state==2?currentPixel:blackPixel;
    if(pixel)CVPixelBufferRetain(pixel);
    os_unfair_lock_unlock(&pixelLock);
    if(!pixel)return;
    CMVideoFormatDescriptionRef format=nullptr;CMSampleBufferRef sample=nullptr;
    CMTime pts=incoming?CMSampleBufferGetPresentationTimeStamp(incoming):CMClockGetTime(CMClockGetHostTimeClock());
    CMSampleTimingInfo timing={CMTimeMake(1,30),pts,kCMTimeInvalid};
    if(CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,pixel,&format)==noErr &&
       CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,pixel,format,&timing,&sample)==noErr) {
        originalCamera(self,cmd,provider,sample);
        if(state==2)videoHits.fetch_add(1,std::memory_order_relaxed);
        CFRelease(sample);
    }
    if(format)CFRelease(format);CVPixelBufferRelease(pixel);
}
static void State(id self,SEL cmd,id state,NSInteger reason) {
    originalState(self,cmd,state,reason);
    if(mode.load())dispatch_async(dispatch_get_main_queue(),^{[Media() state:state wrapper:self];});
}
static bool Hook(NSString *className,NSString *selector,IMP replacement,IMP *original,NSString *expected) {
    Class cls=NSClassFromString(className);SEL sel=NSSelectorFromString(selector);
    Method m=class_getInstanceMethod(cls,sel);
    if(!m || ![expected isEqualToString:@(method_getTypeEncoding(m))])return false;
    *original=method_getImplementation(m);
    class_replaceMethod(cls,sel,replacement,method_getTypeEncoding(m));return true;
}
__attribute__((constructor)) static void Install(void) {
    @autoreleasepool {
        // Objective-C classes are ready after the application launches.
        dispatch_async(dispatch_get_main_queue(),^{
            SnapInstallAudio();
            bool camera=Hook(@"SCTCameraServices",@"cameraProvider:didOutputSampleBuffer:",(IMP)Camera,(IMP*)&originalCamera,@"v32@0:8@16^{opaqueCMSampleBuffer=}24");
            bool state=Hook(@"SCTV3SessionWrapper",@"_handleStateChange:reason:",(IMP)State,(IMP*)&originalState,@"v32@0:8@16q24");
            compatible=camera&&state;
            Hook(@"SCTalkChatSessionImpl",@"_composerCallButtonsOnStartCallMedia:",(IMP)Tap,(IMP*)&originalTap,@"v20@0:8i16");
            NSLog(@"[Snap] Installed: camera=%d state=%d audio=%d",camera,state,SnapAudioReady());
        });
    }
}
