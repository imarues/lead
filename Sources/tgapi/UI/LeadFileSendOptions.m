// Lead custom document send (iOS 14+).
//
// After the user picks one or more files in Files, Lead opens a composer:
// one block per file with
//   - a name field (no extension; the extension is kept automatically),
//   - a cover (thumbnail) square: "بدون غلاف" until the user taps it and picks
//     an image from the gallery,
//   - an optional description that is sent with the file.
// Blocks are separate sections so every file is edited on its own.
//
// Nothing reaches Telegram until the user taps "إرسال". Files are then handed
// to Telegram's own sender one at a time; the name, cover and description are
// applied on the wire by TLParser.rewriteCustomFileSend. Original files are
// never modified.
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import "../Headers.h"
#import "LeadDesign.h"

extern BOOL LeadSendRawRequest(NSData *payload, void (^done)(NSData *result, NSString *error));

static char kLeadFilePickerProxyKey;
static NSMutableSet *gLeadActiveFilePickers;
static void (*gLeadOriginalSetDocumentDelegate)(id, SEL, id) = NULL;
static BOOL gLeadCustomFilePickerHookInstalled = NO;
static const int32_t kLeadUploadSaveFilePart = (int32_t)0xb304a621;
static const int32_t kLeadBoolTrue = (int32_t)0x997275b5;
static const NSUInteger kLeadCaptionLimit = 1024;

static void LeadFileInt32(NSMutableData *d, int32_t n) { [d appendBytes:&n length:4]; }
static void LeadFileInt64(NSMutableData *d, int64_t n) { [d appendBytes:&n length:8]; }
static void LeadFileBytes(NSMutableData *d, NSData *value) {
    NSUInteger length = value.length;
    NSUInteger headerSize = length < 254 ? 1 : 4;
    if (length < 254) {
        uint8_t l = (uint8_t)length;
        [d appendBytes:&l length:1];
    } else {
        uint8_t h[] = {254, (uint8_t)(length & 255),
                       (uint8_t)((length >> 8) & 255),
                       (uint8_t)((length >> 16) & 255)};
        [d appendBytes:h length:4];
    }
    [d appendData:value];
    uint8_t zero[3] = {0};
    NSUInteger padding = (4 - (length + headerSize) % 4) % 4;
    if (padding) [d appendBytes:zero length:padding];
}

static NSData *LeadJPEGThumbnail(UIImage *image) {
    if (!image || image.size.width <= 0 || image.size.height <= 0) return nil;
    CGFloat ratio = MIN(1.0, 320.0 / MAX(image.size.width, image.size.height));
    CGSize target = CGSizeMake(MAX(1, round(image.size.width * ratio)),
                               MAX(1, round(image.size.height * ratio)));
    UIGraphicsBeginImageContextWithOptions(target, YES, 1.0);
    [[UIColor whiteColor] setFill];
    UIRectFill((CGRect){CGPointZero, target});
    [image drawInRect:(CGRect){CGPointZero, target}];
    UIImage *thumb = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!thumb) return nil;
    for (CGFloat quality = 0.85; quality >= 0.2; quality -= 0.15) {
        NSData *jpeg = UIImageJPEGRepresentation(thumb, quality);
        if (jpeg.length > 0 && jpeg.length < 190 * 1024) return jpeg;
    }
    return nil;
}

