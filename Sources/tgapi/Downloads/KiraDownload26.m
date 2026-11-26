#import "KiraDownload26.h"
#import <objc/message.h>
#import <dlfcn.h>
#import <zlib.h>
#import <sys/stat.h>

// Runtime lookup keeps this feature buildable with Theos's old SDK and
// harmless on pre-iOS 26 devices. No audio session or private system API.
@protocol KiraTaskSchedulerAPI
+ (id)sharedScheduler;
- (BOOL)registerForTaskWithIdentifier:(NSString *)identifier usingQueue:(dispatch_queue_t)queue launchHandler:(void (^)(id task))launchHandler;
- (BOOL)submitTaskRequest:(id)request error:(NSError **)error;
- (void)cancelTaskRequestWithIdentifier:(NSString *)identifier;
@end
@protocol KiraTaskRequestAPI
- (instancetype)initWithIdentifier:(NSString *)identifier title:(NSString *)title subtitle:(NSString *)subtitle;
@end
@protocol KiraTaskAPI
@property(nonatomic, copy) void (^expirationHandler)(void);
@property(nonatomic, readonly) NSProgress *progress;
- (void)setTaskCompletedWithSuccess:(BOOL)success;
@end

static NSString *const SettingsChanged = @"LeadSettingsDidChangeNotification";
static const int32_t GetFile = -1101843010, GetCdnFile = 962554330;
static const uint32_t DocumentLocation = 0xbad07584, UploadFile = 0x096a18d5,
                      UploadCdnFile = 0xa99fca4f, CdnRedirect = 0xf18cda44;
static const NSTimeInterval Recent = 120;
static NSMutableDictionary<NSString *, NSDictionary *> *metadata;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *downloads;
static NSMutableDictionary<NSString *, NSString *> *aliases;
static NSMutableSet<NSString *> *mediaRoots;
static NSMapTable *serviceProto;
static NSMapTable *serviceToken;
static NSMapTable *protoTokens;
static NSHashTable *deferredPauses;
static dispatch_queue_t trackerQueue;
static NSString *selectedToken, *taskIdentifier;
static id<KiraTaskAPI> activeTask;
static id<KiraTaskSchedulerAPI> scheduler;
static dispatch_source_t taskTimer;
static BOOL backgrounded;
static CFAbsoluteTime submittedAt, lastProgressAt;
static uint64_t lastProgress;
static NSString *lastStatus;

static BOOL Arabic(void) {
    NSString *lang = [[NSUserDefaults standardUserDefaults] stringForKey:@"LeadLanguage"];
    if (!lang.length) lang = NSLocale.preferredLanguages.firstObject;
    return [lang.lowercaseString hasPrefix:@"ar"];
}
static NSString *L(NSString *ar, NSString *en) { return Arabic() ? ar : en; }
static uint32_t U32(const uint8_t *p) { uint32_t n; memcpy(&n,p,4); return CFSwapInt32LittleToHost(n); }
static uint64_t U64(const uint8_t *p) { uint64_t n; memcpy(&n,p,8); return CFSwapInt64LittleToHost(n); }
static BOOL TLBytes(const uint8_t *p, NSUInteger length, NSUInteger *count, NSUInteger *padded) {
    if (!length || p[0] == 255) return NO;
    NSUInteger h=p[0]==254?4:1;
    if (length<h) return NO;
    NSUInteger n=h==4?((NSUInteger)p[1]|((NSUInteger)p[2]<<8)|((NSUInteger)p[3]<<16)):p[0];
    if(n>length-h) return NO;
    NSUInteger pad=(h+n+3)&~(NSUInteger)3;
    if(pad>length) return NO;
    if(count)*count=n;
    if(padded)*padded=pad;
    return YES;
}
static NSString *CdnToken(const uint8_t *p,NSUInteger n) {
    uint64_t h=14695981039346656037ULL;
    for(NSUInteger i=0;i<n;i++) h=(h^p[i])*1099511628211ULL;
    return [NSString stringWithFormat:@"cdn:%016llx",(unsigned long long)h];
}
static NSString *Resolve(NSString *token) { return token ? (aliases[token] ?: token) : nil; }

