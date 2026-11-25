#import "LeadMenu.h"
#import "Headers.h"
#import <objc/message.h>
#import <CoreText/CoreText.h>

// Entries come from TLParser.messageLogEntries (Swift): dictionaries with
// kind ("deleted"/"edited"), peer ("u…"/"g…"/"c…"), id, text, old, date, name, username.
NSArray<NSDictionary *> *LeadMessageLogEntries(void) {
  Class parser = NSClassFromString(@"TLParser");
  SEL selector = NSSelectorFromString(@"messageLogEntries");
  if (![parser respondsToSelector:selector]) return @[];
  NSArray *entries = ((NSArray * (*)(id, SEL))objc_msgSend)(parser, selector);
  return [entries isKindOfClass:[NSArray class]] ? entries : @[];
}

// Telegram stripped-thumbnail format (core.telegram.org/api/files).
static UIImage *LeadLogAvatar(NSString *peer) {
  if (![peer isKindOfClass:NSString.class] || ![peer hasPrefix:@"u"]) return nil;
  Class parser = NSClassFromString(@"TLParser");
  SEL selector = NSSelectorFromString(@"profileAvatarForPeer:");
  if (![parser respondsToSelector:selector]) return nil;
  NSData *thumb = ((NSData *(*)(id, SEL, id))objc_msgSend)(parser, selector, peer);
  if (thumb.length < 3 || thumb.length > 8192) return nil;
  const uint8_t *bytes = thumb.bytes;
  if (bytes[0] != 1) return [UIImage imageWithData:thumb];
  if (!bytes[1] || !bytes[2]) return nil;
  static NSData *header;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    const char *hex =
      "ffd8ffe000104a46494600010100000100010000ffdb004300281c1e231e19282321232d2b28303c64413c37373c7b58"
      "5d4964918099968f808c8aa0b4e6c3a0aadaad8a8cc8ffcbdaeef5ffffff9bc1fffffffaffe6fdfff8ffdb0043012b2d"
      "2d3c353c76414176f8a58ca5f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8"
      "f8f8f8f8f8f8f8f8f8f8f8f8f8f8ffc00011080000000003012200021101031101ffc4001f0000010501010101010100"
      "000000000000000102030405060708090a0bffc400b5100002010303020403050504040000017d010203000411051221"
      "31410613516107227114328191a1082342b1c11552d1f02433627282090a161718191a25262728292a3435363738393a"
      "434445464748494a535455565758595a636465666768696a737475767778797a838485868788898a9293949596979899"
      "9aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9eaf1"
      "f2f3f4f5f6f7f8f9faffc4001f0100030101010101010101010000000000000102030405060708090a0bffc400b51100"
      "020102040403040705040400010277000102031104052131061241510761711322328108144291a1b1c109233352f015"
      "6272d10a162434e125f11718191a262728292a35363738393a434445464748494a535455565758595a63646566676869"
      "6a737475767778797a82838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4"
      "c5c6c7c8c9cad2d3d4d5d6d7d8d9dae2e3e4e5e6e7e8e9eaf2f3f4f5f6f7f8f9faffda000c03010002110311003f00";
    NSMutableData *data = [NSMutableData dataWithLength:623];
    uint8_t *out = data.mutableBytes;
    for (NSUInteger i = 0; i < 623; i++) {
      char hi = hex[i * 2], lo = hex[i * 2 + 1];
      out[i] = ((hi <= '9' ? hi - '0' : hi - 'a' + 10) << 4) |
               (lo <= '9' ? lo - '0' : lo - 'a' + 10);
    }
    header = [data copy];
  });
  NSMutableData *jpeg = [header mutableCopy];
  uint8_t *head = jpeg.mutableBytes;
  head[164] = bytes[1]; head[166] = bytes[2];
  [jpeg appendBytes:bytes + 3 length:thumb.length - 3];
  const uint8_t footer[] = {0xff, 0xd9};
  [jpeg appendBytes:footer length:sizeof(footer)];
  return [UIImage imageWithData:jpeg];
}

