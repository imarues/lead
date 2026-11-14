// Experimental outgoing-call media source for Lead.
// Opt-in only. Never sends camera frames while a virtual clip is selected.
// The AVFoundation delegate route varies across Telegram versions; verified
// remote transmission requires device testing.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <atomic>
#include <cmath>
#include <memory>
#include <vector>
#include <algorithm>
#include <cstring>

namespace {
struct AudioClip { std::vector<int16_t> samples; };
static std::shared_ptr<AudioClip> gAudioClip;
static std::atomic<int> gVirtualState{0}; // 0 normal; 1 waiting for camera; 2 streaming; 3 completed/muted
static std::atomic<double> gStartClock{0};
static std::atomic<double> gClipDuration{0};
static char kVirtualButtonKey;
static char kCaptureProxyKey;
}

extern "C" bool LeadVirtualMediaReplaceMic(AudioBufferList *buffers,
                                           const AudioStreamBasicDescription *format,
                                           UInt32 frames) {
    if(gVirtualState.load(std::memory_order_acquire)==0) return false;
    if(!buffers || !format) return true;
    // Explicit privacy rule: no microphone fallback even for unsupported formats.
    const bool flt=(format->mFormatFlags & kAudioFormatFlagIsFloat)!=0;
    const bool planar=(format->mFormatFlags & kAudioFormatFlagIsNonInterleaved)!=0;
    const bool integer=(format->mFormatFlags & kAudioFormatFlagIsSignedInteger)!=0;
    const unsigned bits=format->mBitsPerChannel;
    const unsigned channels=std::max(1u,format->mChannelsPerFrame);
    const double outputRate=format->mSampleRate;
    const bool supported=(flt && bits==32)||(integer && (bits==16 || bits==32));
    auto pcm=std::atomic_load(&gAudioClip);
    double start=gStartClock.load(std::memory_order_acquire);
    const bool playing=gVirtualState.load(std::memory_order_relaxed)==2 && start>0
        && outputRate>=8000 && outputRate<=192000 && std::isfinite(outputRate)
        && pcm && !pcm->samples.empty();
    const double position=playing ? std::max(0.0,CACurrentMediaTime()-start) : 0;
    for(UInt32 b=0;b<buffers->mNumberBuffers;b++) {
        AudioBuffer &buf=buffers->mBuffers[b];
        if(!buf.mData)continue;
        if(!supported || !playing || (planar && b>0 && b>=channels)) {
            memset(buf.mData,0,buf.mDataByteSize);
            continue;
        }
        unsigned samplesPerFrame=planar?1:channels;
        unsigned bytesPerSample=bits/8;
        UInt32 count=std::min(frames,buf.mDataByteSize/
                                    std::max(1u,samplesPerFrame*bytesPerSample));
        // The movie's PCM is converted to 48 kHz mono before enabling this hook.
        for(UInt32 i=0;i<count;i++) {
            uint64_t mediaIndex=(uint64_t)((position+i/outputRate)*48000.0);
            float value=mediaIndex<pcm->samples.size()
                     ? pcm->samples[(size_t)mediaIndex]/32768.0f:0.0f;
            for(unsigned c=0;c<samplesPerFrame;c++) {
                size_t idx=(size_t)i*samplesPerFrame+c;
                if(flt)((float*)buf.mData)[idx]=value;
                else if(bits==16)((int16_t*)buf.mData)[idx]=(int16_t)lrintf(value*32767.0f);
                else ((int32_t*)buf.mData)[idx]=(int32_t)llrint((double)value*2147483647.0);
            }
        }
        const size_t used=(size_t)count*samplesPerFrame*bytesPerSample;
        if(used<buf.mDataByteSize)memset((uint8_t*)buf.mData+used,0,buf.mDataByteSize-used);
    }
    return true;
}

