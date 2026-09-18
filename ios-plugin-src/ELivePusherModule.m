//
//  ELivePusherModule.m
//  ELivePusher
//
//  写法已按 DCloud 官方文档（nativesupport.dcloud.net.cn/NativePlugin/course/ios.html）核对：
//  - 继承 DCUniModule；
//  - 用 UNI_EXPORT_METHOD(@selector(xxx:callback:)) 暴露异步方法；
//  - 回调类型 UniModuleKeepAliveCallback（第二参数 YES 表示可多次回调/长连接，NO 表示单次）。
//

#import "ELivePusherModule.h"
#import "ELivePusherManager.h"

#pragma mark - helpers

static NSString *ELivePusherId(NSDictionary *options) {
    NSString *pid = [options isKindOfClass:[NSDictionary class]] ? [options objectForKey:@"pusherId"] : nil;
    return (pid.length > 0) ? pid : @"livePusher";
}

/// 组装 { code, msg } 并单次回调（对齐 Android 的 done()）
static void ELiveDone(UniModuleKeepAliveCallback callback, BOOL ok, NSString *msg) {
    if (!callback) {
        return;
    }
    NSDictionary *ret = @{ @"code": @(ok ? 0 : -1),
                           @"msg" : msg ?: (ok ? @"ok" : @"fail") };
    callback(ret, NO);
}

#pragma mark - ELivePusherModule

@implementation ELivePusherModule

// ------------------------------------------------------------------- init

/// 初始化推流实例。options 支持：
/// pusherId, url, mode, aspect, beauty, whiteness, videoGop,
/// minBitrate, maxBitrate, devicePosition, mirror, width, height, fps,
/// apiBase(业务后端地址), token(authorization), apiProtocol(直连 SRS 信令协议, 默认 http)
UNI_EXPORT_METHOD(@selector(init:callback:))
- (void)init:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback __attribute__((objc_method_family(none))) {
    [[ELivePusherManager sharedInstance] initPusher:ELivePusherId(options)
                                            options:options
                                           callback:^(BOOL ok, NSString *msg) {
        ELiveDone(callback, ok, msg);
    }];
}

// ------------------------------------------------------------ startPreview

/// 开启摄像头/麦克风预览（内部处理动态权限申请）
UNI_EXPORT_METHOD(@selector(startPreview:callback:))
- (void)startPreview:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [[ELivePusherManager sharedInstance] startPreview:ELivePusherId(options)
                                              options:options
                                             callback:^(BOOL ok, NSString *msg) {
        ELiveDone(callback, ok, msg);
    }];
}

// ------------------------------------------------------------------- start

/// 开始推流。options 可覆盖 url
UNI_EXPORT_METHOD(@selector(start:callback:))
- (void)start:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [[ELivePusherManager sharedInstance] start:ELivePusherId(options)
                                       options:options
                                      callback:^(BOOL ok, NSString *msg) {
        ELiveDone(callback, ok, msg);
    }];
}

// -------------------------------------------------------------------- stop

/// 停止推流（保留预览）
UNI_EXPORT_METHOD(@selector(stop:callback:))
- (void)stop:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [[ELivePusherManager sharedInstance] stop:ELivePusherId(options)
                                     callback:^(BOOL ok, NSString *msg) {
        ELiveDone(callback, ok, msg);
    }];
}

// ------------------------------------------------------------------- pause

/// 暂停推流（保持连接，停发画面与声音；RTMP 为断流保预览）
UNI_EXPORT_METHOD(@selector(pause:callback:))
- (void)pause:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [[ELivePusherManager sharedInstance] pause:ELivePusherId(options)
                                      callback:^(BOOL ok, NSString *msg) {
        ELiveDone(callback, ok, msg);
    }];
}

// ------------------------------------------------------------------- resume

