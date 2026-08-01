// HeziSend.m — 赫兹群发+自动匹配 dylib (MobileSubstrate 注入)
//
// 编译: macOS + Xcode, 见 .github/workflows/build.yml
// 安装: HeziSend.dylib + HeziSend.plist → /var/jb/Library/MobileSubstrate/DynamicLibraries/

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

// ==================== 日志 ====================
static void hzLog(NSString *msg) {
    NSLog(@"%@", msg);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"hz_send.log"];
    FILE *f = fopen([path UTF8String], "a");
    if (f) {
        time_t now = time(NULL);
        struct tm *tm = localtime(&now);
        fprintf(f, "%02d:%02d:%02d %s\n", tm->tm_hour, tm->tm_min, tm->tm_sec, [msg UTF8String]);
        fclose(f);
    }
}
#define LOG(fmt, ...) hzLog([NSString stringWithFormat:@"[HZ] " fmt, ##__VA_ARGS__])

// ==================== 全局状态 ====================
static BOOL           _sending     = NO;
static BOOL           _polling     = YES;
static BOOL           _matching    = NO;
static BOOL           _progSwitch  = NO;
static NSTimeInterval _lastSend    = 0;
static NSTimeInterval _lastMatch   = 0;
static UIButton      *_btn         = nil;
static UILabel       *_btnLabel    = nil;
static UISwitch      *_matchSwitch = nil;
static UILabel       *_matchLabel  = nil;
static NSInteger      _totalUsers  = 0;
static NSInteger      _sentCount   = 0;
static NSString      *_deviceNum   = nil;

// ==================== KeyWindow ====================
static UIWindow* keyWin(void) {
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]])
            for (UIWindow *w in ((UIWindowScene*)s).windows)
                if (w.isKeyWindow) return w;
    }
    for (UIWindow *w in [UIApplication sharedApplication].windows)
        if (w.isKeyWindow) return w;
    return [UIApplication sharedApplication].windows.firstObject;
}

// ==================== 设备号 ====================
static NSString* loadDeviceNum(void) {
    NSString *extPath = @"/var/jb/shebeihao.txt";
    NSString *s = [NSString stringWithContentsOfFile:extPath encoding:NSUTF8StringEncoding error:nil];
    if (s) { s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; LOG(@"DeviceNum (external): %@", s); return s; }
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count) {
        NSString *fp = [paths[0] stringByAppendingPathComponent:@"shebeihao.txt"];
        s = [NSString stringWithContentsOfFile:fp encoding:NSUTF8StringEncoding error:nil];
        if (s) { s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; LOG(@"DeviceNum (sandbox): %@", s); return s; }
    }
    return @"";
}

static NSString* labelText(NSString *status) {
    NSString *prefix = _deviceNum ? _deviceNum : @"";
    return [NSString stringWithFormat:@"%@%@", prefix, status];
}

// ==================== 按钮状态 ====================
static void setBtnText(NSString *s) { dispatch_async(dispatch_get_main_queue(), ^{ _btnLabel.text = labelText(s); }); }

// ==================== Toast ====================
static UILabel *_toast = nil;
static void toast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *kw = keyWin(); if (!kw) return;
        if (!_toast) {
            CGFloat sw = [UIScreen mainScreen].bounds.size.width;
            _toast = [[UILabel alloc] initWithFrame:CGRectMake(20, [UIScreen mainScreen].bounds.size.height - 120, sw - 40, 50)];
            _toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
            _toast.textColor = [UIColor whiteColor]; _toast.textAlignment = NSTextAlignmentCenter;
            _toast.numberOfLines = 3; _toast.layer.cornerRadius = 10; _toast.clipsToBounds = YES;
            _toast.font = [UIFont systemFontOfSize:13]; [kw addSubview:_toast];
        }
        _toast.text = msg; _toast.alpha = 1;
        [UIView animateWithDuration:2.5 animations:^{ _toast.alpha = 0; }];
    });
}

// ==================== 数据库 ====================
static NSString* findDBPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (!paths.count) return nil;
    NSString *dbDir = [paths[0] stringByAppendingPathComponent:@"db"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:dbDir error:nil];
    NSString *found = nil; unsigned long long maxSz = 0;
    for (NSString *f in files) {
        if (![f hasPrefix:@"u."] || ![f hasSuffix:@".sqlite"]) continue;
        if ([f rangeOfString:@"wal"].location != NSNotFound || [f rangeOfString:@"shm"].location != NSNotFound || [f rangeOfString:@"backup"].location != NSNotFound) continue;
        NSString *fp = [dbDir stringByAppendingPathComponent:f];
        NSDictionary *attr = [fm attributesOfItemAtPath:fp error:nil];
        if (attr && [attr fileSize] > maxSz) { maxSz = [attr fileSize]; found = fp; }
    }
    LOG(@"DB: %@ (%llu bytes)", found ?: @"NOT FOUND", maxSz);
    return found;
}

