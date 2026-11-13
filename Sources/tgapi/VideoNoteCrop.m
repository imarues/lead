// Interactive video-note crop picker. Saves normalized crop center AND zoom.
// The sending hook applies the exact circle selection to the rendered MP4.
#import "VideoNoteCrop.h"
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <math.h>
#import "UI/Headers.h"
#import "LeadMXMediaCompat.h"

// Sideload injection often includes only Kira.dylib (no updated Kira.bundle).
// Keep the newly introduced picker strings available in Arabic directly;
// otherwise users with an Arabic interface see English labels.
static BOOL mxCropArabicInterface(void) {
    NSString *cancel = [MxLocalization localizedStringForKey:@"CANCEL"];
    if ([cancel isEqualToString:@"إلغاء"]) return YES;
    if (cancel.length && ![cancel isEqualToString:@"CANCEL"] &&
        ![cancel isEqualToString:@"Cancel"]) return NO;
    NSString *preferred = [NSLocale preferredLanguages].firstObject ?: @"";
    return [[preferred lowercaseString] hasPrefix:@"ar"];
}
static NSString *mxCropText(NSString *key, NSString *fallback) {
    NSString *localized = [MxLocalization localizedStringForKey:key];
    if (mxCropArabicInterface()) {
        static NSDictionary<NSString *, NSString *> *arabic = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            arabic = @{
                @"VIDEO_NOTE_CROP_TITLE": @"تحديد مكان دائرة الفيديو",
                @"VIDEO_NOTE_CROP_HINT": @"اسحب الدائرة لتغيير مكانها، وكبّر أو صغّر بإصبعين، ثم اضغط اعتماد وبعدها إرسال.",
                @"VIDEO_NOTE_CROP_APPLY": @"اعتماد",
                @"VIDEO_NOTE_CROP_NORMAL": @"فيديو عادي",
                @"VIDEO_NOTE_CROP_LOADING": @"جارٍ تحميل معاينة الفيديو…",
                @"VIDEO_NOTE_CROP_ERROR": @"تعذّر فتح معاينة هذا الفيديو.",
                @"VIDEO_NOTE_CROP_ZOOM": @"التكبير"
            };
        });
        if (arabic[key]) return arabic[key];
    }
    return (localized.length && ![localized isEqualToString:key]) ? localized : fallback;
}

static id mxCropGetter(id object, NSString *getter) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(getter);
    if (![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// The gallery can wrap a TGMediaAsset in one or more media-picker items.
// Resolve only on a background queue: PHImageManager can download from iCloud.
static AVAsset *mxCropResolveItem(id item) {
    id node = item;
    for (NSInteger i = 0; node && i < 7; ++i) {
        if ([node isKindOfClass:[AVAsset class]]) return node;
        PHAsset *photo = nil;
        if ([node isKindOfClass:[PHAsset class]]) photo = node;
        id backing = mxCropGetter(node, @"backingAsset");
        if ([backing isKindOfClass:[PHAsset class]]) photo = backing;
        if (photo && photo.mediaType == PHAssetMediaTypeVideo) {
            PHVideoRequestOptions *options = [PHVideoRequestOptions new];
            options.networkAccessAllowed = YES;
            options.deliveryMode = PHVideoRequestOptionsDeliveryModeHighQualityFormat;
            __block AVAsset *resolved = nil;
            dispatch_semaphore_t signal = dispatch_semaphore_create(0);
            PHImageRequestID requestId = [[PHImageManager defaultManager]
                requestAVAssetForVideo:photo options:options
                resultHandler:^(AVAsset *asset, __unused AVAudioMix *mix,
                                __unused NSDictionary *info) {
                    resolved = asset;
                    dispatch_semaphore_signal(signal);
                }];
            if (dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW,
                         (int64_t)(90 * NSEC_PER_SEC))) != 0) {
                [[PHImageManager defaultManager] cancelImageRequest:requestId];
                return nil;
            }
            return resolved;
        }

        id urlValue = mxCropGetter(node, @"url");
        if (!urlValue) urlValue = mxCropGetter(node, @"fileUrl");
        NSURL *url = nil;
        if ([urlValue isKindOfClass:[NSURL class]]) url = urlValue;
        if ([urlValue isKindOfClass:[NSString class]]) {
            url = [urlValue hasPrefix:@"file://"] ? [NSURL URLWithString:urlValue]
                                                  : [NSURL fileURLWithPath:urlValue];
        }
        if (url && url.isFileURL) return [AVURLAsset URLAssetWithURL:url options:nil];

        id next = mxCropGetter(node, @"backingItem");
        if (!next || next == node) next = mxCropGetter(node, @"asset");
        if (!next || next == node) next = mxCropGetter(node, @"mediaItem");
        if (next == node) break;
        node = next;
    }
    return nil;
}

