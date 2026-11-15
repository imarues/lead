// In-app Telegram chat list for call recordings. No iOS share sheet. Uploading
// continues after this screen is dismissed; the archive file is never deleted.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "LeadSavedMessagesUpload.h"

extern BOOL LeadSendRawRequest(NSData *payload, void (^done)(NSData *result, NSString *error));
static const int32_t kGetDialogs = (int32_t)0xa0f4cb4f;
static const int32_t kInputPeerEmpty = 2134579434;
static const int32_t kInputPeerSelf = 2107670217;
static const NSUInteger kPageLimit = 100;

static void LeadInt32(NSMutableData *data, int32_t number) { [data appendBytes:&number length:4]; }
static void LeadInt64(NSMutableData *data, int64_t number) { [data appendBytes:&number length:8]; }
static UIWindow *LeadChatWindow(void) {
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class] ||
           scene.activationState != UISceneActivationStateForegroundActive)continue;
        for(UIWindow *w in ((UIWindowScene *)scene).windows)if(w.isKeyWindow)return w;
    }
    return UIApplication.sharedApplication.keyWindow;
}
static UIView *gLeadUploadStatus;
static UILabel *gLeadUploadStatusText;
static UIProgressView *gLeadUploadBar;
static NSUInteger gLeadStatusSequence;
// A non-intercepting overlay: swipes, navigation and buttons remain usable.
static void LeadSetUploadStatus(NSString *label, BOOL temporary) {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{LeadSetUploadStatus(label,temporary);});return;
    }
    UIWindow *window=LeadChatWindow();
    if(!window)return;
    gLeadStatusSequence++;
    if(!gLeadUploadStatus || gLeadUploadStatus.superview!=window) {
        [gLeadUploadStatus removeFromSuperview];
        UIView *banner=[[UIView alloc] initWithFrame:CGRectZero];
        banner.backgroundColor=[UIColor colorWithWhite:0.13 alpha:0.92];
        banner.layer.cornerRadius=14;
        banner.layer.masksToBounds=YES;
        banner.userInteractionEnabled=NO;
        UILabel *text=[[UILabel alloc] initWithFrame:CGRectZero];
        text.textColor=UIColor.whiteColor;
        text.textAlignment=NSTextAlignmentCenter;
        text.font=[UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        text.numberOfLines=2;
        [banner addSubview:text];
        UIProgressView *bar=[[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        bar.trackTintColor=[UIColor colorWithWhite:1 alpha:0.28];
        bar.progressTintColor=[UIColor systemBlueColor];
        [banner addSubview:bar];
        gLeadUploadBar=bar;
        gLeadUploadStatus=banner;gLeadUploadStatusText=text;
        [window addSubview:banner];
    }
    CGFloat width=MIN(window.bounds.size.width-32,320);
    CGFloat top=window.safeAreaInsets.top+8;
    gLeadUploadStatus.frame=CGRectMake((window.bounds.size.width-width)/2,top,width,54);
    gLeadUploadStatusText.frame=CGRectMake(12,2,width-24,39);
    gLeadUploadBar.frame=CGRectMake(14,44,width-28,5);
    gLeadUploadStatusText.text=label;
    gLeadUploadStatus.alpha=1;
    if(temporary) {
        NSUInteger sequence=gLeadStatusSequence;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,4*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            if(sequence!=gLeadStatusSequence)return;
            [UIView animateWithDuration:0.25 animations:^{gLeadUploadStatus.alpha=0;}
             completion:^(__unused BOOL finished){if(sequence==gLeadStatusSequence)
                 [gLeadUploadStatus removeFromSuperview];}];
        });
    }
}

@interface LeadRecordingChatPicker : UITableViewController <UISearchResultsUpdating>
@property(nonatomic,strong) NSURL *file;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *rows;
@property(nonatomic,strong) NSArray<NSDictionary *> *visibleRows;
@property(nonatomic,strong) NSMutableSet<NSString *> *seen;
@property(nonatomic,strong) UISearchController *searcher;
@property(nonatomic,assign) BOOL loading;
@property(nonatomic,assign) BOOL more;
@property(nonatomic,strong) NSDictionary *next;
- (instancetype)initWithFile:(NSURL *)file;
@end

