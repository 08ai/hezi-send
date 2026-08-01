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
static id             _capturedMatchVC = nil; // navigation hook 截获的真实匹配 VC
static IMP            _origPushIMP = NULL;
static IMP            _origPresentIMP = NULL;

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
static void sendHiIfMatched(void);

// 递归遍历 VC 树
static id findMatchVC(Class cls, id root, int depth) {
    if (!root || depth > 30) return nil;
    if ([root isKindOfClass:cls]) return root;
    // presented
    id pres = ((id(*)(id,SEL))objc_msgSend)(root, sel_registerName("presentedViewController"));
    if (pres) { id f = findMatchVC(cls, pres, depth+1); if (f) return f; }
    // navigation stack
    SEL vs = sel_registerName("viewControllers");
    if ([root respondsToSelector:vs]) {
        NSArray *vcs = ((id(*)(id,SEL))objc_msgSend)(root, vs);
        for (id c in vcs) { id f = findMatchVC(cls, c, depth+1); if (f) return f; }
    }
    // child VCs
    SEL cs = sel_registerName("childViewControllers");
    if ([root respondsToSelector:cs]) {
        NSArray *children = ((id(*)(id,SEL))objc_msgSend)(root, cs);
        for (id c in children) { id f = findMatchVC(cls, c, depth+1); if (f) return f; }
    }
    // Also check selectedViewController for tab controllers
    SEL sS = sel_registerName("selectedViewController");
    if ([root respondsToSelector:sS]) {
        id selVC = ((id(*)(id,SEL))objc_msgSend)(root, sS);
        if (selVC) { id f = findMatchVC(cls, selVC, depth+1); if (f) return f; }
    }
    // Check topViewController for nav controllers
    SEL tS = sel_registerName("topViewController");
    if ([root respondsToSelector:tS]) {
        id topVC = ((id(*)(id,SEL))objc_msgSend)(root, tS);
        if (topVC && topVC != root) { id f = findMatchVC(cls, topVC, depth+1); if (f) return f; }
    }
    return nil;
}

static void doMatch(void) {
    LOG(@"doMatch() called");
    @try {
        Class matchCls = objc_getClass("HZRandomMatchViewController");
        if (!matchCls) { LOG(@"Match class not found"); return; }

        // 搜索匹配 VC：先遍历视图层级找关联的 VC
        id matchVC = _capturedMatchVC;
        if (!matchVC) {
            // 遍历所有窗口的所有 view，通过 nextResponder 找匹配 VC
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                matchVC = findMatchVC(matchCls, w.rootViewController, 0);
                if (matchVC) break;
                // 也遍历 view 层级
                UIResponder *resp = w;
                while ((resp = [resp nextResponder])) {
                    if ([resp isKindOfClass:matchCls]) { matchVC = (id)resp; break; }
                }
                if (matchVC) break;
            }
            if (!matchVC) {
                UIWindow *kw = keyWin();
                if (kw) matchVC = findMatchVC(matchCls, kw.rootViewController, 0);
            }
        }
        if (!matchVC) {
            // 最后手段：创建新实例（可能不完整但至少可以试）
            matchVC = ((id(*)(Class,SEL))objc_msgSend)([matchCls class], sel_registerName("alloc"));
            matchVC = ((id(*)(id,SEL))objc_msgSend)(matchVC, sel_registerName("init"));
        }
        if (!matchVC) return;

        // 延迟执行匹配动作
        id vcRef = matchVC;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            // 先获取 requestManager，它应该是真正的匹配业务对象
            id mgr = ((id(*)(id,SEL))objc_msgSend)(vcRef, sel_registerName("requestManager"));
            LOG(@"Match: requestManager=%@", mgr ? @"exists" : @"nil");
            if (mgr) {
                // Try common methods on the manager
                SEL mgrSels[] = {
                    sel_registerName("start"),
                    sel_registerName("request"),
                    sel_registerName("startRequest"),
                    sel_registerName("send"),
                    sel_registerName("begin"),
                };
                for (int i = 0; i < 5; i++) {
                    if ([mgr respondsToSelector:mgrSels[i]]) {
                        ((void(*)(id,SEL))objc_msgSend)(mgr, mgrSels[i]);
                        LOG(@"Match: called requestManager method #%d", i);
                        break;
                    }
                }
            }
            // 同时也调用 buttonActionWithModel
            id model = ((id(*)(id,SEL))objc_msgSend)(vcRef, sel_registerName("model"));
            if (model) {
                SEL btnSel = sel_registerName("buttonActionWithModel:");
                if ([vcRef respondsToSelector:btnSel]) {
                    ((void(*)(id,SEL,id))objc_msgSend)(vcRef, btnSel, model);
                    LOG(@"Match: buttonActionWithModel called");
                }
            }
            // 也调 requestData
            SEL reqSel = sel_registerName("requestData");
            if ([vcRef respondsToSelector:reqSel]) {
                ((void(*)(id,SEL))objc_msgSend)(vcRef, reqSel);
                LOG(@"Match: requestData called");
            }
        });
        _lastMatch = [[NSDate date] timeIntervalSince1970];

    } @catch (NSException *e) {
        LOG(@"Match crash: %@", e);
    }
}

