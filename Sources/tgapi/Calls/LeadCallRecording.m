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
@property(nonatomic,weak) UIView *view;
@property(nonatomic,strong) AVAssetWriter *writer;
@property(nonatomic,strong) AVAssetWriterInput *input;
@property(nonatomic,strong) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property(nonatomic,strong) CADisplayLink *displayLink;
@property(nonatomic,strong) NSURL *url;
@property(nonatomic,assign) CFTimeInterval startTime;
@property(nonatomic,assign) CGSize size;
@property(nonatomic,assign) NSUInteger frameCount;
- (BOOL)startForView:(UIView *)view path:(NSString *)path error:(NSError **)error;
- (void)stop:(void (^)(NSURL *url, NSError *error))completion;
@end

@implementation LeadCallVideoRecorder
- (BOOL)startForView:(UIView *)view path:(NSString *)path error:(NSError **)error {
    if (!view || CGRectIsEmpty(view.bounds)) {
        if(error)*error=LeadRecorderError(@"Call screen is not available.");
        return NO;
    }
    self.view=view;
    CGFloat factor=MIN(1.8,720.0/MAX(1.0,view.bounds.size.width));
    NSInteger width=MAX(2,((NSInteger)(view.bounds.size.width*factor)/2)*2);
    NSInteger height=MAX(2,((NSInteger)(view.bounds.size.height*factor)/2)*2);
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
          AVVideoAverageBitRateKey:@(1200000),
          AVVideoExpectedSourceFrameRateKey:@(10),
          AVVideoMaxKeyFrameIntervalKey:@(20)
       }
    };
    self.input=[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    self.input.expectsMediaDataInRealTime=YES;
    NSDictionary *attrs=@{
       (NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32ARGB),
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
    self.displayLink.preferredFramesPerSecond=10;
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    return YES;
}
- (void)captureFrame:(__unused CADisplayLink *)link {
    UIView *view=self.view;
    if(!view.window || !self.input.readyForMoreMediaData ||
       self.writer.status!=AVAssetWriterStatusWriting ||
       !self.adaptor.pixelBufferPool)return;
    CVPixelBufferRef pixel=NULL;
    if(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,self.adaptor.pixelBufferPool,&pixel)!=kCVReturnSuccess)return;
    CVPixelBufferLockBaseAddress(pixel,0);
    void *buffer=CVPixelBufferGetBaseAddress(pixel);
    size_t stride=CVPixelBufferGetBytesPerRow(pixel);
    CGContextRef ctx=CGBitmapContextCreate(buffer,(size_t)self.size.width,(size_t)self.size.height,8,stride,
                     CGColorSpaceCreateDeviceRGB(),kCGImageAlphaNoneSkipFirst);
    // drawViewHierarchyInRect captures the current Telegram call layout. Some
    // hardware-backed video surfaces can still be black on particular clients.
    if(ctx) {
        CGContextClearRect(ctx,CGRectMake(0,0,self.size.width,self.size.height));
        UIGraphicsPushContext(ctx);
        CGContextScaleCTM(ctx,self.size.width/MAX(view.bounds.size.width,1),
                              self.size.height/MAX(view.bounds.size.height,1));
        [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:NO];
        UIGraphicsPopContext();
        CGContextRelease(ctx);
        NSTimeInterval elapsed=MAX(0,CACurrentMediaTime()-self.startTime);
        CMTime time=CMTimeMakeWithSeconds(elapsed,600);
        if([self.adaptor appendPixelBuffer:pixel withPresentationTime:time])
            self.frameCount++;
    }
    CVPixelBufferUnlockBaseAddress(pixel,0);
    CVPixelBufferRelease(pixel);
}
- (void)stop:(void (^)(NSURL *,NSError *))completion {
    [self.displayLink invalidate];
    self.displayLink=nil;
    if(self.frameCount==0) {
        if(completion)completion(nil,LeadRecorderError(@"No video frames were captured."));
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
                if(completion)completion(nil,videoError);
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
