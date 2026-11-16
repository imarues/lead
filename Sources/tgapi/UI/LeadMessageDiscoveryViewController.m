// Lead Message Explorer — per-user search across accessible common groups
// and the existing 1:1 chat. Tap to open the source, long press to select and
// forward the ORIGINAL message to Saved Messages (never re-uploads media).
#import <UIKit/UIKit.h>
#import "LeadMenu.h"
#import "Headers.h"

#import <zlib.h>

// Local gzip decoder: the gzip function in Hooks.xm is static to that file.
// Limit expanded MTProto responses to avoid decompression bombs.
static NSData *LeadDiscoveryInflate(const uint8_t *bytes, NSUInteger length) {
    const NSUInteger maximum = 32 * 1024 * 1024;
    if (!bytes || !length || length > maximum) return nil;
    z_stream stream = {0};
    stream.next_in = (Bytef *)bytes;
    stream.avail_in = (uInt)length;
    if (inflateInit2(&stream, 16 + MAX_WBITS) != Z_OK) return nil;

    NSUInteger capacity = MIN(maximum, MAX((NSUInteger)65536, length * 2));
    NSMutableData *output = [NSMutableData dataWithLength:capacity];
    int result = Z_OK;
    while (result == Z_OK) {
        if (stream.total_out >= output.length) {
            if (output.length >= maximum) break;
            output.length = MIN(maximum, output.length * 2);
        }
        stream.next_out = (Bytef *)output.mutableBytes + stream.total_out;
        stream.avail_out = (uInt)(output.length - stream.total_out);
        result = inflate(&stream, Z_NO_FLUSH);
    }
    NSUInteger actual = stream.total_out;
    inflateEnd(&stream);
    if (result != Z_STREAM_END || !actual) return nil;
    output.length = actual;
    return output;
}


extern BOOL LeadSendRawRequest(NSData *payload, void (^done)(NSData *result, NSString *error));

static NSData *LeadDiscoveryUnpack(NSData *data) {
    if (!data || data.length < 8) return data;
    int32_t constructor = 0;
    [data getBytes:&constructor length:4];
    if (constructor != (int32_t)0x3072cfa1) return data; // gzip_packed
    const uint8_t *bytes = data.bytes;
    NSUInteger position = 4;
    NSUInteger length = 0;
    if (bytes[position] < 254) {
        length = bytes[position++];
    } else if (bytes[position] == 254 && data.length >= 8) {
        length = (NSUInteger)bytes[5] | ((NSUInteger)bytes[6] << 8) |
                 ((NSUInteger)bytes[7] << 16);
        position = 8;
    }
    if (!length || length > data.length - position) return data;
    NSData *inflated = LeadDiscoveryInflate(bytes + position, length);
    return inflated ?: data;
}

@interface LeadMessageDiscoveryBridge : NSObject
+ (NSData *)resolveRequestForUsername:(NSString *)username;
+ (NSDictionary *)parseResolvedUser:(NSData *)data;
+ (NSData *)commonChatsRequestForUserId:(int64_t)userId accessHash:(int64_t)accessHash maxId:(int64_t)maxId;
+ (NSDictionary *)parseCommonChats:(NSData *)data;
+ (NSData *)dialogsRequestWithOffsetDate:(int32_t)date offsetId:(int32_t)messageId
                               offsetPeer:(NSData *)peer folderId:(int32_t)folderId;
+ (NSDictionary *)parseDiscoveryDialogs:(NSData *)data;
+ (NSData *)legacySenderGroupsRequest:(NSData *)sender;
+ (NSData *)publicGroupCandidatesRequestForUsername:(NSString *)username;
+ (NSDictionary *)parseDiscoveredGroups:(NSData *)data scope:(NSString *)scope;
+ (NSData *)searchRequestForPeer:(NSData *)peer sender:(NSData *)sender category:(NSInteger)category offsetId:(int32_t)offsetId;
+ (NSDictionary *)parseSearchResult:(NSData *)data senderId:(int64_t)sender source:(NSDictionary *)source category:(NSInteger)category;
+ (NSData *)forwardRequestForPeer:(NSData *)peer messageIds:(NSArray<NSNumber *> *)ids;
@end

// Category strip. UIScrollView normally refuses to start scrolling when a drag
// begins on a UIControl, which is why the old segmented control could not be
// moved. Allow the scroll to take over from any chip.
@interface LeadChipScrollView : UIScrollView
@end
@implementation LeadChipScrollView
- (BOOL)touchesShouldCancelInContentView:(UIView *)view { return YES; }
@end

@interface LeadMessageDiscoveryViewController () <UITextFieldDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, strong) UITextField *usernameField;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIScrollView *chipScroll;
@property(nonatomic, strong) NSMutableArray<UIButton *> *chips;
@property(nonatomic, assign) NSInteger category;
@property(nonatomic, assign) CGFloat chipsLaidOutWidth;
@property(nonatomic, copy) NSString *firstScanError;
@property(nonatomic, assign) NSInteger failedChats;
@property(nonatomic, assign) NSInteger partialChats;
@property(nonatomic, strong) UIButton *groupsButton;
@property(nonatomic, strong) NSDictionary *target;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *groups;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *sources;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *results;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *scanQueue;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *olderOffsets;
@property(nonatomic, strong) NSMutableSet<NSString *> *excluded;
@property(nonatomic, strong) NSMutableSet<NSString *> *seen;
@property(nonatomic, strong) NSMutableSet<NSString *> *selectedKeys;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *forwardQueue;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *pagesThisPass;
@property(nonatomic, assign) BOOL gatheringSources;
@property(nonatomic, assign) BOOL discoveryWasLimited;
@property(nonatomic, assign) NSInteger exploredDialogPages;
@property(nonatomic, assign) NSInteger publicCandidateCount;
@property(nonatomic, assign) NSInteger generation;
@property(nonatomic, assign) NSInteger completedChats;
@property(nonatomic, assign) NSInteger totalChats;
@property(nonatomic, assign) BOOL groupsExpanded;
@property(nonatomic, assign) BOOL scanning;
@property(nonatomic, assign) BOOL selectionMode;
@property(nonatomic, assign) BOOL forwarding;
@end

@implementation LeadMessageDiscoveryViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"كشف الرسائل";
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68;
    self.groups = [NSMutableArray array];
    self.sources = [NSMutableArray array];
    self.results = [NSMutableArray array];
    self.scanQueue = [NSMutableArray array];
    self.olderOffsets = [NSMutableDictionary dictionary];
    self.excluded = [NSMutableSet set];
    self.seen = [NSMutableSet set];
    self.selectedKeys = [NSMutableSet set];
    self.forwardQueue = [NSMutableArray array];
    self.pagesThisPass = [NSMutableDictionary dictionary];
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    [self configureHeader];

    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(longPressed:)];
    hold.minimumPressDuration = 0.47;
    hold.delegate = self;
    hold.cancelsTouchesInView = NO;
    [self.tableView addGestureRecognizer:hold];
}

- (void)configureHeader {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 238)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(16, 9, 215, 42)];
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.placeholder = @"@username";
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.returnKeyType = UIReturnKeySearch;
    field.delegate = self;
    field.accessibilityLabel = @"اسم المستخدم المطلوب البحث عن رسائله";
    field.translatesAutoresizingMaskIntoConstraints = NO;
    self.usernameField = field;
    [header addSubview:field];

    UIButton *search = [UIButton buttonWithType:UIButtonTypeSystem];
    [search setTitle:@"بحث" forState:UIControlStateNormal];
    search.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [search addTarget:self action:@selector(searchUsername) forControlEvents:UIControlEventTouchUpInside];
    search.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:search];

    UILabel *status = [UILabel new];
    status.text = @"اكتب اليوزر: نفحص كروبات حسابك حتى لو الشخص غادرها، ونحاول اكتشاف كروبات عامة. النتائج مو شاملة كل تيليگرام.";
    status.font = [UIFont systemFontOfSize:12];
    status.textColor = UIColor.secondaryLabelColor;
    status.numberOfLines = 5;
    status.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel = status;
    [header addSubview:status];

    LeadChipScrollView *scroll = [LeadChipScrollView new];
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.alwaysBounceHorizontal = YES;
    scroll.delaysContentTouches = NO;
    scroll.canCancelContentTouches = YES;
    // Positions are computed by hand (first chip on the right for Arabic), so the
    // scroll view must not be mirrored by the system.
    scroll.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    NSArray *titles = @[ @"الصور", @"الفيديو", @"الفويسات", @"الموسيقى", @"الملفات", @"الدائري", @"الروابط", @"الكل" ];
    self.category = 7; // include text and every media type by default
    self.chips = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeCustom];
        chip.tag = (NSInteger)i;
        [chip setTitle:titles[i] forState:UIControlStateNormal];
        chip.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        chip.contentEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 16);
        chip.layer.cornerRadius = 18;
        chip.layer.masksToBounds = YES;
        [chip addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [scroll addSubview:chip];
        [self.chips addObject:chip];
    }
    self.chipScroll = scroll;
    [self styleChips];
    [header addSubview:scroll];

    UIButton *groupsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [groupsButton setTitle:@"مصادر البحث — إظهار" forState:UIControlStateNormal];
    groupsButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    groupsButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    groupsButton.translatesAutoresizingMaskIntoConstraints = NO;
    [groupsButton addTarget:self action:@selector(toggleGroups) forControlEvents:UIControlEventTouchUpInside];
    groupsButton.enabled = NO;
    self.groupsButton = groupsButton;
    [header addSubview:groupsButton];

    [NSLayoutConstraint activateConstraints:@[
        [field.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:15],
        [field.topAnchor constraintEqualToAnchor:header.topAnchor constant:8],
        [field.trailingAnchor constraintEqualToAnchor:search.leadingAnchor constant:-9],
        [field.heightAnchor constraintEqualToConstant:42],
        [search.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-15],
        [search.widthAnchor constraintEqualToConstant:63],
        [search.centerYAnchor constraintEqualToAnchor:field.centerYAnchor],
        [status.leadingAnchor constraintEqualToAnchor:field.leadingAnchor],
        [status.trailingAnchor constraintEqualToAnchor:search.trailingAnchor],
        [status.topAnchor constraintEqualToAnchor:field.bottomAnchor constant:9],
        [status.heightAnchor constraintEqualToConstant:84],
        [scroll.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:6],
        [scroll.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:15],
        [scroll.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-15],
        [scroll.heightAnchor constraintEqualToConstant:40],
        [groupsButton.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:7],
        [groupsButton.leadingAnchor constraintEqualToAnchor:field.leadingAnchor],
        [groupsButton.trailingAnchor constraintEqualToAnchor:search.trailingAnchor],
        [groupsButton.heightAnchor constraintEqualToConstant:27],
    ]];
    self.tableView.tableHeaderView = header;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self searchUsername];
    return YES;
}