static CGSize mxCropOrientedSize(AVAsset *asset) {
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) return CGSizeZero;
    CGRect bounds = CGRectApplyAffineTransform(
        CGRectMake(0, 0, track.naturalSize.width, track.naturalSize.height),
        track.preferredTransform);
    return CGSizeMake(fabs(bounds.size.width), fabs(bounds.size.height));
}

@interface MxVideoNoteCropController : UIViewController
@property (nonatomic, strong) UIView *previewHolder;
@property (nonatomic, strong) UIImageView *poster;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UILabel *loadingLabel;
@property (nonatomic, strong) UILabel *zoomLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) UIButton *normalButton;
@property (nonatomic, strong) UIButton *applyButton;
@property (nonatomic, strong) CAShapeLayer *shadowLayer;
@property (nonatomic, strong) CAShapeLayer *circleLayer;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, assign) CGSize videoSize;
@property (nonatomic, assign) CGPoint center;
@property (nonatomic, assign) CGPoint panStart;
@property (nonatomic, assign) CGFloat cropZoom;
@property (nonatomic, assign) CGFloat pinchStartZoom;
@property (nonatomic, assign) BOOL alreadySelected;
@property (nonatomic, copy) void (^onApply)(CGPoint, CGFloat);
@property (nonatomic, copy) dispatch_block_t onSendNormally;
- (instancetype)initWithCenter:(CGPoint)center zoom:(CGFloat)zoom active:(BOOL)active;
- (void)loadVideoItem:(id)item;
@end

@implementation MxVideoNoteCropController

