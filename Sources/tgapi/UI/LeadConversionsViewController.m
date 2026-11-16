// Lead Conversions: Photos -> PDF, and PDF -> high quality images.
// Local-only conversion; explicit sharing or Saved Messages upload by user.
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import "LeadMenu.h"
#import "../Calls/LeadSavedMessagesUpload.h"

static NSURL *LeadConversionRoot(void) {
    NSURL *docs = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                           inDomains:NSUserDomainMask].firstObject;
    NSURL *root = [docs URLByAppendingPathComponent:@"LeadConversions" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}

static NSString *LeadSafeConversionName(NSString *input, NSString *fallback) {
    NSString *text = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([text.lowercaseString hasSuffix:@".pdf"]) text = [text substringToIndex:text.length - 4];
    for (NSString *bad in @[@"/", @"\\", @":", @"\n", @"\r"]) {
        text = [text stringByReplacingOccurrencesOfString:bad withString:@"-"];
    }
    if (!text.length || [text isEqualToString:@"."] || [text isEqualToString:@".."]) text = fallback;
    if (text.length > 65) text = [text substringToIndex:65];
    return text;
}

static NSURL *LeadUniqueExportURL(NSURL *folder, NSString *base, NSString *ext) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *proposed = [folder URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@",base,ext]];
    for (int i=2; [fm fileExistsAtPath:proposed.path] && i<10000; i++) {
        proposed = [folder URLByAppendingPathComponent:
                    [NSString stringWithFormat:@"%@-%d.%@",base,i,ext]];
    }
    return proposed;
}

static UIImage *LeadConversionPreview(NSURL *url, NSInteger pixels) {
    if (!url) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return nil;
    NSDictionary *options = @{
        (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
        (__bridge id)kCGImageSourceCreateThumbnailWithTransform:@YES,
        (__bridge id)kCGImageSourceThumbnailMaxPixelSize:@(MAX(64,pixels))
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options);
    UIImage *preview = image ? [UIImage imageWithCGImage:image] : nil;
    if (image) CGImageRelease(image);
    CFRelease(source);
    return preview;
}

static NSData *LeadPDFThumbJPEGFromUIImage(UIImage *image) {
    if (!image) return nil;
    CGSize size=image.size;
    if (size.width<=0 || size.height<=0) return nil;
    CGFloat factor=MIN(1,320.0/MAX(size.width,size.height));
    CGSize target=CGSizeMake(MAX(1,round(size.width*factor)),MAX(1,round(size.height*factor)));
    UIGraphicsBeginImageContextWithOptions(target,YES,1.0);
    [[UIColor whiteColor] setFill];
    UIRectFill((CGRect){CGPointZero,target});
    [image drawInRect:(CGRect){CGPointZero,target}];
    UIImage *scaled=UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!scaled) return nil;
    for (CGFloat q=0.88; q>=0.20; q-=0.15) {
        NSData *data=UIImageJPEGRepresentation(scaled,q);
        if (data.length>0 && data.length<190*1024) return data;
    }
    return nil;
}

static NSData *LeadPDFThumbJPEG(NSURL *url) {
    return LeadPDFThumbJPEGFromUIImage(LeadConversionPreview(url, 320));
}

// Direct Telegram chat chooser shared with call recordings, never the iOS sheet.
extern void LeadPresentConversionChatPicker(NSArray<NSURL *> *files,
                                            BOOL sendAsPhotos,
                                            NSData *thumbnailJPEG,
                                            UIViewController *presenter);
// Telegram chat chooser (in-app list of the user's chats).
static void LeadConversionShare(UIViewController *host, NSArray<NSURL *> *files,
                                BOOL photos, NSData *thumbnailJPEG) {
    if(!host || !files.count)return;
    LeadPresentConversionChatPicker(files,photos,thumbnailJPEG,host);
}

// Official iOS share sheet: the user picks the destination app.
static void LeadConversionIOSShare(UIViewController *host, NSArray<NSURL *> *files, UIView *anchor) {
    if(!host || !files.count)return;
    UIActivityViewController *sheet=[[UIActivityViewController alloc]
        initWithActivityItems:files applicationActivities:nil];
    UIPopoverPresentationController *popover=sheet.popoverPresentationController;
    if(popover) {
        UIView *source=anchor?:host.view;
        popover.sourceView=source;
        popover.sourceRect=anchor?anchor.bounds:CGRectMake(CGRectGetMidX(host.view.bounds),
                                                           CGRectGetMidY(host.view.bounds),1,1);
    }
    UIViewController *top=host;
    while(top.presentedViewController && !top.presentedViewController.isBeingDismissed)
        top=top.presentedViewController;
    [top presentViewController:sheet animated:YES completion:nil];
}