@interface LeadVirtualClip : NSObject
@property(nonatomic,strong) AVAssetReader *reader;
@property(nonatomic,strong) AVAssetReaderTrackOutput *output;
@property(nonatomic,assign) CMSampleBufferRef currentFrame;
@property(nonatomic,assign) CMSampleBufferRef futureFrame;
@property(nonatomic,assign) BOOL reachedEnd;
@property(nonatomic,assign) NSTimeInterval duration;
@end
@implementation LeadVirtualClip
- (void)dealloc {
    if(_currentFrame)CFRelease(_currentFrame);
    if(_futureFrame)CFRelease(_futureFrame);
    [_reader cancelReading];
}
@end

@class LeadVirtualCameraProxy;
@interface LeadVirtualMedia : NSObject <PHPickerViewControllerDelegate>
@property(nonatomic,strong) LeadVirtualClip *clip;
@property(nonatomic,weak) UIView *callView;
@property(nonatomic,weak) UIButton *button;
+ (instancetype)shared;
- (void)openMenu:(UIButton *)button;
- (void)installOnView:(UIView *)view;
- (void)removeFromView:(UIView *)view;
- (CMSampleBufferRef)replacementForSample:(CMSampleBufferRef)original CF_RETURNS_RETAINED;
@end

@interface LeadVirtualCameraProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic,weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> upstream;
@end
@implementation LeadVirtualCameraProxy
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample
       fromConnection:(AVCaptureConnection *)connection {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> upstream=self.upstream;
    if(!upstream || ![upstream respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)])return;
    if(gVirtualState.load(std::memory_order_acquire)==0) {
        [upstream captureOutput:output didOutputSampleBuffer:sample fromConnection:connection];
        return;
    }
    CMSampleBufferRef replacement=[[LeadVirtualMedia shared] replacementForSample:sample];
    // Never forward real camera frames when a virtual movie was requested.
    if(replacement) {
        [upstream captureOutput:output didOutputSampleBuffer:replacement fromConnection:connection];
        CFRelease(replacement);
    }
}
- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sample
       fromConnection:(AVCaptureConnection *)connection {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> upstream=self.upstream;
    if([upstream respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)])
        [upstream captureOutput:output didDropSampleBuffer:sample fromConnection:connection];
}
@end