@interface LeadMessageLogViewController () <UISearchBarDelegate>
@property (nonatomic, strong) UISegmentedControl *segments;
@property (nonatomic, strong) UISearchBar *profileSearch;
@property (nonatomic, strong) NSArray<NSDictionary *> *entries;
@property (nonatomic, strong) UIView *emptyView;
@property (nonatomic, strong) UILabel *emptyTitle;
@property (nonatomic, strong) UILabel *emptyHint;
@end

@implementation LeadMessageLogViewController

- (instancetype)init {
  return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = LeadL(@"UI_MESSAGE_LOG");
  self.tableView.backgroundColor = LeadThemeBackground(); self.tableView.tintColor = LeadThemeAccent();
  self.tableView.separatorColor = [LeadThemeAccent() colorWithAlphaComponent:0.14];
  self.tableView.rowHeight = UITableViewAutomaticDimension;
  self.tableView.estimatedRowHeight = 72;
  [self.tableView registerClass:[LeadCell class] forCellReuseIdentifier:@"LeadCell"];

  self.segments = [[UISegmentedControl alloc] initWithItems:@[ LeadL(@"UI_LOG_DELETED"), LeadL(@"UI_LOG_EDITED"), LeadL(@"UI_LOG_PROFILES") ]];
  self.segments.selectedSegmentIndex = 0;
  [self.segments addTarget:self action:@selector(segmentChanged) forControlEvents:UIControlEventValueChanged];
  UIView *header = [[LeadThemeHeader alloc] initWithFrame:CGRectMake(0, 0, 320, 52)];
  self.segments.backgroundColor = LeadThemeCard(); self.segments.selectedSegmentTintColor = LeadThemeAccent();
  [self.segments setTitleTextAttributes:@{NSForegroundColorAttributeName:LeadThemeInk()} forState:UIControlStateNormal];
  [self.segments setTitleTextAttributes:@{NSForegroundColorAttributeName:LeadThemeBackground()} forState:UIControlStateSelected];
  self.segments.translatesAutoresizingMaskIntoConstraints = NO;
  [header addSubview:self.segments];
  self.profileSearch = [[UISearchBar alloc] initWithFrame:CGRectZero];
  self.profileSearch.searchBarStyle = UISearchBarStyleMinimal;
  self.profileSearch.searchTextField.backgroundColor = LeadThemeCard(); self.profileSearch.searchTextField.textColor = LeadThemeInk(); self.profileSearch.tintColor = LeadThemeAccent();
  self.profileSearch.placeholder = LeadL(@"UI_PROFILE_FILTER_HINT");
  self.profileSearch.delegate = self;
  self.profileSearch.hidden = YES;
  self.profileSearch.translatesAutoresizingMaskIntoConstraints = NO;
  [header addSubview:self.profileSearch];
  [NSLayoutConstraint activateConstraints:@[
    [self.segments.leadingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.leadingAnchor],
    [self.segments.trailingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.trailingAnchor],
    [self.segments.centerYAnchor constraintEqualToAnchor:header.topAnchor constant:26],
    [self.profileSearch.topAnchor constraintEqualToAnchor:header.topAnchor constant:52],
    [self.profileSearch.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:8],
    [self.profileSearch.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-8],
    [self.profileSearch.heightAnchor constraintEqualToConstant:48],
  ]];
  self.tableView.tableHeaderView = header;

  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"trash"] style:UIBarButtonItemStylePlain target:self action:@selector(clearTapped)];
  self.emptyView = [self buildEmptyView];

  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:@"LeadMessageLogChanged" object:nil];
  [self reload];
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSString *)currentKind {
  return @[ @"deleted", @"edited", @"profile" ][MAX(0, MIN(2, self.segments.selectedSegmentIndex))];
}

