// HeziSend.m — 赫兹群发 dylib (MobileSubstrate 注入)
//
// === 编译 (macOS + Xcode) ===
//   SDK=$(xcrun --sdk iphoneos --show-sdk-path)
//   clang -arch arm64 -dynamiclib \
//         -framework Foundation -framework UIKit -framework CoreGraphics \
//         -fobjc-arc -lsqlite3 \
//         -miphoneos-version-min=14.0 -isysroot "$SDK" \
//         -o HeziSend.dylib HeziSend.m
//
// === 安装 ===
//   1. HeziSend.dylib + HeziSend.plist → /Library/MobileSubstrate/DynamicLibraries/
//   2. killall -9 MomoSceneChat 或 respring
//   3. 打开赫兹，右侧出现绿色按钮即成功
//
// === 工作流程 ===
//   启动 → 显示"轮询"按钮 → 每3秒轮询 a1.php
//   → 返回内容≠"1"时 → 自动群发给所有会话用户 → 10秒冷却

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
static BOOL           _sending    = NO;
static BOOL           _polling    = YES;
static BOOL           _matching   = NO;
static NSTimeInterval _lastSend   = 0;
static NSTimeInterval _lastMatch  = 0;
static UIButton      *_btn        = nil;
static UILabel       *_btnLabel   = nil;
static UISwitch      *_matchSwitch = nil;
static UILabel       *_matchLabel  = nil;
static NSInteger      _totalUsers = 0;
static NSInteger      _sentCount  = 0;
static NSString      *_deviceNum  = nil;  // shebeihao.txt 内容

// ==================== 设备号 ====================
static NSString* loadDeviceNum(void) {
    // 优先读沙箱外（恢复数据不会覆盖）
    NSString *extPath = @"/var/jb/shebeihao.txt";
    NSString *s = [NSString stringWithContentsOfFile:extPath encoding:NSUTF8StringEncoding error:nil];
    if (s) {
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        LOG(@"DeviceNum (external): %@", s);
        return s;
    }
    // 回退：App 内 Documents/shebeihao.txt
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count) {
        NSString *fp = [paths[0] stringByAppendingPathComponent:@"shebeihao.txt"];
        s = [NSString stringWithContentsOfFile:fp encoding:NSUTF8StringEncoding error:nil];
        if (s) {
            s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            LOG(@"DeviceNum (sandbox): %@", s);
            return s;
        }
    }
    LOG(@"DeviceNum: not found");
    return @"";
}

// ==================== 按钮文本拼接 ====================
static NSString* labelText(NSString *status) {
    // 格式: "5轮询\n中" / "5 3/50"
    NSString *prefix = _deviceNum ? _deviceNum : @"";
    return [NSString stringWithFormat:@"%@%@", prefix, status];
}

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

// ==================== 按钮状态更新 ====================
static void setBtnText(NSString *s) {
    dispatch_async(dispatch_get_main_queue(), ^{ _btnLabel.text = labelText(s); });
}

// ==================== Toast ====================
static UILabel *_toast = nil;
static void toast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *kw = keyWin();
        if (!kw) return;
        if (!_toast) {
            CGFloat sw = [UIScreen mainScreen].bounds.size.width;
            _toast = [[UILabel alloc] initWithFrame:CGRectMake(20, [UIScreen mainScreen].bounds.size.height - 120, sw - 40, 50)];
            _toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
            _toast.textColor = [UIColor whiteColor];
            _toast.textAlignment = NSTextAlignmentCenter;
            _toast.numberOfLines = 3;
            _toast.layer.cornerRadius = 10;
            _toast.clipsToBounds = YES;
            _toast.font = [UIFont systemFontOfSize:13];
            [kw addSubview:_toast];
        }
        _toast.text = msg; _toast.alpha = 1;
        [UIView animateWithDuration:2.5 animations:^{ _toast.alpha = 0; }];
    });
}

// ==================== 数据库 ====================
static NSString* findDBPath(void) {
    // App 沙盒内不能用 /var/mobile/Containers 扫描，用自身 Documents 目录
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (!paths.count) { LOG(@"Documents dir not found"); return nil; }
    NSString *dbDir = [paths[0] stringByAppendingPathComponent:@"db"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:dbDir error:nil];
    NSString *found = nil;
    unsigned long long maxSz = 0;
    for (NSString *f in files) {
        if (![f hasPrefix:@"u."] || ![f hasSuffix:@".sqlite"]) continue;
        if ([f rangeOfString:@"wal"].location  != NSNotFound) continue;
        if ([f rangeOfString:@"shm"].location  != NSNotFound) continue;
        if ([f rangeOfString:@"backup"].location != NSNotFound) continue;
        NSString *fp = [dbDir stringByAppendingPathComponent:f];
        NSDictionary *attr = [fm attributesOfItemAtPath:fp error:nil];
        if (attr && [attr fileSize] > maxSz) {
            maxSz = [attr fileSize];
            found = fp;
        }
    }
    LOG(@"DB: %@ (%llu bytes)", found ?: @"NOT FOUND", maxSz);
    return found;
}