/// 恢复推流
UNI_EXPORT_METHOD(@selector(resume:callback:))
- (void)resume:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [[ELivePusherManager sharedInstance] resume:ELivePusherId(options)
                                       callback:^(BOOL ok, NSString *msg) {
        ELiveDone(callback, ok, msg);
    }];
}

// ------------------------------------------------------------ switchCamera

/// 切换前后置摄像头，回调 { code, msg, devicePosition }
UNI_EXPORT_METHOD(@selector(switchCamera:callback:))
- (void)switchCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [[ELivePusherManager sharedInstance] switchCamera:ELivePusherId(options)
                                             callback:^(BOOL ok, NSString *msg) {
        if (!callback) {
            return;
        }
        NSMutableDictionary *ret = [NSMutableDictionary dictionary];
        ret[@"code"] = @(ok ? 0 : -1);
        ret[@"msg"] = msg ?: @"";
        if (ok && ([msg isEqualToString:@"front"] || [msg isEqualToString:@"back"])) {
            ret[@"devicePosition"] = msg;
        }
        callback(ret, NO);
    }];
}

// ---------------------------------------------------------------- snapshot

/// 截图，回调 { code: 0, path: '/.../xxx.jpg' }
UNI_EXPORT_METHOD(@selector(snapshot:callback:))
- (void)snapshot:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [[ELivePusherManager sharedInstance] snapshot:ELivePusherId(options)
                                         callback:^(NSString *path, NSString *error) {
        if (!callback) {
            return;
        }
        NSMutableDictionary *ret = [NSMutableDictionary dictionary];
        ret[@"code"] = @(path != nil ? 0 : -1);
        ret[@"msg"] = path != nil ? @"ok" : (error ?: @"fail");
        if (path) {
            ret[@"path"] = path;
        }
        callback(ret, NO);
    }];
}

// ------------------------------------------------------------- stopPreview

/// 关闭摄像头预览
UNI_EXPORT_METHOD(@selector(stopPreview:callback:))
- (void)stopPreview:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [[ELivePusherManager sharedInstance] stopPreview:ELivePusherId(options)
                                            callback:^(BOOL ok, NSString *msg) {
        ELiveDone(callback, ok, msg);
    }];
}

// ------------------------------------------------------------------ setUrl

/// 更新推流地址（协议变化时自动切换推流核心）
UNI_EXPORT_METHOD(@selector(setUrl:callback:))
- (void)setUrl:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSString *url = [options isKindOfClass:[NSDictionary class]] ? [options objectForKey:@"url"] : nil;
    if (url.length == 0) {
        ELiveDone(callback, NO, @"url is empty");
        return;
    }
    [[ELivePusherManager sharedInstance] setUrl:ELivePusherId(options) url:url
                                       callback:^(BOOL ok, NSString *msg) {
        ELiveDone(callback, ok, msg);
    }];
}

// ---------------------------------------------------------- registerEvents

/// 注册事件长连接回调（对应 live-pusher 的 @statechange/@netstatus/@error）。
/// 回调参数：{ event: 'statechange'|'netstatus'|'error', detail: {...} }
UNI_EXPORT_METHOD(@selector(registerEvents:callback:))
- (void)registerEvents:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [[ELivePusherManager sharedInstance] registerEvents:ELivePusherId(options) callback:callback];
}

// ----------------------------------------------------------------- destroy

/// 销毁推流实例（页面卸载时调用）
UNI_EXPORT_METHOD(@selector(destroy:callback:))
- (void)destroy:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [[ELivePusherManager sharedInstance] destroy:ELivePusherId(options)];
    ELiveDone(callback, YES, @"ok");
}

// ------------------------------------------------------------------- close

/// 与 live-pusher.close 对齐：销毁实例
UNI_EXPORT_METHOD(@selector(close:callback:))
- (void)close:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [[ELivePusherManager sharedInstance] destroy:ELivePusherId(options)];
    ELiveDone(callback, YES, @"ok");
}

@end