- (void)reload {
  NSString *kind = self.currentKind;
  BOOL profiles = [kind isEqualToString:@"profile"];
  UIView *header = self.tableView.tableHeaderView;
  CGFloat height = profiles ? 104 : 52;
  self.profileSearch.hidden = !profiles;
  if (!profiles) [self.profileSearch resignFirstResponder];
  if (header && CGRectGetHeight(header.frame) != height) {
    CGRect frame = header.frame;
    frame.size.height = height;
    header.frame = frame;
    self.tableView.tableHeaderView = header;
  }
  NSString *query = profiles ? [self.profileSearch.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
  NSMutableArray *filtered = [NSMutableArray array];
  for (NSDictionary *entry in LeadMessageLogEntries()) {
    if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"kind"] isEqualToString:kind]) continue;
    if (query.length) {
      NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@", [self titleForEntry:entry],
                           entry[@"username"] ?: @"", entry[@"peer"] ?: @"",
                           LeadProfileChangeText(entry), [self profileTimestampForEntry:entry]];
      if (![haystack localizedStandardContainsString:query]) continue;
    }
    [filtered addObject:entry];
  }
  self.entries = filtered;
  NSArray *emptyKeys = @[ @"UI_LOG_EMPTY_DELETED", @"UI_LOG_EMPTY_EDITED", @"UI_LOG_EMPTY_PROFILES" ];
  NSString *emptyKey = emptyKeys[MAX(0, MIN(2, self.segments.selectedSegmentIndex))];
  self.emptyTitle.text = LeadL(query.length ? @"UI_PROFILE_FILTER_EMPTY" : emptyKey);
  self.emptyHint.text = LeadL([kind isEqualToString:@"profile"] ? @"UI_LOG_EMPTY_PROFILES_HINT" : @"UI_LOG_EMPTY_HINT");
  self.tableView.backgroundView = filtered.count ? nil : self.emptyView;
  self.navigationItem.rightBarButtonItem.enabled = LeadMessageLogEntries().count > 0;
  [self.tableView reloadData];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
  if ([self.currentKind isEqualToString:@"profile"]) [self reload];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
  [searchBar resignFirstResponder];
}

- (void)segmentChanged {
  LeadSelectionHaptic();
  [UIView transitionWithView:self.tableView duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
    [self reload];
  } completion:nil];
}

- (UIView *)buildEmptyView {
  UIView *container = [UIView new];
  LeadIconTile *tile = [LeadIconTile new];
  tile.side = 56;
  [tile setSymbol:@"tray"];
  tile.translatesAutoresizingMaskIntoConstraints = NO;
  self.emptyTitle = [UILabel new];
  self.emptyTitle.font = LeadRoundedFont(18, UIFontWeightSemibold); self.emptyTitle.textColor = LeadThemeInk();
  self.emptyTitle.textAlignment = NSTextAlignmentCenter;
  UILabel *hint = [UILabel new];
  self.emptyHint = hint;
  hint.text = LeadL(@"UI_LOG_EMPTY_HINT");
  hint.font = LeadFont(14, UIFontWeightRegular);
  hint.textColor = LeadThemeMuted();
  hint.textAlignment = NSTextAlignmentCenter;
  hint.numberOfLines = 0;
  UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ tile, self.emptyTitle, hint ]];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.alignment = UIStackViewAlignmentCenter;
  stack.spacing = 10;
  [stack setCustomSpacing:16 afterView:tile];
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [container addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [tile.widthAnchor constraintEqualToConstant:56],
    [tile.heightAnchor constraintEqualToConstant:56],
    [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
    [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:40],
    [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-40],
  ]];
  return container;
}

#pragma mark - Formatting