- (instancetype)initWithCenter:(CGPoint)center zoom:(CGFloat)zoom active:(BOOL)active {
    if ((self = [super init])) {
        _center = CGPointMake(isfinite(center.x) ? center.x : 0.5,
                              isfinite(center.y) ? center.y : 0.5);
        _cropZoom = isfinite(zoom) ? fmax(1.0, fmin(5.0, zoom)) : 1.0;
        _alreadySelected = active;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (UIButton *)makeButton:(NSString *)title background:(UIColor *)color
                  action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    button.backgroundColor = color;
    button.layer.cornerRadius = 12;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    self.titleLabel = [UILabel new];
    self.titleLabel.text = mxCropText(@"VIDEO_NOTE_CROP_TITLE", @"Choose video note crop");
    self.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.textColor = UIColor.whiteColor;
    [self.view addSubview:self.titleLabel];

    self.hintLabel = [UILabel new];
    self.hintLabel.text = mxCropText(@"VIDEO_NOTE_CROP_HINT",
             @"Drag to move, pinch with two fingers to zoom, then Apply and Send.");
    self.hintLabel.textColor = [UIColor colorWithWhite:0.83 alpha:1];
    self.hintLabel.font = [UIFont systemFontOfSize:14];
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.numberOfLines = 2;
    [self.view addSubview:self.hintLabel];

    self.previewHolder = [UIView new];
    self.previewHolder.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
    self.previewHolder.clipsToBounds = YES;
    self.previewHolder.layer.cornerRadius = 14;
    [self.view addSubview:self.previewHolder];

    self.poster = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.poster.contentMode = UIViewContentModeScaleAspectFit;
    [self.previewHolder addSubview:self.poster];

    self.shadowLayer = [CAShapeLayer layer];
    self.shadowLayer.fillRule = kCAFillRuleEvenOdd;
    self.shadowLayer.fillColor = [UIColor colorWithWhite:0 alpha:0.57].CGColor;
    [self.previewHolder.layer addSublayer:self.shadowLayer];
    self.circleLayer = [CAShapeLayer layer];
    self.circleLayer.fillColor = UIColor.clearColor.CGColor;
    self.circleLayer.strokeColor = UIColor.whiteColor.CGColor;
    self.circleLayer.lineWidth = 3;
    [self.previewHolder.layer addSublayer:self.circleLayer];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                     initWithTarget:self action:@selector(panCrop:)];
    // One finger moves the circle. Two fingers change its diameter instead of
    // racing the pan recognizer for the same touches.
    pan.minimumNumberOfTouches = 1;
    pan.maximumNumberOfTouches = 1;
    [self.previewHolder addGestureRecognizer:pan];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
                                        initWithTarget:self action:@selector(pinchCrop:)];
    [self.previewHolder addGestureRecognizer:pinch];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                     initWithTarget:self action:@selector(tapCrop:)];
    [self.previewHolder addGestureRecognizer:tap];

    self.spinner = [[UIActivityIndicatorView alloc]
                       initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.color = UIColor.whiteColor;
    [self.spinner startAnimating];
    [self.previewHolder addSubview:self.spinner];

    // A tiny zoom readout gives feedback while pinching, without hiding the
    // circular region or covering the gallery's Send controls.
    self.zoomLabel = [UILabel new];
    self.zoomLabel.textColor = UIColor.whiteColor;
    self.zoomLabel.font = [UIFont monospacedDigitSystemFontOfSize:13
                                                         weight:UIFontWeightSemibold];
    self.zoomLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    self.zoomLabel.textAlignment = NSTextAlignmentCenter;
    self.zoomLabel.layer.cornerRadius = 10;
    self.zoomLabel.clipsToBounds = YES;
    [self.previewHolder addSubview:self.zoomLabel];

    self.loadingLabel = [UILabel new];
    self.loadingLabel.text = mxCropText(@"VIDEO_NOTE_CROP_LOADING", @"Loading video preview…");
    self.loadingLabel.textColor = UIColor.whiteColor;
    self.loadingLabel.font = [UIFont systemFontOfSize:13];
    self.loadingLabel.textAlignment = NSTextAlignmentCenter;
    [self.previewHolder addSubview:self.loadingLabel];

    self.cancelButton = [self makeButton:mxCropText(@"CANCEL", @"Cancel")
                               background:[UIColor colorWithWhite:0.24 alpha:1]
                                   action:@selector(cancelCrop)];
    self.normalButton = [self makeButton:mxCropText(@"VIDEO_NOTE_CROP_NORMAL", @"Normal video")
                               background:[UIColor colorWithWhite:0.24 alpha:1]
                                   action:@selector(sendNormally)];
    self.normalButton.hidden = !self.alreadySelected;
    self.applyButton = [self makeButton:mxCropText(@"VIDEO_NOTE_CROP_APPLY", @"Apply")
                              background:UIColor.systemBlueColor
                                  action:@selector(applyCrop)];
    self.applyButton.enabled = NO;
    self.applyButton.alpha = 0.5;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    BOOL compact = bounds.size.height < 520;
    CGFloat top = safe.top + (compact ? 10 : 24);
    CGFloat margin = 16;
    CGFloat contentWidth = MAX(1, bounds.size.width - 2 * margin);
    self.titleLabel.frame = CGRectMake(margin, top, contentWidth, 32);
    self.hintLabel.hidden = compact;
    self.hintLabel.frame = CGRectMake(margin + 5, top + 42, contentWidth - 10, 50);

    CGFloat buttonHeight = compact ? 44 : 50;
    CGFloat buttonY = bounds.size.height - safe.bottom - buttonHeight - (compact ? 8 : 24);
    CGFloat previewY = top + (compact ? 47 : 113);
    self.previewHolder.frame = CGRectMake(margin, previewY, contentWidth,
                                          MAX(100, buttonY - previewY - (compact ? 10 : 24)));
    CGFloat gap = 10;
    CGFloat count = self.alreadySelected ? 3 : 2;
    CGFloat each = (contentWidth - gap * (count - 1)) / count;
    self.cancelButton.frame = CGRectMake(margin, buttonY, each, buttonHeight);
    self.normalButton.frame = CGRectMake(margin + each + gap, buttonY, each, buttonHeight);
    self.applyButton.frame = CGRectMake(margin + (count - 1) * (each + gap),
                                        buttonY, each, buttonHeight);
    self.poster.frame = self.previewHolder.bounds;
    self.playerLayer.frame = self.previewHolder.bounds;
    self.shadowLayer.frame = self.previewHolder.bounds;
    self.circleLayer.frame = self.previewHolder.bounds;
    self.spinner.center = CGPointMake(CGRectGetMidX(self.previewHolder.bounds),
                                      CGRectGetMidY(self.previewHolder.bounds) - 10);
    self.loadingLabel.frame = CGRectMake(10, CGRectGetMidY(self.previewHolder.bounds) + 20,
                                         contentWidth - 20, 30);
    self.zoomLabel.frame = CGRectMake(CGRectGetMaxX(self.previewHolder.bounds) - 82, 12, 70, 27);
    [self updateCircle];
}