static NSString *LeadCleanFileStem(NSString *input, NSString *extension, NSString *fallback) {
    NSString *stem = [[input ?: @"" stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet]
                      stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    stem = [stem stringByReplacingOccurrencesOfString:@"\\" withString:@"-"];
    if (extension.length) {
        NSString *suffix = [[NSString stringWithFormat:@".%@", extension] lowercaseString];
        if ([stem.lowercaseString hasSuffix:suffix] && stem.length > suffix.length)
            stem = [stem substringToIndex:stem.length - suffix.length];
    }
    if (!stem.length || [stem isEqualToString:@"."] || [stem isEqualToString:@".."]) stem = fallback;
    if (stem.length > 70) stem = [stem substringToIndex:70];
    return stem;
}

#pragma mark - Model

@interface LeadPendingFile : NSObject
@property(nonatomic, strong) NSURL *url;
@property(nonatomic, copy) NSString *originalName;   // as on disk, with extension
@property(nonatomic, copy) NSString *extension;
@property(nonatomic, copy) NSString *stem;           // editable name, no extension
@property(nonatomic, copy) NSString *caption;
@property(nonatomic, strong) NSData *coverJPEG;
@property(nonatomic, strong) UIImage *coverPreview;
@end
@implementation LeadPendingFile
@end

#pragma mark - Cells

@interface LeadComposerNameCell : UITableViewCell <UITextFieldDelegate>
@property(nonatomic, strong) UIButton *coverButton;
@property(nonatomic, strong) UIImageView *coverImage;
@property(nonatomic, strong) UILabel *coverLabel;
@property(nonatomic, strong) UITextField *nameField;
@property(nonatomic, strong) UILabel *extensionLabel;
@property(nonatomic, copy) void (^onName)(NSString *text);
@property(nonatomic, copy) void (^onCover)(UIView *source);
- (void)configureWithFile:(LeadPendingFile *)file;
@end

@implementation LeadComposerNameCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuse {
    self = [super initWithStyle:style reuseIdentifier:reuse];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _coverButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _coverButton.translatesAutoresizingMaskIntoConstraints = NO;
    _coverButton.backgroundColor = UIColor.tertiarySystemFillColor;
    _coverButton.layer.cornerRadius = 12;
    _coverButton.clipsToBounds = YES;
    _coverButton.accessibilityLabel = @"غلاف الملف";
    [_coverButton addTarget:self action:@selector(coverTapped) forControlEvents:UIControlEventTouchUpInside];

    _coverImage = [[UIImageView alloc] initWithFrame:CGRectMake(0, 6, 72, 48)];
    _coverImage.userInteractionEnabled = NO;
    [_coverButton addSubview:_coverImage];

    _coverLabel = [[UILabel alloc] initWithFrame:CGRectMake(2, 54, 68, 14)];
    _coverLabel.text = @"بدون غلاف";
    _coverLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    _coverLabel.textColor = UIColor.secondaryLabelColor;
    _coverLabel.textAlignment = NSTextAlignmentCenter;
    _coverLabel.adjustsFontSizeToFitWidth = YES;
    _coverLabel.minimumScaleFactor = 0.7;
    _coverLabel.userInteractionEnabled = NO;
    [_coverButton addSubview:_coverLabel];
    [self.contentView addSubview:_coverButton];

    _extensionLabel = [UILabel new];
    _extensionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _extensionLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _extensionLabel.textColor = UIColor.secondaryLabelColor;
    _extensionLabel.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    [_extensionLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_extensionLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                     forAxis:UILayoutConstraintAxisHorizontal];
    [self.contentView addSubview:_extensionLabel];

    _nameField = [UITextField new];
    _nameField.translatesAutoresizingMaskIntoConstraints = NO;
    _nameField.placeholder = @"اسم الملف";
    _nameField.font = [UIFont systemFontOfSize:17];
    _nameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _nameField.autocorrectionType = UITextAutocorrectionTypeNo;
    _nameField.returnKeyType = UIReturnKeyDone;
    _nameField.delegate = self;
    [_nameField addTarget:self action:@selector(nameChanged) forControlEvents:UIControlEventEditingChanged];
    [self.contentView addSubview:_nameField];

    NSLayoutConstraint *bottom = [_coverButton.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12];
    bottom.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [_coverButton.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_coverButton.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
        bottom,
        [_coverButton.widthAnchor constraintEqualToConstant:72],
        [_coverButton.heightAnchor constraintEqualToConstant:72],
        [_extensionLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_extensionLabel.centerYAnchor constraintEqualToAnchor:_coverButton.centerYAnchor],
        [_nameField.leadingAnchor constraintEqualToAnchor:_coverButton.trailingAnchor constant:14],
        [_nameField.trailingAnchor constraintEqualToAnchor:_extensionLabel.leadingAnchor constant:-6],
        [_nameField.centerYAnchor constraintEqualToAnchor:_coverButton.centerYAnchor],
        [_nameField.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    ]];
    return self;
}

- (void)configureWithFile:(LeadPendingFile *)file {
    self.nameField.text = file.stem;
    self.extensionLabel.text = file.extension.length ? [@"." stringByAppendingString:file.extension] : @"";
    if (file.coverPreview) {
        self.coverImage.frame = CGRectMake(0, 0, 72, 72);
        self.coverImage.contentMode = UIViewContentModeScaleAspectFill;
        self.coverImage.clipsToBounds = YES;
        self.coverImage.image = file.coverPreview;
        self.coverLabel.hidden = YES;
    } else {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:26
                                                                                           weight:UIImageSymbolWeightRegular];
        self.coverImage.frame = CGRectMake(0, 6, 72, 48);
        self.coverImage.contentMode = UIViewContentModeCenter;
        self.coverImage.tintColor = UIColor.tertiaryLabelColor;
        self.coverImage.image = [UIImage systemImageNamed:@"photo" withConfiguration:config];
        self.coverLabel.hidden = NO;
    }
}