// UIKit normally selects its own fallback fonts, including Apple Color Emoji.
// Only substitute a Unicode compatibility form when the original cluster is
// not renderable. Keep the original string in the log and search data.
static BOOL LeadLogHasGlyph(NSString *text) {
  if (!text.length) return NO;
  NSAttributedString *value = [[NSAttributedString alloc] initWithString:text
    attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:16] }];
  CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)value);
  BOOL visible = NO, missing = NO;
  CFArrayRef runs = CTLineGetGlyphRuns(line);
  for (CFIndex i = 0; i < CFArrayGetCount(runs); i++) {
    CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, i);
    for (CFIndex j = 0; j < CTRunGetGlyphCount(run); j++) {
      CGGlyph glyph = 0;
      CTRunGetGlyphs(run, CFRangeMake(j, 1), &glyph);
      if (glyph) visible = YES; else missing = YES;
    }
  }
  CFRelease(line);
  return visible && !missing;
}

static NSString *LeadLogDisplayGlyphs(NSString *text) {
  if (!text.length) return text;
  NSMutableString *output = [NSMutableString stringWithCapacity:text.length];
  [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
    options:NSStringEnumerationByComposedCharacterSequences
    usingBlock:^(NSString *cluster, NSRange range, NSRange enclosingRange, BOOL *stop) {
      NSString *chosen = cluster;
      if (cluster.length && [cluster characterAtIndex:0] >= 0x80 && !LeadLogHasGlyph(cluster)) {
        NSString *canonical = [cluster precomposedStringWithCanonicalMapping];
        NSString *compatible = [cluster precomposedStringWithCompatibilityMapping];
        NSString *withoutVariant = [[cluster stringByReplacingOccurrencesOfString:@"\uFE0F" withString:@""]
          stringByReplacingOccurrencesOfString:@"\uFE0E" withString:@""];
        for (NSString *candidate in @[canonical, withoutVariant, compatible]) {
          if (![candidate isEqualToString:cluster] && LeadLogHasGlyph(candidate)) {
            chosen = candidate;
            break;
          }
        }
      }
      [output appendString:chosen ?: @""];
    }];
  return output;
}

NSString *LeadProfileChangeText(NSDictionary *entry) {
  NSString *field = entry[@"field"];
  NSString *old = [entry[@"old"] isKindOfClass:[NSString class]] ? entry[@"old"] : nil;
  NSString *now = [entry[@"text"] isKindOfClass:[NSString class]] ? entry[@"text"] : nil;
  if ([field isEqualToString:@"photo"]) return LeadL(@"UI_PROFILE_PHOTO_CHANGED");
  if ([field isEqualToString:@"photo_added"]) return LeadL(@"UI_PROFILE_PHOTO_ADDED");
  if ([field isEqualToString:@"photo_removed"]) return LeadL(@"UI_PROFILE_PHOTO_REMOVED");
  if ([field isEqualToString:@"story_seen"]) return LeadL(@"UI_PROFILE_STORY_SEEN");
  if ([field isEqualToString:@"story_removed"]) return LeadL(@"UI_PROFILE_STORY_REMOVED");

  NSString *label = LeadL(@"UI_PROFILE_NAME");
  if ([field isEqualToString:@"bio"]) label = LeadL(@"UI_PROFILE_BIO");
  if ([field isEqualToString:@"username"]) {
    label = LeadL(@"UI_PROFILE_USERNAME");
    if (old.length) old = [@"@" stringByAppendingString:old];
    if (now.length) now = [@"@" stringByAppendingString:now];
  }
  NSString *empty = LeadL(@"UI_PROFILE_EMPTY_VALUE");
  NSString *change = [NSString stringWithFormat:LeadL(@"UI_PROFILE_CHANGE_FORMAT"),
    old.length ? LeadLogDisplayGlyphs(old) : empty, now.length ? LeadLogDisplayGlyphs(now) : empty];
  return [NSString stringWithFormat:@"%@\n%@", [NSString stringWithFormat:LeadL(@"UI_PROFILE_CHANGE_FIELD"), label], change];
}