static NSArray<NSString*>* loadUserIDs(void) {
    NSString *dbPath = findDBPath();
    if (!dbPath) return @[];
    NSMutableArray *arr = [NSMutableArray array];
    sqlite3 *db = NULL;
    if (sqlite3_open([dbPath UTF8String], &db) != SQLITE_OK) {
        LOG(@"sqlite3_open failed");
        return @[];
    }
    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT s_sessionID FROM md_default_session WHERE s_sessionID NOT LIKE 'key_%'";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *c = (const char*)sqlite3_column_text(stmt, 0);
            if (!c) continue;
            NSString *s = [NSString stringWithUTF8String:c];
            NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
            if ([s rangeOfCharacterFromSet:nonDigits].location == NSNotFound && s.length > 0) {
                [arr addObject:s];
            }
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
    id vc = ((id(*)(Class, SEL))objc_msgSend)(vcClass, sel_registerName("alloc"));
    SEL initSel = sel_registerName("initWithTargetID:sceneType:");
    vc = ((id(*)(id, SEL, id, NSInteger))objc_msgSend)(vc, initSel, uid, 1);
    if (!vc) { LOG(@"sendMsg: vc init failed for %@", uid); return; }
    SEL sendSel = sel_registerName("sendMessageText:extInfo:");
    ((void(*)(id, SEL, id, id))objc_msgSend)(vc, sendSel, text, nil);
}

static void sendAll(NSString *text) {
    if (_sending || !text || text.length == 0 || [text isEqualToString:@"1"]) return;
    _sending = YES;

    // 按 ### 分段，去掉空段
    NSArray<NSString*> *segments = [text componentsSeparatedByString:@"###"];
    NSMutableArray<NSString*> *msgs = [NSMutableArray array];
    for (NSString *s in segments) {
        NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length > 0) [msgs addObject:t];
    }
    if (msgs.count == 0) { _sending = NO; return; }

    NSArray<NSString*> *uids = loadUserIDs();
    _totalUsers = uids.count;
    _sentCount  = 0;
    if (_totalUsers == 0) {
        _sending = NO;
        toast(@"无用户");
        setBtnText(@"轮询\n中");
        return;
    }
    NSInteger totalMsgs = msgs.count;
    LOG(@"sendAll: %ld users × %ld msgs", (long)_totalUsers, (long)totalMsgs);
    setBtnText([NSString stringWithFormat:@"0/%ld", (long)_totalUsers]);
    toast([NSString stringWithFormat:@"群发 %ld人×%ld条", (long)_totalUsers, (long)totalMsgs]);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        for (NSInteger i = 0; i < uids.count; i++) {
            // 给同一个用户依次发送每条消息
            for (NSInteger j = 0; j < totalMsgs; j++) {
                dispatch_sync(dispatch_get_main_queue(), ^{ sendMsg(uids[i], msgs[j]); });
                if (j < totalMsgs - 1) usleep(200000); // 两条消息之间 200ms
            }
            _sentCount = i + 1;
            dispatch_async(dispatch_get_main_queue(), ^{
                setBtnText([NSString stringWithFormat:@"%ld/%ld", (long)_sentCount, (long)_totalUsers]);
            });
            usleep(600000); // 用户之间 600ms
        }
        dispatch_sync(dispatch_get_main_queue(), ^{
            _lastSend = [[NSDate date] timeIntervalSince1970];
            _sending  = NO;
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
        while (_polling) {
            sleep(3);
            @try {
                NSString *urlStr = [NSString stringWithFormat:@"http://39.102.210.175:5523/a1.php?shebeihao=%@",
                                    _deviceNum ? _deviceNum : @""];
                NSURL *url = [NSURL URLWithString:urlStr];
                NSData *data = [NSData dataWithContentsOfURL:url];
                if (!data) continue;
                NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (!s) continue;
                s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (_sending) continue; // 正在发送中，跳过本次轮询
                if ([s isEqualToString:@"1"]) continue;
                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                if (now - _lastSend < 10) continue; // 10秒冷却
                LOG(@"Poll trigger: %@", s);
                dispatch_async(dispatch_get_main_queue(), ^{ sendAll(s); });
            } @catch (NSException *e) {
                LOG(@"Poll error: %@", e);
            }
        }
    });
}

// 前置声明
static void onMatchToggle(id self, SEL _cmd);