- (void)nameChanged { if (self.onName) self.onName(self.nameField.text ?: @""); }
- (void)coverTapped { [self.nameField resignFirstResponder]; if (self.onCover) self.onCover(self.coverButton); }
- (BOOL)textFieldShouldReturn:(UITextField *)textField { [textField resignFirstResponder]; return YES; }
@end

@interface LeadComposerCaptionCell : UITableViewCell <UITextViewDelegate>
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, strong) UILabel *placeholderLabel;
@property(nonatomic, copy) void (^onChange)(NSString *text);
@property(nonatomic, copy) void (^onGrow)(void);
- (void)configureWithFile:(LeadPendingFile *)file;
@end

@implementation LeadComposerCaptionCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuse {
    self = [super initWithStyle:style reuseIdentifier:reuse];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _textView = [UITextView new];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.backgroundColor = UIColor.clearColor;
    _textView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _textView.scrollEnabled = NO;
    _textView.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    _textView.delegate = self;
    [self.contentView addSubview:_textView];

    _placeholderLabel = [UILabel new];
    _placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _placeholderLabel.text = @"وصف الملف (اختياري) — يُرسل مع الملف";
    _placeholderLabel.font = _textView.font;
    _placeholderLabel.textColor = UIColor.placeholderTextColor;
    _placeholderLabel.numberOfLines = 0;
    _placeholderLabel.userInteractionEnabled = NO;
    [self.contentView addSubview:_placeholderLabel];

    NSLayoutConstraint *minHeight = [_textView.heightAnchor constraintGreaterThanOrEqualToConstant:92];
    minHeight.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [_textView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_textView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [_textView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [_textView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        minHeight,
        [_placeholderLabel.leadingAnchor constraintEqualToAnchor:_textView.leadingAnchor constant:17],
        [_placeholderLabel.trailingAnchor constraintEqualToAnchor:_textView.trailingAnchor constant:-17],
        [_placeholderLabel.topAnchor constraintEqualToAnchor:_textView.topAnchor constant:12],
    ]];
    return self;
}

- (void)configureWithFile:(LeadPendingFile *)file {
    self.textView.text = file.caption ?: @"";
    self.placeholderLabel.hidden = self.textView.text.length > 0;
}

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    NSString *result = [textView.text stringByReplacingCharactersInRange:range withString:text];
    return result.length <= kLeadCaptionLimit;
}

- (void)textViewDidChange:(UITextView *)textView {
    self.placeholderLabel.hidden = textView.text.length > 0;
    if (self.onChange) self.onChange(textView.text ?: @"");
    if (self.onGrow) self.onGrow();
}
@end

#pragma mark - Composer

@interface LeadFileComposerController : UITableViewController <PHPickerViewControllerDelegate>
@property(nonatomic, copy) NSArray<LeadPendingFile *> *files;
@property(nonatomic, copy) void (^onSend)(NSArray<LeadPendingFile *> *files, LeadFileComposerController *composer);
@property(nonatomic, copy) void (^onOriginal)(void);
@property(nonatomic, copy) void (^onCancel)(void);
@property(nonatomic, assign) NSInteger coverIndex;
@property(nonatomic, assign) BOOL busy;
- (void)setBusy:(BOOL)busy message:(NSString *)message;
@end