// 匹配成功后给用户发"嗨"
static void sendHiIfMatched(void) {
    LOG(@"sendHi: enter, matching=%d", _matching);
    if (!_matching) return;

    // 搜索所有可能的聊天 VC 类
    NSArray *chatClasses = @[@"MDChatSingleViewController", @"HZMessageViewController"];
    for (NSString *cn in chatClasses) {
        Class chatCls = objc_getClass([cn UTF8String]);
        if (!chatCls) continue;

        id chatVC = nil;
        UIWindow *kw = keyWin();
        if (kw) chatVC = findMatchVC(chatCls, kw.rootViewController, 0);
        if (!chatVC) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                chatVC = findMatchVC(chatCls, w.rootViewController, 0);
                if (chatVC) break;
            }
        }
        LOG(@"sendHi: %@ = %@", cn, chatVC ? @"FOUND" : @"nil");
        if (chatVC) {
            SEL sendSel = sel_registerName("sendMessageText:extInfo:");
            if ([chatVC respondsToSelector:sendSel]) {
                ((void(*)(id,SEL,id,id))objc_msgSend)(chatVC, sendSel, @"嗨", nil);
                LOG(@"Match: SENT hi via %@!", cn);
                return;
            }
        }
    }
}

static void startAutoMatch(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        LOG(@"Auto-match loop started");
        int tick = 0;
        while (YES) {
            sleep(2);
            if (!_matching) { tick = 0; continue; }
            tick++;
            // 每 2 秒检测聊天页（持续发"嗨"）
            dispatch_async(dispatch_get_main_queue(), ^{ sendHiIfMatched(); });
            // 每 8 秒触发一次匹配（10秒冷却）
            if (tick % 4 == 0) {
                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                if (now - _lastMatch >= 10) {
                    dispatch_async(dispatch_get_main_queue(), ^{ doMatch(); });
                }
            }
        }
    });
}

// ==================== 匹配开关 ====================
static void onMatchToggle(id self, SEL _cmd) {
    _matching = !_matching;
    LOG(@"Match toggle: %@", _matching ? @"ON" : @"OFF");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_matching) {
            toast(@"自动匹配已开启");
            doMatch();
        } else {
            toast(@"自动匹配已关闭");
        }
    });
}

// ==================== Navigation Hook：截获匹配页 VC ====================
static void captureMatchVC(id vc) {
    Class matchCls = objc_getClass("HZRandomMatchViewController");
    if (matchCls && vc && [vc isKindOfClass:matchCls]) {
        _capturedMatchVC = vc;
        LOG(@"Match: captured real VC!");
    }
}

// Hook UINavigationController pushViewController:
static void navPushHook(id self, SEL _cmd, id vc, BOOL animated) {
    captureMatchVC(vc);
    if (_origPushIMP) ((void(*)(id,SEL,id,BOOL))_origPushIMP)(self, _cmd, vc, animated);
}

// Hook UIViewController presentViewController:
static void presentHook(id self, SEL _cmd, id vc, BOOL animated, id completion) {
    captureMatchVC(vc);
    if (_origPresentIMP) ((void(*)(id,SEL,id,BOOL,id))_origPresentIMP)(self, _cmd, vc, animated, completion);
}

static void installNavHook(void) {
    // Hook push
    Class navCls = objc_getClass("UINavigationController");
    if (navCls) {
        Method pm = class_getInstanceMethod(navCls, sel_registerName("pushViewController:animated:"));
        if (pm) { _origPushIMP = method_setImplementation(pm, (IMP)navPushHook); LOG(@"Match: push hook OK"); }
    }
    // Hook present
    Class vcCls = objc_getClass("UIViewController");
    if (vcCls) {
        Method sm = class_getInstanceMethod(vcCls, sel_registerName("presentViewController:animated:completion:"));
        if (sm) { _origPresentIMP = method_setImplementation(sm, (IMP)presentHook); LOG(@"Match: present hook OK"); }
    }
    // 如果当前已经在匹配页，直接搜索捕获
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        Class matchCls = objc_getClass("HZRandomMatchViewController");
        if (!matchCls) return;
        UIWindow *kw = keyWin();
        if (!kw) return;
        // 深层搜索
        id found = findMatchVC(matchCls, kw.rootViewController, 0);
        if (!found) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                found = findMatchVC(matchCls, w.rootViewController, 0);
                if (found) break;
            }
        }
        if (found) {
            _capturedMatchVC = found;
            LOG(@"Match: captured existing VC from hierarchy");
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
        installNavHook();
        LOG(@"HeziSend ready — polling a1.php every 3s");
        toast(@"赫兹群发已就绪");
    });
}