static NSString *LeadLogText(id value) {
  NSString *text = [value isKindOfClass:[NSString class]] ? value : nil;
  if (!text) return nil;
  if ([text isEqualToString:@"[media]"]) return LeadL(@"UI_LOG_MEDIA");
  return text;
}

- (NSString *)titleForEntry:(NSDictionary *)entry {
  NSString *name = entry[@"name"];
  if ([name isKindOfClass:[NSString class]] && name.length) return name;
  NSString *username = entry[@"username"];
  if ([username isKindOfClass:[NSString class]] && username.length) return [@"@" stringByAppendingString:username];
  NSString *peer = entry[@"peer"];
  return [peer isKindOfClass:[NSString class]] && peer.length > 1 ? [NSString stringWithFormat:@"ID %@", [peer substringFromIndex:1]] : @"Telegram";
}

- (NSString *)timeForEntry:(NSDictionary *)entry {
  NSDate *date = [NSDate dateWithTimeIntervalSince1970:[entry[@"date"] doubleValue]];
  static NSDateFormatter *time, *day;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    time = [NSDateFormatter new];
    [time setLocalizedDateFormatFromTemplate:@"jjmm"];
    day = [NSDateFormatter new];
    [day setLocalizedDateFormatFromTemplate:@"dMMM"];
  });
  return [NSCalendar.currentCalendar isDateInToday:date] ? [time stringFromDate:date] : [day stringFromDate:date];
}

- (NSString *)profileTimestampForEntry:(NSDictionary *)entry {
  NSNumber *value = [entry[@"date"] isKindOfClass:NSNumber.class] ? entry[@"date"] : nil;
  if (value.doubleValue <= 0) return @"";
  NSDate *date = [NSDate dateWithTimeIntervalSince1970:value.doubleValue];
  NSString *language = [[NSUserDefaults standardUserDefaults] stringForKey:@"LeadLanguage"] ?: @"en";
  NSDateFormatter *format = [NSDateFormatter new];
  format.locale = [NSLocale localeWithLocaleIdentifier:[language isEqualToString:@"ar"] ? @"ar_IQ" : language];
  format.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
  format.timeZone = NSTimeZone.localTimeZone;
  format.dateFormat = @"d/M/yyyy HH:mm";
  NSString *key = [entry[@"dateSource"] isEqualToString:@"published"] ? @"UI_PROFILE_PUBLISHED_AT" : @"UI_PROFILE_OBSERVED_AT";
  return [NSString stringWithFormat:LeadL(key), [format stringFromDate:date] ?: @""];
}