static uint64_t MergeRange(NSMutableArray<NSValue *> *ranges,uint64_t offset,NSUInteger count) {
    if(!count || offset>NSUIntegerMax-count) return 0;
    NSUInteger lo=(NSUInteger)offset,hi=lo+count,first=0,end;
    while(first<ranges.count && NSMaxRange(ranges[first].rangeValue)<lo) first++;
    uint64_t old=0;
    for(end=first;end<ranges.count;end++){
        NSRange r=ranges[end].rangeValue;
        if(r.location>hi)break;
        old+=r.length; lo=MIN(lo,r.location); hi=MAX(hi,NSMaxRange(r));
    }
    if(end>first)[ranges removeObjectsInRange:NSMakeRange(first,end-first)];
    [ranges insertObject:[NSValue valueWithRange:NSMakeRange(lo,hi-lo)] atIndex:first];
    return (uint64_t)(hi-lo)-old;
}

// Read only MediaBox's verified ranges, never the cached payload or message text.
static BOOL ReadMediaMap(NSString *path,uint64_t *received,int64_t *total){
    struct stat st;
    if(stat(path.fileSystemRepresentation,&st)!=0 || st.st_size<12 || st.st_size>1024*1024)return NO;
    NSData *data=[NSData dataWithContentsOfFile:path options:0 error:nil];
    if(data.length<12 || data.length>1024*1024)return NO;
    const uint8_t *p=data.bytes;
    BOOL wide=U32(p)==0x7bac1487;
    NSUInteger header=wide?12:8,width=wide?8:4;
    if(data.length<header+width)return NO;
    uint32_t expected=U32(p+(wide?4:0));
    int32_t count=(int32_t)U32(p+(wide?8:4));
    if(count<0||(NSUInteger)count>(data.length-header-width)/(2*width))return NO;
    NSUInteger payload=width+(NSUInteger)count*2*width;
    if((uint32_t)crc32(0,p+header,(uInt)payload)!=expected)return NO;
    int64_t truncation=wide?(int64_t)U64(p+header):(int64_t)(int32_t)U32(p+header);
    uint64_t sum=0,previousEnd=0;
    for(int32_t i=0;i<count;i++){
        const uint8_t *r=p+header+width+(NSUInteger)i*2*width;
        int64_t start=wide?(int64_t)U64(r):(int64_t)(int32_t)U32(r);
        int64_t len=wide?(int64_t)U64(r+width):(int64_t)(int32_t)U32(r+width);
        if(start<0||len<=0||(uint64_t)start<previousEnd||(uint64_t)len>INT64_MAX-(uint64_t)start||(uint64_t)len>INT64_MAX-sum)return NO;
        previousEnd=(uint64_t)start+(uint64_t)len; sum+=(uint64_t)len;
    }
    if(truncation>0&&previousEnd>(uint64_t)truncation)return NO;
    *received=sum; *total=truncation; return YES;
}

static NSString *AllowedIdentifier(void){
    NSString *bid=NSBundle.mainBundle.bundleIdentifier;
    if(!bid.length)return nil;
    NSString *allowed=[bid stringByAppendingString:@".kira.download.*"];
    NSArray *identifiers=NSBundle.mainBundle.infoDictionary[@"BGTaskSchedulerPermittedIdentifiers"];
    return [identifiers isKindOfClass:NSArray.class] && [identifiers containsObject:allowed] ? allowed : nil;
}
static void Changed(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:SettingsChanged object:nil];
    });
}
static void Notice(UIViewController *host,NSString *message) {
    if(!host)return;
    UIAlertController *a=[UIAlertController alertControllerWithTitle:L(@"استمرار التحميل بالخلفية",@"Background download") message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:L(@"حسناً",@"OK") style:UIAlertActionStyleCancel handler:nil]];
    [host presentViewController:a animated:YES completion:nil];
}

