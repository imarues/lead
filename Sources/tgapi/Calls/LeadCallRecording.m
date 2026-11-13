#import "LeadCallRecording.h"
#import "LeadCallAudio.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <QuartzCore/QuartzCore.h>

NSString *const LeadCallRecordingEnabledKey=@"LeadCallRecordingEnabled";
NSString *const LeadCallRecordingChangedNotification=@"LeadCallRecordingChanged";

static NSError *LeadRecorderError(NSString *detail) {
    return [NSError errorWithDomain:@"Lead.CallRecorder" code:1
       userInfo:@{NSLocalizedDescriptionKey:detail ?: @"Recording failed."}];
}

@interface LeadCallVideoRecorder : NSObject
@property(nonatomic,weak) UIWindow *originalWindow;
@property(nonatomic,strong) AVAssetWriter *writer;
@property(nonatomic,strong) AVAssetWriterInput *input;
@property(nonatomic,strong) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property(nonatomic,strong) CADisplayLink *displayLink;
@property(nonatomic,strong) NSURL *url;
@property(nonatomic,assign) CFTimeInterval startTime;
@property(nonatomic,assign) CGSize size;
@property(nonatomic,assign) NSUInteger frameCount;
@property(nonatomic,copy) NSString *lastCaptureIssue;
@property(nonatomic,assign) NSUInteger droppedFrameCount;
- (BOOL)startForView:(UIView *)view path:(NSString *)path error:(NSError **)error;
- (void)stop:(void (^)(NSURL *url, NSError *error))completion;
@end