@implementation LeadRecordingChatPicker
- (instancetype)initWithFile:(NSURL *)file {
    self=[super initWithStyle:UITableViewStylePlain];
    if(self){
        _file=file;
        _seen=[NSMutableSet set];
        NSMutableData *input=[NSMutableData data]; LeadInt32(input,kInputPeerSelf);
        _rows=[NSMutableArray arrayWithObject:@{@"title":@"الرسائل المحفوظة",@"kind":@"حسابي",
                                                @"key":@"saved",@"peer":input}];
        [_seen addObject:@"saved"];
        _visibleRows=[_rows copy];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"إرسال التسجيل";
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc]
       initWithTitle:@"إلغاء" style:UIBarButtonItemStylePlain
       target:self action:@selector(closePicker)];
    self.searcher=[[UISearchController alloc] initWithSearchResultsController:nil];
    self.searcher.searchResultsUpdater=self;
    self.searcher.obscuresBackgroundDuringPresentation=NO;
    self.searcher.searchBar.placeholder=@"ابحث في محادثاتك";
    self.navigationItem.searchController=self.searcher;
    self.definesPresentationContext=YES;
    self.tableView.rowHeight=60;
    self.tableView.tableFooterView=[UIView new];
    [self loadNextPage];
}
- (void)closePicker { [self.navigationController dismissViewControllerAnimated:YES completion:nil]; }
- (void)updateSearchResultsForSearchController:(UISearchController *)controller { [self filter]; }
- (void)filter {
    NSString *query=[self.searcher.searchBar.text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!query.length)self.visibleRows=[self.rows copy];
    else {
        NSPredicate *match=[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings) {
            return [[row[@"title"] description] localizedCaseInsensitiveContainsString:query];
        }];
        self.visibleRows=[self.rows filteredArrayUsingPredicate:match];
    }
    [self.tableView reloadData];
}
- (void)loadNextPage {
    if(self.loading || (self.rows.count>1 && !self.more))return;
    self.loading=YES;
    NSMutableData *p=[NSMutableData data];
    LeadInt32(p,kGetDialogs);
    LeadInt32(p,0); // no folder filter, include pinned
    LeadInt32(p,[self.next[@"date"] intValue]);
    LeadInt32(p,[self.next[@"id"] intValue]);
    NSData *offset=self.next[@"peer"];
    if(offset.length)[p appendData:offset];else LeadInt32(p,kInputPeerEmpty);
    LeadInt32(p,(int32_t)kPageLimit);
    LeadInt64(p,0);
    BOOL queued=LeadSendRawRequest(p,^(NSData *result,NSString *error) {
        self.loading=NO;
        if(error.length || !result.length){
            [self showProblem:error?:@"ما گدرت أجيب قائمة محادثات Telegram."];
            self.more=NO;return;
        }
        Class parser=NSClassFromString(@"LeadDialogResponseParser");
        SEL selector=NSSelectorFromString(@"parseDialogs:");
        NSDictionary *parsed=parser && [parser respondsToSelector:selector] ?
             ((id (*)(id,SEL,id))objc_msgSend)(parser,selector,result) : nil;
        if(![parsed isKindOfClass:NSDictionary.class]){
            [self showProblem:@"تعذّر قراءة محادثات نسخة VoidGram الحالية."];
            self.more=NO;return;
        }
        NSUInteger added=0;
        for(NSDictionary *row in parsed[@"items"]) {
            NSString *key=row[@"key"];
            NSData *peer=row[@"peer"];
            if(!key.length || !peer.length || [self.seen containsObject:key])continue;
            [self.seen addObject:key]; [self.rows addObject:row]; added++;
        }
        self.next=parsed[@"next"];
        self.more=[parsed[@"hasMore"] boolValue] && added>0 &&
             [self.next[@"peer"] isKindOfClass:NSData.class];
        [self filter];
    });
    if(!queued){self.loading=NO;self.more=NO;
        [self showProblem:@"اتصال Telegram بعده مو جاهز. افتح إحدى محادثاتك وجرب مرة ثانية."];}
}
- (void)showProblem:(NSString *)reason {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"محادثات Telegram"
       message:reason preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"موافق" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.visibleRows.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"LeadChatCell"];
    if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"LeadChatCell"];
    NSDictionary *row=self.visibleRows[indexPath.row];
    cell.textLabel.text=row[@"title"];
    cell.detailTextLabel.text=row[@"kind"];
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    cell.imageView.image=[UIImage systemImageNamed:[row[@"key"] isEqualToString:@"saved"]?
                                  @"bookmark.fill":@"bubble.left.and.bubble.right"];
    if(!self.searcher.isActive && self.more && !self.loading && indexPath.row>=self.visibleRows.count-12)
        [self loadNextPage];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row=self.visibleRows[indexPath.row];
    NSString *title=row[@"title"];
    NSData *peer=row[@"peer"];
    if(!peer.length)return;
    UIAlertController *confirm=[UIAlertController alertControllerWithTitle:title
        message:[NSString stringWithFormat:@"إرسال %@ إلى هذه المحادثة؟",self.file.lastPathComponent]
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"رجوع" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"إرسال" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action){
        NSURL *file=self.file;
        [self.navigationController dismissViewControllerAnimated:YES completion:^{
            LeadSetUploadStatus([NSString stringWithFormat:@"جارٍ إرسال التسجيل إلى %@ · 0%%",title],NO);
            [gLeadUploadBar setProgress:0 animated:NO];
            [LeadSavedMessagesUpload startWithFile:file peerData:peer progress:^(double fraction) {
                // Telegram confirms parts in 512-KiB chunks; the percentage
                // therefore advances discretely. Animate visual progress
                // between acknowledged checkpoints without over-reporting it.
                LeadSetUploadStatus([NSString stringWithFormat:@"إرسال إلى %@ · %d%%",title,
                    (int)(fraction*100.0+0.5)],NO);
                [gLeadUploadBar setProgress:(float)fraction animated:YES];
            } completion:^(NSString *error){
                if(error) {
                    NSLog(@"[LeadRecorder] send to %@ failed: %@",title,error);
                    LeadSetUploadStatus([NSString stringWithFormat:@"تعذّر الإرسال إلى %@. التسجيل محفوظ بالأرشيف.",title],YES);
                } else {
                    LeadSetUploadStatus([NSString stringWithFormat:@"تم إرسال التسجيل إلى %@",title],YES);
                }
            }];
        }];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}
@end

void LeadPresentRecordingChatPicker(NSURL *file,UIViewController *presenter) {
    if(!NSThread.isMainThread){
        dispatch_async(dispatch_get_main_queue(),^{LeadPresentRecordingChatPicker(file,presenter);});return;
    }
    if(!file.isFileURL || ![[NSFileManager defaultManager] fileExistsAtPath:file.path])return;
    UIViewController *host=presenter;
    if(!host || !host.view.window)host=LeadChatWindow().rootViewController;
    if(!host)return;
    while(host.presentedViewController)host=host.presentedViewController;
    LeadRecordingChatPicker *picker=[[LeadRecordingChatPicker alloc] initWithFile:file];
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:picker];
    nav.modalPresentationStyle=UIModalPresentationFullScreen;
    [host presentViewController:nav animated:YES completion:nil];
}