@implementation LeadFileComposerController

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.files.count > 1 ? @"تجهيز الملفات" : @"تجهيز الملف";
    if (@available(iOS 13.0, *)) self.modalInPresentation = YES;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 96;
    [self.tableView registerClass:LeadComposerNameCell.class forCellReuseIdentifier:@"name"];
    [self.tableView registerClass:LeadComposerCaptionCell.class forCellReuseIdentifier:@"caption"];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"إلغاء" style:UIBarButtonItemStylePlain target:self action:@selector(cancelTapped)];
    UIBarButtonItem *send = [[UIBarButtonItem alloc]
        initWithTitle:@"إرسال" style:UIBarButtonItemStyleDone target:self action:@selector(sendTapped)];
    self.navigationItem.rightBarButtonItem = send;
}

- (void)setBusy:(BOOL)busy message:(NSString *)message {
    self.busy = busy;
    self.navigationItem.prompt = busy ? message : nil;
    self.navigationItem.rightBarButtonItem.enabled = !busy;
    self.navigationItem.leftBarButtonItem.enabled = !busy;
    self.tableView.userInteractionEnabled = !busy;
}

- (void)cancelTapped {
    [self.view endEditing:YES];
    if (self.busy) return;
    if (self.onCancel) self.onCancel();
}

- (void)sendTapped {
    [self.view endEditing:YES];
    if (self.busy) return;
    if (self.onSend) self.onSend(self.files, self);
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)self.files.count + 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section < (NSInteger)self.files.count ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section >= (NSInteger)self.files.count) return nil;
    LeadPendingFile *file = self.files[section];
    return [NSString stringWithFormat:@"الملف %ld من %lu — %@", (long)section + 1,
            (unsigned long)self.files.count, file.originalName];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == (NSInteger)self.files.count)
        return @"يرسل الملفات بأسمائها الأصلية بدون غلاف أو وصف.";
    if (section == (NSInteger)self.files.count - 1) return nil;
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section >= (NSInteger)self.files.count) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"plain"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"plain"];
        cell.textLabel.text = @"إرسال كما هي (بدون تعديل)";
        cell.textLabel.textColor = UIColor.systemBlueColor;
        cell.textLabel.textAlignment = NSTextAlignmentNatural;
        return cell;
    }
    LeadPendingFile *file = self.files[indexPath.section];
    __weak typeof(self) weakSelf = self;
    if (indexPath.row == 0) {
        LeadComposerNameCell *cell = [tableView dequeueReusableCellWithIdentifier:@"name" forIndexPath:indexPath];
        [cell configureWithFile:file];
        NSInteger index = indexPath.section;
        cell.onName = ^(NSString *text) { file.stem = text; };
        cell.onCover = ^(UIView *source) { [weakSelf chooseCoverForIndex:index source:source]; };
        return cell;
    }
    LeadComposerCaptionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"caption" forIndexPath:indexPath];
    [cell configureWithFile:file];
    cell.onChange = ^(NSString *text) { file.caption = text; };
    cell.onGrow = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [UIView performWithoutAnimation:^{
            [self.tableView beginUpdates];
            [self.tableView endUpdates];
        }];
    };
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.busy) return;
    if (indexPath.section >= (NSInteger)self.files.count && self.onOriginal) {
        [self.view endEditing:YES];
        self.onOriginal();
    }
}

#pragma mark Cover

- (void)chooseCoverForIndex:(NSInteger)index source:(UIView *)source {
    if (self.busy || index < 0 || index >= (NSInteger)self.files.count) return;
    self.coverIndex = index;
    LeadPendingFile *file = self.files[index];
    if (!file.coverPreview) { [self openGalleryPicker]; return; }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"غلاف الملف" message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"اختيار صورة أخرى" style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) { [self openGalleryPicker]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"إزالة الغلاف" style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *a) {
        file.coverJPEG = nil;
        file.coverPreview = nil;
        [self reloadCoverRow:index];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source ?: self.view;
    sheet.popoverPresentationController.sourceRect = source ? source.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), 80, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)openGalleryPicker {
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = [PHPickerFilter imagesFilter];
    config.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)reloadCoverRow:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.files.count) return;
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:0 inSection:index]]
                          withRowAnimation:UITableViewRowAnimationNone];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14.0)) {
    NSInteger index = self.coverIndex;
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count || index < 0 || index >= (NSInteger)self.files.count) return;
    NSItemProvider *provider = results.firstObject.itemProvider;
    if (![provider canLoadObjectOfClass:UIImage.class]) {
        [self showCoverError:@"تعذر قراءة الصورة المختارة."];
        return;
    }
    LeadPendingFile *file = self.files[index];
    __weak typeof(self) weakSelf = self;
    [provider loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
        UIImage *image = [object isKindOfClass:UIImage.class] ? (UIImage *)object : nil;
        NSData *jpeg = LeadJPEGThumbnail(image);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (!jpeg.length) {
                [self showCoverError:error.localizedDescription ?: @"تعذّر تجهيز الصورة المصغّرة."];
                return;
            }
            file.coverJPEG = jpeg;
            file.coverPreview = [UIImage imageWithData:jpeg];
            [self reloadCoverRow:index];
        });
    }];
}