static void LeadConversionAlert(UIViewController *host, NSString *title, NSString *message) {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}

static NSArray<NSDictionary *> *LeadPDFPageSizes(void) {
    return @[
        @{@"title":@"A4 عمودي", @"width":@595.28, @"height":@841.89},
        @{@"title":@"A4 أفقي", @"width":@841.89, @"height":@595.28},
        @{@"title":@"A5 عمودي", @"width":@419.53, @"height":@595.28},
        @{@"title":@"Letter", @"width":@612, @"height":@792},
        @{@"title":@"16:9 أفقي", @"width":@960, @"height":@540},
        @{@"title":@"9:16 عمودي", @"width":@540, @"height":@960},
        @{@"title":@"4:3 أفقي", @"width":@800, @"height":@600},
        @{@"title":@"3:4 عمودي", @"width":@600, @"height":@800},
        @{@"title":@"1:1 مربع", @"width":@640, @"height":@640}
    ];
}

@interface LeadConversionPDFPicker : UIDocumentPickerViewController
@end
@implementation LeadConversionPDFPicker
@end

// A simple preview for a rendered PDF page, including explicit share/save.
@interface LeadConversionPreviewController : UIViewController
- (instancetype)initWithImageURL:(NSURL *)url;
@end
@implementation LeadConversionPreviewController {
    NSURL *_url;
    UIImageView *_imageView;
    BOOL _sending;
}
- (instancetype)initWithImageURL:(NSURL *)url {
    if ((self=[super init])) _url=url;
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=_url.lastPathComponent;
    self.view.backgroundColor=UIColor.systemBackgroundColor;
    _imageView=[[UIImageView alloc] initWithFrame:self.view.bounds];
    _imageView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    _imageView.contentMode=UIViewContentModeScaleAspectFit;
    _imageView.image=[UIImage imageWithContentsOfFile:_url.path];
    [self.view addSubview:_imageView];
    self.navigationItem.rightBarButtonItems=@[
        [[UIBarButtonItem alloc] initWithTitle:@"المحفوظة" style:UIBarButtonItemStylePlain
                                       target:self action:@selector(sendSaved)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                     target:self action:@selector(share)]
    ];
}
- (void)share {
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:nil message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"مشاركة (قائمة iOS)" style:UIAlertActionStyleDefault
                                          handler:^(__unused UIAlertAction *a) {
        LeadConversionIOSShare(self,@[self->_url],nil);
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"إرسال لمحادثة تيليگرام" style:UIAlertActionStyleDefault
                                          handler:^(__unused UIAlertAction *a) {
        LeadConversionShare(self,@[self->_url],YES,nil);
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.barButtonItem=self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)sendSaved {
    if (_sending) return;
    _sending=YES;
    self.navigationItem.prompt=@"جاري إرسال الصورة إلى المحفوظة…";
    __weak typeof(self) weakSelf=self;
    [LeadSavedMessagesUpload sendPhotoToSavedMessages:_url progress:^(double progress) {
        __strong typeof(weakSelf) self=weakSelf;
        if (self) self.navigationItem.prompt=[NSString stringWithFormat:@"رفع الصورة %.0f%%",progress*100];
    } completion:^(NSString *error) {
        __strong typeof(weakSelf) self=weakSelf;
        if (!self) return;
        self->_sending=NO;
        self.navigationItem.prompt=nil;
        if (error.length) LeadConversionAlert(self,@"فشل الإرسال",error);
        else [LeadToast showText:@"أُرسلت الصورة إلى المحفوظة" symbol:@"checkmark.circle" inView:self.view];
    }];
}
@end

// ------------------------- Photos -> PDF -------------------------

@interface LeadPhotosToPDFController : UITableViewController <PHPickerViewControllerDelegate>
@property(nonatomic,strong) NSArray<NSURL *> *imageFiles;
@property(nonatomic,strong) NSURL *stagingDirectory;
@property(nonatomic,strong) NSURL *outputURL;
@property(nonatomic,strong) NSData *customThumbnail;
@property(nonatomic,copy) NSString *fileName;
@property(nonatomic,assign) NSUInteger pageSizeIndex;
@property(nonatomic,assign) BOOL pickingThumbnail;
@property(nonatomic,assign) BOOL working;
@property(nonatomic,assign) BOOL uploading;
@end

@implementation LeadPhotosToPDFController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"صور إلى PDF";
    self.fileName=@"الصور";
    self.pageSizeIndex=0;
    self.tableView.backgroundColor=UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight=UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight=58;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section==0?1:(section==1?3:(self.outputURL?4:1));
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"الخطوة 1 — اختيار الصور", @"الخطوة 2 — خيارات الملف", @"الخطوة 3 — إنشاء وتصدير"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section==1) return @"الصور تبقى بنسبتها الأصلية بدون مطّ؛ أي مساحة فارغة بالصفحة تكون بيضاء. الصورة المصغّرة تخص إرسال تيليگرام وقد يتجاهلها بعض العملاء.";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index {
    static NSString *reuse=@"LeadPDFOptionCell";
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuse];
    cell.imageView.image=nil;
    cell.textLabel.textColor=UIColor.labelColor;
    cell.detailTextLabel.text=@"";
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    if (index.section==0) {
        cell.textLabel.text=@"اختيار الصور من المعرض";
        cell.detailTextLabel.text=[NSString stringWithFormat:@"%lu صورة",(unsigned long)self.imageFiles.count];
    } else if(index.section==1) {
        if(index.row==0) { cell.textLabel.text=@"اسم ملف PDF";cell.detailTextLabel.text=[self.fileName stringByAppendingString:@".pdf"]; }
        else if(index.row==1) { cell.textLabel.text=@"مقاس الصفحة";cell.detailTextLabel.text=LeadPDFPageSizes()[self.pageSizeIndex][@"title"]; }
        else { cell.textLabel.text=@"الصورة المصغّرة";cell.detailTextLabel.text=self.customThumbnail?@"صورة مخصصة":@"أول صورة تلقائياً"; }
    } else {
        if(index.row==0) { cell.textLabel.text=self.working?@"جاري إنشاء الملف…":@"إنشاء PDF";cell.detailTextLabel.text=@"التالي"; }
        else if(index.row==1) { cell.textLabel.text=@"المشاركة";cell.detailTextLabel.text=@"قائمة iOS"; }
        else if(index.row==2) { cell.textLabel.text=@"مشاركة للمحادثات";cell.detailTextLabel.text=@"اختر محادثة تيليگرام"; }
        else { cell.textLabel.text=@"إرسال إلى الرسائل المحفوظة";cell.detailTextLabel.text=@"مباشرة"; }
    }
    cell.selectionStyle=(self.working||self.uploading)?UITableViewCellSelectionStyleNone:UITableViewCellSelectionStyleDefault;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)index {
    [tableView deselectRowAtIndexPath:index animated:YES];
    if (self.working || self.uploading) return;
    if (index.section==0) { [self openPhotoPickerForThumbnail:NO];return; }
    if (index.section==1) {
        if(index.row==0) [self editName];
        else if(index.row==1) [self chooseSize];
        else [self chooseThumbnail];
        return;
    }
    if(index.row==0) [self createPDF];
    else if(index.row==1 && self.outputURL)
        LeadConversionIOSShare(self,@[self.outputURL],[tableView cellForRowAtIndexPath:index]);
    else if(index.row==2 && self.outputURL)
        LeadConversionShare(self,@[self.outputURL],NO,
           self.customThumbnail?:LeadPDFThumbJPEG(self.imageFiles.firstObject));
    else if(index.row==3 && self.outputURL) [self sendToSaved];
}
- (void)editName {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"اسم الملف"
                           message:@"اكتب الاسم فقط؛ صيغة .pdf تُضاف تلقائياً."
                    preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text=self.fileName;
        field.placeholder=@"اسم الملف";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"حفظ" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        self.fileName=LeadSafeConversionName(alert.textFields.firstObject.text,@"الصور");
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)chooseSize {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"مقاس صفحات PDF"
                    message:@"جميع الصفحات ستكون بنفس المقاس مع حواف بيضاء عند اختلاف نسب الصور."
                    preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *items=LeadPDFPageSizes();
    for(NSUInteger i=0;i<items.count;i++) {
        [sheet addAction:[UIAlertAction actionWithTitle:items[i][@"title"] style:UIAlertActionStyleDefault
                                          handler:^(__unused UIAlertAction *a) {
            self.pageSizeIndex=i;
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView=self.view;
    sheet.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(self.view.bounds),80,1,1);
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)chooseThumbnail {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"صورة PDF المصغّرة"
                                   message:@"تُستخدم أول صورة تلقائياً، أو اختَر صورة مختلفة لإرفاقها عند رفع PDF إلى تيليگرام."
                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"اختيار من المعرض" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self openPhotoPickerForThumbnail:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"استخدام أول صورة" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        self.customThumbnail=nil;
        [self.tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView=self.view;
    sheet.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(self.view.bounds),80,1,1);
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)openPhotoPickerForThumbnail:(BOOL)thumbnail {
    self.pickingThumbnail=thumbnail;
    PHPickerConfiguration *configuration=[[PHPickerConfiguration alloc] init];
    configuration.filter=[PHPickerFilter imagesFilter];
    configuration.selectionLimit=thumbnail?1:0;
    PHPickerViewController *picker=[[PHPickerViewController alloc] initWithConfiguration:configuration];
    picker.delegate=self;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    BOOL thumb=self.pickingThumbnail;
    [picker dismissViewControllerAnimated:YES completion:nil];
    if(!results.count) return;
    if(thumb) {
        NSItemProvider *provider=results.firstObject.itemProvider;
        if (![provider canLoadObjectOfClass:UIImage.class]) {
            LeadConversionAlert(self,@"صورة غير مدعومة",@"ما قدرت أقرأ الصورة المختارة.");
            return;
        }
        __weak typeof(self) weakSelf=self;
        [provider loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> object,NSError *error) {
            UIImage *image=[object isKindOfClass:UIImage.class]?(UIImage *)object:nil;
            NSData *jpeg=image?LeadPDFThumbJPEGFromUIImage(image):nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self=weakSelf;
                if(!self) return;
                if(!jpeg.length) LeadConversionAlert(self,@"فشل الصورة المصغّرة",error.localizedDescription?:@"الصورة غير قابلة للاستخدام.");
                else {self.customThumbnail=jpeg;[self.tableView reloadData];}
            });
        }];
        return;
    }
    if(results.count>100) {
        LeadConversionAlert(self,@"عدد الصور كبير",@"اختر حتى 100 صورة لكل ملف PDF حتى يبقى التحويل مستقراً.");
        return;
    }
    self.working=YES;
    self.navigationItem.prompt=@"جاري تجهيز الصور…";
    NSString *unique=[NSUUID UUID].UUIDString;
    NSURL *stage=[NSURL fileURLWithPath:[NSTemporaryDirectory()
                         stringByAppendingPathComponent:[@"LeadImages-" stringByAppendingString:unique]]
                         isDirectory:YES];
    NSError *mkdirError=nil;
    if(![NSFileManager.defaultManager createDirectoryAtURL:stage withIntermediateDirectories:YES attributes:nil error:&mkdirError]) {
        self.working=NO;self.navigationItem.prompt=nil;
        LeadConversionAlert(self,@"خطأ",mkdirError.localizedDescription);
        return;
    }
    NSMutableArray *ordered=[NSMutableArray arrayWithCapacity:results.count];
    for(NSUInteger i=0;i<results.count;i++) [ordered addObject:NSNull.null];
    dispatch_group_t group=dispatch_group_create();
    for(NSUInteger i=0;i<results.count;i++) {
        dispatch_group_enter(group);
        NSItemProvider *provider=results[i].itemProvider;
        [provider loadFileRepresentationForTypeIdentifier:UTTypeImage.identifier
                                       completionHandler:^(NSURL *url,NSError *error) {
            @autoreleasepool {
                if(url) {
                    NSString *extension=url.pathExtension.length?url.pathExtension:@"img";
                    NSURL *target=[stage URLByAppendingPathComponent:
                                   [NSString stringWithFormat:@"%03lu.%@",(unsigned long)i,extension]];
                    if([NSFileManager.defaultManager copyItemAtURL:url toURL:target error:nil]) {
                        @synchronized(ordered) {ordered[i]=target;}
                    }
                }
                dispatch_group_leave(group);
            }
        }];
    }
    __weak typeof(self) weakSelf=self;
    dispatch_group_notify(group,dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self=weakSelf;
        if(!self) return;
        self.working=NO;
        self.navigationItem.prompt=nil;
        NSMutableArray<NSURL *> *files=[NSMutableArray array];
        for(id item in ordered) if([item isKindOfClass:NSURL.class]) [files addObject:item];
        if(files.count!=results.count) {
            [[NSFileManager defaultManager] removeItemAtURL:stage error:nil];
            LeadConversionAlert(self,@"تعذر تجهيز الصور",@"بعض الصور ما انقرأت؛ أعد الاختيار حتى ما ينقص ملف PDF أي صفحة.");
            return;
        }
        if(self.stagingDirectory) [[NSFileManager defaultManager] removeItemAtURL:self.stagingDirectory error:nil];
        self.stagingDirectory=stage;
        self.imageFiles=files;
        self.customThumbnail=nil;
        self.outputURL=nil;
        [self.tableView reloadData];
    });
}
- (void)createPDF {
    if(!self.imageFiles.count) {
        LeadConversionAlert(self,@"اختيار الصور",@"حدد الصور أولاً ثم اختَر المقاس والاسم.");
        return;
    }
    self.working=YES;
    self.navigationItem.prompt=@"جاري إنشاء ملف PDF…";
    [self.tableView reloadData];
    NSArray<NSURL *> *images=[self.imageFiles copy];
    NSDictionary *size=LeadPDFPageSizes()[self.pageSizeIndex];
    CGRect page=CGRectMake(0,0,[size[@"width"] doubleValue],[size[@"height"] doubleValue]);
    NSURL *dest=LeadUniqueExportURL(LeadConversionRoot(),
        LeadSafeConversionName(self.fileName,@"الصور"),@"pdf");
    __weak typeof(self) weakSelf=self;
    __strong typeof(self) controllerDuringExport=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        (void)controllerDuringExport;
        @autoreleasepool {
            NSString *failed=nil;
            UIGraphicsBeginPDFContextToFile(dest.path,page,@{
                (__bridge NSString *)kCGPDFContextCreator:@"Lead Conversions"
            });
            for(NSURL *url in images) {
                @autoreleasepool {
                    UIImage *image=[UIImage imageWithContentsOfFile:url.path];
                    if(!image || image.size.width<=0 || image.size.height<=0) {
                        failed=@"صورة مختارة غير قابلة للقراءة.";
                        break;
                    }
                    UIGraphicsBeginPDFPageWithInfo(page,nil);
                    [[UIColor whiteColor] setFill];
                    UIRectFill(page);
                    CGFloat factor=MIN(CGRectGetWidth(page)/image.size.width,
                                       CGRectGetHeight(page)/image.size.height);
                    CGSize drawSize=CGSizeMake(image.size.width*factor,image.size.height*factor);
                    CGRect destination=CGRectMake((CGRectGetWidth(page)-drawSize.width)/2,
                                                 (CGRectGetHeight(page)-drawSize.height)/2,
                                                 drawSize.width,drawSize.height);
                    [image drawInRect:destination];
                }
            }
            UIGraphicsEndPDFContext();
            NSDictionary *attrs=[NSFileManager.defaultManager attributesOfItemAtPath:dest.path error:nil];
            if([attrs[NSFileSize] unsignedLongLongValue]==0 && !failed.length)
                failed=@"ملف PDF الناتج فارغ.";
            if(failed.length) [NSFileManager.defaultManager removeItemAtURL:dest error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self=weakSelf;
                if(!self) return;
                self.working=NO;self.navigationItem.prompt=nil;
                if(failed.length) LeadConversionAlert(self,@"فشل التحويل",failed);
                else {
                    self.outputURL=dest;
                    [LeadToast showText:@"ملف PDF جاهز للمشاركة أو المحفوظة" symbol:@"checkmark.circle" inView:self.view];
                }
                [self.tableView reloadData];
            });
        }
    });
}
- (void)sendToSaved {
    if(!self.outputURL||self.uploading) return;
    self.uploading=YES;
    NSURL *thumb=self.imageFiles.firstObject;
    NSData *jpeg=self.customThumbnail?:LeadPDFThumbJPEG(thumb);
    self.navigationItem.prompt=@"رفع PDF إلى الرسائل المحفوظة…";
    __weak typeof(self) weakSelf=self;
    [LeadSavedMessagesUpload sendDocumentToSavedMessages:self.outputURL thumbnailJPEG:jpeg
        progress:^(double progress) {
            __strong typeof(weakSelf) self=weakSelf;
            if (self) self.navigationItem.prompt=[NSString stringWithFormat:@"رفع PDF %.0f%%",progress*100];
        } completion:^(NSString *error) {
            __strong typeof(weakSelf) self=weakSelf;
            if(!self) return;
            self.uploading=NO;self.navigationItem.prompt=nil;
            if(error.length) LeadConversionAlert(self,@"تعذر الإرسال",error);
            else [LeadToast showText:@"وصل PDF إلى رسائلك المحفوظة" symbol:@"checkmark.circle" inView:self.view];
            [self.tableView reloadData];
        }];
}
- (void)dealloc {
    if(self.stagingDirectory) [NSFileManager.defaultManager removeItemAtURL:self.stagingDirectory error:nil];
}
@end