static NSArray<NSString*>* loadUserIDs(void) {
    NSString *dbPath = findDBPath(); if (!dbPath) return @[];
    NSMutableArray *arr = [NSMutableArray array]; sqlite3 *db = NULL;
    if (sqlite3_open([dbPath UTF8String], &db) != SQLITE_OK) return @[];
    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT s_sessionID FROM md_default_session WHERE s_sessionID NOT LIKE 'key_%'";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *c = (const char*)sqlite3_column_text(stmt, 0);
            if (!c) continue;
            NSString *s = [NSString stringWithUTF8String:c];
            NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
            if ([s rangeOfCharacterFromSet:nonDigits].location == NSNotFound && s.length > 0) [arr addObject:s];
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
    LOG(@"Loaded %lu users", (unsigned long)arr.count);
    return arr;
}

// ==================== 发送消息 ====================
static void sendMsg(NSString *uid, NSString *text) {
    Class vcClass = objc_getClass("MDChatSingleViewController");
    if (!vcClass) { LOG(@"sendMsg: class not found"); return; }
    id vc = ((id(*)(Class,SEL))objc_msgSend)(vcClass, sel_registerName("alloc"));
    vc = ((id(*)(id,SEL,id,NSInteger))objc_msgSend)(vc, sel_registerName("initWithTargetID:sceneType:"), uid, 1);
    if (!vc) { LOG(@"sendMsg: init failed for %@", uid); return; }
    ((void(*)(id,SEL,id,id))objc_msgSend)(vc, sel_registerName("sendMessageText:extInfo:"), text, nil);
}

static void sendAll(NSString *text) {
    if (_sending || !text || text.length == 0 || [text isEqualToString:@"1"]) return;
    _sending = YES;
    NSArray<NSString*> *segments = [text componentsSeparatedByString:@"###"];
    NSMutableArray<NSString*> *msgs = [NSMutableArray array];
    for (NSString *s in segments) { NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; if (t.length > 0) [msgs addObject:t]; }
    if (msgs.count == 0) { _sending = NO; return; }
    NSArray<NSString*> *uids = loadUserIDs();
    _totalUsers = uids.count; _sentCount = 0;
    if (_totalUsers == 0) { _sending = NO; toast(@"无用户"); setBtnText(@"轮询\n中"); return; }
    NSInteger totalMsgs = msgs.count;
    LOG(@"sendAll: %ld users x %ld msgs", (long)_totalUsers, (long)totalMsgs);
    setBtnText([NSString stringWithFormat:@"0/%ld", (long)_totalUsers]);
    toast([NSString stringWithFormat:@"群发 %ld人x%ld条", (long)_totalUsers, (long)totalMsgs]);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        for (NSInteger i = 0; i < uids.count; i++) {
            for (NSInteger j = 0; j < totalMsgs; j++) {
                dispatch_sync(dispatch_get_main_queue(), ^{ sendMsg(uids[i], msgs[j]); });
                if (j < totalMsgs - 1) usleep(200000);
            }
            _sentCount = i + 1;
            dispatch_async(dispatch_get_main_queue(), ^{ setBtnText([NSString stringWithFormat:@"%ld/%ld", (long)_sentCount, (long)_totalUsers]); });
            usleep(600000);
        }
        dispatch_sync(dispatch_get_main_queue(), ^{
            _lastSend = [[NSDate date] timeIntervalSince1970]; _sending = NO;
            setBtnText(@"轮询\n中");
            LOG(@"sendAll done: %ld/%ld", (long)_sentCount, (long)_totalUsers);
            toast([NSString stringWithFormat:@"群发完成 %ld/%ld", (long)_sentCount, (long)_totalUsers]);
        });
    });
}

// ==================== URL 轮询 ====================
static void startPolling(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        LOG(@"Polling started");
        while (_polling) { sleep(3);
            @try {
                NSString *urlStr = [NSString stringWithFormat:@"http://39.102.210.175:5523/a1.php?shebeihao=%@", _deviceNum ? _deviceNum : @""];
                NSURL *url = [NSURL URLWithString:urlStr];
                NSData *data = [NSData dataWithContentsOfURL:url]; if (!data) continue;
                NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]; if (!s) continue;
                s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (_sending || [s isEqualToString:@"1"]) continue;
                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                if (now - _lastSend < 10) continue;
                LOG(@"Poll trigger: %@", s);
                dispatch_async(dispatch_get_main_queue(), ^{ sendAll(s); });
            } @catch (NSException *e) { LOG(@"Poll error: %@", e); }
        }
    });
}