- (void)displayStatus:(NSString *)message {
    self.statusLabel.text = message ?: @"";
}

- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"كشف الرسائل"
                                                                   message:message ?: @"فشلت العملية."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"حسناً" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)searchUsername {
    if (self.forwarding) return;
    [self.usernameField resignFirstResponder];
    NSString *username = [self.usernameField.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([username hasPrefix:@"@"]) username = [username substringFromIndex:1];
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet];
    if (!username.length || [username rangeOfCharacterFromSet:invalid].location != NSNotFound) {
        [self showError:@"اكتب اسم مستخدم صحيح بدون روابط أو مسافات."];
        return;
    }
    [self leaveSelection];
    self.generation++;
    NSInteger token = self.generation;
    self.target = nil;
    self.gatheringSources = YES;
    self.discoveryWasLimited = NO;
    self.exploredDialogPages = 0;
    self.publicCandidateCount = 0;
    [self.groups removeAllObjects];
    [self.sources removeAllObjects];
    [self.results removeAllObjects];
    [self.excluded removeAllObjects];
    [self.olderOffsets removeAllObjects];
    [self.seen removeAllObjects];
    self.scanning = YES;
    self.groupsButton.enabled = NO;
    [self displayStatus:@"جاري البحث عن المستخدم…"];
    [self.tableView reloadData];
    NSData *payload = [LeadMessageDiscoveryBridge resolveRequestForUsername:username];
    __weak typeof(self) weakSelf = self;
    if (!LeadSendRawRequest(payload, ^(NSData *data, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || token != self.generation) return;
        NSDictionary *target = (!error.length && data.length)
            ? [LeadMessageDiscoveryBridge parseResolvedUser:LeadDiscoveryUnpack(data)] : nil;
        if (!target) {
            self.scanning = NO;
            self.gatheringSources = NO;
            [self displayStatus:@"تعذر العثور على الحساب."];
            [self showError:error.length ? error : @"هذا اليوزر غير متاح أو لم يرجع تيليگرام معلومات الحساب."];
            return;
        }
        self.target = target;
        [self displayStatus:[NSString stringWithFormat:@"تم العثور على %@. جاري جمع الكروبات المشتركة وبقية محادثات حسابك…",
                             target[@"title"] ?: @"المستخدم"]];
        [self loadCommonPage:0 page:0 token:token];
    })) {
        self.scanning = NO;
        self.gatheringSources = NO;
        [self displayStatus:@"اتصال تيليگرام غير جاهز. افتح محادثة ثم أعد المحاولة."];
    }
}

- (void)loadCommonPage:(int64_t)maxId page:(NSInteger)page token:(NSInteger)token {
    NSDictionary *target = self.target;
    if (!target || token != self.generation) return;
    NSData *payload = [LeadMessageDiscoveryBridge
        commonChatsRequestForUserId:[target[@"userId"] longLongValue]
        accessHash:[target[@"accessHash"] longLongValue] maxId:maxId];
    __weak typeof(self) weakSelf = self;
    if (!LeadSendRawRequest(payload, ^(NSData *data, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || token != self.generation) return;
        NSDictionary *response = (error.length || !data.length) ? nil : [LeadMessageDiscoveryBridge parseCommonChats:LeadDiscoveryUnpack(data)];
        if (!response) {
            // Private chat can still be searched if common chats are unavailable.
            [self displayStatus:error.length ? [NSString stringWithFormat:@"تعذر جلب بعض الكروبات: %@",error] :
             @"تعذر قراءة الكروبات المشتركة، يمكن البحث في الخاص فقط."];
            [self commonChatsFinished];
            return;
        }
        for (NSDictionary *group in response[@"items"]) {
            BOOL already = NO;
            for (NSDictionary *existing in self.groups)
                if ([existing[@"key"] isEqual:group[@"key"]]) { already = YES; break; }
            if (!already) [self.groups addObject:group];
        }
        int64_t nextId = [response[@"nextMaxId"] longLongValue];
        BOOL more = [response[@"hasMore"] boolValue];
        if (more && nextId > 0 && nextId != maxId && page < 19) {
            [self displayStatus:[NSString stringWithFormat:@"تم العثور على %lu كروب مشترك…",
                                 (unsigned long)self.groups.count]];
            [self loadCommonPage:nextId page:page+1 token:token];
        } else {
            [self commonChatsFinished];
        }
    })) {
        [self commonChatsFinished];
    }
}


// The old version relied on getCommonChats alone and therefore missed messages
// in groups where the target sender has already left. We now combine it with
// all group dialogs in this account and limited public discovery candidates.
- (BOOL)addDiscoveredSource:(NSDictionary *)source {
    NSString *key = source[@"key"];
    if (!key.length || ![source[@"peer"] isKindOfClass:NSData.class]) return NO;
    for (NSDictionary *existing in self.sources) {
        if ([existing[@"key"] isEqual:key]) return NO;
    }
    [self.sources addObject:source];
    return YES;
}