// ------------------------- PDF -> Photos -------------------------

@interface LeadPDFToPhotosController : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic,strong) NSURL *pdfURL;
@property(nonatomic,strong) NSArray<NSURL *> *imageFiles;
@property(nonatomic,assign) BOOL working;
@property(nonatomic,assign) BOOL uploading;
@property(nonatomic,assign) NSUInteger sendIndex;
@end

@implementation LeadPDFToPhotosController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"PDF إلى صور";
    self.tableView.backgroundColor=UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight=UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight=85;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.imageFiles.count?3:1;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section==0?1:(section==1?self.imageFiles.count:3);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if(section==0) return @"اختيار ملف PDF";
    if(section==1) return [NSString stringWithFormat:@"الصور المستخرجة — %lu صفحة",(unsigned long)self.imageFiles.count];
    return @"مشاركة أو إرسال الكل";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index {
    static NSString *reuse=@"LeadPDFImageCell";
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:reuse];
    if(!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    cell.imageView.image=nil;
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.textColor=UIColor.labelColor;
    cell.detailTextLabel.text=@"";
    if(index.section==0) {
        cell.textLabel.text=@"اختيار PDF من الملفات";
        cell.detailTextLabel.text=self.pdfURL.lastPathComponent?:@"يحفظ النتائج كصور PNG بدون فقد التفاصيل";
    } else if(index.section==1) {
        NSURL *url=self.imageFiles[index.row];
        cell.textLabel.text=[NSString stringWithFormat:@"الصفحة %ld",(long)index.row+1];
        cell.detailTextLabel.text=@"معاينة · مشاركة · إرسال للمحفوظة";
        cell.imageView.image=LeadConversionPreview(url,96);
        cell.imageView.contentMode=UIViewContentModeScaleAspectFit;
    } else {
        if(index.row==0) { cell.textLabel.text=@"المشاركة";cell.detailTextLabel.text=@"قائمة iOS"; }
        else if(index.row==1) { cell.textLabel.text=@"مشاركة للمحادثات";cell.detailTextLabel.text=@"اختر محادثة تيليگرام — كصور"; }
        else { cell.textLabel.text=@"إرسال جميع الصور للمحفوظة";cell.detailTextLabel.text=@"مباشرة — كصور وليس ملف PDF"; }
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)index {
    [tableView deselectRowAtIndexPath:index animated:YES];
    if(self.working || self.uploading) return;
    if(index.section==0) [self choosePDF];
    else if(index.section==1)
        [self.navigationController pushViewController:[[LeadConversionPreviewController alloc]
               initWithImageURL:self.imageFiles[index.row]] animated:YES];
    else if(index.row==0) LeadConversionIOSShare(self,self.imageFiles,[tableView cellForRowAtIndexPath:index]);
    else if(index.row==1) LeadConversionShare(self,self.imageFiles,YES,nil);
    else [self sendAllToSaved];
}
- (void)choosePDF {
    // Dedicated subclass avoids Lead's global Files -> Send rename popup.
    LeadConversionPDFPicker *picker=[[LeadConversionPDFPicker alloc]
         initWithDocumentTypes:@[@"com.adobe.pdf"] inMode:UIDocumentPickerModeImport];
    picker.allowsMultipleSelection=NO;
    picker.delegate=self;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url=urls.firstObject;
    if(!url) return;
    BOOL scoped=[url startAccessingSecurityScopedResource];
    NSString *base=LeadSafeConversionName(url.lastPathComponent.stringByDeletingPathExtension,@"PDF");
    NSURL *copied=LeadUniqueExportURL(LeadConversionRoot(),base,@"pdf");
    NSError *error=nil;
    BOOL copiedOK=[NSFileManager.defaultManager copyItemAtURL:url toURL:copied error:&error];
    if(scoped) [url stopAccessingSecurityScopedResource];
    if(!copiedOK) {
        LeadConversionAlert(self,@"تعذر قراءة PDF",error.localizedDescription?:@"الملف غير متاح.");
        return;
    }
    self.pdfURL=copied;
    [self renderPages];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    [self documentPicker:controller didPickDocumentsAtURLs:url?@[url]:@[]];
}
- (void)renderPages {
    if(!self.pdfURL || self.working) return;
    self.working=YES;
    self.imageFiles=nil;
    self.navigationItem.prompt=@"جاري تحويل صفحات PDF إلى صور…";
    [self.tableView reloadData];
    NSURL *pdf=[self.pdfURL copy];
    NSString *folderName=[NSString stringWithFormat:@"%@-صور-%@",
      LeadSafeConversionName(pdf.lastPathComponent.stringByDeletingPathExtension,@"PDF"),
      [[NSUUID UUID].UUIDString substringToIndex:8]];
    NSURL *folder=[LeadConversionRoot() URLByAppendingPathComponent:folderName isDirectory:YES];
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool {
            NSString *errorMessage=nil;
            NSMutableArray<NSURL *> *output=[NSMutableArray array];
            CGPDFDocumentRef pdfDocument=CGPDFDocumentCreateWithURL((__bridge CFURLRef)pdf);
            size_t total=pdfDocument?CGPDFDocumentGetNumberOfPages(pdfDocument):0;
            if (!pdfDocument || (CGPDFDocumentIsEncrypted(pdfDocument) && !CGPDFDocumentIsUnlocked(pdfDocument)))
                errorMessage=@"الملف محمي بكلمة مرور أو غير صالح.";
            else if(total==0) errorMessage=@"الملف ما يحتوي صفحات قابلة للتحويل.";
            else if(total>300) errorMessage=@"الملف يحتوي أكثر من 300 صفحة؛ لتجنب نفاد ذاكرة الجهاز قسّمه أولاً.";
            if(!errorMessage && ![NSFileManager.defaultManager createDirectoryAtURL:folder
                        withIntermediateDirectories:YES attributes:nil error:nil]) errorMessage=@"تعذر إنشاء مجلد الصور.";
            if(!errorMessage) {
                for(size_t i=1;i<=total;i++) {
                    @autoreleasepool {
                        CGPDFPageRef page=CGPDFDocumentGetPage(pdfDocument,i);
                        if(!page) {errorMessage=@"تعذر قراءة إحدى الصفحات.";break;}
                        CGPDFBox boxType=kCGPDFCropBox;
                        CGRect bounds=CGPDFPageGetBoxRect(page,boxType);
                        if(bounds.size.width<1 || bounds.size.height<1) {
                            boxType=kCGPDFMediaBox;
                            bounds=CGPDFPageGetBoxRect(page,boxType);
                        }
                        if(bounds.size.width<1 || bounds.size.height<1) {errorMessage=@"أبعاد الصفحة غير صالحة.";break;}
                        int rotation=((CGPDFPageGetRotationAngle(page)%360)+360)%360;
                        CGFloat pw=(rotation==90||rotation==270)?bounds.size.height:bounds.size.width;
                        CGFloat ph=(rotation==90||rotation==270)?bounds.size.width:bounds.size.height;
                        CGFloat factor=MIN(2.0,2400.0/MAX(pw,ph));
                        CGSize size=CGSizeMake(MAX(1,ceil(pw*factor)),MAX(1,ceil(ph*factor)));
                        UIGraphicsBeginImageContextWithOptions(size,YES,1.0);
                        CGContextRef context=UIGraphicsGetCurrentContext();
                        if(!context) {errorMessage=@"تعذر إنشاء الصورة.";UIGraphicsEndImageContext();break;}
                        CGContextSetRGBFillColor(context,1,1,1,1);
                        CGContextFillRect(context,(CGRect){CGPointZero,size});
                        CGContextSaveGState(context);
                        CGContextTranslateCTM(context,0,size.height);
                        CGContextScaleCTM(context,1,-1);
                        CGAffineTransform transform=CGPDFPageGetDrawingTransform(
                            page,boxType,(CGRect){CGPointZero,size},0,true);
                        CGContextConcatCTM(context,transform);
                        CGContextDrawPDFPage(context,page);
                        CGContextRestoreGState(context);
                        UIImage *rendered=UIGraphicsGetImageFromCurrentImageContext();
                        NSData *png=UIImagePNGRepresentation(rendered);
                        UIGraphicsEndImageContext();
                        if(!png.length) {errorMessage=@"فشلت كتابة إحدى الصور.";break;}
                        NSURL *dest=[folder URLByAppendingPathComponent:
                            [NSString stringWithFormat:@"صفحة-%04lu.png",(unsigned long)i]];
                        if(![png writeToURL:dest atomically:YES]) {errorMessage=@"تعذر حفظ إحدى الصور.";break;}
                        [output addObject:dest];
                        if(i%5==0 || i==total) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                __strong typeof(weakSelf) self=weakSelf;
                                if(self) self.navigationItem.prompt=[NSString stringWithFormat:@"تحويل الصفحة %lu من %lu",
                                                                      (unsigned long)i,(unsigned long)total];
                            });
                        }
                    }
                }
            }
            if(pdfDocument) CGPDFDocumentRelease(pdfDocument);
            if(errorMessage.length) [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self=weakSelf;
                if(!self) return;
                self.working=NO;self.navigationItem.prompt=nil;
                if(errorMessage.length) LeadConversionAlert(self,@"فشل التحويل",errorMessage);
                else {
                    self.imageFiles=output;
                    [LeadToast showText:[NSString stringWithFormat:@"تم استخراج %lu صورة",(unsigned long)output.count]
                                symbol:@"checkmark.circle" inView:self.view];
                }
                [self.tableView reloadData];
            });
        }
    });
}
- (void)sendAllToSaved {
    if(!self.imageFiles.count||self.uploading) return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"إرسال الصور إلى المحفوظة"
          message:[NSString stringWithFormat:@"إرسال %lu صورة كرسائل صور منفصلة؟",
                   (unsigned long)self.imageFiles.count]
 preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إرسال" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        self.uploading=YES;
        self.sendIndex=0;
        [self sendNextImage];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)sendNextImage {
    if(!self.uploading || self.sendIndex>=self.imageFiles.count) {
        self.uploading=NO;
        self.navigationItem.prompt=nil;
        [LeadToast showText:@"اكتمل إرسال الصور للمحفوظة" symbol:@"checkmark.circle" inView:self.view];
        return;
    }
    NSURL *image=self.imageFiles[self.sendIndex];
    NSUInteger current=self.sendIndex+1;
    self.navigationItem.prompt=[NSString stringWithFormat:@"إرسال %lu من %lu…",
                                 (unsigned long)current,(unsigned long)self.imageFiles.count];
    __weak typeof(self) weakSelf=self;
    [LeadSavedMessagesUpload sendPhotoToSavedMessages:image progress:^(double progress) {
        __strong typeof(weakSelf) self=weakSelf;
        if(self) self.navigationItem.prompt=[NSString stringWithFormat:@"صورة %lu/%lu — %.0f%%",
                              (unsigned long)current,(unsigned long)self.imageFiles.count,progress*100];
    } completion:^(NSString *error) {
        __strong typeof(weakSelf) self=weakSelf;
        if(!self) return;
        if(error.length) {
            self.uploading=NO;
            self.navigationItem.prompt=nil;
            LeadConversionAlert(self,@"توقف الإرسال",
               [NSString stringWithFormat:@"نجح إرسال %lu صورة. الخطأ: %@",
                (unsigned long)self.sendIndex,error]);
            return;
        }
        self.sendIndex++;
        [self sendNextImage];
    }];
}
@end

// ------------------------- Selection screen -------------------------

@implementation LeadConversionsViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"التحويلات";
    self.tableView.backgroundColor=UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight=76;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 2; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"اختَر نوع التحويل";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"يتم إنشاء الملفات على جهازك. ما ينرسل أي ملف إلى تيليگرام إلا من تختار الإرسال بنفسك.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index {
    static NSString *reuse=@"LeadConversionChoice";
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:reuse];
    if(!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    cell.textLabel.text=index.row==0?@"صور إلى PDF":@"PDF إلى صور";
    cell.detailTextLabel.text=index.row==0?
       @"حدد الصور ثم الاسم والمقاس وThumbnail، وبعدها شارك الملف":
       @"اختر PDF، استخرج جميع الصفحات، وشارك الصور أو أرسلها للمحفوظة";
    cell.detailTextLabel.numberOfLines=2;
    cell.imageView.image=[UIImage systemImageNamed:index.row==0?@"doc.richtext":@"photo.on.rectangle"];
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)index {
    [tableView deselectRowAtIndexPath:index animated:YES];
    UIViewController *next=index.row==0?[LeadPhotosToPDFController new]:[LeadPDFToPhotosController new];
    [self.navigationController pushViewController:next animated:YES];
}
@end
