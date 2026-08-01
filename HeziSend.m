// HeziSend.m — 赫兹群发+在线匹配
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

static void hzLog(NSString *msg) { NSLog(@"%@", msg); NSString *p=[NSTemporaryDirectory() stringByAppendingPathComponent:@"hz_send.log"]; FILE *f=fopen([p UTF8String],"a"); if(f){ time_t n=time(NULL); struct tm *t=localtime(&n); fprintf(f,"%02d:%02d:%02d %s\n",t->tm_hour,t->tm_min,t->tm_sec,[msg UTF8String]); fclose(f); } }
#define LOG(fmt,...) hzLog([NSString stringWithFormat:@"[HZ] " fmt,##__VA_ARGS__])

static BOOL _sending=NO,_polling=YES,_matching=NO,_progSwitch=NO;
static NSTimeInterval _lastSend=0,_lastMatch=0;
static UIButton *_btn; static UILabel *_btnLabel;
static UISwitch *_matchSwitch; static UILabel *_matchLabel;
static NSInteger _totalUsers,_sentCount;
static NSString *_deviceNum;

static UIWindow* keyWin(void) {
    for(UIScene *s in [UIApplication sharedApplication].connectedScenes){ if([s isKindOfClass:[UIWindowScene class]]) for(UIWindow *w in ((UIWindowScene*)s).windows) if(w.isKeyWindow) return w; }
    for(UIWindow *w in [UIApplication sharedApplication].windows) if(w.isKeyWindow) return w;
    return [UIApplication sharedApplication].windows.firstObject;
}
static NSString* loadDeviceNum(void) { NSString *s=[NSString stringWithContentsOfFile:@"/var/jb/shebeihao.txt" encoding:NSUTF8StringEncoding error:nil]; if(s){ s=[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; return s; } return @""; }
static NSString* labelText(NSString *st) { return [NSString stringWithFormat:@"%@%@",_deviceNum?:@"",st]; }
static void setBtnText(NSString *s) { dispatch_async(dispatch_get_main_queue(),^{ _btnLabel.text=labelText(s); }); }
static UILabel *_toast;
static void toast(NSString *msg) { dispatch_async(dispatch_get_main_queue(),^{ UIWindow *kw=keyWin(); if(!kw)return; if(!_toast){ CGFloat sw=[UIScreen mainScreen].bounds.size.width; _toast=[[UILabel alloc] initWithFrame:CGRectMake(20,[UIScreen mainScreen].bounds.size.height-120,sw-40,50)]; _toast.backgroundColor=[[UIColor blackColor] colorWithAlphaComponent:0.85]; _toast.textColor=[UIColor whiteColor]; _toast.textAlignment=NSTextAlignmentCenter; _toast.numberOfLines=3; _toast.layer.cornerRadius=10; _toast.clipsToBounds=YES; _toast.font=[UIFont systemFontOfSize:13]; [kw addSubview:_toast]; } _toast.text=msg; _toast.alpha=1; [UIView animateWithDuration:2.5 animations:^{_toast.alpha=0;}]; }); }

static NSString* findDBPath(void) { NSArray *p=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES); if(!p.count)return nil; NSString *d=[p[0] stringByAppendingPathComponent:@"db"]; NSFileManager *f=[NSFileManager defaultManager]; NSArray *fs=[f contentsOfDirectoryAtPath:d error:nil]; NSString *r=nil; unsigned long long m=0; for(NSString *n in fs){ if(![n hasPrefix:@"u."]||![n hasSuffix:@".sqlite"])continue; if([n rangeOfString:@"wal"].location!=NSNotFound||[n rangeOfString:@"shm"].location!=NSNotFound||[n rangeOfString:@"backup"].location!=NSNotFound)continue; NSString *fp=[d stringByAppendingPathComponent:n]; NSDictionary *a=[f attributesOfItemAtPath:fp error:nil]; if(a&&[a fileSize]>m){m=[a fileSize];r=fp;} } return r; }
static NSArray* loadUserIDs(void) { NSString *dp=findDBPath(); if(!dp)return @[]; NSMutableArray *a=[NSMutableArray array]; sqlite3 *db=NULL; if(sqlite3_open([dp UTF8String],&db)!=SQLITE_OK)return @[]; sqlite3_stmt *st=NULL; if(sqlite3_prepare_v2(db,"SELECT s_sessionID FROM md_default_session WHERE s_sessionID NOT LIKE 'key_%'",-1,&st,NULL)==SQLITE_OK){ while(sqlite3_step(st)==SQLITE_ROW){ const char *c=(const char*)sqlite3_column_text(st,0); if(!c)continue; NSString *s=[NSString stringWithUTF8String:c]; if([s rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location==NSNotFound&&s.length>0)[a addObject:s]; } sqlite3_finalize(st); } sqlite3_close(db); return a; }

static void sendMsg(NSString *uid,NSString *text) { Class c=objc_getClass("MDChatSingleViewController"); if(!c)return; id vc=((id(*)(Class,SEL))objc_msgSend)(c,sel_registerName("alloc")); vc=((id(*)(id,SEL,id,NSInteger))objc_msgSend)(vc,sel_registerName("initWithTargetID:sceneType:"),uid,1); if(vc)((void(*)(id,SEL,id,id))objc_msgSend)(vc,sel_registerName("sendMessageText:extInfo:"),text,nil); }
static void sendAll(NSString *text) { if(_sending||!text||text.length==0||[text isEqualToString:@"1"])return; _sending=YES; NSArray *segs=[text componentsSeparatedByString:@"###"]; NSMutableArray *ms=[NSMutableArray array]; for(NSString *s in segs){ NSString *t=[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; if(t.length>0)[ms addObject:t]; } if(!ms.count){_sending=NO;return;} NSArray *uids=loadUserIDs(); _totalUsers=uids.count; _sentCount=0; if(!_totalUsers){_sending=NO;toast(@"无用户");setBtnText(@"轮询\n中");return;} NSInteger tm=ms.count; setBtnText([NSString stringWithFormat:@"0/%ld",(long)_totalUsers]); toast([NSString stringWithFormat:@"群发 %ld人x%ld条",(long)_totalUsers,(long)tm]); dispatch_async(dispatch_get_global_queue(0,0),^{ for(NSInteger i=0;i<uids.count;i++){ for(NSInteger j=0;j<tm;j++){ dispatch_sync(dispatch_get_main_queue(),^{sendMsg(uids[i],ms[j]);}); if(j<tm-1)usleep(200000); } _sentCount=i+1; dispatch_async(dispatch_get_main_queue(),^{setBtnText([NSString stringWithFormat:@"%ld/%ld",(long)_sentCount,(long)_totalUsers]);}); usleep(600000); } dispatch_sync(dispatch_get_main_queue(),^{_lastSend=[[NSDate date] timeIntervalSince1970]; _sending=NO; setBtnText(@"轮询\n中"); toast([NSString stringWithFormat:@"群发完成 %ld/%ld",(long)_sentCount,(long)_totalUsers]); }); }); }
static void startPolling(void) { dispatch_async(dispatch_get_global_queue(0,0),^{ while(_polling){ sleep(3); @try{ NSString *u=[NSString stringWithFormat:@"http://39.102.210.175:5523/a1.php?shebeihao=%@",_deviceNum?:@""]; NSData *d=[NSData dataWithContentsOfURL:[NSURL URLWithString:u]]; if(!d)continue; NSString *s=[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]; if(!s)continue; s=[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; if(_sending||[s isEqualToString:@"1"])continue; if([[NSDate date] timeIntervalSince1970]-_lastSend<10)continue; dispatch_async(dispatch_get_main_queue(),^{sendAll(s);}); }@catch(NSException *e){} } }); }

// ====== 匹配：用 HZRandomMatchViewController 触发 App 自己的匹配 ======
static void doMatch(void) {
    Class hzr = objc_getClass("HZHTTPRequest");
    if(!hzr) return;
    id req = ((id(*)(Class,SEL))objc_msgSend)([hzr class], @selector(alloc));
    req = ((id(*)(id,SEL))objc_msgSend)(req, @selector(init));
    if(!req) return;

    // 获取 _configuration ivar
    Ivar configIvar = class_getInstanceVariable(hzr, "_configuration");
    id config = nil;
    if(configIvar) config = object_getIvar(req, configIvar);
    LOG(@"Match: config=%@", config?:@"nil");

    // 在 config 上设 URL
    NSString *urlStr = @"https://vchat-api.mokatech.cn/like/find/match?fr=48051782";
    if(config){
        @try {
            [config setValue:urlStr forKey:@"url"];
            LOG(@"Match: config.url set");
        } @catch(NSException *e){ LOG(@"KVC url fail: %@", e); }
        @try {
            [config setValue:urlStr forKey:@"URL"];
            LOG(@"Match: config.URL set");
        } @catch(NSException *e){}
        @try {
            [config setValue:urlStr forKey:@"requestURL"];
            LOG(@"Match: config.requestURL set");
        } @catch(NSException *e){}
        @try {
            [config setValue:@"POST" forKey:@"httpMethod"];
            LOG(@"Match: config.httpMethod set");
        } @catch(NSException *e){}
        @try {
            [config setValue:@"POST" forKey:@"method"];
            LOG(@"Match: config.method set");
        } @catch(NSException *e){}
        @try {
            [config setValue:@{@"fr":@"48051782"} forKey:@"params"];
            LOG(@"Match: config.params set");
        } @catch(NSException *e){}
        @try {
            [config setValue:@{@"fr":@"48051782"} forKey:@"parameters"];
            LOG(@"Match: config.parameters set");
        } @catch(NSException *e){}
    }

    // dump config ivars
    unsigned int cc=0; Ivar *ivs = class_copyIvarList([config class], &cc);
    for(unsigned int i=0;i<cc;i++){
        const char *n = ivar_getName(ivs[i]);
        const char *t = ivar_getTypeEncoding(ivs[i]);
        if(t && t[0]=='@'){ id v = object_getIvar(config, ivs[i]); LOG(@"  config.%s=%@", n, v?:@"nil"); }
    }
    free(ivs);

    if([req respondsToSelector:@selector(start)]){
        ((void(*)(id,SEL))objc_msgSend)(req, @selector(start));
        LOG(@"Match: HZHTTP started");
    }
    _lastMatch = [[NSDate date] timeIntervalSince1970];
}

static void sendHiIfMatched(void) {
    if(!_matching)return;
    Class cc=objc_getClass("MDChatSingleViewController"); if(!cc)return;
    UIWindow *kw=keyWin(); if(!kw)return;
    id cur=kw.rootViewController, chatVC=nil;
    for(int i=0;i<20&&cur&&!chatVC;i++){ if([cur isKindOfClass:cc]){chatVC=cur;break;} id pres=((id(*)(id,SEL))objc_msgSend)(cur,@selector(presentedViewController)); if(pres){cur=pres;continue;} NSArray *vcs=((id(*)(id,SEL))objc_msgSend)(cur,sel_registerName("viewControllers")); if(vcs.count>0){cur=vcs.lastObject;continue;} break; }
    if(chatVC){ SEL ss=sel_registerName("sendMessageText:extInfo:"); if([chatVC respondsToSelector:ss]){((void(*)(id,SEL,id,id))objc_msgSend)(chatVC,ss,@"嗨",nil); LOG(@"SENT hi!"); _matching=NO; _progSwitch=YES; dispatch_async(dispatch_get_main_queue(),^{[_matchSwitch setOn:NO animated:YES];_progSwitch=NO;}); } }
}

static void startAutoMatch(void) { dispatch_async(dispatch_get_global_queue(0,0),^{ int tick=0; while(1){ sleep(2); if(!_matching){tick=0;continue;} tick++; dispatch_async(dispatch_get_main_queue(),^{sendHiIfMatched();}); if(tick%8==0&&[[NSDate date] timeIntervalSince1970]-_lastMatch>=15){ dispatch_async(dispatch_get_main_queue(),^{doMatch();}); } } }); }

static void onMatchToggle(id self, SEL _cmd) { if(_progSwitch)return; _matching=!_matching; dispatch_async(dispatch_get_main_queue(),^{ if(_matching){toast(@"自动匹配已开启");doMatch();}else{toast(@"自动匹配已关闭");} }); }

static void makeButton(void) { dispatch_async(dispatch_get_main_queue(),^{ UIWindow *kw=keyWin(); if(!kw){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,1*NSEC_PER_SEC),dispatch_get_main_queue(),^{makeButton();});return;} CGFloat sw=[UIScreen mainScreen].bounds.size.width,sh=[UIScreen mainScreen].bounds.size.height,bs=60,bx=sw-bs-14,by=sh*0.35;
_btn=[UIButton buttonWithType:UIButtonTypeCustom]; _btn.frame=CGRectMake(bx,by,bs,bs); _btn.backgroundColor=[[UIColor colorWithRed:0 green:0.7 blue:0.3 alpha:1] colorWithAlphaComponent:0.92]; _btn.layer.cornerRadius=bs/2; _btn.clipsToBounds=YES; _btn.layer.borderWidth=2; _btn.layer.borderColor=[UIColor whiteColor].CGColor;
_btnLabel=[[UILabel alloc] initWithFrame:CGRectMake(2,8,bs-4,bs-16)]; _btnLabel.text=labelText(@"轮询\n中"); _btnLabel.numberOfLines=2; _btnLabel.textAlignment=NSTextAlignmentCenter; _btnLabel.font=[UIFont boldSystemFontOfSize:12]; _btnLabel.textColor=[UIColor whiteColor]; _btnLabel.userInteractionEnabled=NO; [_btn addSubview:_btnLabel]; [kw addSubview:_btn];
CGFloat pW=80,pH=58; UIView *mp=[[UIView alloc] initWithFrame:CGRectMake(bx-10,by-pH-8,pW,pH)]; mp.backgroundColor=[[UIColor blackColor] colorWithAlphaComponent:0.55]; mp.layer.cornerRadius=12; [kw addSubview:mp];
_matchLabel=[[UILabel alloc] initWithFrame:CGRectMake(0,4,pW,16)]; _matchLabel.text=labelText(@"匹配"); _matchLabel.font=[UIFont boldSystemFontOfSize:11]; _matchLabel.textColor=[UIColor whiteColor]; _matchLabel.textAlignment=NSTextAlignmentCenter; [mp addSubview:_matchLabel];
_matchSwitch=[[UISwitch alloc] initWithFrame:CGRectMake((pW-51)/2,20,51,31)]; _matchSwitch.onTintColor=[UIColor colorWithRed:0 green:0.7 blue:0.3 alpha:1]; [_matchSwitch setOn:NO]; [mp addSubview:_matchSwitch];
static id t=nil; if(!t){Class h=objc_allocateClassPair([NSObject class],"HZMH",0);class_addMethod(h,sel_registerName("onMatchToggle:"),(IMP)onMatchToggle,"v@:@");objc_registerClassPair(h);t=[[h alloc] init];} [_matchSwitch addTarget:t action:sel_registerName("onMatchToggle:") forControlEvents:UIControlEventValueChanged];
[NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer*_){UIWindow *k2=keyWin();if(k2&&_btn.superview!=k2){[_btn removeFromSuperview];[k2 addSubview:_btn];} if(k2&&mp.superview!=k2){[mp removeFromSuperview];[k2 addSubview:mp];} if(k2){[k2 bringSubviewToFront:_btn];[k2 bringSubviewToFront:mp];}}]; }); }

__attribute__((constructor)) static void HZInit(void) { LOG(@"HeziSend loaded"); _deviceNum=loadDeviceNum(); dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{ makeButton(); startPolling(); startAutoMatch(); LOG(@"ready"); }); }