- (void)commonChatsFinished {
    if (!self.target) return;
    [self.sources removeAllObjects];
    NSDictionary *target = self.target;
    [self.sources addObject:@{
        @"id": target[@"userId"],
        @"key": [NSString stringWithFormat:@"u%@", target[@"userId"]],
        @"kind": @"u", @"title": @"المحادثة الخاصة",
        @"scope": @"المحادثة الخاصة",
        @"username": target[@"username"] ?: @"",
        @"peer": target[@"peer"]
    }];
    for (NSDictionary *group in self.groups) [self addDiscoveredSource:group];
    self.groupsButton.enabled = NO;
    [self displayStatus:@"جاري فحص كروبات حسابك، حتى الكروبات التي غادرها صاحب اليوزر…"];
    [self loadDialogPage:nil page:0 folderId:0 token:self.generation];
}

- (void)loadDialogPage:(NSDictionary *)offset page:(NSInteger)page
               folderId:(int32_t)folderId token:(NSInteger)token {
    if (token != self.generation || !self.target) return;
    NSData *peer = [offset[@"peer"] isKindOfClass:NSData.class] ? offset[@"peer"] : nil;
    NSData *payload = [LeadMessageDiscoveryBridge
        dialogsRequestWithOffsetDate:[offset[@"date"] intValue]
        offsetId:[offset[@"id"] intValue] offsetPeer:peer folderId:folderId];
    __weak typeof(self) weakSelf = self;
    if (!LeadSendRawRequest(payload, ^(NSData *data, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || token != self.generation) return;
        if ([error hasPrefix:@"FLOOD_WAIT"]) {
            self.gatheringSources = NO;
            self.scanning = NO;
            [self displayStatus:[NSString stringWithFormat:@"تيليگرام طلب تقليل الطلبات: %@. جرّب بعد انتهاء المدة.",error]];
            return;
        }
        NSDictionary *parsed = (!error.length && data.length) ?
            [LeadMessageDiscoveryBridge parseDiscoveryDialogs:LeadDiscoveryUnpack(data)] : nil;
        if (!parsed) {
            self.discoveryWasLimited = YES;
            [self finishDialogFolder:folderId token:token];
            return;
        }
        self.exploredDialogPages++;
        for (NSDictionary *group in parsed[@"items"]) [self addDiscoveredSource:group];
        NSDictionary *next = parsed[@"next"];
        BOOL more = [parsed[@"hasMore"] boolValue] && [next isKindOfClass:NSDictionary.class] &&
                    [next[@"peer"] isKindOfClass:NSData.class];
        // Hard limit avoids unbounded request bursts on accounts with thousands of dialogs.
        if (more && page < 29 && ![offset isEqual:next]) {
            [self displayStatus:[NSString stringWithFormat:@"تفحّص %ld صفحة من محادثاتك؛ عثر على %lu مصدر…",
                (long)self.exploredDialogPages,(unsigned long)self.sources.count-1]];
            [self loadDialogPage:next page:page+1 folderId:folderId token:token];
        } else {
            if (more) self.discoveryWasLimited = YES;
            [self finishDialogFolder:folderId token:token];
        }
    })) {
        self.discoveryWasLimited = YES;
        [self finishDialogFolder:folderId token:token];
    }
}

- (void)finishDialogFolder:(int32_t)folderId token:(NSInteger)token {
    if (token != self.generation || !self.target) return;
    if (folderId == 0) {
        [self displayStatus:@"جاري تفحّص الكروبات المؤرشفة أيضاً…"];
        [self loadDialogPage:nil page:0 folderId:1 token:token];
    } else {
        [self discoverLegacySenderGroupsWithToken:token];
    }
}

- (void)discoverLegacySenderGroupsWithToken:(NSInteger)token {
    if (token != self.generation || !self.target) return;
    [self displayStatus:@"جاري تجربة البحث الشامل في الكروبات العادية غير المشمولة بالقائمة…"];
    NSData *payload = [LeadMessageDiscoveryBridge legacySenderGroupsRequest:self.target[@"peer"]];
    if (!payload.length) {
        self.discoveryWasLimited = YES;
        [self discoverPublicCandidatesWithToken:token];
        return;
    }
    __weak typeof(self) weakSelf = self;
    if (!LeadSendRawRequest(payload, ^(NSData *data, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || token != self.generation) return;
        if ([error hasPrefix:@"FLOOD_WAIT"]) {
            self.gatheringSources = NO;
            self.scanning = NO;
            [self displayStatus:[NSString stringWithFormat:@"تيليگرام طلب تقليل البحث: %@. جرّب لاحقاً.",error]];
            return;
        }
        NSDictionary *parsed = (!error.length && data.length) ?
          [LeadMessageDiscoveryBridge parseDiscoveredGroups:LeadDiscoveryUnpack(data)
               scope:@"بحث بالكروبات العادية"] : nil;
        if (parsed) {
            for (NSDictionary *group in parsed[@"items"]) [self addDiscoveredSource:group];
        } else self.discoveryWasLimited = YES;
        [self discoverPublicCandidatesWithToken:token];
    })) {
        self.discoveryWasLimited = YES;
        [self discoverPublicCandidatesWithToken:token];
    }
}