- (CGRect)videoRect {
    CGRect available = CGRectInset(self.previewHolder.bounds, 2, 2);
    if (self.videoSize.width <= 0 || self.videoSize.height <= 0) return CGRectZero;
    return AVMakeRectWithAspectRatioInsideRect(self.videoSize, available);
}

// At 1× the circle selects the maximum possible square. A two-finger
// pinch adjusts the amount of source video inside that same 640×640 note.
// Shrinking the visible circle is equivalent to zooming IN the final result;
// expanding it again zooms OUT, up to the full original square (1×).
- (void)updateCircle {
    CGRect image = [self videoRect];
    if (CGRectIsEmpty(image)) {
        self.shadowLayer.path = nil;
        self.circleLayer.path = nil;
        return;
    }
    CGFloat diameter = MIN(image.size.width, image.size.height) / self.cropZoom;
    CGFloat halfX = diameter / (2.0 * image.size.width);
    CGFloat halfY = diameter / (2.0 * image.size.height);
    self.center = CGPointMake(fmax(halfX, fmin(1.0 - halfX, self.center.x)),
                               fmax(halfY, fmin(1.0 - halfY, self.center.y)));
    CGPoint position = CGPointMake(CGRectGetMinX(image) + image.size.width * self.center.x,
                                    CGRectGetMinY(image) + image.size.height * self.center.y);
    CGRect ring = CGRectMake(position.x - diameter / 2, position.y - diameter / 2,
                             diameter, diameter);
    UIBezierPath *shade = [UIBezierPath bezierPathWithRect:self.previewHolder.bounds];
    [shade appendPath:[UIBezierPath bezierPathWithOvalInRect:ring]];
    self.shadowLayer.path = shade.CGPath;
    self.circleLayer.path = [UIBezierPath bezierPathWithOvalInRect:ring].CGPath;
    self.zoomLabel.text = [NSString stringWithFormat:@"%.1f×", (double)self.cropZoom];
}

- (void)panCrop:(UIPanGestureRecognizer *)pan {
    CGRect image = [self videoRect];
    if (CGRectIsEmpty(image)) return;
    if (pan.state == UIGestureRecognizerStateBegan) self.panStart = self.center;
    if (pan.state == UIGestureRecognizerStateBegan ||
        pan.state == UIGestureRecognizerStateChanged ||
        pan.state == UIGestureRecognizerStateEnded) {
        CGPoint shift = [pan translationInView:self.previewHolder];
        self.center = CGPointMake(self.panStart.x + shift.x / image.size.width,
                                   self.panStart.y + shift.y / image.size.height);
        [self updateCircle];
    }
}

- (void)pinchCrop:(UIPinchGestureRecognizer *)pinch {
    if (CGRectIsEmpty([self videoRect])) return;
    if (pinch.state == UIGestureRecognizerStateBegan) {
        self.pinchStartZoom = self.cropZoom;
    }
    if (pinch.state == UIGestureRecognizerStateBegan ||
        pinch.state == UIGestureRecognizerStateChanged ||
        pinch.state == UIGestureRecognizerStateEnded) {
        // Fingers moving APART zoom in (smaller source crop). Moving TOGETHER
        // zooms back out. Never exceed the original video's edges.
        CGFloat candidate = self.pinchStartZoom * pinch.scale;
        if (!isfinite(candidate)) return;
        self.cropZoom = fmax(1.0, fmin(5.0, candidate));
        [self updateCircle];
    }
}

