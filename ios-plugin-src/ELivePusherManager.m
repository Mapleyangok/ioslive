//
//  ELivePusherManager.m
//  ELivePusher
//

#import "ELivePusherManager.h"
#import "ELivePusherComponent.h"
#import "ELiveWebRTCPusher.h"
#import "ELiveRTMPPusher.h"
#import "ELiveUrlParser.h"

#import <AVFoundation/AVFoundation.h>

static NSString * const kDefaultPusherId = @"livePusher";

@implementation ELivePusherEntry
@end

@interface ELivePusherManager ()

/// entries 仅在主线程访问（所有公开方法统一 dispatch 到主队列）
@property (nonatomic, strong) NSMutableDictionary<NSString *, ELivePusherEntry *> *entries;

@end

@implementation ELivePusherManager

+ (instancetype)sharedInstance {
    static ELivePusherManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ELivePusherManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _entries = [NSMutableDictionary dictionary];
    }
    return self;
}

// ------------------------------------------------------------------ entry

- (NSString *)normalizeId:(NSString *)pusherId {
    return (pusherId.length > 0) ? pusherId : kDefaultPusherId;
}

- (ELivePusherEntry *)getOrCreate:(NSString *)pusherId {
    NSString *id_ = [self normalizeId:pusherId];
    ELivePusherEntry *e = self.entries[id_];
    if (!e) {
        e = [ELivePusherEntry new];
        e.pusherId = id_;
        e.config = [NSMutableDictionary dictionary];
        self.entries[id_] = e;
    }
    return e;
}

- (ELivePusherEntry *)get:(NSString *)pusherId {
    return self.entries[[self normalizeId:pusherId]];
}

/// 按地址协议创建推流核心（webrtc:// / rtc:// / 空地址默认 WebRTC；rtmp:// 走 LFLiveKit）
- (void)ensureCore:(ELivePusherEntry *)e {
    if (e.core) {
        return;
    }
    NSString *url = e.config[@"url"];
    // 注意：block 持有 entry，entry 持有 core，core 持有 block —— 循环引用
    // 由 destroy()（移除 entry、置空 core）打破，与 Android 端一致
    ELivePusherEventBlock events = ^(NSString *name, NSDictionary *detail) {
        [self fireEntryEvent:e name:name detail:detail];
    };
    if ([ELiveUrlParser isRtmpUrl:url]) {
        e.core = [[ELiveRTMPPusher alloc] initWithEventBlock:events];
    } else {
        e.core = [[ELiveWebRTCPusher alloc] initWithEventBlock:events];
    }
    if (e.pendingPreview && e.viewComp) {
        id<ELiveCorePusher> core = e.core;
        ELivePusherComponent *comp = e.viewComp;
        NSDictionary *cfg = [e.config copy];
        e.pendingPreview = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [core startPreviewWithContainer:comp.containerView config:cfg];
        });
    }
}

// ------------------------------------------------------------------ view

- (void)attachView:(NSString *)pusherId component:(ELivePusherComponent *)comp {
    dispatch_async(dispatch_get_main_queue(), ^{
        ELivePusherEntry *e = [self getOrCreate:pusherId];
        e.viewComp = comp;
        UIView *container = comp.containerView;
        if (e.core && container) {
            [e.core reattachToContainer:container];
        } else if (e.pendingPreview && container) {
            // 组件后挂载：补执行暂存的预览请求
            // （ensureCore 内部也会消费 pendingPreview，这里再查一次避免重复开启预览）
            [self ensureCore:e];
            if (e.core && e.pendingPreview) {
                id<ELiveCorePusher> core = e.core;
                NSDictionary *cfg = [e.config copy];
                e.pendingPreview = NO;
                [core startPreviewWithContainer:container config:cfg];
            }
        }
    });
}

- (void)detachView:(NSString *)pusherId component:(ELivePusherComponent *)comp {
    dispatch_async(dispatch_get_main_queue(), ^{
        ELivePusherEntry *e = [self get:pusherId];
        if (e && e.viewComp == comp) {
            e.viewComp = nil;
        }
    });
}