- (void)discoverPublicCandidatesWithToken:(NSInteger)token {
    if (token != self.generation || !self.target) return;
    [self displayStatus:@"جاري تجربة البحث العام عن كروبات يظهر فيها اليوزر… النتائج المرشّحة تُفحص باسم المرسل للتأكد."];
    NSString *username = self.target[@"username"];
    if (![username isKindOfClass:NSString.class] || !username.length)
        username = [self.usernameField.text stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([username hasPrefix:@"@"]) username = [username substringFromIndex:1];
    if (!username.length) {
        [self finishSourceDiscoveryWithToken:token];
        return;
    }
    NSData *payload = [LeadMessageDiscoveryBridge publicGroupCandidatesRequestForUsername:username];
    __weak typeof(self) weakSelf = self;
    if (!LeadSendRawRequest(payload, ^(NSData *data, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || token != self.generation) return;
        if ([error hasPrefix:@"FLOOD_WAIT"]) {
            self.gatheringSources = NO;
            self.scanning = NO;
            [self displayStatus:[NSString stringWithFormat:@"تيليگرام طلب تقليل البحث: %@. جرّب لاحقاً.",error]];
            return;
        }
        NSDictionary *parsed = (!error.length && data.length) ?
          [LeadMessageDiscoveryBridge parseDiscoveredGroups:LeadDiscoveryUnpack(data)
               scope:@"مرشّح من البحث العام"] : nil;
        if (parsed) {
            for (NSDictionary *group in parsed[@"items"]) {
                if (self.publicCandidateCount >= 60) {
                    self.discoveryWasLimited = YES;
                    break;
                }
                if ([self addDiscoveredSource:group]) self.publicCandidateCount++;
            }
        } else self.discoveryWasLimited = YES;
        [self finishSourceDiscoveryWithToken:token];
    })) {
        self.discoveryWasLimited = YES;
        [self finishSourceDiscoveryWithToken:token];
    }
}

- (void)finishSourceDiscoveryWithToken:(NSInteger)token {
    if (token != self.generation || !self.target) return;
    self.gatheringSources = NO;
    self.groupsButton.enabled = YES;
    [self.groupsButton setTitle:[NSString stringWithFormat:@"مصادر البحث (%lu) — %@",
        (unsigned long)self.sources.count,
        self.groupsExpanded ? @"إخفاء" : @"إظهار"] forState:UIControlStateNormal];
    [self startFreshScan];
}

- (void)toggleGroups {
    self.groupsExpanded = !self.groupsExpanded;
    [self.groupsButton setTitle:[NSString stringWithFormat:@"مصادر البحث (%lu) — %@",
         (unsigned long)self.sources.count, self.groupsExpanded ? @"إخفاء" : @"إظهار"]
                        forState:UIControlStateNormal];
    [self.tableView reloadData];
}

- (void)styleChips {
    for (UIButton *chip in self.chips) {
        BOOL on = chip.tag == self.category;
        chip.backgroundColor = on ? UIColor.systemBlueColor : UIColor.secondarySystemFillColor;
        [chip setTitleColor:on ? UIColor.whiteColor : UIColor.labelColor forState:UIControlStateNormal];
    }
}

// First chip sits at the right edge (reading order of Arabic); the strip scrolls
// freely in both directions when the chips are wider than the screen.
- (void)layoutChipsForce:(BOOL)force {
    CGFloat width = self.chipScroll.bounds.size.width;
    if (width < 1 || !self.chips.count) return;
    if (!force && fabs(width - self.chipsLaidOutWidth) < 0.5) return;
    BOOL first = self.chipsLaidOutWidth < 1;
    self.chipsLaidOutWidth = width;
    const CGFloat gap = 8, height = 36;
    NSMutableArray<NSNumber *> *widths = [NSMutableArray array];
    CGFloat total = 0;
    for (UIButton *chip in self.chips) {
        CGFloat w = ceil([chip sizeThatFits:CGSizeMake(CGFLOAT_MAX, height)].width);
        w = MAX(w, 64);
        [widths addObject:@(w)];
        total += w;
    }
    total += gap * (self.chips.count - 1);
    CGFloat content = MAX(total, width);
    CGFloat x = content;
    for (NSUInteger i = 0; i < self.chips.count; i++) {
        CGFloat w = widths[i].doubleValue;
        x -= w;
        self.chips[i].frame = CGRectMake(x, 2, w, height);
        x -= gap;
    }
    self.chipScroll.contentSize = CGSizeMake(content, 40);
    if (first) [self.chipScroll setContentOffset:CGPointMake(MAX(0, content - width), 0) animated:NO];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.tableView.tableHeaderView;
    CGFloat tableWidth = self.tableView.bounds.size.width;
    if (header && tableWidth > 1 && fabs(header.frame.size.width - tableWidth) > 0.5) {
        CGRect frame = header.frame;
        frame.size.width = tableWidth;
        header.frame = frame;
        self.tableView.tableHeaderView = header;
        [header layoutIfNeeded];
    }
    [self layoutChipsForce:NO];
}

- (void)chipTapped:(UIButton *)chip {
    if (chip.tag == self.category) return;
    if (self.forwarding) return;
    self.category = chip.tag;
    [self styleChips];
    [self.chipScroll scrollRectToVisible:CGRectInset(chip.frame, -24, 0) animated:YES];
    LeadSelectionHaptic();
    if (self.target && !self.gatheringSources) [self startFreshScan];
}