@implementation KiraDownload26
+ (BOOL)supported {
    static BOOL ok; static dispatch_once_t once;
    dispatch_once(&once,^{
        if(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion<26 ||
           NSBundle.mainBundle.infoDictionary[@"NSExtension"] ||
           [NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"appex"])return;
        dlopen("/System/Library/Frameworks/BackgroundTasks.framework/BackgroundTasks",RTLD_LAZY|RTLD_LOCAL);
        ok=NSClassFromString(@"BGContinuedProcessingTaskRequest")!=Nil &&
           NSClassFromString(@"BGTaskScheduler")!=Nil;
    });
    return ok;
}
+ (void)initialize {
    if(self!=KiraDownload26.class)return;
    metadata=[NSMutableDictionary new]; downloads=[NSMutableDictionary new]; aliases=[NSMutableDictionary new];
    mediaRoots=[NSMutableSet new]; serviceProto=[NSMapTable weakToWeakObjectsMapTable];
    serviceToken=[NSMapTable weakToStrongObjectsMapTable]; protoTokens=[NSMapTable weakToStrongObjectsMapTable];
    deferredPauses=[NSHashTable weakObjectsHashTable];
    trackerQueue=dispatch_queue_create("kira.download.metadata",DISPATCH_QUEUE_SERIAL);
}
+ (void)install {
    if(![self supported])return;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        NSNotificationCenter *c=NSNotificationCenter.defaultCenter;
        [c addObserverForName:@"KiraDownload26Metadata" object:nil queue:nil usingBlock:^(NSNotification *note){
            NSNumber *doc=note.userInfo[@"id"],*size=note.userInfo[@"size"]; NSString *name=note.userInfo[@"name"];
            if(doc.longLongValue==0 || size.longLongValue<=0 || !name.length)return;
            NSString *t=[NSString stringWithFormat:@"doc:%lld",doc.longLongValue];
            @synchronized(KiraDownload26.class){
                metadata[t]=@{@"name":name.lastPathComponent,@"size":size,@"dc":note.userInfo[@"dc"]?:@0};
                if(metadata.count>2500){ for(NSString *key in metadata.allKeys){if(![key isEqualToString:selectedToken]&&!downloads[key]){[metadata removeObjectForKey:key];break;}} }
            }
        }];
        for(NSString *s in @[UIApplicationWillResignActiveNotification,UIApplicationDidEnterBackgroundNotification]){
            [c addObserverForName:s object:nil queue:nil usingBlock:^(__unused NSNotification *n){@synchronized(KiraDownload26.class){backgrounded=YES;}}];
        }
        [c addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(__unused NSNotification *n){
            @synchronized(KiraDownload26.class){backgrounded=NO;[deferredPauses removeAllObjects];}
            Changed();
        }];
    });
}
+ (void)registerMediaRoot:(NSString *)root {
    if(![self supported]||!root.length)return;
    @synchronized(self){if(mediaRoots.count<32)[mediaRoots addObject:root];}
}
+ (NSString *)tokenForPayload:(NSData *)payload functionID:(int32_t)functionID {
    if(![self supported] || payload.length<24)return nil;
    const uint8_t *p=payload.bytes;
    if(functionID==GetFile){
        // upload.getFile flags, inputDocumentFileLocation, offset:long, limit:int.
        if(payload.length<8+24+12 || U32(p+8)!=DocumentLocation)return nil;
        NSUInteger len=payload.length-8-12;
        NSUInteger pad=0,thumb=0;
        if(!TLBytes(p+28,len-20,NULL,&pad)||20+pad>=len ||
           !TLBytes(p+28+pad,len-20-pad,&thumb,NULL)||thumb!=0)return nil;
        return [NSString stringWithFormat:@"doc:%lld",(long long)(int64_t)U64(p+12)];
    }
    if(functionID==GetCdnFile){
        NSUInteger padded=0;
        if(!TLBytes(p+4,payload.length-4-12,NULL,&padded)||padded!=payload.length-4-12)return nil;
        return CdnToken(p+4,padded);
    }
    return nil;
}
+ (void)associateService:(id)service withProto:(id)proto {
    if(![self supported] || !service || !proto)return;
    @synchronized(self){
        [serviceProto setObject:proto forKey:service];
        NSString *t=[serviceToken objectForKey:service];
        if(t){NSMutableDictionary *d=[protoTokens objectForKey:proto];if(!d){d=[NSMutableDictionary new];[protoTokens setObject:d forKey:proto];}d[t]=@(CFAbsoluteTimeGetCurrent());}
    }
}
+ (void)noteRequest:(NSData *)payload functionID:(int32_t)functionID service:(id)service {
    NSString *token=[self tokenForPayload:payload functionID:functionID];
    if(!token || !service)return;
    @synchronized(self){
        NSString *t=Resolve(token); if(!t)return;
        [serviceToken setObject:t forKey:service];
        id proto=[serviceProto objectForKey:service];
        if(proto){
            NSMutableDictionary *d=[protoTokens objectForKey:proto];
            if(!d){d=[NSMutableDictionary new];[protoTokens setObject:d forKey:proto];}
            CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
            for(NSString *k in d.allKeys)if(now-[d[k] doubleValue]>Recent)[d removeObjectForKey:k];
            d[t]=@(now);
        }
    }
}
+ (BOOL)deferPause:(id)proto {
    if(![self supported])return NO;
    @synchronized(self){
        if(!selectedToken || !taskIdentifier || !backgrounded)return NO;
        NSDictionary *d=[protoTokens objectForKey:proto];
        if(!d)return NO;
        CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
        BOOL fileWorker=NO;
        for(NSString *k in d)if([Resolve(k) isEqualToString:selectedToken]&&now-[d[k] doubleValue]<Recent){fileWorker=YES;break;}
        if(fileWorker)[deferredPauses addObject:proto];
        return fileWorker;
    }
}
+ (void)noteResume:(id)proto {
    if(![self supported])return;
    @synchronized(self){[deferredPauses removeObject:proto];}
}
+ (void)receivedResponse:(NSData *)response forToken:(NSString *)token payload:(NSData *)payload functionID:(int32_t)functionID{
    if(!token||response.length<8||payload.length<16)return;
    const uint8_t *p=response.bytes; uint32_t ctor=U32(p);
    if(ctor==CdnRedirect&&functionID==GetFile&&response.length>8){
        NSUInteger padded=0;
        if(TLBytes(p+8,response.length-8,NULL,&padded)){
            @synchronized(self){
                if(aliases.count>2500)[aliases removeAllObjects];
                aliases[CdnToken(p+8,padded)]=token;
            }
        }return;
    }
    NSUInteger start=ctor==UploadFile?12:(ctor==UploadCdnFile?4:0),count=0;
    if(!start || response.length<=start || !TLBytes(p+start,response.length-start,&count,NULL)||!count||count>2*1024*1024)return;
    uint64_t offset=U64((const uint8_t *)payload.bytes+payload.length-12);
    if(offset>INT64_MAX)return;
    @synchronized(self){
        NSString *t=Resolve(token);
        if(![t hasPrefix:@"doc:"])return;
        CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
        for(NSString *k in downloads.allKeys)if(![k isEqualToString:selectedToken]&&now-[downloads[k][@"last"] doubleValue]>Recent)[downloads removeObjectForKey:k];
        NSMutableDictionary *d=downloads[t];
        if(!d){if(downloads.count>=128)return;d=[@{@"ranges":[NSMutableArray new],@"bytes":@0,@"last":@(now)} mutableCopy];downloads[t]=d;}
        uint64_t total=[metadata[t][@"size"] unsignedLongLongValue];
        if(total && offset>=total)return;
        if(total)count=(NSUInteger)MIN((uint64_t)count,total-offset);
        uint64_t added=MergeRange(d[@"ranges"],offset,count);
        if(added){d[@"bytes"]=@([d[@"bytes"] unsignedLongLongValue]+added);d[@"last"]=@(now);}
    }
}

