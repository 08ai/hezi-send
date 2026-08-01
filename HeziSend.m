// HeziSend.m — 赫兹群发+自动匹配 dylib
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

static void hzLog(NSString *msg) {
    NSLog(@"%@", msg);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"hz_send.log"];
    FILE *f = fopen([path UTF8String], "a");
    if (f) { time_t now = time(NULL); struct tm *tm = localtime(&now); fprintf(f, "%02d:%02d:%02d %s\n", tm->tm_hour, tm->tm_min, tm->tm_sec, [msg UTF8String]); fclose(f); }
}
#define LOG(fmt, ...) hzLog([NSString stringWithFormat:@"[HZ] " fmt, ##__VA_ARGS__])

static BOOL _sending=NO, _polling=YES, _matching=NO, _progSwitch=NO;
static NSTimeInterval _lastSend=0, _lastMatch=0;
static UIButton *_btn; static UILabel *_btnLabel;
static UISwitch *_matchSwitch; static UILabel *_matchLabel;
static NSInteger _totalUsers, _sentCount;
static NSString *_deviceNum;

static UIWindow* keyWin(void) {
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) { if ([s isKindOfClass:[UIWindowScene class]]) for (UIWindow *w in ((UIWindowScene*)s).windows) if (w.isKeyWindow) return w; }
    for (UIWindow *w in [UIApplication sharedApplication].windows) if (w.isKeyWindow) return w;
    return [UIApplication sharedApplication].windows.firstObject;
}

static NSString* loadDeviceNum(void) {
    NSString *s = [NSString stringWithContentsOfFile:@"/var/jb/shebeihao.txt" encoding:NSUTF8StringEncoding error:nil];
    if (s) { s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; LOG(@"DeviceNum: %@", s); return s; }
    NSArray *p = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (p.count) { s = [NSString stringWithContentsOfFile:[[p[0] stringByAppendingPathComponent:@"shebeihao.txt"] stringByExpandingTildeInPath] encoding:NSUTF8StringEncoding error:nil] ?: @""; s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; if (s.length) return s; }
    return @"";
}
static NSString* labelText(NSString *st) { return [NSString stringWithFormat:@"%@%@", _deviceNum?:@"", st]; }
static void setBtnText(NSString *s) { dispatch_async(dispatch_get_main_queue(), ^{ _btnLabel.text = labelText(s); }); }

static UILabel *_toast;
static void toast(NSString *msg) { dispatch_async(dispatch_get_main_queue(), ^{ UIWindow *kw = keyWin(); if(!kw)return; if(!_toast){ CGFloat sw=[UIScreen mainScreen].bounds.size.width; _toast=[[UILabel alloc] initWithFrame:CGRectMake(20,[UIScreen mainScreen].bounds.size.height-120,sw-40,50)]; _toast.backgroundColor=[[UIColor blackColor] colorWithAlphaComponent:0.85]; _toast.textColor=[UIColor whiteColor]; _toast.textAlignment=NSTextAlignmentCenter; _toast.numberOfLines=3; _toast.layer.cornerRadius=10; _toast.clipsToBounds=YES; _toast.font=[UIFont systemFontOfSize:13]; [kw addSubview:_toast]; } _toast.text=msg; _toast.alpha=1; [UIView animateWithDuration:2.5 animations:^{_toast.alpha=0;}]; }); }

// ========== DB ==========
static NSString* findDBPath(void) { NSArray *p=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES); if(!p.count)return nil; NSString *d=[[p[0] stringByAppendingPathComponent:@"db"] stringByExpandingTildeInPath]; NSFileManager *f=[NSFileManager defaultManager]; NSArray *fs=[f contentsOfDirectoryAtPath:d error:nil]; NSString *r=nil; unsigned long long m=0; for(NSString *n in fs){ if(![n hasPrefix:@"u."]||![n hasSuffix:@".sqlite"])continue; if([n rangeOfString:@"wal"].location!=NSNotFound||[n rangeOfString:@"shm"].location!=NSNotFound||[n rangeOfString:@"backup"].location!=NSNotFound)continue; NSString *fp=[d stringByAppendingPathComponent:n]; NSDictionary *a=[f attributesOfItemAtPath:fp error:nil]; if(a&&[a fileSize]>m){m=[a fileSize];r=fp;} } LOG(@"DB: %@ (%llu)",r?:@"NOT FOUND",m); return r; }