- (void)tapCrop:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateEnded) return;
    CGRect image = [self videoRect];
    if (CGRectIsEmpty(image)) return;
    CGPoint point = [tap locationInView:self.previewHolder];
    self.center = CGPointMake((point.x - CGRectGetMinX(image)) / image.size.width,
                               (point.y - CGRectGetMinY(image)) / image.size.height);
    [self updateCircle];
}

- (void)loadVideoItem:(id)item {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        AVAsset *asset = mxCropResolveItem(item);
        CGSize size = asset ? mxCropOrientedSize(asset) : CGSizeZero;
        UIImage *still = nil;
        if (asset && size.width > 0 && size.height > 0) {
            AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
            generator.appliesPreferredTrackTransform = YES;
            generator.maximumSize = CGSizeMake(960, 960);
            CGImageRef picture = [generator copyCGImageAtTime:kCMTimeZero
                                                   actualTime:NULL error:NULL];
            if (picture) {
                still = [UIImage imageWithCGImage:picture];
                CGImageRelease(picture);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            MxVideoNoteCropController *controller = weakSelf;
            if (!controller) return;
            [controller.spinner stopAnimating];
            controller.loadingLabel.hidden = YES;
            if (!asset || size.width < 1 || size.height < 1) {
                controller.loadingLabel.text = mxCropText(@"VIDEO_NOTE_CROP_ERROR",
                                                        @"Could not load this video.");
                controller.loadingLabel.hidden = NO;
                return;
            }
            controller.videoSize = size;
            controller.poster.image = still;
            controller.player = [AVPlayer playerWithPlayerItem:[AVPlayerItem playerItemWithAsset:asset]];
            controller.player.muted = YES;
            controller.playerLayer = [AVPlayerLayer playerLayerWithPlayer:controller.player];
            controller.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
            controller.playerLayer.frame = controller.previewHolder.bounds;
            [controller.previewHolder.layer insertSublayer:controller.playerLayer
                                                    below:controller.shadowLayer];
            controller.applyButton.enabled = YES;
            controller.applyButton.alpha = 1;
            [controller updateCircle];
            [controller.player play];
        });
    });
}

- (void)cancelCrop {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)sendNormally {
    dispatch_block_t completion = self.onSendNormally;
    [self dismissViewControllerAnimated:YES completion:^{
        if (completion) completion();
    }];
}

- (void)applyCrop {
    if (!self.applyButton.enabled || CGRectIsEmpty([self videoRect])) return;
    CGPoint selected = self.center;
    CGFloat zoom = self.cropZoom;
    void (^completion)(CGPoint, CGFloat) = self.onApply;
    [self dismissViewControllerAnimated:YES completion:^{
        if (completion) completion(selected, zoom);
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.player pause];
}

@end

void MxPresentVideoNoteCrop(UIView *sourceView, id galleryItem,
                            CGPoint initialCenter, CGFloat initialZoom,
                            BOOL alreadySelected,
                            void (^onApply)(CGPoint center, CGFloat zoom),
                            dispatch_block_t onSendNormally) {
    if (!sourceView.window || !galleryItem) return;
    UIViewController *presenter = sourceView.window.rootViewController;
    while (presenter.presentedViewController &&
           !presenter.presentedViewController.isBeingDismissed) {
        presenter = presenter.presentedViewController;
    }
    if (!presenter) return;
    MxVideoNoteCropController *picker =
        [[MxVideoNoteCropController alloc] initWithCenter:initialCenter
                                                    zoom:initialZoom active:alreadySelected];
    picker.onApply = onApply;
    picker.onSendNormally = onSendNormally;
    [presenter presentViewController:picker animated:YES completion:nil];
    [picker loadVideoItem:galleryItem];
}