@implementation LeadCallVideoRecorder
- (BOOL)startForView:(UIView *)view path:(NSString *)path error:(NSError **)error {
    if (!view || CGRectIsEmpty(view.bounds)) {
        if(error)*error=LeadRecorderError(@"Call screen is not available.");
        return NO;
    }
    // Capture the active Telegram window, not the temporary call view.
    // The window remains usable when the call UI is minimized to browse chats.
    self.originalWindow=view.window;
    CGSize screenSize=view.window ? view.window.bounds.size : view.bounds.size;
    CGFloat shorter=MIN(screenSize.width,screenSize.height);
    CGFloat longer=MAX(screenSize.width,screenSize.height);
    // Full-HD class: 1080 short edge and up to 2400 long edge, no stretching.
    CGFloat factor=MIN(1080.0/MAX(1.0,shorter),2400.0/MAX(1.0,longer));
    NSInteger width=MAX(2,((NSInteger)round(screenSize.width*factor)/2)*2);
    NSInteger height=MAX(2,((NSInteger)round(screenSize.height*factor)/2)*2);
    self.size=CGSizeMake(width,height);
    self.url=[NSURL fileURLWithPath:path];
    [[NSFileManager defaultManager] removeItemAtURL:self.url error:nil];
    self.writer=[AVAssetWriter assetWriterWithURL:self.url fileType:AVFileTypeMPEG4 error:error];
    if (!self.writer) return NO;
    NSDictionary *settings=@{
       AVVideoCodecKey:AVVideoCodecTypeH264,
       AVVideoWidthKey:@(width),
       AVVideoHeightKey:@(height),
       AVVideoCompressionPropertiesKey:@{
          AVVideoAverageBitRateKey:@(8000000),
          AVVideoExpectedSourceFrameRateKey:@(30),
          AVVideoMaxKeyFrameIntervalKey:@(60)
       }
    };
    self.input=[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    self.input.expectsMediaDataInRealTime=YES;
    NSDictionary *attrs=@{
       (NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
       (NSString *)kCVPixelBufferWidthKey:@(width),
       (NSString *)kCVPixelBufferHeightKey:@(height),
       (NSString *)kCVPixelBufferCGImageCompatibilityKey:@YES,
       (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey:@YES
    };
    self.adaptor=[AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.input sourcePixelBufferAttributes:attrs];
    [self.writer addInput:self.input];
    if(![self.writer startWriting]) {
        if(error)*error=self.writer.error ?: LeadRecorderError(@"Cannot start video writer.");
        return NO;
    }
    [self.writer startSessionAtSourceTime:kCMTimeZero];
    self.startTime=CACurrentMediaTime();
    self.displayLink=[CADisplayLink displayLinkWithTarget:self selector:@selector(captureFrame:)];
    self.displayLink.preferredFramesPerSecond=30;
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    // Capture the first frame immediately, even for short recordings.
    [self captureFrame:nil];
    return YES;
}
- (UIView *)captureViewForCurrentTelegramScreen {
    // Keep following Telegram's normal key window while the user browses chats.
    // IMPORTANT: UIWindow.window can be nil on a UIWindow itself; never use it
    // as the capture gate. Prefer the actual attached root content UIView.
    UIWindow *window=nil;
    UIWindowScene *scene=self.originalWindow.windowScene;
    if(scene) {
        for(UIWindow *candidate in scene.windows) {
            if(candidate.isKeyWindow && !candidate.hidden &&
               candidate.windowLevel==UIWindowLevelNormal && candidate.rootViewController) {
                window=candidate;
                break;
            }
        }
    }
    if(!window) {
        for(UIScene *candidateScene in UIApplication.sharedApplication.connectedScenes) {
            if(![candidateScene isKindOfClass:[UIWindowScene class]] ||
               candidateScene.activationState!=UISceneActivationStateForegroundActive)continue;
            for(UIWindow *candidate in ((UIWindowScene *)candidateScene).windows) {
                if(candidate.isKeyWindow && !candidate.hidden &&
                   candidate.windowLevel==UIWindowLevelNormal && candidate.rootViewController) {
                    window=candidate;
                    break;
                }
            }
            if(window)break;
        }
    }
    if(!window && self.originalWindow && !self.originalWindow.hidden)
        window=self.originalWindow;
    if(!window)return nil;
    UIView *content=window.rootViewController.view;
    // If UIKit is between presentations use the window itself as a fallback.
    return (content && content.window==window && !CGRectIsEmpty(content.bounds))?content:window;
}
- (void)captureFrame:(__unused CADisplayLink *)link {
    UIView *view=[self captureViewForCurrentTelegramScreen];
    if(!view || CGRectIsEmpty(view.bounds)) {
        self.lastCaptureIssue=@"Telegram capture view is not visible.";
        return;
    }
    if(self.writer.status!=AVAssetWriterStatusWriting) {
        self.lastCaptureIssue=self.writer.error.localizedDescription?:@"Video writer is no longer writing.";
        return;
    }
    if(!self.input.readyForMoreMediaData) {
        self.droppedFrameCount++;
        return;
    }

    CVPixelBufferRef pixel=NULL;
    CVReturn result=kCVReturnError;
    CVPixelBufferPoolRef pool=self.adaptor.pixelBufferPool;
    if(pool)
        result=CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pool,&pixel);
    if(!pixel) {
        // On some versions the adaptor's pool is not available immediately.
        // A manually created compatible BGRA buffer is valid for appendPixelBuffer.
        NSDictionary *attrs=@{(NSString *)kCVPixelBufferCGImageCompatibilityKey:@YES,
                              (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey:@YES,
                              (NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}};
        result=CVPixelBufferCreate(kCFAllocatorDefault,(size_t)self.size.width,
                                   (size_t)self.size.height,kCVPixelFormatType_32BGRA,
                                   (__bridge CFDictionaryRef)attrs,&pixel);
    }
    if(result!=kCVReturnSuccess || !pixel) {
        self.lastCaptureIssue=[NSString stringWithFormat:@"Video pixel buffer error: %d",(int)result];
        return;
    }

    CVReturn lockResult=CVPixelBufferLockBaseAddress(pixel,0);
    if(lockResult!=kCVReturnSuccess) {
        self.lastCaptureIssue=@"Cannot lock video pixel buffer.";
        CVPixelBufferRelease(pixel);
        return;
    }
    void *buffer=CVPixelBufferGetBaseAddress(pixel);
    size_t stride=CVPixelBufferGetBytesPerRow(pixel);
    if(!buffer || !stride) {
        self.lastCaptureIssue=@"Video pixel buffer has no writable memory.";
        CVPixelBufferUnlockBaseAddress(pixel,0);
        CVPixelBufferRelease(pixel);
        return;
    }
    CGColorSpaceRef colorSpace=CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx=CGBitmapContextCreate(buffer,(size_t)self.size.width,(size_t)self.size.height,
                   8,stride,colorSpace,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(colorSpace);
    if(!ctx) {
        self.lastCaptureIssue=@"Cannot create BGRA bitmap render context.";
        CVPixelBufferUnlockBaseAddress(pixel,0);
        CVPixelBufferRelease(pixel);
        return;
    }
    CGContextClearRect(ctx,CGRectMake(0,0,self.size.width,self.size.height));
    // UIKit top-left origin: keep text and call controls upright.
    CGContextTranslateCTM(ctx,0,self.size.height);
    CGContextScaleCTM(ctx,1.0,-1.0);
    CGContextScaleCTM(ctx,self.size.width/MAX(view.bounds.size.width,1),
                          self.size.height/MAX(view.bounds.size.height,1));
    UIGraphicsPushContext(ctx);
    BOOL drawn=[view drawViewHierarchyInRect:view.bounds afterScreenUpdates:NO];
    UIGraphicsPopContext();
    if(!drawn) {
        // CALayer fallback avoids a zero-frame recording if UIKit declines
        // a snapshot during a Telegram transition or on a specific iOS build.
        [view.layer renderInContext:ctx];
    }
    CGContextRelease(ctx);
    NSTimeInterval elapsed=MAX(0,CACurrentMediaTime()-self.startTime);
    CMTime presentationTime=CMTimeMakeWithSeconds(elapsed,600);
    if([self.adaptor appendPixelBuffer:pixel withPresentationTime:presentationTime]) {
        self.frameCount++;
        self.lastCaptureIssue=nil;
    } else {
        self.lastCaptureIssue=self.writer.error.localizedDescription?:@"Video writer rejected the captured frame.";
    }
    CVPixelBufferUnlockBaseAddress(pixel,0);
    CVPixelBufferRelease(pixel);
}
- (void)stop:(void (^)(NSURL *,NSError *))completion {
    [self.displayLink invalidate];
    self.displayLink=nil;
    if(self.frameCount==0) {
        [self.writer cancelWriting];
        NSString *detail=self.lastCaptureIssue?:@"No frames reached the video writer.";
        if(completion)completion(nil,LeadRecorderError(
            [NSString stringWithFormat:@"No video frames were captured. %@",detail]));
        return;
    }
    [self.input markAsFinished];
    [self.writer finishWritingWithCompletionHandler:^{
        NSError *error=self.writer.status==AVAssetWriterStatusCompleted?nil:
            (self.writer.error ?: LeadRecorderError(@"Could not finish video recording."));
        dispatch_async(dispatch_get_main_queue(),^{
            if(completion)completion(error?nil:self.url,error);
        });
    }];
}
@end

@interface LeadCallRecording ()
@property(nonatomic,assign,getter=isRecording) BOOL recording;
@property(nonatomic,assign) BOOL videoRequested;
@property(nonatomic,assign) BOOL audioRequested;
@property(nonatomic,strong) LeadCallVideoRecorder *videoRecorder;
@property(nonatomic,copy) NSString *temporaryFolder;
@property(nonatomic,strong) NSDate *startDate;
@end

@implementation LeadCallRecording
+ (instancetype)shared {
    static LeadCallRecording *one;
    static dispatch_once_t once;
    dispatch_once(&once,^{one=[LeadCallRecording new];});
    return one;
}
+ (NSString *)recordingsDirectory {
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSString *folder=[[documents stringByAppendingPathComponent:@"Lead"] stringByAppendingPathComponent:@"Calls"];
    [[NSFileManager defaultManager] createDirectoryAtPath:folder
          withIntermediateDirectories:YES attributes:nil error:nil];
    return folder;
}
+ (NSArray<NSURL *> *)recordings {
    NSString *path=[self recordingsDirectory];
    NSArray<NSString *> *names=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil]?:@[];
    NSMutableArray<NSURL *> *items=[NSMutableArray array];
    for(NSString *name in names) {
        NSString *ext=name.pathExtension.lowercaseString;
        if([ext isEqualToString:@"m4a"] || [ext isEqualToString:@"mp4"])
            [items addObject:[NSURL fileURLWithPath:[path stringByAppendingPathComponent:name]]];
    }
    [items sortUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b) {
        return [b.lastPathComponent compare:a.lastPathComponent options:NSNumericSearch];
    }];
    return items;
}
- (NSTimeInterval)elapsedSeconds {
    return (self.recording && self.startDate)?MAX(0,[[NSDate date] timeIntervalSinceDate:self.startDate]):0;
}
- (void)notifyChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:LeadCallRecordingChangedNotification object:self];
}
- (void)startForView:(UIView *)view video:(BOOL)video
          completion:(void (^)(NSError *))completion {
    // Recording may only be initiated by tapping the visible in-call control.
    if(self.recording || !view.window ||
       ![[NSUserDefaults standardUserDefaults] boolForKey:LeadCallRecordingEnabledKey]) {
        if(completion)completion(LeadRecorderError(@"Enable Call Recording in Lead settings and open an active call."));
        return;
    }
    self.startDate=[NSDate date];
    self.videoRequested=video;
    self.audioRequested=YES;
    self.temporaryFolder=[NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"LeadCall-%@",NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.temporaryFolder
        withIntermediateDirectories:YES attributes:nil error:nil];
    if(!LeadCallAudioStart(self.temporaryFolder)) {
        if(completion)completion(LeadRecorderError(@"The call audio capture engine could not start."));
        return;
    }
    if(video) {
        self.videoRecorder=[LeadCallVideoRecorder new];
        NSError *e=nil;
        NSString *screenPath=[self.temporaryFolder stringByAppendingPathComponent:@"screen.mp4"];
        if(![self.videoRecorder startForView:view path:screenPath error:&e]) {
            // Stop the audio engine too; don't leave an invisible recording.
            LeadCallAudioStop(nil);
            self.videoRecorder=nil;
            if(completion)completion(e?:LeadRecorderError(@"Video writer could not start."));
            return;
        }
    }
    self.recording=YES;
    [self notifyChanged];
    if(completion)completion(nil);
}
- (void)finishOutputAudio:(NSURL *)audio video:(NSURL *)video
               completion:(void (^)(NSURL *,NSError *))completion {
    NSString *extension=video?@"mp4":@"m4a";
    NSDateFormatter *formatter=[NSDateFormatter new];
    formatter.dateFormat=@"yyyyMMdd-HHmmss";
    NSString *name=[NSString stringWithFormat:@"Call-%@.%@",[formatter stringFromDate:self.startDate?:[NSDate date]],extension];
    NSURL *final=[NSURL fileURLWithPath:[[LeadCallRecording recordingsDirectory] stringByAppendingPathComponent:name]];
    [[NSFileManager defaultManager] removeItemAtURL:final error:nil];
    if(!video) {
        NSError *err=nil;
        if(![[NSFileManager defaultManager] moveItemAtURL:audio toURL:final error:&err]) {
            if(completion)completion(nil,err);
        } else if(completion)completion(final,nil);
        return;
    }
    AVURLAsset *movie=[AVURLAsset URLAssetWithURL:video options:nil];
    AVURLAsset *sound=audio?[AVURLAsset URLAssetWithURL:audio options:nil]:nil;
    AVAssetTrack *videoTrack=[movie tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if(!videoTrack){if(completion)completion(nil,LeadRecorderError(@"Video track is missing."));return;}
    AVMutableComposition *mix=[AVMutableComposition composition];
    AVMutableCompositionTrack *outVideo=[mix addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    NSError *err=nil;
    [outVideo insertTimeRange:CMTimeRangeMake(kCMTimeZero,videoTrack.timeRange.duration)
                   ofTrack:videoTrack atTime:kCMTimeZero error:&err];
    if(err){if(completion)completion(nil,err);return;}
    AVAssetTrack *audioTrack=[sound tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if(audioTrack) {
        AVMutableCompositionTrack *outAudio=[mix addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
        CMTime duration=CMTimeMinimum(audioTrack.timeRange.duration,videoTrack.timeRange.duration);
        [outAudio insertTimeRange:CMTimeRangeMake(kCMTimeZero,duration)
                        ofTrack:audioTrack atTime:kCMTimeZero error:&err];
        if(err){if(completion)completion(nil,err);return;}
    }
    AVAssetExportSession *exporter=[[AVAssetExportSession alloc] initWithAsset:mix
                       presetName:AVAssetExportPresetHighestQuality];
    exporter.outputURL=final;
    exporter.outputFileType=AVFileTypeMPEG4;
    [exporter exportAsynchronouslyWithCompletionHandler:^{
        NSError *error=exporter.status==AVAssetExportSessionStatusCompleted?nil:
           (exporter.error ?: LeadRecorderError(@"Video/audio merge failed."));
        dispatch_async(dispatch_get_main_queue(),^{
            if(completion)completion(error?nil:final,error);
        });
    }];
}
- (void)stop:(void (^)(NSURL *,NSError *))completion {
    if(!self.recording) {
        if(completion)completion(nil,LeadRecorderError(@"There is no active recording."));
        return;
    }
    self.recording=NO;[self notifyChanged];
    LeadCallVideoRecorder *video=self.videoRecorder;
    self.videoRecorder=nil;
    __weak typeof(self) weakSelf=self;
    void (^finish)(NSURL *,NSError *)=^(NSURL *videoFile,NSError *videoError) {
        LeadCallAudioStop(^(NSURL *audioFile,NSError *audioError) {
            typeof(self) strongSelf=weakSelf;
            if(!strongSelf) return;
            // Do not claim a complete two-sided audio call if AudioUnit hooks
            // were incompatible with this Telegram version.
            if(audioError) {
                if(completion)completion(nil,audioError);
                return;
            }
            if(videoError) {
                // Never lose a valid two-sided audio track just because
                // iOS rejects the video frames on this device.
                [strongSelf finishOutputAudio:audioFile video:nil completion:^(NSURL *savedAudio,NSError *savingError) {
                    if(!savingError && savedAudio) {
                        NSError *warning=[NSError errorWithDomain:@"Lead.CallRecorder" code:2
                         userInfo:@{NSLocalizedDescriptionKey:
                           [NSString stringWithFormat:@"Video capture failed (%@). The audio was saved.",
                            videoError.localizedDescription?:@"unknown reason"]}];
                        if(completion)completion(savedAudio,warning);
                    } else if(completion)completion(nil,savingError?:videoError);
                }];
                return;
            }
            [strongSelf finishOutputAudio:audioFile video:videoFile completion:^(NSURL *url,NSError *error) {
                if(!error && strongSelf.temporaryFolder)
                    [[NSFileManager defaultManager] removeItemAtPath:strongSelf.temporaryFolder error:nil];
                if(completion)completion(url,error);
            }];
        });
    };
    if(video) [video stop:finish]; else finish(nil,nil);
}
@end

@interface LeadCallRecordingsViewController () <UISearchResultsUpdating>
@property(nonatomic,strong) NSArray<NSURL *> *allFiles;
@property(nonatomic,strong) NSArray<NSURL *> *visibleFiles;
@property(nonatomic,strong) UISearchController *search;
@property(nonatomic,assign) BOOL ascending;
@property(nonatomic,strong) AVPlayerViewController *player;
@end
@implementation LeadCallRecordingsViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"تسجيلات المكالمات";
    self.tableView.rowHeight=70;
    self.tableView.tableFooterView=[UIView new];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"ترتيب"
              style:UIBarButtonItemStylePlain target:self action:@selector(toggleSort)];
    self.search=[[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.obscuresBackgroundDuringPresentation=NO;
    self.search.searchBar.placeholder=@"بحث في التسجيلات";
    self.search.searchResultsUpdater=self;
    self.navigationItem.searchController=self.search;
    self.definesPresentationContext=YES;
    [self reloadFiles];
}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];[self reloadFiles];}
- (void)toggleSort {self.ascending=!self.ascending;[self reloadFiles];}
- (void)updateSearchResultsForSearchController:(__unused UISearchController *)controller {[self filterFiles];}
- (void)reloadFiles {
    self.allFiles=[LeadCallRecording recordings];
    if(self.ascending)self.allFiles=self.allFiles.reverseObjectEnumerator.allObjects;
    [self filterFiles];
}
- (void)filterFiles {
    NSString *query=self.search.searchBar.text ?: @"";
    NSMutableArray *filtered=[NSMutableArray array];
    for(NSURL *url in self.allFiles)
        if(!query.length || [url.lastPathComponent localizedCaseInsensitiveContainsString:query])
            [filtered addObject:url];
    self.visibleFiles=filtered;[self.tableView reloadData];
    self.tableView.backgroundView=filtered.count?nil:[self emptyLabel];
}
- (UIView *)emptyLabel {
    UILabel *label=[UILabel new];
    label.numberOfLines=0;
    label.textAlignment=NSTextAlignmentCenter;
    label.textColor=UIColor.secondaryLabelColor;
    label.text=@"ماكو تسجيلات بعد.\nابدأ تسجيل من زر REC داخل المكالمة بعد موافقة المشاركين.";
    return label;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleFiles.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"LeadCallRecording"];
    if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                         reuseIdentifier:@"LeadCallRecording"];
    NSURL *url=self.visibleFiles[indexPath.row];
    NSDictionary *attrs=[[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil];
    cell.textLabel.text=url.lastPathComponent;
    cell.textLabel.font=[UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ • %.1f MB",
             [url.pathExtension.uppercaseString isEqual:@"MP4"]?@"فيديو":@"صوت",
             [attrs[NSFileSize] doubleValue]/1048576.0];
    cell.imageView.image=[UIImage systemImageNamed:
             [url.pathExtension.lowercaseString isEqual:@"mp4"]?@"video":@"waveform"];
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    AVPlayerViewController *player=[AVPlayerViewController new];
    player.player=[AVPlayer playerWithURL:self.visibleFiles[indexPath.row]];
    self.player=player;
    [self presentViewController:player animated:YES completion:^{[player.player play];}];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSURL *url=self.visibleFiles[indexPath.row];
    UIContextualAction *share=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                 title:@"مشاركة" handler:^(__unused UIContextualAction *action,
                                          __unused UIView *view,void (^done)(BOOL)) {
        UIActivityViewController *activity=[[UIActivityViewController alloc]
                           initWithActivityItems:@[url] applicationActivities:nil];
        activity.popoverPresentationController.sourceView=self.view;
        activity.popoverPresentationController.sourceRect=CGRectMake(10,10,1,1);
        [self presentViewController:activity animated:YES completion:nil];
        done(YES);
    }];
    UIContextualAction *remove=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                  title:@"حذف" handler:^(__unused UIContextualAction *action,
                                        __unused UIView *view,void (^done)(BOOL)) {
        UIAlertController *confirm=[UIAlertController alertControllerWithTitle:@"حذف التسجيل؟"
               message:@"راح ينحذف هذا التسجيل من الجهاز نهائياً."
               preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel
                 handler:^(__unused UIAlertAction *a){done(NO);}]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"حذف" style:UIAlertActionStyleDestructive
                 handler:^(__unused UIAlertAction *a){
            BOOL ok=[[NSFileManager defaultManager] removeItemAtURL:url error:nil];
            [self reloadFiles];done(ok);
        }]];
        [self presentViewController:confirm animated:YES completion:nil];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove,share]];
}
@end