- (void)startFreshScan {
    if (!self.target || self.forwarding || self.gatheringSources) return;
    [self leaveSelection];
    self.generation++;
    [self.results removeAllObjects];
    [self.olderOffsets removeAllObjects];
    [self.pagesThisPass removeAllObjects];
    [self.seen removeAllObjects];
    [self.scanQueue removeAllObjects];
    for (NSDictionary *source in self.sources) {
        if (![self.excluded containsObject:source[@"key"]]) [self.scanQueue addObject:source];
    }
    self.completedChats = 0;
    self.totalChats = self.scanQueue.count;
    self.firstScanError = nil;
    self.failedChats = 0;
    self.partialChats = 0;
    self.scanning = YES;
    [self displayStatus:[NSString stringWithFormat:@"جاري فحص %ld محادثة…", (long)self.totalChats]];
    [self.tableView reloadData];
    [self scanNextWithToken:self.generation];
}

- (void)scanNextWithToken:(NSInteger)token {
    if (token != self.generation || !self.target) return;
    if (self.scanQueue.count == 0) {
        self.scanning = NO;
        NSString *summary = self.results.count ?
            [NSString stringWithFormat:@"نتائج البحث: %lu رسالة من %ld مصدر. ضغطة للفتح أو مطوّلة للتحديد.",
             (unsigned long)self.results.count, (long)self.totalChats] :
            [NSString stringWithFormat:@"ما ظهرت رسائل من الفئة ضمن أول الصفحات المفحوصة من %ld مصدر.", (long)self.totalChats];
        if (self.olderOffsets.count)
            summary = [summary stringByAppendingFormat:@"\nباقي تاريخ أقدم في %lu محادثة؛ اضغط تحميل رسائل أقدم.",
                       (unsigned long)self.olderOffsets.count];
        if (self.publicCandidateCount)
            summary = [summary stringByAppendingFormat:@"\nفحصنا %ld كروب عام مرشّح؛ مو فهرس شامل لتيليگرام.",
                       (long)self.publicCandidateCount];
        else
            summary = [summary stringByAppendingString:@"\nمحاولة البحث العام محدودة: ما تضمن اكتشاف كل الكروبات."];
        if (self.discoveryWasLimited)
            summary = [summary stringByAppendingString:@"\nبعض مصادر البحث ما انقرأت؛ النتائج جزئية."];
        if (self.failedChats > 0)
            summary = [summary stringByAppendingFormat:@"\nتعذّر فحص %ld محادثة%@.", (long)self.failedChats,
                       self.firstScanError.length ? [NSString stringWithFormat:@" (%@)", self.firstScanError] : @""];
        else if (self.partialChats > 0)
            summary = [summary stringByAppendingFormat:@"\nبعض الرسائل في %ld محادثة لم تُقرأ (نوع غير مدعوم).", (long)self.partialChats];
        [self displayStatus:summary];
        [self.tableView reloadData];
        return;
    }

    NSDictionary *source = self.scanQueue.firstObject;
    [self.scanQueue removeObjectAtIndex:0];
    NSString *key = source[@"key"];
    NSNumber *offsetValue = self.olderOffsets[key];
    int32_t offset = offsetValue ? offsetValue.intValue : 0;
    NSData *payload = [LeadMessageDiscoveryBridge searchRequestForPeer:source[@"peer"]
         sender:self.target[@"peer"] category:self.category offsetId:offset];
    if (offset == 0) self.completedChats++;
    if (!payload.length) {
        self.failedChats++;
        if (!self.firstScanError.length) self.firstScanError = @"تعذّر إنشاء طلب البحث";
        [self scanNextWithToken:token]; return;
    }
    __weak typeof(self) weakSelf = self;
    if (!LeadSendRawRequest(payload, ^(NSData *data, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || token != self.generation) return;
        NSDictionary *response = (!error.length && data.length) ?
            [LeadMessageDiscoveryBridge parseSearchResult:LeadDiscoveryUnpack(data)
                 senderId:[self.target[@"userId"] longLongValue]
                 source:source category:self.category] : nil;
        // Stop rather than keep issuing requests when Telegram imposes a limit.
        if ([error hasPrefix:@"FLOOD_WAIT"]) {
            self.scanning = NO;
            [self displayStatus:[NSString stringWithFormat:@"تيليگرام طلب تقليل البحث: %@. أعد المحاولة لاحقاً.", error]];
            return;
        }
        // A failed chat is skipped; never fabricate results or retry in a flood loop.
        if (!response) {
            self.failedChats++;
            if (!self.firstScanError.length)
                self.firstScanError = error.length ? error : @"تعذّر قراءة رد تيليگرام";
        } else if ([response[@"partial"] boolValue]) {
            self.partialChats++;
        }
        if (response) {
            for (NSDictionary *item in response[@"items"]) {
                NSString *unique = [NSString stringWithFormat:@"%@:%@", item[@"key"], item[@"id"]];
                if ([self.seen containsObject:unique]) continue;
                [self.seen addObject:unique];
                [self.results addObject:item];
            }
            if ([response[@"hasMore"] boolValue] && [response[@"nextOffset"] intValue] > 0
                && (!offset || [response[@"nextOffset"] intValue] < offset))
            {
                self.olderOffsets[key] = response[@"nextOffset"];
                NSInteger pages = [self.pagesThisPass[key] integerValue] + 1;
                self.pagesThisPass[key] = @(pages);
                // Scan at most 3 pages (300 messages by sender) per source
                // automatically. The button below fetches subsequent pages.
                // This prevents a single prolific sender from delaying all groups.
                if (pages < 3) [self.scanQueue addObject:source];
            }
            else
                [self.olderOffsets removeObjectForKey:key];
        } else {
            [self.olderOffsets removeObjectForKey:key];
        }
        [self.results sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"date"] compare:a[@"date"]];
        }];
        [self displayStatus:[NSString stringWithFormat:@"فحص %ld/%ld محادثة — %lu رسالة%@",
             (long)self.completedChats, (long)self.totalChats,
             (unsigned long)self.results.count, error.length ? @" (بعض المحادثات تعذّر فحصها)" : @""]];
        [self.tableView reloadData];
        // Keep the scan responsive while avoiding a burst across many groups.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self scanNextWithToken:token];
        });
    })) {
        [self displayStatus:@"اتصال تيليگرام توقف قبل اكتمال البحث."];
        self.scanning = NO;
    }
}