+ (uint64_t)verifiedDiskBytes:(NSString *)token meta:(NSDictionary *)meta {
    if(![token hasPrefix:@"doc:"] || [meta[@"dc"] integerValue]<=0)return 0;
    NSArray *roots;
    @synchronized(self){roots=mediaRoots.allObjects;}
    NSMutableSet *all=[NSMutableSet setWithArray:roots];
    NSString *docs=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [all addObject:docs];[all addObject:[docs stringByAppendingPathComponent:@"AppGroup"]];
    NSString *name=[NSString stringWithFormat:@"telegram-cloud-document-%ld-%@",(long)[meta[@"dc"] integerValue],[token substringFromIndex:4]];
    int64_t expected=[meta[@"size"] longLongValue]; uint64_t best=0;
    NSFileManager *fm=NSFileManager.defaultManager;
    for(NSString *root in all){
        NSString *data=[root stringByAppendingPathComponent:@"telegram-data"];
        for(NSString *account in [fm contentsOfDirectoryAtPath:data error:nil]?:@[]){
            if(![account hasPrefix:@"account-"])continue;
            NSString *base=[[[data stringByAppendingPathComponent:account] stringByAppendingPathComponent:@"postbox/media"] stringByAppendingPathComponent:name];
            struct stat st;
            if(stat(base.fileSystemRepresentation,&st)==0&&S_ISREG(st.st_mode)&&st.st_size==expected)return (uint64_t)expected;
            uint64_t found=0;int64_t trunc=-1;
            if(ReadMediaMap([base stringByAppendingString:@"_partial.meta"],&found,&trunc)&&found<=(uint64_t)expected&&(trunc<=0||trunc==expected))best=MAX(best,found);
        }
    }
    return best;
}

