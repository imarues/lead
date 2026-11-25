#import <UIKit/UIKit.h>
#import "LeadMenu.h"
#import "../Headers.h"
#import <QuartzCore/QuartzCore.h>

extern NSData *LeadDiscoveryUnpack(NSData *data);
@interface LeadUsernameScanner : NSObject
+ (NSDictionary *)resolveTarget:(NSString *)text;
+ (NSDictionary *)parseTarget:(NSData *)data kind:(NSString *)kind;
+ (NSData *)fullRequest:(NSDictionary *)target;
+ (NSArray *)parseFull:(NSData *)data;
+ (NSData *)pageRequest:(NSDictionary *)target offset:(int32_t)offset pinned:(BOOL)pinned limit:(int32_t)limit;
+ (NSDictionary *)parsePage:(NSData *)data;
@end
// A separate source list keeps every occurrence accessible without duplicating the results.
@interface LeadUsernameSourceController : UITableViewController
@property(nonatomic,copy) NSArray<NSNumber *> *messageIds;
@property(nonatomic,copy) void (^openSource)(NSNumber *);
@end
@implementation LeadUsernameSourceController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"مصادر النتيجة";
    self.tableView.backgroundColor = LeadThemeBackground(); self.tableView.tintColor = LeadThemeAccent();
    self.tableView.separatorColor = [LeadThemeAccent() colorWithAlphaComponent:0.14];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.messageIds.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"source"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"source"];
    NSNumber *mid = self.messageIds[indexPath.row];
    cell.textLabel.text = mid.longLongValue > 0 ? [NSString stringWithFormat:@"الرسالة #%@",mid] : @"نبذة القناة";
    KiraStyleListCell(cell);
    cell.textLabel.font = LeadFont(15, UIFontWeightMedium); cell.tintColor = LeadThemeAccent();
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.openSource) self.openSource(self.messageIds[indexPath.row]);
}
@end
@interface LeadUsernameScanViewController () <UITextFieldDelegate>
@property(nonatomic,strong) UITextField *field;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIButton *start;
@property(nonatomic,strong) NSDictionary *target;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSString *> *unique;
@property(nonatomic,strong) NSArray<NSString *> *rows;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSMutableOrderedSet<NSNumber *> *> *sources;
@property(nonatomic,copy) NSString *bioURL;
@property(nonatomic,strong) NSMutableArray<NSString *> *warnings;
@property(nonatomic) NSInteger generation;
@property(nonatomic) NSInteger scanned;
@property(nonatomic) BOOL running;
@end
@implementation LeadUsernameScanViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"فحص اليوزرات";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.backgroundColor = LeadThemeBackground(); self.tableView.tintColor = LeadThemeAccent();
    self.tableView.separatorColor = [LeadThemeAccent() colorWithAlphaComponent:0.14];
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 72;
    self.rows = @[]; self.unique = [NSMutableDictionary dictionary]; self.sources = [NSMutableDictionary dictionary]; self.warnings = [NSMutableArray array];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"نسخ الكل" style:UIBarButtonItemStylePlain target:self action:@selector(copyAll)];
    UIView *header = [[LeadThemeHeader alloc] initWithFrame:CGRectMake(0,0,320,194)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.field = [UITextField new]; self.field.borderStyle = UITextBorderStyleNone; self.field.backgroundColor = LeadThemeCard();
    self.field.layer.cornerRadius = 12; self.field.layer.borderWidth = 1; self.field.layer.borderColor = [LeadThemeAccent() colorWithAlphaComponent:0.32].CGColor;
    self.field.textColor = LeadThemeInk(); self.field.tintColor = LeadThemeAccent(); self.field.font = LeadFont(15, UIFontWeightMedium);
    self.field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,12,1)]; self.field.leftViewMode = UITextFieldViewModeAlways;
    self.field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"https://t.me/channel أو رابط دعوة" attributes:@{NSForegroundColorAttributeName:LeadThemeMuted()}]; self.field.keyboardType = UIKeyboardTypeURL;
    self.field.autocapitalizationType = UITextAutocapitalizationTypeNone; self.field.autocorrectionType = UITextAutocorrectionTypeNo;
    self.field.clearButtonMode = UITextFieldViewModeWhileEditing; self.field.returnKeyType = UIReturnKeySearch; self.field.delegate = self;
    self.start = [UIButton buttonWithType:UIButtonTypeSystem]; [self.start setTitle:@"بدء الفحص" forState:UIControlStateNormal];
    self.start.backgroundColor = LeadThemeAccent(); self.start.layer.cornerRadius = 12; self.start.titleLabel.font = LeadRoundedFont(15, UIFontWeightSemibold);
    [self.start setTitleColor:LeadThemeBackground() forState:UIControlStateNormal];
    [self.start addTarget:self action:@selector(startScan) forControlEvents:UIControlEventTouchUpInside];
    self.status = [UILabel new]; self.status.numberOfLines = 0; self.status.font = LeadFont(13, UIFontWeightRegular); self.status.textColor = LeadThemeMuted();
    self.status.text = @"يفحص النبذة والمثبتات وسجل الرسائل المتاح لحسابك. لا ينضم للقنوات ولا يفحص الأعضاء.";
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.field,self.start,self.status]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = NO; [header addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],[stack.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],[stack.topAnchor constraintEqualToAnchor:header.topAnchor constant:8],[self.field.heightAnchor constraintEqualToConstant:44],[self.start.heightAnchor constraintEqualToConstant:36]]];
    self.tableView.tableHeaderView = header;
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; if (self.isMovingFromParentViewController) { self.generation++; self.running = NO; } }
- (BOOL)textFieldShouldReturn:(UITextField *)textField { [self startScan]; return YES; }
- (void)refreshRows {
    self.rows = [[self.unique allValues] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [self.tableView reloadData];
}
- (void)addRefs:(NSArray *)refs {
    for (id item in refs) {
        NSString *ref = [item isKindOfClass:NSDictionary.class] ? item[@"value"] : item;
        NSNumber *mid = [item isKindOfClass:NSDictionary.class] ? item[@"messageId"] : @0;
        if (![ref isKindOfClass:NSString.class] || ![mid isKindOfClass:NSNumber.class]) continue;
        NSString *key = [ref hasPrefix:@"@"] ? ref.lowercaseString : ref;
        if (!self.unique[key]) self.unique[key] = ref;
        if (!self.sources[key]) self.sources[key] = [NSMutableOrderedSet orderedSet];
        [self.sources[key] addObject:mid];
    }
    [self refreshRows];
}
- (void)finish:(NSString *)reason {
    self.running = NO; self.field.enabled = YES; [self.start setTitle:@"بدء الفحص" forState:UIControlStateNormal];
    self.status.text = [NSString stringWithFormat:@"%@ — %ld رسالة، %lu نتيجة فريدة%@",reason,(long)self.scanned,(unsigned long)self.rows.count,self.warnings.count ? [@"\nفحص غير مكتمل: " stringByAppendingString:[self.warnings componentsJoinedByString:@"؛ "]] : @""];
}
// Request timeout prevents the screen from becoming stuck if the session is disconnected.
- (void)send:(NSData *)payload generation:(NSInteger)gen completion:(void (^)(NSData *,NSString *))completion {
    if (!payload.length) { completion(nil,@"تعذر تجهيز الطلب"); return; }
    __block BOOL delivered = NO;
    BOOL sent = LeadSendRawRequest(payload, ^(NSData *data, NSString *error) {
        if (delivered || gen != self.generation || !self.running) return;
        delivered = YES; completion(LeadDiscoveryUnpack(data),error);
    });
    if (!sent) { delivered = YES; completion(nil,@"جلسة تيليكرام غير متاحة"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if (delivered || gen != self.generation || !self.running) return;
        delivered = YES; completion(nil,@"انتهت مهلة الطلب");
    });
}
- (void)startScan {
    if (self.running) { self.generation++; [self finish:@"أُوقف الفحص — النتائج جزئية"]; return; }
    [self.field resignFirstResponder]; NSDictionary *req = [LeadUsernameScanner resolveTarget:self.field.text ?: @""];
    if (!req) { self.status.text = @"أدخل رابط قناة أو رابط دعوة صحيح، وليس رابط رسالة."; return; }
    NSInteger gen = ++self.generation; self.running = YES; self.scanned = 0;
    [self.unique removeAllObjects]; [self.sources removeAllObjects]; self.bioURL = nil; [self.warnings removeAllObjects]; [self refreshRows]; self.field.enabled = NO;
    [self.start setTitle:@"إيقاف الفحص" forState:UIControlStateNormal]; self.status.text = @"جاري التحقق من القناة…";
    [self send:req[@"payload"] generation:gen completion:^(NSData *data, NSString *error) {
        self.target = data.length && !error.length ? [LeadUsernameScanner parseTarget:data kind:req[@"kind"]] : nil;
        if (!self.target[@"peer"]) { [self finish:error ?: self.target[@"error"] ?: @"تعذر الوصول إلى القناة أو الرابط ليس قناة"]; return; }
        NSString *name = self.target[@"username"];
        if (name.length) self.bioURL = [NSString stringWithFormat:@"tg://resolve?domain=%@",name];
        else if ([req[@"kind"] isEqual:@"invite"]) self.bioURL = [NSString stringWithFormat:@"tg://join?invite=%@",req[@"targetValue"]];
        else self.bioURL = [NSString stringWithFormat:@"tg://resolve?domain=%@",req[@"targetValue"]];
        [self send:[LeadUsernameScanner fullRequest:self.target] generation:gen completion:^(NSData *full, NSString *err) {
            NSArray *refs = !err.length && full.length ? [LeadUsernameScanner parseFull:full] : nil;
            if (refs) [self addRefs:refs]; else [self.warnings addObject:@"تعذر فحص النبذة"];
            [self scanPage:0 pinned:YES limit:100 generation:gen];
        }];
    }];
}
- (void)scanPage:(int32_t)offset pinned:(BOOL)pinned limit:(int32_t)limit generation:(NSInteger)gen {
    if (!self.running || gen != self.generation) return;
    self.status.text = [NSString stringWithFormat:@"%@ — %@ — %ld رسالة، %lu نتيجة",self.target[@"title"],pinned ? @"المثبتات" : @"سجل الرسائل",(long)self.scanned,(unsigned long)self.rows.count];
    [self send:[LeadUsernameScanner pageRequest:self.target offset:offset pinned:pinned limit:limit] generation:gen completion:^(NSData *data, NSString *error) {
        NSDictionary *page = !error.length && data.length ? [LeadUsernameScanner parsePage:data] : nil;
        if (!page) {
            [self.warnings addObject:[NSString stringWithFormat:@"%@ (%@)",pinned ? @"المثبتات" : @"السجل",error ?: @"تعذر تحليل الرد"]];
            if (pinned) [self scanPage:0 pinned:NO limit:100 generation:gen]; else [self finish:@"توقف الفحص"];
            return;
        }
        [self addRefs:page[@"refs"]]; if (!pinned) self.scanned += [page[@"count"] integerValue];
        int32_t next = [page[@"offset"] intValue]; BOOL partial = [page[@"partial"] boolValue];
        if (partial && (!next || (offset && next >= offset))) {
            if (limit > 1) { [self scanPage:offset pinned:pinned limit:1 generation:gen]; return; }
            [self.warnings addObject:pinned ? @"مثبت بتنسيق غير مدعوم" : @"رسالة بتنسيق غير مدعوم؛ لا يمكن ضمان بقية السجل"];
            if (pinned) [self scanPage:0 pinned:NO limit:100 generation:gen]; else [self finish:@"توقف الفحص"];
            return;
        }
        if (![page[@"returned"] integerValue] || !next || (offset && next >= offset)) {
            if ([page[@"returned"] integerValue]) [self.warnings addObject:@"توقف مؤشر الصفحات"];
            if (pinned) [self scanPage:0 pinned:NO limit:100 generation:gen]; else [self finish:self.warnings.count ? @"انتهى الفحص الجزئي" : @"اكتمل الفحص"];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),dispatch_get_main_queue(),^{ [self scanPage:next pinned:pinned limit:100 generation:gen]; });
    }];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.rows.count; }
