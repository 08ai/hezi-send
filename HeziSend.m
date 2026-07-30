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
static NSTimeInterval _lastSend   = 0;
static UIButton      *_btn        = nil;
static UILabel       *_btnLabel   = nil;
static NSInteger      _totalUsers = 0;
static NSInteger      _sentCount  = 0;

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
    dispatch_async(dispatch_get_main_queue(), ^{ _btnLabel.text = s; });
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
    NSArray<NSString*> *uids = loadUserIDs();
    _totalUsers = uids.count;
    _sentCount  = 0;
    if (_totalUsers == 0) {
        _sending = NO;
        toast(@"无用户");
        setBtnText(@"轮询\n中");
        return;
    }
    LOG(@"sendAll start: \"%@\" → %ld users", text, (long)_totalUsers);
    setBtnText([NSString stringWithFormat:@"0/%ld", (long)_totalUsers]);
    toast([NSString stringWithFormat:@"开始群发 %ld 人", (long)_totalUsers]);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        for (NSInteger i = 0; i < uids.count; i++) {
            dispatch_sync(dispatch_get_main_queue(), ^{ sendMsg(uids[i], text); });
            _sentCount = i + 1;
            dispatch_async(dispatch_get_main_queue(), ^{
                setBtnText([NSString stringWithFormat:@"%ld/%ld", (long)_sentCount, (long)_totalUsers]);
            });
            usleep(800000); // 800ms
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
                NSURL *url = [NSURL URLWithString:@"http://39.102.210.175:5523/a1.php"];
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

// ==================== UI 按钮 ====================
static void makeButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *kw = keyWin();
        if (!kw) {
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
        _btnLabel.text = @"轮询\n中";
        _btnLabel.numberOfLines = 2;
        _btnLabel.textAlignment = NSTextAlignmentCenter;
        _btnLabel.font = [UIFont boldSystemFontOfSize:12];
        _btnLabel.textColor = [UIColor whiteColor];
        _btnLabel.userInteractionEnabled = NO;
        [_btn addSubview:_btnLabel];

        [kw addSubview:_btn];
        LOG(@"Button created at (%.0f,%.0f) size=%.0f", bx, by, bs);

        // 保持按钮在最前 & 监听窗口变化
        [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) {
            UIWindow *kw2 = keyWin();
            if (kw2 && _btn.superview != kw2) {
                [_btn removeFromSuperview];
                [kw2 addSubview:_btn];
            }
            if (kw2) [kw2 bringSubviewToFront:_btn];
        }];
    });
}

// ==================== 入口 ====================
__attribute__((constructor))
static void HZInit(void) {
    LOG(@"HeziSend dylib loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        makeButton();
        startPolling();
        LOG(@"HeziSend ready — polling a1.php every 3s");
        toast(@"赫兹群发已就绪");
    });
}