- (void)setMirror:(NSString *)pusherId mirror:(BOOL)mirror {
    dispatch_async(dispatch_get_main_queue(), ^{
        ELivePusherEntry *e = [self get:pusherId];
        if (!e) {
            return;
        }
        e.config[@"mirror"] = @(mirror);
    });
}

// ----------------------------------------------------------------- events

- (void)registerEvents:(NSString *)pusherId callback:(UniModuleKeepAliveCallback)callback {
    dispatch_async(dispatch_get_main_queue(), ^{
        ELivePusherEntry *e = [self getOrCreate:pusherId];
        e.eventCallback = callback;
    });
}

- (void)fireEntryEvent:(ELivePusherEntry *)e name:(NSString *)name detail:(NSDictionary *)detail {
    UniModuleKeepAliveCallback cb = e.eventCallback;
    if (!cb) {
        return;
    }
    NSDictionary *payload = @{ @"event": name ?: @"", @"detail": detail ?: @{} };
    @try {
        // keepAlive = YES：长连接回调，可连续触发
        cb(payload, YES);
    } @catch (NSException *ignore) {
    }
}

// ------------------------------------------------------------------- api

- (void)initPusher:(NSString *)pusherId options:(NSDictionary *)options callback:(ELiveActionCallback)cb {
    dispatch_async(dispatch_get_main_queue(), ^{
        ELivePusherEntry *e = [self getOrCreate:pusherId];
        if ([options isKindOfClass:[NSDictionary class]]) {
            [e.config addEntriesFromDictionary:options];
        }
        [self ensureCore:e];
        cb(e.core != nil, e.core != nil ? @"ok" : @"组件尚未挂载，无法创建推流核心");
    });
}

- (void)setUrl:(NSString *)pusherId url:(NSString *)url callback:(ELiveActionCallback)cb {
    dispatch_async(dispatch_get_main_queue(), ^{
        ELivePusherEntry *e = [self getOrCreate:pusherId];
        e.config[@"url"] = url;
        if (!e.core) {
            [self ensureCore:e];
            cb(e.core != nil, e.core != nil ? @"ok" : @"组件尚未挂载");
            return;
        }
        // 协议变化时重建核心
        if ([e.core isPushing]) {
            [e.core stop];
        }
        BOOL isRtmp = [ELiveUrlParser isRtmpUrl:url];
        BOOL coreIsRtmp = [e.core isKindOfClass:[ELiveRTMPPusher class]];
        if (isRtmp != coreIsRtmp) {
            @try {
                [e.core destroy];
            } @catch (NSException *ignore) {
            }
            e.core = nil;
            [self ensureCore:e];
        }
        cb(e.core != nil, e.core != nil ? @"ok" : @"组件尚未挂载");
    });
}

- (void)startPreview:(NSString *)pusherId options:(NSDictionary *)options callback:(ELiveActionCallback)cb {
    dispatch_async(dispatch_get_main_queue(), ^{
        ELivePusherEntry *e = [self getOrCreate:pusherId];
        if ([options isKindOfClass:[NSDictionary class]]) {
            [e.config addEntriesFromDictionary:options];
        }
        UIView *container = e.viewComp.containerView;
        if (!e.viewComp || !container) {
            e.pendingPreview = YES;
            cb(YES, @"等待组件挂载后自动开启预览");
            return;
        }
        [self ensureCore:e];
        if (!e.core) {
            cb(NO, @"无法创建推流核心");
            return;
        }
        [ELivePusherManager ensurePermissions:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!granted) {
                    [self fireEntryEvent:e name:ELiveEventError
                                  detail:@{ @"errMsg": @"摄像头/麦克风权限被拒绝",
                                            @"errCode": @(ELiveStateCameraFailed) }];
                    cb(NO, @"权限被拒绝");
                    return;
                }
                [e.core startPreviewWithContainer:container config:e.config];
                cb(YES, @"ok");
            });
        }];
    });
}