- (NSAttributedString *)detailForEntry:(NSDictionary *)entry {
  UIFont *font = LeadFont(14, UIFontWeightRegular);
  if ([entry[@"kind"] isEqualToString:@"profile"]) {
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:LeadProfileChangeText(entry) attributes:@{
      NSFontAttributeName : font,
      NSForegroundColorAttributeName : LeadThemeInk(),
    }];
    NSString *stamp = [self profileTimestampForEntry:entry];
    if (stamp.length) {
      [result appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:stamp] attributes:@{
        NSFontAttributeName : LeadFont(12, UIFontWeightRegular),
        NSForegroundColorAttributeName : LeadThemeMuted(),
      }]];
    }
    return result;
  }
  NSString *text = LeadLogText(entry[@"text"]);
  if ([entry[@"kind"] isEqualToString:@"edited"]) {
    NSMutableAttributedString *result = [NSMutableAttributedString new];
    NSString *old = LeadLogText(entry[@"old"]);
    if (old.length) {
      [result appendAttributedString:[[NSAttributedString alloc] initWithString:old attributes:@{
        NSFontAttributeName : font,
        NSForegroundColorAttributeName : [LeadThemeMuted() colorWithAlphaComponent:0.70],
        NSStrikethroughStyleAttributeName : @(NSUnderlineStyleSingle),
      }]];
      [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:@{ NSFontAttributeName : font }]];
    }
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:text ?: @"" attributes:@{
      NSFontAttributeName : font,
      NSForegroundColorAttributeName : LeadThemeInk(),
    }]];
    return result;
  }
  if (text.length == 0) {
    return [[NSAttributedString alloc] initWithString:LeadL(@"UI_LOG_NO_TEXT") attributes:@{
      NSFontAttributeName : [UIFont italicSystemFontOfSize:14],
      NSForegroundColorAttributeName : [LeadThemeMuted() colorWithAlphaComponent:0.70],
    }];
  }
  return [[NSAttributedString alloc] initWithString:text attributes:@{
    NSFontAttributeName : font,
    NSForegroundColorAttributeName : LeadThemeMuted(),
  }];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return self.entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  NSDictionary *entry = self.entries[indexPath.row];
  LeadCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LeadCell" forIndexPath:indexPath];
  NSString *title = LeadLogDisplayGlyphs([self titleForEntry:entry]);
  [cell configureTitle:title subtitle:@" " symbol:nil];
  BOOL named = [entry[@"name"] length] > 0 || [entry[@"username"] length] > 0;
  UIImage *avatar = [entry[@"kind"] isEqualToString:@"profile"] ? LeadLogAvatar(entry[@"peer"]) : nil;
  if (avatar) {
    [cell.tile setImage:avatar];
  } else if (named && title.length) {
    NSRange first = [title rangeOfComposedCharacterSequenceAtIndex:0];
    [cell.tile setText:[[title substringWithRange:first] uppercaseString]];
  } else {
    // Chat never seen by name: show what kind of event it is instead of a stray letter.
    [cell.tile setSymbol:[entry[@"kind"] isEqualToString:@"edited"] ? @"pencil" : ([entry[@"kind"] isEqualToString:@"profile"] ? @"person" : @"trash")];
  }
  cell.subtitleLabel.attributedText = [self detailForEntry:entry];
  BOOL isProfile = [entry[@"kind"] isEqualToString:@"profile"];
  cell.subtitleLabel.numberOfLines = isProfile ? 0 : 6;
  [cell showValue:isProfile ? nil : [self timeForEntry:entry] chevron:NO];
  return cell;
}

- (NSString *)urlForEntry:(NSDictionary *)entry {
  return LeadURLForLogEntry(entry);
}

NSString *LeadURLForLogEntry(NSDictionary *entry) {
  NSString *peer = entry[@"peer"];
  if (![peer isKindOfClass:[NSString class]] || peer.length < 2) return nil;
  NSString *rawId = [peer substringFromIndex:1];
  NSString *username = [entry[@"username"] isKindOfClass:[NSString class]] ? entry[@"username"] : nil;
  long long messageId = [entry[@"id"] longLongValue];
  if ([peer hasPrefix:@"c"] && messageId == 0) {
    return username.length ? [NSString stringWithFormat:@"tg://resolve?domain=%@", username] : nil;
  }
  if ([peer hasPrefix:@"c"]) {
    return username.length ? [NSString stringWithFormat:@"tg://resolve?domain=%@&post=%lld", username, messageId]
                           : [NSString stringWithFormat:@"tg://privatepost?channel=%@&post=%lld", rawId, messageId];
  }
  if ([peer hasPrefix:@"u"]) {
    return username.length ? [NSString stringWithFormat:@"tg://resolve?domain=%@", username]
                           : [NSString stringWithFormat:@"tg://user?id=%@", rawId];
  }
  return nil;
}