- (NSArray<NSNumber *> *)sourcesFor:(NSString *)ref {
    NSString *key = [ref hasPrefix:@"@"] ? ref.lowercaseString : ref;
    return [self.sources[key].array sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
}
- (void)openMessageId:(NSNumber *)mid {
    NSString *url = nil;
    if (mid.longLongValue == 0) url = self.bioURL;
    else if ([self.target[@"username"] length]) url = [NSString stringWithFormat:@"tg://resolve?domain=%@&post=%@",self.target[@"username"],mid];
    else if ([self.target[@"channelId"] longLongValue] > 0) url = [NSString stringWithFormat:@"tg://privatepost?channel=%@&post=%@",self.target[@"channelId"],mid];
    if (url.length) {
        if (self.running) { self.generation++; [self finish:@"أُوقف الفحص — النتائج جزئية"]; }
        LeadOpenTelegramURL(url); // Internal app delegate/scene router; never LaunchServices for tg://.
    }
}
- (void)openReference:(NSString *)ref {
    NSArray<NSNumber *> *ids = [self sourcesFor:ref];
    if (ids.count == 1) { [self openMessageId:ids.firstObject]; return; }
    if (ids.count > 1) {
        LeadUsernameSourceController *vc = [[LeadUsernameSourceController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        vc.messageIds = ids;
        __weak typeof(self) weakSelf = self;
        vc.openSource = ^(NSNumber *mid) { [weakSelf openMessageId:mid]; };
        [self.navigationController pushViewController:vc animated:YES];
    }
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"referenceActions"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"referenceActions"];
    NSString *ref = self.rows[indexPath.row];
    NSArray *ids = [self sourcesFor:ref];
    KiraStyleListCell(cell);
    cell.textLabel.text = ref; cell.textLabel.font = LeadFont(15, UIFontWeightSemibold); cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = ids.count == 1 ? ([ids.firstObject longLongValue] == 0 ? @"نبذة القناة" : [NSString stringWithFormat:@"الرسالة #%@",ids.firstObject]) : [NSString stringWithFormat:@"%lu مصادر",(unsigned long)ids.count];
    cell.detailTextLabel.textColor = LeadThemeMuted(); cell.detailTextLabel.font = LeadFont(12, UIFontWeightRegular);
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    __weak typeof(self) weakSelf = self;
    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    [copy setTitle:@"نسخ" forState:UIControlStateNormal];
    [copy addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        UIPasteboard.generalPasteboard.string = ref;
        LeadUsernameScanViewController *host = weakSelf;
        if (host) [LeadToast showText:@"تم النسخ" symbol:@"checkmark" inView:host.view];
    }] forControlEvents:UIControlEventTouchUpInside];
    UIButton *open = [UIButton buttonWithType:UIButtonTypeSystem];
    [open setTitle:@"فتح" forState:UIControlStateNormal];
    [open addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { [weakSelf openReference:ref]; }] forControlEvents:UIControlEventTouchUpInside];
    open.enabled = ids.count > 0;
    for (UIButton *button in @[copy, open]) {
        button.backgroundColor = [LeadThemeAccent() colorWithAlphaComponent:0.18];
        button.layer.cornerRadius = 10; button.titleLabel.font = LeadFont(13, UIFontWeightSemibold);
        [button setTitleColor:LeadThemeInk() forState:UIControlStateNormal];
        [button setTitleColor:[LeadThemeMuted() colorWithAlphaComponent:0.5] forState:UIControlStateDisabled];
    }
    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[copy,open]];
    actions.axis = UILayoutConstraintAxisHorizontal; actions.distribution = UIStackViewDistributionFillEqually; actions.spacing = 4;
    actions.frame = CGRectMake(0,0,104,34);
    cell.accessoryView = actions;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath { [tableView deselectRowAtIndexPath:indexPath animated:YES]; }
- (void)copyAll { UIPasteboard.generalPasteboard.string = [self.rows componentsJoinedByString:@"\n"]; }
@end