+ (void)finish:(BOOL)success reason:(NSString *)reason {
    NSAssert(NSThread.isMainThread,@"task state must be on main");
    NSString *identifier; id<KiraTaskAPI> task; NSArray *pauses;
    @synchronized(self){
        identifier=taskIdentifier; if(!identifier)return;
        task=activeTask; activeTask=nil; selectedToken=nil; taskIdentifier=nil;
        pauses=backgrounded?deferredPauses.allObjects:@[];[deferredPauses removeAllObjects];
        lastStatus=reason;
    }
    if(taskTimer){dispatch_source_cancel(taskTimer);taskTimer=nil;}
    if(task){task.expirationHandler=nil;[task setTaskCompletedWithSuccess:success];}
    else if(identifier)[scheduler cancelTaskRequestWithIdentifier:identifier];
    for(id proto in pauses){
        if([proto respondsToSelector:NSSelectorFromString(@"pause")])((void(*)(id,SEL))objc_msgSend)(proto,NSSelectorFromString(@"pause"));
    }
    Changed();
}

+ (void)tick {
    NSString *token, *identifier; NSDictionary *meta;
    uint64_t received=0;
    @synchronized(self){token=selectedToken;identifier=taskIdentifier;if(!token)return;meta=metadata[token];received=[downloads[token][@"bytes"] unsignedLongLongValue];}
    uint64_t total=[meta[@"size"] unsignedLongLongValue];
    uint64_t disk=[self verifiedDiskBytes:token meta:meta]; received=MIN(total,MAX(received,disk));
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized(self){if(![taskIdentifier isEqualToString:identifier])return;}
        if(!total){[self finish:NO reason:L(@"تعذر معرفة حجم الملف",@"File size unavailable")];return;}
        CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
        if(!activeTask&&now-submittedAt>25){[self finish:NO reason:L(@"لم يسمح النظام بالمهمة",@"System did not grant task")];return;}
        if(received>lastProgress){lastProgress=received;lastProgressAt=now;}
        if(activeTask){
            NSProgress *p=activeTask.progress;
            p.totalUnitCount=(int64_t)total;p.completedUnitCount=(int64_t)received;
        }
        if(received>=total){[self finish:YES reason:L(@"اكتمل التحميل",@"Download completed")];return;}
        if(now-lastProgressAt>Recent)[self finish:NO reason:L(@"توقف تقدم التحميل",@"Download stopped making progress")];
    });
}