@implementation LeadVirtualMedia
+ (instancetype)shared {
    static LeadVirtualMedia *media;
    static dispatch_once_t once;
    dispatch_once(&once,^{media=[LeadVirtualMedia new];});
    return media;
}
- (UIViewController *)host {
    UIResponder *responder=self.button ?: self.callView;
    while(responder && ![responder isKindOfClass:[UIViewController class]])
        responder=[responder nextResponder];
    if([responder isKindOfClass:[UIViewController class]])
        return (UIViewController*)responder;
    UIWindow *window=self.callView.window ?: UIApplication.sharedApplication.keyWindow;
    return window.rootViewController;
}
- (void)showMessage:(NSString *)title detail:(NSString *)detail {
    dispatch_async(dispatch_get_main_queue(),^{
        UIViewController *host=[self host];
        if(!host)return;
        while(host.presentedViewController)host=host.presentedViewController;
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:detail
                    preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleDefault handler:nil]];
        [host presentViewController:alert animated:YES completion:nil];
    });
}
- (void)setNormal {
    gVirtualState.store(0,std::memory_order_release);
    gStartClock.store(0,std::memory_order_release);
    std::atomic_store(&gAudioClip,std::shared_ptr<AudioClip>());
    @synchronized(self) {self.clip=nil;}
    dispatch_async(dispatch_get_main_queue(),^{
        self.button.backgroundColor=UIColor.systemBlueColor;
        [self.button setTitle:@"VID" forState:UIControlStateNormal];
    });
}
- (void)installOnView:(UIView *)view {
    if(!view.window || objc_getAssociatedObject(view,&kVirtualButtonKey))return;
    UIButton *button=[UIButton buttonWithType:UIButtonTypeCustom];
    CGFloat y=MAX(90,MIN(view.bounds.size.height-55,view.bounds.size.height*0.39));
    button.frame=CGRectMake(8,y,56,42);
    button.backgroundColor=UIColor.systemBlueColor;
    button.layer.cornerRadius=10;
    button.layer.borderColor=UIColor.whiteColor.CGColor;
    button.layer.borderWidth=1;
    button.titleLabel.font=[UIFont boldSystemFontOfSize:14];
    [button setTitle:@"VID" forState:UIControlStateNormal];
    button.accessibilityLabel=@"خيارات الفيديو للمكالمة";
    [button addTarget:self action:@selector(openMenu:) forControlEvents:UIControlEventTouchUpInside];
    [view addSubview:button];
    objc_setAssociatedObject(view,&kVirtualButtonKey,button,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.callView=view;
    self.button=button;
}
- (void)removeFromView:(UIView *)view {
    UIButton *button=objc_getAssociatedObject(view,&kVirtualButtonKey);
    [button removeFromSuperview];
    objc_setAssociatedObject(view,&kVirtualButtonKey,nil,OBJC_ASSOCIATION_ASSIGN);
    if(self.button==button){self.button=nil;self.callView=nil;}
}
- (void)openMenu:(UIButton *)button {
    UIViewController *host=[self host];
    if(!host)return;
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"مصدر الفيديو"
        message:@"الفيديو التجريبي يستبدل إطارات الكاميرا وصوت المايك؛ افتح الكاميرا داخل المكالمة بعد اختيار الملف."
        preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"الكاميرا الحقيقية + المايك"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[self setNormal];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"فيديو من المعرض بدل الكاميرا"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[self pickVideo];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"فيديو بدل مشاركة الشاشة"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
            [self showMessage:@"مشاركة الشاشة"
                detail:@"ما نكدر نوصل لامتداد BroadcastUpload من ديلب التطبيق وحده. هذا المسار يحتاج باتش للـIPA، وما راح نعرض فيديو غير مرسل على أنه شغال."];
        }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView=button;
    menu.popoverPresentationController.sourceRect=button.bounds;
    [host presentViewController:menu animated:YES completion:nil];
}
- (void)pickVideo {
    PHPickerConfiguration *conf=[[PHPickerConfiguration alloc] init];
    conf.selectionLimit=1;
    conf.filter=[PHPickerFilter videosFilter];
    PHPickerViewController *picker=[[PHPickerViewController alloc] initWithConfiguration:conf];
    picker.delegate=self;
    [[self host] presentViewController:picker animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if(!results.count)return;
    NSItemProvider *provider=results.firstObject.itemProvider;
    if(![provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        [self showMessage:@"الملف غير مدعوم" detail:@"اختَر فيديو يحتوي على صوت."];
        return;
    }
    [provider loadFileRepresentationForTypeIdentifier:@"public.movie"
        completionHandler:^(NSURL *temporary,NSError *e) {
        if(e || !temporary) {
            [self showMessage:@"تعذر فتح الفيديو" detail:e.localizedDescription?:@"فشل استيراد الفيديو."];
            return;
        }
        NSURL *copied=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"lead-virtual-%@.mov",NSUUID.UUID.UUIDString]]];
        NSError *copyError=nil;
        [[NSFileManager defaultManager] copyItemAtURL:temporary toURL:copied error:&copyError];
        if(copyError) {
            [self showMessage:@"خطأ نسخ الفيديو" detail:copyError.localizedDescription];
            return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            [self prepareMovie:copied];
        });
    }];
}
- (void)prepareMovie:(NSURL *)url {
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *video=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *audio=[asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    NSTimeInterval duration=CMTimeGetSeconds(asset.duration);
    if(!video || !audio || !std::isfinite(duration) || duration<=0 || duration>720) {
        [self showMessage:@"تعذر تجهيز الفيديو"
            detail:@"يلزم ملف فيديو يحتوي على صوت، مدته من ثانية إلى 12 دقيقة بالحد الأقصى في النسخة التجريبية."];
        return;
    }
    NSError *error=nil;
    AVAssetReader *audioReader=[[AVAssetReader alloc] initWithAsset:asset error:&error];
    if(!audioReader){[self showMessage:@"قراءة الصوت" detail:error.localizedDescription];return;}
    NSDictionary *audioSettings=@{AVFormatIDKey:@(kAudioFormatLinearPCM),
        AVSampleRateKey:@48000,AVNumberOfChannelsKey:@1,
        AVLinearPCMBitDepthKey:@16,AVLinearPCMIsFloatKey:@NO,
        AVLinearPCMIsBigEndianKey:@NO,AVLinearPCMIsNonInterleaved:@NO};
    AVAssetReaderTrackOutput *audioOutput=[[AVAssetReaderTrackOutput alloc]
        initWithTrack:audio outputSettings:audioSettings];
    [audioReader addOutput:audioOutput];
    if(![audioReader startReading]){
        [self showMessage:@"فشل الصوت" detail:audioReader.error.localizedDescription?:@"خطأ فك الصوت."];
        return;
    }
    NSMutableData *decoded=[NSMutableData data];
    CMSampleBufferRef packet=NULL;
    while((packet=[audioOutput copyNextSampleBuffer])) {
        CMBlockBufferRef block=CMSampleBufferGetDataBuffer(packet);
        size_t length=block?CMBlockBufferGetDataLength(block):0;
        if(length && decoded.length+length<75000000) {
            NSUInteger offset=decoded.length;
            [decoded increaseLengthBy:length];
            CMBlockBufferCopyDataBytes(block,0,length,(uint8_t*)decoded.mutableBytes+offset);
        }
        CFRelease(packet);
        if(decoded.length>=74990000)break;
    }
    if(audioReader.status==AVAssetReaderStatusFailed || decoded.length<2) {
        [self showMessage:@"فشل استخراج الصوت"
            detail:audioReader.error.localizedDescription?:@"ما حصلنا عينات صوت مناسبة."];
        return;
    }
    auto pcm=std::make_shared<AudioClip>();
    pcm->samples.resize(decoded.length/sizeof(int16_t));
    memcpy(pcm->samples.data(),decoded.bytes,pcm->samples.size()*sizeof(int16_t));

    AVAssetReader *reader=[[AVAssetReader alloc] initWithAsset:asset error:&error];
    if(!reader){[self showMessage:@"قراءة الفيديو" detail:error.localizedDescription];return;}
    AVAssetReaderTrackOutput *output=[[AVAssetReaderTrackOutput alloc] initWithTrack:video
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
    output.alwaysCopiesSampleData=NO;
    [reader addOutput:output];
    if(![reader startReading]){
        [self showMessage:@"فشل الفيديو" detail:reader.error.localizedDescription?:@"خطأ فك الفيديو."];
        return;
    }
    LeadVirtualClip *clip=[LeadVirtualClip new];
    clip.reader=reader;clip.output=output;clip.duration=duration;
    @synchronized(self) {
        self.clip=clip;
        gClipDuration.store(duration);
        gStartClock.store(0,std::memory_order_release);
        std::atomic_store(&gAudioClip,pcm);
        gVirtualState.store(1,std::memory_order_release);
    }
    dispatch_async(dispatch_get_main_queue(),^{
        self.button.backgroundColor=UIColor.systemOrangeColor;
        [self.button setTitle:@"FILE" forState:UIControlStateNormal];
        [self showMessage:@"تم تجهيز الفيديو"
           detail:@"شغّل الكاميرا داخل المكالمة. بمجرد ظهور إطارات الكاميرا يبدأ بث الملف وصوته، والمايك يبقى مكتوماً. اختبر النتيجة من جهاز ثاني."];
    });
}
- (void)completed {
    int expected=2;
    if(!gVirtualState.compare_exchange_strong(expected,3))return;
    // The outgoing microphone stays suppressed after EOF.
    dispatch_async(dispatch_get_main_queue(),^{
        self.button.backgroundColor=UIColor.systemRedColor;
        [self.button setTitle:@"END" forState:UIControlStateNormal];
        [self showMessage:@"انتهى الفيديو"
            detail:@"توقف بث إطارات الملف وصوته، والمايك باقي مكتوم. أوقف الكاميرا من زر Telegram؛ المكالمة تبقى مستمرة. اختَر الكاميرا الحقيقية من VID حتى يرجع المايك."];
    });
}
- (CMSampleBufferRef)replacementForSample:(CMSampleBufferRef)original {
    LeadVirtualClip *clip=nil;
    @synchronized(self) {clip=self.clip;}
    if(!clip)return NULL;
    @synchronized(clip) {
        int state=gVirtualState.load(std::memory_order_acquire);
        if(state==0 || state==3)return NULL;
        double start=gStartClock.load(std::memory_order_acquire);
        if(state==1 || start<=0) {
            start=CACurrentMediaTime();
            gStartClock.store(start,std::memory_order_release);
            gVirtualState.store(2,std::memory_order_release);
        }
        double elapsed=CACurrentMediaTime()-start;
        if(elapsed>=clip.duration) {
            [self completed];
            return NULL;
        }
        for(int i=0;i<15;i++) {
            if(!clip.futureFrame && !clip.reachedEnd) {
                clip.futureFrame=[clip.output copyNextSampleBuffer];
                if(!clip.futureFrame)clip.reachedEnd=YES;
            }
            if(!clip.futureFrame)break;
            double pts=CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(clip.futureFrame));
            if(!std::isfinite(pts) || pts>elapsed+0.02)break;
            if(clip.currentFrame)CFRelease(clip.currentFrame);
            clip.currentFrame=clip.futureFrame;
            clip.futureFrame=NULL;
        }
        if(!clip.currentFrame)return NULL;
        CVImageBufferRef pixels=CMSampleBufferGetImageBuffer(clip.currentFrame);
        if(!pixels)return NULL;
        CMVideoFormatDescriptionRef desc=NULL;
        if(CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,pixels,&desc)!=noErr)
            return NULL;
        CMSampleTimingInfo timing={CMSampleBufferGetDuration(original),
                                  CMSampleBufferGetPresentationTimeStamp(original),kCMTimeInvalid};
        CMSampleBufferRef replacement=NULL;
        OSStatus status=CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,pixels,true,NULL,NULL,
                              desc,&timing,&replacement);
        CFRelease(desc);
        return status==noErr?replacement:NULL;
    }
}
@end

// Intercept only live AVFoundation camera capture delegates.
// If Telegram uses a private tgcalls capture pathway instead, no false
// claim of successful transmission is made: this is a device-test probe.
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                           queue:(dispatch_queue_t)queue {
    if(!delegate || [delegate isKindOfClass:[LeadVirtualCameraProxy class]]) {
        %orig(delegate,queue);
        return;
    }
    LeadVirtualCameraProxy *proxy=[LeadVirtualCameraProxy new];
    proxy.upstream=delegate;
    objc_setAssociatedObject(self,&kCaptureProxyKey,proxy,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig((id<AVCaptureVideoDataOutputSampleBufferDelegate>)proxy,queue);
}
%end

extern "C" void LeadVirtualMediaInstallButton(UIView *view) {
    dispatch_async(dispatch_get_main_queue(),^{[[LeadVirtualMedia shared] installOnView:view];});
}
extern "C" void LeadVirtualMediaRemoveButton(UIView *view) {
    dispatch_async(dispatch_get_main_queue(),^{[[LeadVirtualMedia shared] removeFromView:view];});
}