- (void)openEntry:(NSDictionary *)entry {
  NSString *url = [self urlForEntry:entry];
  if (!url) {
    [LeadToast showText:LeadL(@"UI_LOG_CANT_OPEN") symbol:@"exclamationmark.circle" inView:self.view];
    return;
  }
  LeadOpenTelegramURL(url);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  [self openEntry:self.entries[indexPath.row]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                        point:(CGPoint)point {
  NSDictionary *entry = self.entries[indexPath.row];
  __weak typeof(self) weakSelf = self;
  return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(__unused NSArray *suggested) {
    NSMutableArray *actions = [NSMutableArray array];
    NSString *text = LeadLogText(entry[@"text"]);
    if (text.length) {
      [actions addObject:[UIAction actionWithTitle:LeadL(@"UI_COPY") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *action) {
        [UIPasteboard generalPasteboard].string = text;
        [LeadToast showText:LeadL(@"UI_COPIED") symbol:@"checkmark" inView:weakSelf.view];
      }]];
    }
    if ([weakSelf urlForEntry:entry]) {
      [actions addObject:[UIAction actionWithTitle:LeadL(@"UI_LOG_OPEN") image:[UIImage systemImageNamed:@"arrow.up.forward.app"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf openEntry:entry];
      }]];
    }
    return [UIMenu menuWithTitle:@"" children:actions];
  }];
}

- (void)clearTapped {
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:LeadL(@"UI_LOG_CLEAR_CONFIRM") message:nil preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:LeadL(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:LeadL(@"UI_CLEAR") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
    Class parser = NSClassFromString(@"TLParser");
    SEL selector = NSSelectorFromString(@"clearMessageLog");
    if ([parser respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(parser, selector);
    LeadImpactHaptic(UIImpactFeedbackStyleMedium);
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Deletion banner

// "Anna · deleted a message" at the top of Telegram when Anti-Revoke catches a
// deletion. Deletions arriving together (a cleared chat) collapse into one banner.
@implementation LeadDeletionBanner {
  NSMutableArray<NSDictionary *> *_pending;
  UIView *_current;
}

+ (instancetype)shared {
  static LeadDeletionBanner *banner;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    banner = [LeadDeletionBanner new];
  });
  return banner;
}

+ (void)install {
  [[NSNotificationCenter defaultCenter] addObserver:[self shared] selector:@selector(deletion:) name:@"LeadDeletionBanner" object:nil];
}

- (void)deletion:(NSNotification *)note {
  if (!note.userInfo) return;
  if (!_pending) _pending = [NSMutableArray array];
  [_pending addObject:note.userInfo];
  if (_pending.count == 1) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self flush];
    });
  }
}

- (void)flush {
  NSArray *entries = [_pending copy];
  [_pending removeAllObjects];
  if (entries.count == 0) return;
  UIWindow *window = LeadMainWindow();
  if (!window) return;
  NSDictionary *first = entries.firstObject;
  NSString *name = [first[@"name"] isKindOfClass:[NSString class]] && [first[@"name"] length] ? first[@"name"] : LeadL(@"UI_BANNER_FALLBACK");
  NSString *text = LeadLogText(first[@"text"]);
  NSString *detail = entries.count > 1 ? [NSString stringWithFormat:LeadL(@"UI_BANNER_MANY"), (long)entries.count]
                                       : (text.length ? [NSString stringWithFormat:@"%@: %@", LeadL(@"UI_BANNER_ONE"), text] : LeadL(@"UI_BANNER_ONE"));
  [self showTitle:name detail:detail entry:entries.count == 1 ? first : nil inWindow:window];
}