- (void)showCoverError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"تعذر اختيار الغلاف"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

#pragma mark - Picker proxy

@interface LeadFilePickerProxy : NSObject <UIDocumentPickerDelegate>
@property(nonatomic, strong) id<UIDocumentPickerDelegate> originalDelegate;
@property(nonatomic, strong) UIDocumentPickerViewController *picker;
@property(nonatomic, weak) UIViewController *presenter;
@property(nonatomic, copy) NSArray<NSURL *> *sourceURLs;
@property(nonatomic, assign) BOOL selected;
@end

@implementation LeadFilePickerProxy

- (UIViewController *)presentationHost {
    UIViewController *host = self.presenter;
    if (!host || !host.view.window) host = LeadTopPresenter();
    if (host == self.picker || !host) host = self.picker.presentingViewController ?: LeadTopPresenter();
    while (host.presentedViewController && !host.presentedViewController.isBeingDismissed
           && host.presentedViewController != self.picker) {
        host = host.presentedViewController;
    }
    return host;
}

- (void)releasePicker {
    UIDocumentPickerViewController *picker = self.picker;
    if (picker && gLeadOriginalSetDocumentDelegate) {
        gLeadOriginalSetDocumentDelegate(picker, @selector(setDelegate:), self.originalDelegate);
        objc_setAssociatedObject(picker, &kLeadFilePickerProxyKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [gLeadActiveFilePickers removeObject:self];
    self.originalDelegate = nil;
    self.picker = nil;
    self.sourceURLs = nil;
}

// Hands URLs to Telegram's own delegate, exactly as if the user had picked them.
- (void)deliverURLs:(NSArray<NSURL *> *)urls {
    id<UIDocumentPickerDelegate> delegate = self.originalDelegate;
    UIDocumentPickerViewController *picker = self.picker;
    if (!delegate || !picker || !urls.count) return;
    if ([delegate respondsToSelector:@selector(documentPicker:didPickDocumentsAtURLs:)]) {
        [delegate documentPicker:picker didPickDocumentsAtURLs:urls];
    } else if ([delegate respondsToSelector:@selector(documentPicker:didPickDocumentAtURL:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (NSURL *url in urls) [delegate documentPicker:picker didPickDocumentAtURL:url];
#pragma clang diagnostic pop
    }
}

- (void)deliverAllOriginal {
    [self deliverURLs:self.sourceURLs];
    [self releasePicker];
}

- (void)stopWithoutSending {
    // The user explicitly cancelled before Telegram received the selection.
    [self releasePicker];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (self.selected) return; // picker was dismissed to show Lead's composer
    if ([self.originalDelegate respondsToSelector:@selector(documentPickerWasCancelled:)])
        [self.originalDelegate documentPickerWasCancelled:controller];
    [self releasePicker];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    [self documentPicker:controller didPickDocumentsAtURLs:url ? @[url] : @[]];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (self.selected) return;
    BOOL plainFiles = urls.count > 0;
    for (NSURL *url in urls) {
        BOOL directory = NO;
        if (!url.isFileURL || ![[NSFileManager defaultManager] fileExistsAtPath:url.path isDirectory:&directory] || directory) {
            plainFiles = NO;
            break;
        }
    }
    if (!plainFiles || ![[NSUserDefaults standardUserDefaults] boolForKey:@"LeadCustomFileSend"]) {
        if ([self.originalDelegate respondsToSelector:@selector(documentPicker:didPickDocumentsAtURLs:)])
            [self.originalDelegate documentPicker:controller didPickDocumentsAtURLs:urls];
        else if (urls.firstObject && [self.originalDelegate respondsToSelector:@selector(documentPicker:didPickDocumentAtURL:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [self.originalDelegate documentPicker:controller didPickDocumentAtURL:urls.firstObject];
#pragma clang diagnostic pop
        }
        [self releasePicker];
        return;
    }

    self.selected = YES;
    self.sourceURLs = urls;
    self.presenter = controller.presentingViewController ?: LeadTopPresenter();
    if (!gLeadActiveFilePickers) gLeadActiveFilePickers = [NSMutableSet new];
    [gLeadActiveFilePickers addObject:self];

    // Do not let Telegram process the selection before customization.
    if (controller.presentingViewController) {
        [controller dismissViewControllerAnimated:YES completion:^{ [self presentComposer]; }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ [self presentComposer]; });
    }
}

#pragma mark Composer

- (void)presentComposer {
    NSMutableArray<LeadPendingFile *> *files = [NSMutableArray array];
    for (NSURL *url in self.sourceURLs) {
        LeadPendingFile *file = [LeadPendingFile new];
        file.url = url;
        file.originalName = url.lastPathComponent ?: @"file";
        file.extension = url.pathExtension ?: @"";
        file.stem = file.extension.length ? [file.originalName stringByDeletingPathExtension] : file.originalName;
        file.caption = @"";
        [files addObject:file];
    }
    LeadFileComposerController *composer = [LeadFileComposerController new];
    composer.files = files;
    __weak typeof(self) weakSelf = self;
    __weak typeof(composer) weakComposer = composer;
    composer.onCancel = ^{
        __strong typeof(weakSelf) self = weakSelf;
        __strong typeof(weakComposer) strongComposer = weakComposer;
        if (!self) return;
        [strongComposer.navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
        [self stopWithoutSending];
    };
    composer.onOriginal = ^{
        __strong typeof(weakSelf) self = weakSelf;
        __strong typeof(weakComposer) strongComposer = weakComposer;
        if (!self) return;
        UIViewController *presenting = strongComposer.navigationController.presentingViewController;
        [presenting dismissViewControllerAnimated:YES completion:^{ [self deliverAllOriginal]; }];
    };
    composer.onSend = ^(NSArray<LeadPendingFile *> *pending, LeadFileComposerController *sender) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [sender setBusy:YES message:@"جاري التجهيز…"];
        [self uploadCoversFromIndex:0 files:pending ids:[NSMutableDictionary dictionary] composer:sender];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:composer];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    UIViewController *host = [self presentationHost];
    if (!host) { [self deliverAllOriginal]; return; }
    [host presentViewController:nav animated:YES completion:nil];
}

// Covers are uploaded over Telegram's own connection (one small part each).
- (void)uploadCoversFromIndex:(NSUInteger)index
                        files:(NSArray<LeadPendingFile *> *)files
                          ids:(NSMutableDictionary<NSNumber *, NSNumber *> *)ids
                     composer:(LeadFileComposerController *)composer {
    while (index < files.count && !files[index].coverJPEG.length) index++;
    if (index >= files.count) {
        [self finishComposer:composer files:files ids:ids];
        return;
    }
    LeadPendingFile *file = files[index];
    NSUInteger current = index;
    [composer setBusy:YES message:[NSString stringWithFormat:@"رفع غلاف الملف %lu من %lu…",
                                   (unsigned long)current + 1, (unsigned long)files.count]];
    int64_t coverId = 0;
    arc4random_buf(&coverId, sizeof(coverId));
    NSMutableData *payload = [NSMutableData dataWithCapacity:file.coverJPEG.length + 32];
    LeadFileInt32(payload, kLeadUploadSaveFilePart);
    LeadFileInt64(payload, coverId);
    LeadFileInt32(payload, 0); // small JPEG: one part
    LeadFileBytes(payload, file.coverJPEG);

    __weak typeof(self) weakSelf = self;
    void (^failed)(NSString *) = ^(NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:[NSString stringWithFormat:@"تعذر رفع غلاف الملف %lu", (unsigned long)current + 1]
                             message:error.length ? error : @"السيرفر رفض الصورة المصغّرة."
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"إرسال هذا الملف بدون غلاف" style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) {
            [self uploadCoversFromIndex:current + 1 files:files ids:ids composer:composer];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"رجوع" style:UIAlertActionStyleCancel
                                                handler:^(__unused UIAlertAction *a) {
            [composer setBusy:NO message:nil];
        }]];
        [composer presentViewController:alert animated:YES completion:nil];
    };
    BOOL accepted = LeadSendRawRequest(payload, ^(NSData *result, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        int32_t signature = 0;
        if (result.length >= 4) [result getBytes:&signature length:4];
        if (error.length || signature != kLeadBoolTrue) { failed(error); return; }
        ids[@(current)] = @(coverId);
        [self uploadCoversFromIndex:current + 1 files:files ids:ids composer:composer];
    });
    if (!accepted) failed(@"اتصال تيليگرام غير جاهز. افتح أي محادثة وانتظر ثانيتين ثم أعد المحاولة.");
}

- (void)finishComposer:(LeadFileComposerController *)composer
                 files:(NSArray<LeadPendingFile *> *)files
                   ids:(NSDictionary<NSNumber *, NSNumber *> *)ids {
    UIViewController *presenting = composer.navigationController.presentingViewController;
    void (^start)(void) = ^{ [self deliverFiles:files ids:ids]; };
    if (presenting) [presenting dismissViewControllerAnimated:YES completion:start];
    else start();
}

// A picker selection is a one-shot callback. The audio picker hook and
// Telegram's completion both consume it; repeated callbacks drop later files.
- (void)deliverFiles:(NSArray<LeadPendingFile *> *)files
                 ids:(NSDictionary<NSNumber *, NSNumber *> *)ids {
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:files.count];
    for (NSUInteger index = 0; index < files.count; index++) {
        LeadPendingFile *file = files[index];
        NSString *fallback = file.extension.length ? [file.originalName stringByDeletingPathExtension] : file.originalName;
        NSString *stem = LeadCleanFileStem(file.stem, file.extension, fallback);
        NSString *newName = file.extension.length ? [NSString stringWithFormat:@"%@.%@", stem, file.extension] : stem;
        NSString *caption = [file.caption stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (caption.length > kLeadCaptionLimit) caption = [caption substringToIndex:kLeadCaptionLimit];
        NSNumber *coverId = ids[@(index)];
        if (![newName isEqualToString:file.originalName] || coverId || caption.length) {
            [TLParser registerCustomFileSendForOriginalName:file.originalName
                                               displayName:newName
                                           thumbnailFileId:coverId
                                                   caption:caption.length ? caption : nil];
        }
        [urls addObject:file.url];
    }
    [self deliverURLs:urls];
    [self releasePicker];
}

@end

static void LeadInterceptDocumentDelegate(id picker, SEL selector, id delegate) {
    if (!gLeadOriginalSetDocumentDelegate) return;
    NSString *delegateClass = delegate ? NSStringFromClass([delegate class]) : @"";
    if (!delegate || [delegate isKindOfClass:LeadFilePickerProxy.class] ||
        [delegateClass hasPrefix:@"Lead"] ||
        (NSClassFromString(@"LeadConversionPDFPicker") && [picker isKindOfClass:NSClassFromString(@"LeadConversionPDFPicker")]) ||
        ![[NSUserDefaults standardUserDefaults] boolForKey:@"LeadCustomFileSend"]) {
        gLeadOriginalSetDocumentDelegate(picker, selector, delegate);
        return;
    }

    LeadFilePickerProxy *proxy = [LeadFilePickerProxy new];
    proxy.originalDelegate = delegate;
    proxy.picker = picker;
    objc_setAssociatedObject(picker, &kLeadFilePickerProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gLeadOriginalSetDocumentDelegate(picker, selector, proxy);
}

void LeadInstallFileSendOptions(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = UIDocumentPickerViewController.class;
        SEL selector = @selector(setDelegate:);
        Method m = class_getInstanceMethod(cls, selector);
        if (!m) return;
        IMP original = method_getImplementation(m);
        const char *type = method_getTypeEncoding(m);
        // Ensure an inherited UIKit setter isn't globally replaced.
        if (class_addMethod(cls, selector, original, type))
            m = class_getInstanceMethod(cls, selector);
        gLeadOriginalSetDocumentDelegate = (void (*)(id, SEL, id))method_setImplementation(
            m, (IMP)LeadInterceptDocumentDelegate);
        gLeadCustomFilePickerHookInstalled = gLeadOriginalSetDocumentDelegate != NULL;
        NSLog(@"[Lead] custom file send picker: %@", gLeadCustomFilePickerHookInstalled ? @"on" : @"unavailable");
    });
}