// ==================== 在线匹配 ====================
// 通过辅助功能搜索 Flutter 按钮
static id findA11yElement(NSString *text, UIView *view) {
    if (!view) return nil;
    if (view.isAccessibilityElement) { NSString *l = view.accessibilityLabel; if (l && [l rangeOfString:text].location != NSNotFound) return view; }
    for (UIView *sub in view.subviews) { id f = findA11yElement(text, sub); if (f) return f; }
    return nil;
}

static void doMatch(void) {
    LOG(@"doMatch() called");
    @try {
        UIWindow *kw = keyWin(); if (!kw) { LOG(@"doMatch: no keyWindow"); return; }
        // 方式1: 辅助功能找"匹配"按钮（对 Flutter 有效）
        id el = findA11yElement(@"匹配", kw);
        LOG(@"doMatch: a11y result=%@", el ? @"FOUND" : @"nil");
        if (el) { LOG(@"Match: a11y element found, activating"); [el accessibilityActivate]; _lastMatch = [[NSDate date] timeIntervalSince1970]; return; }

        // 方式2: 找 HZRandomMatchViewController
        Class mc = objc_getClass("HZRandomMatchViewController"); if (!mc) return;
        id vc = nil; if (kw) { // 简单遍历 presented/viewControllers
            id cur = kw.rootViewController;
            for (int i = 0; i < 20 && cur && !vc; i++) {
                if ([cur isKindOfClass:mc]) { vc = cur; break; }
                id pres = ((id(*)(id,SEL))objc_msgSend)(cur, sel_registerName("presentedViewController"));
                if (pres) { cur = pres; continue; }
                SEL vs = sel_registerName("viewControllers");
                if ([cur respondsToSelector:vs]) { NSArray *vcs = ((id(*)(id,SEL))objc_msgSend)(cur, vs); if (vcs.count > 0) { cur = vcs.lastObject; continue; } }
                break;
            }
        }
        if (vc) {
            id model = ((id(*)(id,SEL))objc_msgSend)(vc, sel_registerName("model"));
            SEL bs = sel_registerName("buttonActionWithModel:");
            if (model && [vc respondsToSelector:bs]) { ((void(*)(id,SEL,id))objc_msgSend)(vc, bs, model); _lastMatch = [[NSDate date] timeIntervalSince1970]; LOG(@"Match: buttonActionWithModel"); return; }
            SEL rs = sel_registerName("requestData");
            if ([vc respondsToSelector:rs]) { ((void(*)(id,SEL))objc_msgSend)(vc, rs); _lastMatch = [[NSDate date] timeIntervalSince1970]; LOG(@"Match: requestData"); }
        }
    } @catch (NSException *e) { LOG(@"Match crash: %@", e); }
}

// 发送"嗨"
static void sendHiIfMatched(void) {
    if (!_matching) return;
    Class chatCls = objc_getClass("MDChatSingleViewController");
    if (chatCls) {
        UIWindow *kw = keyWin(); id chatVC = nil;
        if (kw) { id cur = kw.rootViewController;
            for (int i = 0; i < 20 && cur && !chatVC; i++) {
                if ([cur isKindOfClass:chatCls]) { chatVC = cur; break; }
                id pres = ((id(*)(id,SEL))objc_msgSend)(cur, sel_registerName("presentedViewController"));
                if (pres) { cur = pres; continue; }
                SEL vs = sel_registerName("viewControllers");
                if ([cur respondsToSelector:vs]) { NSArray *vcs = ((id(*)(id,SEL))objc_msgSend)(cur, vs); if (vcs.count > 0) { cur = vcs.lastObject; continue; } }
                break;
            }
        }
        if (chatVC) {
            SEL ss = sel_registerName("sendMessageText:extInfo:");
            if ([chatVC respondsToSelector:ss]) {
                ((void(*)(id,SEL,id,id))objc_msgSend)(chatVC, ss, @"嗨", nil);
                LOG(@"Match: SENT hi!");
                _matching = NO; _progSwitch = YES;
                dispatch_async(dispatch_get_main_queue(), ^{ [_matchSwitch setOn:NO animated:YES]; _progSwitch = NO; });
            }
        }
    }
}