// ==================== UI 按钮 ====================
static void makeButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *kw = keyWin();
        if (!kw) {
            // 没有 keyWindow（App 可能还在启动），1秒后重试
            LOG(@"No keyWindow, retrying...");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ makeButton(); });
            return;
        }

        CGFloat sw = [UIScreen mainScreen].bounds.size.width;
        CGFloat sh = [UIScreen mainScreen].bounds.size.height;
        CGFloat bs = 60;
        CGFloat bx = sw - bs - 14;
        CGFloat by = sh * 0.35; // 屏幕 35% 高度位置

        _btn = [UIButton buttonWithType:UIButtonTypeCustom];
        _btn.frame = CGRectMake(bx, by, bs, bs);
        _btn.backgroundColor = [[UIColor colorWithRed:0 green:0.7 blue:0.3 alpha:1] colorWithAlphaComponent:0.92];
        _btn.layer.cornerRadius = bs / 2;
        _btn.clipsToBounds = YES;
        _btn.layer.borderWidth = 2;
        _btn.layer.borderColor = [UIColor whiteColor].CGColor;

        _btnLabel = [[UILabel alloc] initWithFrame:CGRectMake(2, 8, bs-4, bs-16)];
        _btnLabel.text = labelText(@"轮询\n中");
        _btnLabel.numberOfLines = 2;
        _btnLabel.textAlignment = NSTextAlignmentCenter;
        _btnLabel.font = [UIFont boldSystemFontOfSize:12];
        _btnLabel.textColor = [UIColor whiteColor];
        _btnLabel.userInteractionEnabled = NO;
        [_btn addSubview:_btnLabel];

        [kw addSubview:_btn];
        LOG(@"Send button at (%.0f,%.0f)", bx, by);

        // ── 匹配开关 (绿色按钮正上方) ──
        // 背景小面板
        CGFloat panelW = 80, panelH = 58;
        __block UIView *matchPanel = [[UIView alloc] initWithFrame:CGRectMake(bx - 10, by - panelH - 8, panelW, panelH)];
        matchPanel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
        matchPanel.layer.cornerRadius = 12;
        [kw addSubview:matchPanel];

        // 标签
        _matchLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 4, panelW, 16)];
        _matchLabel.text = labelText(@"匹配");
        _matchLabel.font = [UIFont boldSystemFontOfSize:11];
        _matchLabel.textColor = [UIColor whiteColor];
        _matchLabel.textAlignment = NSTextAlignmentCenter;
        [matchPanel addSubview:_matchLabel];

        // 开关
        _matchSwitch = [[UISwitch alloc] initWithFrame:CGRectMake((panelW - 51) / 2, 20, 51, 31)];
        _matchSwitch.onTintColor = [UIColor colorWithRed:0 green:0.7 blue:0.3 alpha:1];
        [_matchSwitch setOn:NO];
        [matchPanel addSubview:_matchSwitch];

        static id matchTarget = nil;
        if (!matchTarget) {
            Class helper = objc_allocateClassPair([NSObject class], "HZMatchHelper", 0);
            class_addMethod(helper, sel_registerName("onMatchToggle:"), (IMP)onMatchToggle, "v@:@");
            objc_registerClassPair(helper);
            matchTarget = [[helper alloc] init];
        }
        [_matchSwitch addTarget:matchTarget action:sel_registerName("onMatchToggle:") forControlEvents:UIControlEventValueChanged];
        LOG(@"Match switch panel created");

        // Switch 状态同步定时器
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            if (_matchSwitch.isOn != _matching) {
                [_matchSwitch setOn:_matching animated:YES];
            }
        }];

        // 保持按钮在最前 & 监听窗口变化
        [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) {
            UIWindow *kw2 = keyWin();
            if (kw2 && _btn.superview != kw2) {
                [_btn removeFromSuperview];
                [kw2 addSubview:_btn];
            }
            if (kw2 && matchPanel.superview != kw2) {
                [matchPanel removeFromSuperview];
                [kw2 addSubview:matchPanel];
            }
            if (kw2) {
                [kw2 bringSubviewToFront:_btn];
                [kw2 bringSubviewToFront:matchPanel];
            }
        }];
    });
}

// ==================== 在线匹配 ====================
// 前置声明
static void sendHiIfMatched(void);

// 递归找按钮（限制深度防崩溃）
static UIButton* findMatchButtonDepth(UIView *view, int depth) {
    if (!view || depth > 15) return nil;
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        @try {
            NSString *title = [btn currentTitle];
            if (title && [title rangeOfString:@"匹配" options:NSCaseInsensitiveSearch].location != NSNotFound)
                return btn;
        } @catch (NSException *e) {}
    }
    @try {
        NSArray *subs = view.subviews;
        for (UIView *sub in subs) {
            UIButton *found = findMatchButtonDepth(sub, depth + 1);
            if (found) return found;
        }
    } @catch (NSException *e) {}
    return nil;
}