+ (void)start:(NSString *)token host:(UIViewController *)host {
    if(![self supported] || !AllowedIdentifier()){Notice(host,L(@"تحتاج نسخة IPA مجهزة لصلاحيات التحميل بالخلفية و iOS 26.",@"Requires iOS 26 and the prepared IPA Info.plist."));return;}
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive){Notice(host,L(@"افتح التطبيق أولاً.",@"Open the app first."));return;}
    NSDictionary *meta; uint64_t bytes;
    @synchronized(self){
        meta=metadata[token];bytes=[downloads[token][@"bytes"] unsignedLongLongValue];
        if(taskIdentifier)return;
    }
    uint64_t total=[meta[@"size"] unsignedLongLongValue];
    if(!total||bytes>=total){Notice(host,L(@"ابدأ تحميل ملف أولاً.",@"Start a file download first."));return;}
    Class cls=NSClassFromString(@"BGTaskScheduler");
    Class requestClass=NSClassFromString(@"BGContinuedProcessingTaskRequest");
    scheduler=[(Class<KiraTaskSchedulerAPI>)cls sharedScheduler];
    NSString *prefix=[AllowedIdentifier() substringToIndex:AllowedIdentifier().length-1];
    NSString *identifier=[prefix stringByAppendingString:NSUUID.UUID.UUIDString];
    // Each identifier is unique. The system permits dynamic registration for continued processing tasks.
    BOOL registered=NO;
    @try {
        registered=[scheduler registerForTaskWithIdentifier:identifier usingQueue:dispatch_get_main_queue() launchHandler:^(id obj){
            id<KiraTaskAPI> task=obj;
            @synchronized(self){
                if(![taskIdentifier isEqualToString:identifier]){[task setTaskCompletedWithSuccess:NO];return;}
                activeTask=task;
            }
            task.expirationHandler=^{dispatch_async(dispatch_get_main_queue(), ^{
                @synchronized(self){if(![taskIdentifier isEqualToString:identifier])return;}
                [self finish:NO reason:L(@"أوقف النظام المهمة",@"Background task expired or cancelled")];
            });};
            task.progress.totalUnitCount=(int64_t)total;
            task.progress.completedUnitCount=(int64_t)MIN(total,lastProgress);
            Changed();
        }];
    } @catch(__unused NSException *ex) {}
    if(!registered){Notice(host,L(@"تعذر تسجيل مهمة التحميل.",@"Could not register background task."));return;}
    id<KiraTaskRequestAPI> request = nil;
    NSError *error=nil; BOOL accepted=NO;
    @synchronized(self){selectedToken=token;taskIdentifier=identifier;activeTask=nil;submittedAt=lastProgressAt=CFAbsoluteTimeGetCurrent();lastProgress=bytes;lastStatus=nil;}
    @try{
        request=[(id<KiraTaskRequestAPI>)[requestClass alloc] initWithIdentifier:identifier title:L(@"تحميل الملف",@"Downloading file") subtitle:meta[@"name"]];
        if(request)accepted=[scheduler submitTaskRequest:request error:&error];
    }@catch(__unused NSException *ex){}
    if(!accepted){[self finish:NO reason:L(@"رفض النظام بدء المهمة",@"System declined background task")];Notice(host,error.localizedDescription ?: L(@"رفض النظام بدء المهمة.",@"System declined the background task."));return;}
    taskTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,trackerQueue);
    dispatch_source_set_timer(taskTimer,dispatch_time(DISPATCH_TIME_NOW,0),2*NSEC_PER_SEC,NSEC_PER_SEC/4);
    dispatch_source_set_event_handler(taskTimer,^{[self tick];});
    dispatch_resume(taskTimer);
    Changed();
    Notice(host,L(@"تم إرسال المهمة للنظام. يمكنك مغادرة التطبيق بعد بدء المهمة.",@"Task submitted. You can leave the app once the task starts."));
}