static NSArray<NSString*>* loadUserIDs(void) { NSString *dp=findDBPath(); if(!dp)return @[]; NSMutableArray *a=[NSMutableArray array]; sqlite3 *db=NULL; if(sqlite3_open([dp UTF8String],&db)!=SQLITE_OK)return @[]; sqlite3_stmt *st=NULL; if(sqlite3_prepare_v2(db,"SELECT s_sessionID FROM md_default_session WHERE s_sessionID NOT LIKE 'key_%'",-1,&st,NULL)==SQLITE_OK){ while(sqlite3_step(st)==SQLITE_ROW){ const char *c=(const char*)sqlite3_column_text(st,0); if(!c)continue; NSString *s=[NSString stringWithUTF8String:c]; if([s rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location==NSNotFound&&s.length>0)[a addObject:s]; } sqlite3_finalize(st); } sqlite3_close(db); LOG(@"Loaded %lu users",(unsigned long)a.count); return a; }

// ========== SEND ==========
static void sendMsg(NSString *uid,NSString *text) { Class c=objc_getClass("MDChatSingleViewController"); if(!c)return; id vc=((id(*)(Class,SEL))objc_msgSend)(c,sel_registerName("alloc")); vc=((id(*)(id,SEL,id,NSInteger))objc_msgSend)(vc,sel_registerName("initWithTargetID:sceneType:"),uid,1); if(vc)((void(*)(id,SEL,id,id))objc_msgSend)(vc,sel_registerName("sendMessageText:extInfo:"),text,nil); }
static void sendAll(NSString *text) { if(_sending||!text||text.length==0||[text isEqualToString:@"1"])return; _sending=YES; NSArray *segs=[text componentsSeparatedByString:@"###"]; NSMutableArray *ms=[NSMutableArray array]; for(NSString *s in segs){ NSString *t=[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; if(t.length>0)[ms addObject:t]; } if(!ms.count){_sending=NO;return;} NSArray *uids=loadUserIDs(); _totalUsers=uids.count; _sentCount=0; if(!_totalUsers){_sending=NO;toast(@"无用户");setBtnText(@"轮询\n中");return;} NSInteger tm=ms.count; setBtnText([NSString stringWithFormat:@"0/%ld",(long)_totalUsers]); toast([NSString stringWithFormat:@"群发 %ld人x%ld条",(long)_totalUsers,(long)tm]); dispatch_async(dispatch_get_global_queue(0,0),^{ for(NSInteger i=0;i<uids.count;i++){ for(NSInteger j=0;j<tm;j++){ dispatch_sync(dispatch_get_main_queue(),^{sendMsg(uids[i],ms[j]);}); if(j<tm-1)usleep(200000); } _sentCount=i+1; dispatch_async(dispatch_get_main_queue(),^{setBtnText([NSString stringWithFormat:@"%ld/%ld",(long)_sentCount,(long)_totalUsers]);}); usleep(600000); } dispatch_sync(dispatch_get_main_queue(),^{_lastSend=[[NSDate date] timeIntervalSince1970]; _sending=NO; setBtnText(@"轮询\n中"); LOG(@"sendAll done: %ld/%ld",(long)_sentCount,(long)_totalUsers); toast([NSString stringWithFormat:@"群发完成 %ld/%ld",(long)_sentCount,(long)_totalUsers]); }); }); }

static void startPolling(void) { dispatch_async(dispatch_get_global_queue(0,0),^{ LOG(@"Polling started"); while(_polling){ sleep(3); @try{ NSString *u=[NSString stringWithFormat:@"http://39.102.210.175:5523/a1.php?shebeihao=%@",_deviceNum?:@""]; NSData *d=[NSData dataWithContentsOfURL:[NSURL URLWithString:u]]; if(!d)continue; NSString *s=[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]; if(!s)continue; s=[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; if(_sending||[s isEqualToString:@"1"])continue; if([[NSDate date] timeIntervalSince1970]-_lastSend<10)continue; LOG(@"Poll: %@",s); dispatch_async(dispatch_get_main_queue(),^{sendAll(s);}); }@catch(NSException *e){LOG(@"Poll err: %@",e);} } }); }

// ========== 监听：记录 HZRandomMatchViewController 的方法调用 ==========
static void installMethodMonitor(void) {
    Class mc = objc_getClass("HZRandomMatchViewController");
    if (!mc) return;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(mc, &count);
    LOG(@"Monitoring %u methods on HZRandomMatchViewController:", count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        LOG(@"  [%u] %@", i, name);
    }
    free(methods);
}

// ========== MATCH ==========
// 暴力遍历 ivars 找真正的 HZRandomMatchViewController
static id findMatchInObj(id obj) {
    if(!obj)return nil; Class mc=objc_getClass("HZRandomMatchViewController"); if(!mc)return nil;
    if([obj isKindOfClass:mc])return obj;
    unsigned int cnt=0; Ivar *ivars=class_copyIvarList([obj class],&cnt);
    for(unsigned int i=0;i<cnt;i++){ const char *type=ivar_getTypeEncoding(ivars[i]); if(!type||type[0]!='@')continue; @try{ id v=object_getIvar(obj,ivars[i]); if(v&&[v isKindOfClass:mc]){free(ivars);return v;} }@catch(NSException *e){} }
    free(ivars);
    for(id child in ((id(*)(id,SEL))objc_msgSend)(obj,@selector(childViewControllers))?:@[]){ id f=findMatchInObj(child); if(f)return f; }
    id pres=((id(*)(id,SEL))objc_msgSend)(obj,@selector(presentedViewController)); if(pres){id f=findMatchInObj(pres);if(f)return f;}
    return nil;
}

// Hook UIWindow sendEvent: 记录所有触摸坐标
static IMP _origSendEvent = NULL;
static void hookedSendEvent(id self, SEL _cmd, id event) {
    // 只记录 touchesBegan
    NSSet *touches = ((id(*)(id,SEL))objc_msgSend)(event, @selector(allTouches));
    id touch = [touches anyObject];
    if(touch){
        NSInteger phase = ((NSInteger(*)(id,SEL))objc_msgSend)(touch, @selector(phase));
        if(phase == 0){ // UITouchPhaseBegan
            CGPoint pt; ((void(*)(id,SEL,CGPoint*,id))objc_msgSend)(touch, @selector(locationInView:), &pt, self);
            LOG(@"TAP at (%.0f, %.0f)", pt.x, pt.y);
        }
    }
    if(_origSendEvent) ((void(*)(id,SEL,id))_origSendEvent)(self, _cmd, event);
}

static void installTouchLogger(void) {
    Class wc = objc_getClass("UIWindow");
    if(!wc)return;
    Method m = class_getInstanceMethod(wc, @selector(sendEvent:));
    if(m) _origSendEvent = method_setImplementation(m, (IMP)hookedSendEvent);
    LOG(@"Touch logger installed");
}

static void dumpA11y(id container, int depth) {
    if(!container||depth>15)return;
    if([container isAccessibilityElement]){
        NSString *l=[container accessibilityLabel];
        if(l.length>0)LOG(@"A11Y[%d]: '%@'",depth,l);
    }
    if([container respondsToSelector:@selector(accessibilityElementCount)]){
        NSInteger cnt=[container accessibilityElementCount];
        for(NSInteger i=0;i<cnt;i++){
            id child=[container accessibilityElementAtIndex:i];
            dumpA11y(child,depth+1);
        }
    }
    if([container isKindOfClass:[UIView class]]){
        for(UIView *sub in [(UIView*)container subviews]){
            dumpA11y(sub,depth+1);
        }
    }
}

// 递归找按钮并点击
static BOOL tapAnyButton(UIView *view) {
    if(!view)return NO;
    if([view isKindOfClass:[UIButton class]]){
        UIButton *b=(UIButton*)view;
        if(b.enabled&&!b.hidden&&b.alpha>0.5){
            [b sendActionsForControlEvents:UIControlEventTouchUpInside];
            LOG(@"Match: tapped button '%@'",[b currentTitle]?:@"(no title)");
            return YES;
        }
    }
    for(UIView *sub in view.subviews){ if(tapAnyButton(sub))return YES; }
    return NO;
}

// 从 Flutter accessibility 树中找按钮并激活
static BOOL activateFlutterButton(NSString *label, UIView *view) {
    if(!view)return NO;
    // 检查 Flutter accessibility 子元素
    if([view respondsToSelector:@selector(accessibilityElementCount)]){
        NSInteger cnt=[view accessibilityElementCount];
        for(NSInteger i=0;i<cnt;i++){
            id child=[view accessibilityElementAtIndex:i];
            if([child isAccessibilityElement]){
                NSString *l=[child accessibilityLabel];
                if(l&&[l rangeOfString:label].location!=NSNotFound){
                    [child accessibilityActivate];
                    LOG(@"Match: activated Flutter '%@'",l);
                    return YES;
                }
            }
            if(activateFlutterButton(label,child))return YES;
        }
    }
    // 递归子视图
    for(UIView *sub in view.subviews){
        if(activateFlutterButton(label,sub))return YES;
    }
    return NO;
}

static void doMatch(void) {
    LOG(@"doMatch: sending HTTP match request");
    // 1. 获取 fr (用户 ID)
    NSString *fr = nil;
    NSArray *uids = loadUserIDs();
    // 从 DB 获取当前用户的 fr
    NSString *dbPath = findDBPath();
    if(dbPath){
        sqlite3 *db=NULL; sqlite3_stmt *st=NULL;
        if(sqlite3_open([dbPath UTF8String],&db)==SQLITE_OK){
            // 尝试从某处读取当前用户 ID
            if(sqlite3_prepare_v2(db,"SELECT value FROM md_config WHERE key='user_id'",-1,&st,NULL)==SQLITE_OK){
                if(sqlite3_step(st)==SQLITE_ROW){ const char *c=(const char*)sqlite3_column_text(st,0); if(c) fr=[NSString stringWithUTF8String:c]; }
                sqlite3_finalize(st);
            }
            sqlite3_close(db);
        }
    }
    if(!fr) fr = @"48051782"; // fallback

    // 2. 从 DB 或 UserDefaults 获取 SESSIONID
    NSString *sessionId = nil;
    // 尝试从 NSHTTPCookieStorage
    for(NSHTTPCookie *ck in [NSHTTPCookieStorage sharedHTTPCookieStorage].cookies){
        if([ck.name isEqualToString:@"SESSIONID"]){ sessionId = ck.value; break; }
    }
    // 尝试从 DB
    if(!sessionId && dbPath){
        sqlite3 *db2=NULL; sqlite3_stmt *st2=NULL;
        if(sqlite3_open([dbPath UTF8String],&db2)==SQLITE_OK){
            // 尝试各种可能的表/列
            const char *queries[] = {
                "SELECT value FROM md_config WHERE key='session_id'",
                "SELECT s_value FROM md_session WHERE s_key='SESSIONID'",
                "SELECT sessionId FROM md_user",
                "SELECT s_sessionID FROM md_default_session LIMIT 1",
            };
            for(int qi=0;qi<4&&!sessionId;qi++){
                if(sqlite3_prepare_v2(db2,queries[qi],-1,&st2,NULL)==SQLITE_OK){
                    if(sqlite3_step(st2)==SQLITE_ROW){
                        const char *c=(const char*)sqlite3_column_text(st2,0);
                        if(c) sessionId=[NSString stringWithUTF8String:c];
                    }
                    sqlite3_finalize(st2); st2=NULL;
                }
            }
            sqlite3_close(db2);
        }
    }
    // 尝试从 NSUserDefaults
    if(!sessionId){
        NSString *sid = [[NSUserDefaults standardUserDefaults] stringForKey:@"SESSIONID"];
        if(sid) sessionId = sid;
        // 尝试从 HTTPCookieStorage 读 mokatech.cn 域
        if(!sid){
            NSHTTPCookieStorage *store = [NSHTTPCookieStorage sharedHTTPCookieStorage];
            for(NSHTTPCookie *c in store.cookies){
                if([c.name isEqualToString:@"SESSIONID"]){
                    sessionId = c.value;
                    LOG(@"Match: cookie SESSIONID=%@ domain=%@", c.value, c.domain);
                    break;
                }
            }
        }
    }
    LOG(@"Match: sessionId=%@ fr=%@", sessionId?:@"NOT FOUND", fr);

    // 3. 发送匹配请求（用抓包得到的真实数据）
    NSString *urlStr = [NSString stringWithFormat:@"https://vchat-api.mokatech.cn/like/find/match?fr=%@", fr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"content-type"];
    [req setValue:[NSString stringWithFormat:@"SESSIONID=%@", sessionId] forHTTPHeaderField:@"cookie"];
    [req setValue:@"Vchat/4.9.3 ios/2130 (iPhone 11; iOS 15.3.1; zh_CN; iPhone12,1; S2)" forHTTPHeaderField:@"user-agent"];
    [req setValue:@"*/*" forHTTPHeaderField:@"accept"];
    [req setValue:@"zh-Hans-CN;q=1" forHTTPHeaderField:@"accept-language"];
    [req setValue:@"1" forHTTPHeaderField:@"x-lv"];
    [req setValue:@"66e6ccf7" forHTTPHeaderField:@"x-kv"];
    // 从抓包拿到的 x-sign 和 mzip（临时可用）
    [req setValue:@"Kp1EtxB12upj2xqnV/1O1mkYYeo=" forHTTPHeaderField:@"x-sign"];
    NSString *mzip = @"AgOz2piJANhHNJNV3WX5jOcWThXZIlRkxe23GDIiDiiueT8UKovtW5HwP2ZED8LG5ysKzctXTc6l6lUWICw2G/TUHFiZNu3545PRoZJgiMoY7L079EWKZf0J6JJ89p1icTrEH6mlTrBdnbUD+89pVtiiPaDqvcVPJnzz+ru4h70GgwJLazNKAbgeeVFpvm/qeNDftRK2uIC5zoeCzpMVTP2ed7uiCkew2B2EIh6RHsYGeCbx6h6PXs6gxOr1mF9mJhV45f8WjPcIyAx+CpjwUmjyIM/m7ZR8kH7KceKi6QObqfdnOlqV6p3diLxWek8hN7Ka+DaL5hz/ct6UlXrW00eCxcA54uKlWPfbL2jeYrI30usrYZd3QQp8aMGwENe168mLwhBz/yu5rOhFWVCPgANPuiH2CSRh/yBARBZhf7W853wM7S8dfDVWy2bhbjLT68EX3x4J/o2Iu8oGuS4YgPiZSq7lRcd9RGI4UXytyZjZ5HaIzLrlvbua6JeM1KEgc01hDUBzTXldSXTeWHZny9Vs7Vg06OHOEr1YTd20ekH0uunm8I4MbdsGfC1crEsQVcek/8vocnhqZTg/chplr4duadMxQw5s8XRWuUn9O97yi+PxCogDGHQh5Jie5xXN4TNbzH0r0+3HkwjhR+YUgmn7vBrm9P29JTWok3RGIj9oFWurmXrEsLbJA6AhqbUD5gWKpR6J69RqHgsFi46zMKXEj6N+df+iAs7wzWVWfnwTTc55gBBRZYOwLIAVM/zCM/8GeMwXsYjN1EvxyGFAYCuczriTVZLAzmixV90+98Q9vU2C6ba22+lCIOrCeP5KS8sz6HyMAQDUYABRH50t0ibPfoOqkM3OoBc70LsDQZ5fXlquN1xsg+6IZR61SiLO0mtuMJLAXf25YOUzwY2m2dKn9JVEXebaZKRO21NIm/BVG8gQRDi2/c2ja6oLNDTBnmeq7GAYhDqDjgNLQZBQw1cbXpGb0Av+z8dIoYdpNH1r9iOGab2phup31kfFd4AE09bKnEEs0musbJAB0zYEaI3W7GDlrZr6z7HfC1peDkpvBI31i/adqNFk2gl98QQNlNKgwbmfJLesHRGfSzwWLyCUMDtHQ8EgCyqFy4jmJqFGVVYx/AuDbu+nNgsRE5Vx7gWee9b2z2N6GRWU9KxugeWcyJgxbRQKvTaDc/Udc7q4h2k/IHju6rQQ4iQe3iqO0tcA3Edq9YTymh1O7Mf5+p8joUxSHcvksyWwkVE9Pyva8ayIQaPMvxguegXTQ6Z1HeceHu23XulfrhWaFp9yeGvAMuqYVhWu/u7PmNenZkP/G71JwHHZlnYvypLgMqbwBIPB1J9ixBLlcRxtYGmM9CzX8r0ivnzO3XuAfo/Npw4qg/uYRyoxHWua2pxhkhU9DxTvV0iIBPdTfsfp5mz0ok0z6yy0UqwqFsJdvLVc0w6MgZajoGsShNSYSvPvw6GDmz5nvdPlitEbKrMpVCgunrE3zHuFTevBx5X/fCHVhUGoq2WNH1+Mi1ihc9c3B5XqhJVIyaonhbKDTZNpmGycMYL1Kq6CsVmJBGG0ni9Jz8hnRw30HAtsgzCuBXxxTE5hygdE3W9lOIdf5GzL5uhN4en1JuIdpbDoBREn5D9z/PLJjkf/m1q7J2Fecu9GA8wRq7io0T9Nos8cPFAkhaXEg5PtQJDJ3e77U/w+Lh5RUm+YRlZ7Ln75FbThhz+3q/dMfqtS3uKzUXJcAvzq371JaYB5PIoekgP5zV5R5+VmEGrMpe0LXLT6otAUvCcBcwmvGUBmu3MBOsU50RUGJeWpDlCoDeX+hHBTbU581gNIWZuNxvi3IP6i0cYnrylKTGXsAEvqyo3YyoWVQV+6d+3/Rfeng2YX354=";
    [req setHTTPBody:[[NSString stringWithFormat:@"mzip=%@", mzip] dataUsingEncoding:NSUTF8StringEncoding]];

    dispatch_async(dispatch_get_global_queue(0,0), ^{
        NSURLSession *sess = [NSURLSession sharedSession];
        NSURLSessionDataTask *task = [sess dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err){
            if(err){
                LOG(@"Match API error: %@", err);
            } else {
                NSInteger code = ((NSHTTPURLResponse*)resp).statusCode;
                NSString *body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
                LOG(@"Match API: %ld %@", (long)code, body?:@"");
            }
        }];
        [task resume];
    });
    _lastMatch = [[NSDate date] timeIntervalSince1970];
}

static void sendHiIfMatched(void) {
    if(!_matching)return;
    Class cc=objc_getClass("MDChatSingleViewController"); if(!cc)return;
    UIWindow *kw=keyWin(); if(!kw)return;
    id chatVC=nil, cur=kw.rootViewController;
    for(int i=0;i<20&&cur&&!chatVC;i++){ if([cur isKindOfClass:cc]){chatVC=cur;break;} id pres=((id(*)(id,SEL))objc_msgSend)(cur,@selector(presentedViewController)); if(pres){cur=pres;continue;} NSArray *vcs=((id(*)(id,SEL))objc_msgSend)(cur,sel_registerName("viewControllers")); if(vcs.count>0){cur=vcs.lastObject;continue;} break; }
    if(chatVC){ SEL ss=sel_registerName("sendMessageText:extInfo:"); if([chatVC respondsToSelector:ss]){((void(*)(id,SEL,id,id))objc_msgSend)(chatVC,ss,@"嗨",nil); LOG(@"Match: SENT hi!"); _matching=NO; _progSwitch=YES; dispatch_async(dispatch_get_main_queue(),^{[_matchSwitch setOn:NO animated:YES];_progSwitch=NO;}); } }
}

static void startAutoMatch(void) { dispatch_async(dispatch_get_global_queue(0,0),^{ LOG(@"Auto-match STARTED"); int tick=0; while(1){ sleep(2); if(!_matching){tick=0;continue;} tick++; dispatch_async(dispatch_get_main_queue(),^{sendHiIfMatched();}); if(tick%4==0&&[[NSDate date] timeIntervalSince1970]-_lastMatch>=10){ dispatch_async(dispatch_get_main_queue(),^{doMatch();}); } } }); }

static void onMatchToggle(id self, SEL _cmd) { if(_progSwitch)return; _matching=!_matching; LOG(@"Match toggle: %@",_matching?@"ON":@"OFF"); dispatch_async(dispatch_get_main_queue(),^{ if(_matching){toast(@"自动匹配已开启");doMatch();}else{toast(@"自动匹配已关闭");} }); }

// ========== UI ==========
static void makeButton(void) { dispatch_async(dispatch_get_main_queue(),^{ UIWindow *kw=keyWin(); if(!kw){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,1*NSEC_PER_SEC),dispatch_get_main_queue(),^{makeButton();});return;} CGFloat sw=[UIScreen mainScreen].bounds.size.width,sh=[UIScreen mainScreen].bounds.size.height,bs=60,bx=sw-bs-14,by=sh*0.35;
_btn=[UIButton buttonWithType:UIButtonTypeCustom]; _btn.frame=CGRectMake(bx,by,bs,bs); _btn.backgroundColor=[[UIColor colorWithRed:0 green:0.7 blue:0.3 alpha:1] colorWithAlphaComponent:0.92]; _btn.layer.cornerRadius=bs/2; _btn.clipsToBounds=YES; _btn.layer.borderWidth=2; _btn.layer.borderColor=[UIColor whiteColor].CGColor;
_btnLabel=[[UILabel alloc] initWithFrame:CGRectMake(2,8,bs-4,bs-16)]; _btnLabel.text=labelText(@"轮询\n中"); _btnLabel.numberOfLines=2; _btnLabel.textAlignment=NSTextAlignmentCenter; _btnLabel.font=[UIFont boldSystemFontOfSize:12]; _btnLabel.textColor=[UIColor whiteColor]; _btnLabel.userInteractionEnabled=NO; [_btn addSubview:_btnLabel]; [kw addSubview:_btn];
CGFloat pW=80,pH=58; UIView *mp=[[UIView alloc] initWithFrame:CGRectMake(bx-10,by-pH-8,pW,pH)]; mp.backgroundColor=[[UIColor blackColor] colorWithAlphaComponent:0.55]; mp.layer.cornerRadius=12; [kw addSubview:mp];
_matchLabel=[[UILabel alloc] initWithFrame:CGRectMake(0,4,pW,16)]; _matchLabel.text=labelText(@"匹配"); _matchLabel.font=[UIFont boldSystemFontOfSize:11]; _matchLabel.textColor=[UIColor whiteColor]; _matchLabel.textAlignment=NSTextAlignmentCenter; [mp addSubview:_matchLabel];
_matchSwitch=[[UISwitch alloc] initWithFrame:CGRectMake((pW-51)/2,20,51,31)]; _matchSwitch.onTintColor=[UIColor colorWithRed:0 green:0.7 blue:0.3 alpha:1]; [_matchSwitch setOn:NO]; [mp addSubview:_matchSwitch];
static id t=nil; if(!t){Class h=objc_allocateClassPair([NSObject class],"HZMH",0);class_addMethod(h,sel_registerName("onMatchToggle:"),(IMP)onMatchToggle,"v@:@");objc_registerClassPair(h);t=[[h alloc] init];} [_matchSwitch addTarget:t action:sel_registerName("onMatchToggle:") forControlEvents:UIControlEventValueChanged];
[NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer*_){UIWindow *k2=keyWin();if(k2&&_btn.superview!=k2){[_btn removeFromSuperview];[k2 addSubview:_btn];} if(k2&&mp.superview!=k2){[mp removeFromSuperview];[k2 addSubview:mp];} if(k2){[k2 bringSubviewToFront:_btn];[k2 bringSubviewToFront:mp];}}]; }); }