static void doMatch(void) {
    @try {
        UIWindow *kw = keyWin();
        if (!kw) return;

        // 方式1：在屏幕上找含"匹配"的按钮直接点
        UIButton *btn = findMatchButtonDepth(kw, 0);
        if (btn && btn.enabled && !btn.hidden) {
            LOG(@"Match: tapping button");
            [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
            _lastMatch = [[NSDate date] timeIntervalSince1970];
            // 延迟检查是否匹配成功并发送"嗨"
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                sendHiIfMatched();
            });
            return;
        }

        // 方式2：找 HZRandomMatchViewController
        Class matchCls = objc_getClass("HZRandomMatchViewController");
        if (!matchCls) return;

        // 简单遍历 VC 链
        id vc = kw.rootViewController;
        id matchVC = nil;
        for (int i = 0; i < 20 && vc && !matchVC; i++) {
            if ([vc isKindOfClass:matchCls]) { matchVC = vc; break; }
            SEL ps = sel_registerName("presentedViewController");
            id pres = ((id(*)(id,SEL))objc_msgSend)(vc, ps);
            if (pres) { vc = pres; continue; }
            SEL cs = sel_registerName("childViewControllers");
            if ([vc respondsToSelector:cs]) {
                NSArray *children = ((id(*)(id,SEL))objc_msgSend)(vc, cs);
                if (children.count > 0) { vc = children.lastObject; continue; }
            }
            break;
        }

        if (!matchVC) return;

        // 在 VC 的 view 里找匹配按钮
        UIView *vcView = ((id(*)(id,SEL))objc_msgSend)(matchVC, sel_registerName("view"));
        btn = findMatchButtonDepth(vcView, 0);
        if (btn && btn.enabled && !btn.hidden) {
            LOG(@"Match: tapping VC button");
            [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
            _lastMatch = [[NSDate date] timeIntervalSince1970];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                sendHiIfMatched();
            });
            return;
        }

        // 方式3：尝试调 startMatch / startLink
        SEL s = sel_registerName("startMatch");
        if ([matchVC respondsToSelector:s]) {
            ((void(*)(id,SEL))objc_msgSend)(matchVC, s);
            _lastMatch = [[NSDate date] timeIntervalSince1970];
            LOG(@"Match: startMatch called");
        } else {
            s = sel_registerName("startLink");
            if ([matchVC respondsToSelector:s]) {
                ((void(*)(id,SEL))objc_msgSend)(matchVC, s);
                _lastMatch = [[NSDate date] timeIntervalSince1970];
                LOG(@"Match: startLink called");
            }
        }
    } @catch (NSException *e) {
        LOG(@"Match crash: %@", e);
    }
}

// 匹配成功后给用户发"嗨"
static void sendHiIfMatched(void) {
    UIWindow *kw = keyWin();
    if (!kw) return;
    Class chatCls = objc_getClass("MDChatSingleViewController");
    if (!chatCls) return;

    // 找当前是否在聊天页
    id vc = kw.rootViewController;
    id chatVC = nil;
    for (int i = 0; i < 20 && vc && !chatVC; i++) {
        if ([vc isKindOfClass:chatCls]) { chatVC = vc; break; }
        SEL ps = sel_registerName("presentedViewController");
        id pres = ((id(*)(id,SEL))objc_msgSend)(vc, ps);
        if (pres) { vc = pres; continue; }
        SEL cs = sel_registerName("childViewControllers");
        if ([vc respondsToSelector:cs]) {
            NSArray *children = ((id(*)(id,SEL))objc_msgSend)(vc, cs);
            if (children.count > 0) { vc = children.lastObject; continue; }
        }
        break;
    }

    if (chatVC) {
        // 在聊天页，发送"嗨"
        SEL sendSel = sel_registerName("sendMessageText:extInfo:");
        if ([chatVC respondsToSelector:sendSel]) {
            ((void(*)(id,SEL,id,id))objc_msgSend)(chatVC, sendSel, @"嗨", nil);
            LOG(@"Match: sent 嗨");
        }
    }
}

static void startAutoMatch(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        while (YES) {
            sleep(8);
            if (!_matching) continue;
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            if (now - _lastMatch < 10) continue; // 10秒冷却
            dispatch_async(dispatch_get_main_queue(), ^{
                doMatch();
            });
        }
    });
}

// ==================== 匹配开关 ====================
static void onMatchToggle(id self, SEL _cmd) {
    _matching = !_matching;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_matching) {
            toast(@"自动匹配已开启");
            doMatch();
        } else {
            toast(@"自动匹配已关闭");
        }
    });
}

// ==================== 入口 ====================
__attribute__((constructor))
static void HZInit(void) {
    LOG(@"HeziSend dylib loaded");
    _deviceNum = loadDeviceNum();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        makeButton();
        startPolling();
        startAutoMatch();
        LOG(@"HeziSend ready — polling a1.php every 3s");
        toast(@"赫兹群发已就绪");
    });
}