+ (NSString *)status {
    if(![self supported])return L(@"يتطلب iOS 26 أو أحدث",@"Requires iOS 26 or later");
    if(!AllowedIdentifier())return L(@"تحتاج نسخة IPA مجهزة",@"Requires prepared IPA");
    @synchronized(self){
        if(taskIdentifier)return activeTask?L(@"قيد التحميل",@"Running"):L(@"بانتظار النظام",@"Waiting");
        return lastStatus?:L(@"بدء مهمة",@"Start");
    }
}
+ (void)showOptions:(UIViewController *)host {
    if(!host)return;
    if(![self supported]||!AllowedIdentifier()){Notice(host,L(@"تحتاج iOS 26 ونسخة IPA مهيأة.",@"Requires iOS 26 and the prepared IPA."));return;}
    @synchronized(self){
        if(taskIdentifier){
            UIAlertController *a=[UIAlertController alertControllerWithTitle:L(@"تحميل بالخلفية",@"Background download") message:L(@"إيقاف مهمة الخلفية الحالية؟",@"Stop the current background task?") preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:L(@"إيقاف",@"Stop") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){[self finish:NO reason:L(@"تم إيقاف المهمة",@"Task stopped")];}]];
            [a addAction:[UIAlertAction actionWithTitle:L(@"رجوع",@"Back") style:UIAlertActionStyleCancel handler:nil]];
            [host presentViewController:a animated:YES completion:nil];return;
        }
    }
    NSMutableArray<NSDictionary *> *choices=[NSMutableArray new];
    @synchronized(self){
        CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
        for(NSString *token in downloads){
            NSDictionary *d=downloads[token],*m=metadata[token];uint64_t total=[m[@"size"] unsignedLongLongValue],got=[d[@"bytes"] unsignedLongLongValue];
            if(m[@"name"]&&total&&got<total&&now-[d[@"last"] doubleValue]<Recent)
                [choices addObject:@{@"token":token,@"name":m[@"name"],@"size":@(total),@"last":d[@"last"]}];
        }
    }
    [choices sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){return [b[@"last"] compare:a[@"last"]];}];
    if(!choices.count){Notice(host,L(@"ابدأ تحميل ملف داخل المحادثة ثم ارجع لهذا الخيار. تأكد من استخدام محرك MTProto المعتاد.",@"Start a file download in a chat, then return here. Use the standard MTProto engine."));return;}
    UIAlertController *a=[UIAlertController alertControllerWithTitle:L(@"اختيار الملف",@"Choose file") message:L(@"اختر التنزيل الذي تريد استمراره في الخلفية.",@"Choose the download to continue in the background.") preferredStyle:UIAlertControllerStyleAlert];
    for(NSDictionary *choice in [choices subarrayWithRange:NSMakeRange(0,MIN(choices.count,(NSUInteger)8))]){
        NSString *token=choice[@"token"];
        NSString *title=[NSString stringWithFormat:@"%@ (%@)",choice[@"name"],[NSByteCountFormatter stringFromByteCount:[choice[@"size"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]];
        [a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){
            dispatch_async(dispatch_get_main_queue(),^{[self start:token host:host];});
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:L(@"إلغاء",@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [host presentViewController:a animated:YES completion:nil];
}
@end