- (void)showTitle:(NSString *)title detail:(NSString *)detail entry:(NSDictionary *)entry inWindow:(UIWindow *)window {
  [_current removeFromSuperview];
  UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
  card.layer.cornerRadius = 22;
  card.layer.cornerCurve = kCACornerCurveContinuous;
  card.clipsToBounds = YES;
  card.translatesAutoresizingMaskIntoConstraints = NO;

  LeadIconTile *tile = [LeadIconTile new];
  tile.side = 34;
  [tile setSymbol:@"trash"];
  [tile setActive:YES animated:NO];
  tile.translatesAutoresizingMaskIntoConstraints = NO;
  UILabel *titleLabel = [UILabel new];
  titleLabel.text = title;
  titleLabel.font = LeadFont(15, UIFontWeightSemibold);
  UILabel *detailLabel = [UILabel new];
  detailLabel.text = detail;
  detailLabel.font = LeadFont(14, UIFontWeightRegular);
  detailLabel.textColor = LeadThemeMuted();
  detailLabel.numberOfLines = 2;
  UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[ titleLabel, detailLabel ]];
  texts.axis = UILayoutConstraintAxisVertical;
  texts.spacing = 1;
  UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ tile, texts ]];
  row.spacing = 12;
  row.alignment = UIStackViewAlignmentCenter;
  row.translatesAutoresizingMaskIntoConstraints = NO;
  [card.contentView addSubview:row];
  [window addSubview:card];
  _current = card;
  [NSLayoutConstraint activateConstraints:@[
    [tile.widthAnchor constraintEqualToConstant:34],
    [tile.heightAnchor constraintEqualToConstant:34],
    [row.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:12],
    [row.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-16],
    [row.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:11],
    [row.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-11],
    [card.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:6],
    [card.leadingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor constant:12],
    [card.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-12],
  ]];
  [window layoutIfNeeded];

  if (entry && LeadURLForLogEntry(entry)) {
    objc_setAssociatedObject(card, @selector(tapped:), entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [card addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)]];
  }
  UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swiped:)];
  swipe.direction = UISwipeGestureRecognizerDirectionUp;
  [card addGestureRecognizer:swipe];
  [card addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pressed:)]];

  LeadImpactHaptic(UIImpactFeedbackStyleLight);
  card.alpha = 0;
  card.transform = CGAffineTransformMakeTranslation(0, -60);
  LeadSpring(0.55, 0.78, ^{
    card.alpha = 1;
    card.transform = CGAffineTransformIdentity;
  }, nil);
  __weak UIView *weakCard = card;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self dismiss:weakCard];
  });
}

- (void)dismiss:(UIView *)card {
  if (!card.superview) return;
  [UIView animateWithDuration:0.25 animations:^{
    card.alpha = 0;
    card.transform = CGAffineTransformMakeTranslation(0, -40);
  } completion:^(__unused BOOL finished) {
    [card removeFromSuperview];
  }];
}

- (void)swiped:(UISwipeGestureRecognizer *)gesture {
  [self dismiss:gesture.view];
}

// Long press: offer to turn the banner off without going through the menu.
- (void)pressed:(UILongPressGestureRecognizer *)gesture {
  if (gesture.state != UIGestureRecognizerStateBegan) return;
  UIView *card = gesture.view;
  UIViewController *host = card.window.rootViewController;
  while (host.presentedViewController) host = host.presentedViewController;
  if (!host) return;
  LeadImpactHaptic(UIImpactFeedbackStyleMedium);
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:LeadL(@"UI_BANNER_DISABLE_TITLE")
                                                                 message:LeadL(@"UI_BANNER_DISABLE_MESSAGE")
                                                          preferredStyle:UIAlertControllerStyleActionSheet];
  [alert addAction:[UIAlertAction actionWithTitle:LeadL(@"UI_BANNER_DISABLE_ACTION") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
    LeadSetBool(kDeletionBanner, NO);
    [self dismiss:card];
    [LeadToast showText:LeadL(@"UI_BANNER_DISABLED") symbol:@"bell.slash" inView:host.view];
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:LeadL(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
  alert.popoverPresentationController.sourceView = card;
  alert.popoverPresentationController.sourceRect = card.bounds;
  [host presentViewController:alert animated:YES completion:nil];
}

- (void)tapped:(UITapGestureRecognizer *)gesture {
  NSDictionary *entry = objc_getAssociatedObject(gesture.view, @selector(tapped:));
  [self dismiss:gesture.view];
  NSString *url = LeadURLForLogEntry(entry);
  if (url) LeadOpenTelegramURL(url);
}

@end