- (void)loadOlder {
    if (self.scanning || !self.target || self.forwarding) return;
    [self.scanQueue removeAllObjects];
    for (NSDictionary *source in self.sources) {
        if (![self.excluded containsObject:source[@"key"]] &&
            [self.olderOffsets[source[@"key"]] intValue] > 0)
            [self.scanQueue addObject:source];
    }
    self.totalChats = self.scanQueue.count;
    self.completedChats = 0;
    [self.pagesThisPass removeAllObjects];
    self.scanning = YES;
    [self scanNextWithToken:self.generation];
}

#pragma mark - Selection and ordinary forwarding

- (NSString *)uniqueForEntry:(NSDictionary *)entry {
    return [NSString stringWithFormat:@"%@:%@", entry[@"key"], entry[@"id"]];
}

- (void)updateSelectionNavigation {
    NSInteger count = self.selectedKeys.count;
    self.navigationItem.title = count ?
        [NSString stringWithFormat:@"محدد: %ld", (long)count] : @"تحديد الرسائل";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:[NSString stringWithFormat:@"تحويل (%ld)",(long)count]
                                         style:UIBarButtonItemStyleDone target:self action:@selector(forwardSelected)];
    self.navigationItem.rightBarButtonItem.enabled = count > 0 && !self.forwarding;
}

- (void)enterSelectionAt:(NSIndexPath *)path {
    if (self.forwarding || path.section != 1 || path.row >= (NSInteger)self.results.count) return;
    self.selectionMode = YES;
    self.selectedKeys = [NSMutableSet set];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"إلغاء" style:UIBarButtonItemStylePlain
                                       target:self action:@selector(leaveSelection)];
    [self.tableView setEditing:YES animated:YES];
    [self.tableView selectRowAtIndexPath:path animated:NO
                          scrollPosition:UITableViewScrollPositionNone];
    [self.selectedKeys addObject:[self uniqueForEntry:self.results[path.row]]];
    [self updateSelectionNavigation];
}

- (void)leaveSelection {
    if (!self.selectionMode || self.forwarding) return;
    self.selectionMode = NO;
    [self.selectedKeys removeAllObjects];
    [self.tableView setEditing:NO animated:YES];
    self.navigationItem.leftBarButtonItem = nil;
    self.navigationItem.rightBarButtonItem = nil;
    self.title = @"كشف الرسائل";
}

- (void)longPressed:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan || self.selectionMode) return;
    CGPoint point = [recognizer locationInView:self.tableView];
    NSIndexPath *path = [self.tableView indexPathForRowAtPoint:point];
    if (path && path.section == 1) [self enterSelectionAt:path];
}

- (void)forwardSelected {
    if (!self.selectedKeys.count || self.forwarding) return;
    NSMutableArray *selected = [NSMutableArray array];
    for (NSDictionary *entry in self.results) {
        if ([self.selectedKeys containsObject:[self uniqueForEntry:entry]]) {
            if ([entry[@"protected"] boolValue]) {
                [self showError:@"إحدى الرسائل مختومة بمنع التحويل، ولا يمكن تحويلها كرسالة عادية."];
                return;
            }
            [selected addObject:entry];
        }
    }
    if (!selected.count) return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"تحويل إلى الرسائل المحفوظة"
        message:[NSString stringWithFormat:@"تحويل %lu رسالة كما هي، مع مصدرها الأصلي؟",
                 (unsigned long)selected.count]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"تحويل" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self performForward:selected];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performForward:(NSArray<NSDictionary *> *)selected {
    if (self.forwarding || !selected.count) return;
    self.forwarding = YES;
    [self.forwardQueue removeAllObjects];
    NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *ids = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSData *> *peers = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSDictionary *entry in selected) {
        NSString *key = entry[@"key"];
        if (!ids[key]) { ids[key] = [NSMutableArray array]; peers[key] = entry[@"sourcePeer"]; [order addObject:key]; }
        [ids[key] addObject:entry[@"id"]];
    }
    for (NSString *key in order) {
        NSArray *numbers = ids[key];
        for (NSUInteger start = 0; start < numbers.count; start += 50) {
            NSArray *chunk = [numbers subarrayWithRange:NSMakeRange(start, MIN((NSUInteger)50, numbers.count-start))];
            NSData *payload = [LeadMessageDiscoveryBridge forwardRequestForPeer:peers[key] messageIds:chunk];
            if (!payload.length) {
                self.forwarding = NO;
                [self showError:@"تعذر إعداد طلب تحويل إحدى الرسائل."];
                return;
            }
            [self.forwardQueue addObject:@{@"payload":payload, @"count":@(chunk.count)}];
        }
    }
    [self updateSelectionNavigation];
    [self displayStatus:@"جاري تحويل الرسائل إلى المحفوظة…"];
    [self forwardNextWithSent:0];
}