- (void)start:(NSString *)pusherId options:(NSDictionary *)options callback:(ELiveActionCallback)cb {
    dispatch_async(dispatch_get_main_queue(), ^{
        ELivePusherEntry *e = [self getOrCreate:pusherId];
        NSString *url = [options objectForKey:@"url"];
        if ([options isKindOfClass:[NSDictionary class]] && url.length > 0) {
            e.config[@"url"] = url;
        }
        [self ensureCore:e];
        if (!e.core) {
            cb(NO, @"推流核心未就绪");
            return;
        }
        [e.core start:e.config[@"url"]];
        cb(YES, @"ok");
    });
}

- (void)stop:(NSString *)pusherId callback:(ELiveActionCallback)cb {
    dispatch_async(dispatch_get_main_queue(), ^{
        ELivePusherEntry *e = [self get:pusherId];
        if (e && e.core) {
            [e.core stop];
        }
        cb(YES, @"ok");
    });
}

- (void)pause:(NSString *)pusherId callback:(ELiveActionCallback)cb {
    dispatch_async(dispatch_get_main_queue(), ^{
        ELivePusherEntry *e = [self get:pusherId];
        if (e && e.core) {
            [e.core pause];
        }
        cb(YES, @"ok");
    });
}

- (void)resume:(NSString *)pusherId callback:(ELiveActionCallback)cb {
    dispatch_async(dispatch_get_main_queue(), ^{
        ELivePusherEntry *e = [self get:pusherId];
        if (e && e.core) {
            [e.core resume];
        }
        cb(YES, @"ok");
    });
}

- (void)switchCamera:(NSString *)pusherId callback:(ELiveActionCallback)cb {
    dispatch_async(dispatch_get_main_queue(), ^{
        ELivePusherEntry *e = [self getOrCreate:pusherId];
        NSString *cur = [e.config objectForKey:@"devicePosition"];
        BOOL toFront = ![cur isEqualToString:@"back"];
        e.config[@"devicePosition"] = toFront ? @"front" : @"back";
        [self ensureCore:e];
        if (!e.core) {
            cb(NO, @"推流核心未就绪");
            return;
        }
        [e.core switchCameraToFront:toFront];
        cb(YES, toFront ? @"front" : @"back");
    });
}

- (void)snapshot:(NSString *)pusherId callback:(ELiveSnapshotCallback)cb {
    dispatch_async(dispatch_get_main_queue(), ^{
        ELivePusherEntry *e = [self get:pusherId];
        if (e && e.core) {
            [e.core snapshot:cb];
        } else {
            cb(nil, @"预览未开启");
        }
    });
}

- (void)stopPreview:(NSString *)pusherId callback:(ELiveActionCallback)cb {
    dispatch_async(dispatch_get_main_queue(), ^{
        ELivePusherEntry *e = [self get:pusherId];
        if (e && e.core) {
            [e.core stopPreview];
        }
        cb(YES, @"ok");
    });
}

- (void)destroy:(NSString *)pusherId {
    dispatch_async(dispatch_get_main_queue(), ^{
        ELivePusherEntry *e = [self get:pusherId];
        if (!e) {
            return;
        }
        e.destroyed = YES;
        if (e.core) {
            @try {
                [e.core destroy];
            } @catch (NSException *ignore) {
            }
            e.core = nil;
        }
        e.viewComp = nil;
        e.eventCallback = nil;
        [self.entries removeObjectForKey:e.pusherId];
    });
}

// ----------------------------------------------------------- permissions

/// 相机 + 麦克风权限检查/申请（iOS 不需要 Activity，直接走 AVCaptureDevice 授权接口）
+ (void)ensurePermissions:(void (^)(BOOL granted))completion {
    dispatch_group_t group = dispatch_group_create();
    __block BOOL granted = YES;
    NSArray<AVMediaType> *types = @[ AVMediaTypeVideo, AVMediaTypeAudio ];
    for (AVMediaType type in types) {
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:type];
        if (status == AVAuthorizationStatusAuthorized) {
            continue;
        }
        if (status == AVAuthorizationStatusNotDetermined) {
            dispatch_group_enter(group);
            [AVCaptureDevice requestAccessForMediaType:type completionHandler:^(BOOL ok) {
                if (!ok) {
                    granted = NO;
                }
                dispatch_group_leave(group);
            }];
        } else { // Denied / Restricted
            granted = NO;
        }
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        completion(granted);
    });
}

@end
