#import <UIKit/UIKit.h>
#import "LeadMenu.h"
#import "../Headers.h"

extern NSData *LeadDiscoveryUnpack(NSData *data);
@interface LeadUsernameScanner : NSObject
+ (NSDictionary *)resolveTarget:(NSString *)text;
+ (NSDictionary *)parseTarget:(NSData *)data kind:(NSString *)kind;
+ (NSData *)fullRequest:(NSDictionary *)target;
+ (NSArray *)parseFull:(NSData *)data;
+ (NSData *)pageRequest:(NSDictionary *)target offset:(int32_t)offset pinned:(BOOL)pinned limit:(int32_t)limit;
+ (NSDictionary *)parsePage:(NSData *)data;
@end
@interface LeadUsernameScanViewController () <UITextFieldDelegate>
@property(nonatomic,strong) UITextField *field;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIButton *start;
@property(nonatomic,strong) NSDictionary *target;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSString *> *unique;
@property(nonatomic,strong) NSArray<NSString *> *rows;
@property(nonatomic,strong) NSMutableArray<NSString *> *warnings;
@property(nonatomic) NSInteger generation;
@property(nonatomic) NSInteger scanned;
@property(nonatomic) BOOL running;
@end
@implementation LeadUsernameScanViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"فحص اليوزرات";
    self.rows = @[]; self.unique = [NSMutableDictionary dictionary]; self.warnings = [NSMutableArray array];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"نسخ الكل" style:UIBarButtonItemStylePlain target:self action:@selector(copyAll)];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0,0,320,178)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.field = [UITextField new]; self.field.borderStyle = UITextBorderStyleRoundedRect;
    self.field.placeholder = @"https://t.me/channel أو رابط دعوة"; self.field.keyboardType = UIKeyboardTypeURL;
    self.field.autocapitalizationType = UITextAutocapitalizationTypeNone; self.field.autocorrectionType = UITextAutocorrectionTypeNo;
    self.field.clearButtonMode = UITextFieldViewModeWhileEditing; self.field.returnKeyType = UIReturnKeySearch; self.field.delegate = self;
    self.start = [UIButton buttonWithType:UIButtonTypeSystem]; [self.start setTitle:@"بدء الفحص" forState:UIControlStateNormal];
    [self.start addTarget:self action:@selector(startScan) forControlEvents:UIControlEventTouchUpInside];
    self.status = [UILabel new]; self.status.numberOfLines = 0; self.status.font = [UIFont systemFontOfSize:13]; self.status.textColor = UIColor.secondaryLabelColor;
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
    for (NSString *ref in refs) { if (![ref isKindOfClass:NSString.class]) continue;
        NSString *key = [ref hasPrefix:@"@"] ? ref.lowercaseString : ref;
        if (!self.unique[key]) self.unique[key] = ref;
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
    [self.unique removeAllObjects]; [self.warnings removeAllObjects]; [self refreshRows]; self.field.enabled = NO;
    [self.start setTitle:@"إيقاف الفحص" forState:UIControlStateNormal]; self.status.text = @"جاري التحقق من القناة…";
    [self send:req[@"payload"] generation:gen completion:^(NSData *data, NSString *error) {
        self.target = data.length && !error.length ? [LeadUsernameScanner parseTarget:data kind:req[@"kind"]] : nil;
        if (!self.target[@"peer"]) { [self finish:error ?: self.target[@"error"] ?: @"تعذر الوصول إلى القناة أو الرابط ليس قناة"]; return; }
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
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"reference"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"reference"];
    cell.textLabel.text = self.rows[indexPath.row]; cell.textLabel.font = [UIFont systemFontOfSize:15]; cell.textLabel.numberOfLines = 0; cell.accessoryType = UITableViewCellAccessoryNone; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath { UIPasteboard.generalPasteboard.string = self.rows[indexPath.row]; [tableView deselectRowAtIndexPath:indexPath animated:YES]; }
- (void)copyAll { UIPasteboard.generalPasteboard.string = [self.rows componentsJoinedByString:@"\n"]; }
@end