// 自动匹配循环
static void startAutoMatch(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        LOG(@"Auto-match loop STARTED"); int tick = 0;
        while (YES) {
            sleep(2);
            LOG(@"Auto-match: tick=%d matching=%d", tick, _matching);
            if (!_matching) { tick = 0; continue; }
            tick++;
            dispatch_async(dispatch_get_main_queue(), ^{ sendHiIfMatched(); });
            if (tick % 4 == 0) {
                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                LOG(@"Auto-match: check doMatch (age=%.0fs)", now - _lastMatch);
                if (now - _lastMatch >= 10) {
                    dispatch_async(dispatch_get_main_queue(), ^{ doMatch(); });
                }
            }
        }
    });
}

// ==================== 匹配开关 ====================
static void onMatchToggle(id self, SEL _cmd) {
    if (_progSwitch) return;
    _matching = !_matching; LOG(@"Match toggle: %@", _matching ? @"ON" : @"OFF");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_matching) { toast(@"自动匹配已开启"); doMatch(); } else { toast(@"自动匹配已关闭"); }
    });
}

// ==================== UI ====================
static void makeButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *kw = keyWin();
        if (!kw) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ makeButton(); }); return; }
        CGFloat sw = [UIScreen mainScreen].bounds.size.width;
        CGFloat sh = [UIScreen mainScreen].bounds.size.height;
        CGFloat bs = 60, bx = sw - bs - 14, by = sh * 0.35;

        // 群发按钮(绿色)
        _btn = [UIButton buttonWithType:UIButtonTypeCustom];
        _btn.frame = CGRectMake(bx, by, bs, bs);
        _btn.backgroundColor = [[UIColor colorWithRed:0 green:0.7 blue:0.3 alpha:1] colorWithAlphaComponent:0.92];
        _btn.layer.cornerRadius = bs/2; _btn.clipsToBounds = YES;
        _btn.layer.borderWidth = 2; _btn.layer.borderColor = [UIColor whiteColor].CGColor;
        _btnLabel = [[UILabel alloc] initWithFrame:CGRectMake(2, 8, bs-4, bs-16)];
        _btnLabel.text = labelText(@"轮询\n中"); _btnLabel.numberOfLines = 2; _btnLabel.textAlignment = NSTextAlignmentCenter;
        _btnLabel.font = [UIFont boldSystemFontOfSize:12]; _btnLabel.textColor = [UIColor whiteColor]; _btnLabel.userInteractionEnabled = NO;
        [_btn addSubview:_btnLabel]; [kw addSubview:_btn];

        // 匹配开关面板(绿色按钮上方)
        CGFloat panelW = 80, panelH = 58;
        UIView *matchPanel = [[UIView alloc] initWithFrame:CGRectMake(bx - 10, by - panelH - 8, panelW, panelH)];
        matchPanel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55]; matchPanel.layer.cornerRadius = 12;
        [kw addSubview:matchPanel];
        _matchLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 4, panelW, 16)];
        _matchLabel.text = labelText(@"匹配"); _matchLabel.font = [UIFont boldSystemFontOfSize:11];
        _matchLabel.textColor = [UIColor whiteColor]; _matchLabel.textAlignment = NSTextAlignmentCenter;
        [matchPanel addSubview:_matchLabel];
        _matchSwitch = [[UISwitch alloc] initWithFrame:CGRectMake((panelW - 51) / 2, 20, 51, 31)];
        _matchSwitch.onTintColor = [UIColor colorWithRed:0 green:0.7 blue:0.3 alpha:1]; [_matchSwitch setOn:NO];
        [matchPanel addSubview:_matchSwitch];

        // 开关事件
        static id target = nil;
        if (!target) { Class h = objc_allocateClassPair([NSObject class], "HZMatchHelper", 0); class_addMethod(h, sel_registerName("onMatchToggle:"), (IMP)onMatchToggle, "v@:@"); objc_registerClassPair(h); target = [[h alloc] init]; }
        [_matchSwitch addTarget:target action:sel_registerName("onMatchToggle:") forControlEvents:UIControlEventValueChanged];

        LOG(@"Buttons created at (%.0f,%.0f)", bx, by);
        [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) {
            UIWindow *kw2 = keyWin();
            if (kw2 && _btn.superview != kw2) { [_btn removeFromSuperview]; [kw2 addSubview:_btn]; }
            if (kw2 && matchPanel.superview != kw2) { [matchPanel removeFromSuperview]; [kw2 addSubview:matchPanel]; }
            if (kw2) { [kw2 bringSubviewToFront:_btn]; [kw2 bringSubviewToFront:matchPanel]; }
        }];
    });
}

// ==================== 入口 ====================
__attribute__((constructor))
static void HZInit(void) {
    LOG(@"HeziSend dylib loaded"); _deviceNum = loadDeviceNum();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        makeButton(); startPolling(); startAutoMatch();
        LOG(@"HeziSend ready"); toast(@"赫兹群发已就绪");
    });
}