// Hook 所有 Flutter → Native 通信
static void logFlutterCall(NSString *prefix, NSString *method) {
    if(method.length>0) LOG(@"FMC[%@]: %@", prefix, method);
}

static void installFlutterHooks(void) {
    // 1. FlutterMethodChannel invokeMethod:arguments:result:
    Class fmc = objc_getClass("FlutterMethodChannel");
    if(fmc){
        Method m = class_getInstanceMethod(fmc, sel_registerName("invokeMethod:arguments:result:"));
        if(m){
            IMP orig = method_setImplementation(m, imp_implementationWithBlock(^(id self, NSString *m, id args, id result){
                logFlutterCall(@"M", m);
                IMP old = class_getMethodImplementation(fmc, sel_registerName("_hz_fmc_orig"));
                if(old) ((void(*)(id,SEL,id,id,id))old)(self, sel_registerName("invokeMethod:arguments:result:"), m, args, result);
            }));
            class_addMethod(fmc, sel_registerName("_hz_fmc_orig"), orig, method_getTypeEncoding(m));
            LOG(@"FMC hook OK");
        }
    }
    // 2. FlutterBasicMessageChannel sendMessage:
    Class fbmc = objc_getClass("FlutterBasicMessageChannel");
    if(fbmc){
        Method m2 = class_getInstanceMethod(fbmc, sel_registerName("sendMessage:"));
        if(m2){
            IMP orig2 = method_setImplementation(m2, imp_implementationWithBlock(^(id self, id msg){
                logFlutterCall(@"B", [msg description]);
                IMP old = class_getMethodImplementation(fbmc, sel_registerName("_hz_fbmc_orig"));
                if(old) ((void(*)(id,SEL,id))old)(self, sel_registerName("sendMessage:"), msg);
            }));
            class_addMethod(fbmc, sel_registerName("_hz_fbmc_orig"), orig2, method_getTypeEncoding(m2));
            LOG(@"FBMC hook OK");
        }
    }
    // 3. Hook HZHTTPRequest start — 抓所有 HTTP 请求
    Class hzr = objc_getClass("HZHTTPRequest");
    if(hzr){
        Method rqm = class_getInstanceMethod(hzr, sel_registerName("start"));
        if(rqm){
            IMP origRQ = method_setImplementation(rqm, imp_implementationWithBlock(^(id self){
                // dump 所有信息
                NSString *desc = [self description];
                LOG(@"HZHTTP: %@", desc);
                // 也尝试常见属性
                id url2 = ((id(*)(id,SEL))objc_msgSend)(self, sel_registerName("url"));
                id url3 = ((id(*)(id,SEL))objc_msgSend)(self, sel_registerName("requestURL"));
                id bd = ((id(*)(id,SEL))objc_msgSend)(self, sel_registerName("body"));
                id bd2 = ((id(*)(id,SEL))objc_msgSend)(self, sel_registerName("requestBody"));
                id hd = ((id(*)(id,SEL))objc_msgSend)(self, sel_registerName("headers"));
                id hd2 = ((id(*)(id,SEL))objc_msgSend)(self, sel_registerName("requestHeaders"));
                id hd3 = ((id(*)(id,SEL))objc_msgSend)(self, sel_registerName("allHTTPHeaderFields"));
                id mt = ((id(*)(id,SEL))objc_msgSend)(self, sel_registerName("httpMethod"));
                id mt2 = ((id(*)(id,SEL))objc_msgSend)(self, sel_registerName("requestMethod"));
                LOG(@"HZHTTP: url=%@ url2=%@ body=%@ body2=%@ hdr=%@ hdr2=%@ hdr3=%@ mt=%@ mt2=%@",
                    url2,url3,bd,bd2,hd,hd2,hd3,mt,mt2);
                IMP old = class_getMethodImplementation(hzr, sel_registerName("_hz_http_orig"));
                if(old) ((void(*)(id,SEL))old)(self, sel_registerName("start"));
            }));
            class_addMethod(hzr, sel_registerName("_hz_http_orig"), origRQ, method_getTypeEncoding(rqm));
            LOG(@"HZHTTP hook OK");
        }
    }
    // 4. Hook PhotonIMClient sendMessage:completion: (抓所有 Photon 消息)
    Class pic = objc_getClass("PhotonIMClient");
    if(pic){
        Method pm = class_getInstanceMethod(pic, sel_registerName("sendMessage:completion:"));
        if(pm){
            IMP orig3 = method_setImplementation(pm, imp_implementationWithBlock(^(id self, id msg, id completion){
                // 记录消息类型
                Class msgCls = objc_getClass("PhotonIMMessage");
                if(msgCls && [msg isKindOfClass:msgCls]){
                    NSInteger msgType = ((NSInteger(*)(id,SEL))objc_msgSend)(msg, sel_registerName("messageType"));
                    NSInteger chatType = ((NSInteger(*)(id,SEL))objc_msgSend)(msg, sel_registerName("chatType"));
                    id fromId = ((id(*)(id,SEL))objc_msgSend)(msg, sel_registerName("frid"));
                    id toId = ((id(*)(id,SEL))objc_msgSend)(msg, sel_registerName("toid"));
                    id body = ((id(*)(id,SEL))objc_msgSend)(msg, sel_registerName("mesageBody"));
                    NSString *bodyDesc = body ? [body description] : @"nil";
                    LOG(@"Photon: type=%ld chat=%ld from=%@ to=%@ body=%@", (long)msgType, (long)chatType, fromId, toId, bodyDesc);
                }
                IMP old = class_getMethodImplementation(pic, sel_registerName("_hz_photon_orig"));
                if(old) ((void(*)(id,SEL,id,id))old)(self, sel_registerName("sendMessage:completion:"), msg, completion);
            }));
            class_addMethod(pic, sel_registerName("_hz_photon_orig"), orig3, method_getTypeEncoding(pm));
            LOG(@"Photon hook OK");
        }
    }
    // 4. Hook UIControl sendAction:to:forEvent:
    Class uic = objc_getClass("UIControl");
    if(uic){
        Method m3 = class_getInstanceMethod(uic, sel_registerName("sendAction:to:forEvent:"));
        if(m3){
            IMP orig3 = method_setImplementation(m3, imp_implementationWithBlock(^(id self, SEL action, id target, id event){
                NSString *selName = NSStringFromSelector(action);
                NSString *clsName = NSStringFromClass([target class]);
                LOG(@"UICtrl: %@ %@", clsName, selName);
                IMP old = class_getMethodImplementation(uic, sel_registerName("_hz_ctrl_orig"));
                if(old) ((void(*)(id,SEL,SEL,id,id))old)(self, sel_registerName("sendAction:to:forEvent:"), action, target, event);
            }));
            class_addMethod(uic, sel_registerName("_hz_ctrl_orig"), orig3, method_getTypeEncoding(m3));
            LOG(@"UICtrl hook OK");
        }
    }
}
__attribute__((constructor)) static void HZInit(void) { LOG(@"HeziSend loaded"); _deviceNum=loadDeviceNum(); installFlutterHooks(); dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{ makeButton(); startPolling(); startAutoMatch(); LOG(@"HeziSend ready"); toast(@"赫兹群发已就绪"); }); }