- (void)forwardNextWithSent:(NSUInteger)sent {
    if (!self.forwardQueue.count) {
        self.forwarding = NO;
        [self leaveSelection];
        [self displayStatus:[NSString stringWithFormat:@"تم تحويل %lu رسالة إلى الرسائل المحفوظة.", (unsigned long)sent]];
        [LeadToast showText:@"اكتمل التحويل إلى المحفوظة" symbol:@"checkmark.circle" inView:self.view];
        return;
    }
    NSDictionary *job = self.forwardQueue.firstObject;
    [self.forwardQueue removeObjectAtIndex:0];
    __weak typeof(self) weakSelf = self;
    if (!LeadSendRawRequest(job[@"payload"], ^(NSData *data, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error.length || data.length < 4) {
            self.forwarding = NO;
            [self updateSelectionNavigation];
            [self showError:[NSString stringWithFormat:@"فشل تحويل بعض الرسائل بعد نجاح %lu: %@",
                            (unsigned long)sent, error.length ? error : @"رد غير صالح"]];
            return;
        }
        [self forwardNextWithSent:sent+[job[@"count"] unsignedIntegerValue]];
    })) {
        self.forwarding = NO;
        [self updateSelectionNavigation];
        [self showError:@"اتصال تيليگرام غير جاهز لتحويل الرسائل."];
    }
}

#pragma mark - Table and navigation

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return self.groupsExpanded ? self.sources.count : 0;
    if (section == 1) return self.results.count;
    return !self.scanning && self.olderOffsets.count && !self.selectionMode ? 1 : 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0 && self.groupsExpanded) return @"مصادر البحث: مشتركة، بحسابك ولو غادرها الشخص، ومرشّحة عامة";
    if (section == 1 && self.target) return [NSString stringWithFormat:@"رسائل %@ — %lu", self.target[@"title"], (unsigned long)self.results.count];
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    static NSString *const reuse = @"LeadExplorerRow";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.detailTextLabel.numberOfLines = 2;
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    if (path.section == 0) {
        NSDictionary *group = self.sources[path.row];
        BOOL included = ![self.excluded containsObject:group[@"key"]];
        cell.textLabel.text = group[@"title"];
        cell.detailTextLabel.text = group[@"scope"] ?: ([group[@"kind"] isEqual:@"u"] ?
            @"المحادثة الخاصة" : @"كروب مشترك");
        cell.accessoryType = included ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    } else if (path.section == 1) {
        NSDictionary *item = self.results[path.row];
        cell.textLabel.text = [NSString stringWithFormat:@"%@ — %@", item[@"type"], item[@"title"]];
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:[item[@"date"] doubleValue]];
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.dateStyle = NSDateFormatterShortStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
        NSString *body = item[@"text"];
        if (![body isKindOfClass:NSString.class] || !body.length) body = @"وسائط";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", [formatter stringFromDate:date], body];
        if (!self.selectionMode) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.textLabel.text = [NSString stringWithFormat:@"تحميل رسائل أقدم (%lu مصدر)",
           (unsigned long)self.olderOffsets.count];
        cell.detailTextLabel.text = @"متابعة فحص رسائل المرسل القديمة على دفعات";
        cell.textLabel.textColor = UIColor.systemBlueColor;
    }
    return cell;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)path {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)path {
    return path.section == 1;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == 0) {
        [tableView deselectRowAtIndexPath:path animated:YES];
        if (self.selectionMode) return;
        NSDictionary *group = self.sources[path.row];
        NSString *key = group[@"key"];
        if ([self.excluded containsObject:key]) [self.excluded removeObject:key];
        else [self.excluded addObject:key];
        [self startFreshScan];
        return;
    }
    if (path.section == 2) {
        [tableView deselectRowAtIndexPath:path animated:YES];
        [self loadOlder];
        return;
    }
    NSDictionary *entry = self.results[path.row];
    if (self.selectionMode) {
        [self.selectedKeys addObject:[self uniqueForEntry:entry]];
        [self updateSelectionNavigation];
        return;
    }
    [tableView deselectRowAtIndexPath:path animated:YES];
    NSString *kind = entry[@"kind"];
    long long identifier = [entry[@"sourceId"] longLongValue];
    long long message = [entry[@"id"] longLongValue];
    NSString *url = nil;
    if ([kind isEqual:@"c"]) {
        NSString *username = entry[@"username"];
        url = username.length ?
            [NSString stringWithFormat:@"tg://resolve?domain=%@&post=%lld",username,message] :
            [NSString stringWithFormat:@"tg://privatepost?channel=%lld&post=%lld",identifier,message];
    } else if ([kind isEqual:@"u"]) {
        url = [NSString stringWithFormat:@"tg://openmessage?user_id=%lld&message_id=%lld",identifier,message];
    } else if ([kind isEqual:@"g"]) {
        url = [NSString stringWithFormat:@"tg://openmessage?chat_id=%lld&message_id=%lld",identifier,message];
    }
    if (url) LeadOpenTelegramURL(url);
    else [self showError:@"تعذر إنشاء رابط لهذه الرسالة."];
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)path {
    if (self.selectionMode && path.section == 1 && path.row < (NSInteger)self.results.count) {
        [self.selectedKeys removeObject:[self uniqueForEntry:self.results[path.row]]];
        [self updateSelectionNavigation];
    }
}

@end
