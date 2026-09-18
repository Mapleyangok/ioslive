//
//  ELiveRTMPPusher.m
//  ELivePusher
//
//  与 LFLiveKit 2.6 源码（github.com/LaiFengiOS/LFLiveKit tag 2.6）核对过的 API 约定：
//  - LFLiveSession：initWithAudioConfiguration:videoConfiguration: / startLive:(streamInfo) / stopLive
//  - stopLive 只断开 socket 不停采集（running 仍为 YES），预览得以保留；
//    pause() 采用"断流保预览"方案（RTMP 协议无真正暂停），resume() 重新 startLive。
//  - session.preView 为 null_resettable 的容器视图，SDK 会把 OpenGL ES 预览视图加入其中；
//    running = YES 开始采集，captureDevicePosition/beautyFace/beautyLevel/mirror/muted 可运行时切换。
//  - LFLiveState：Ready=0 / Pending=1 / Start=2 / Stop=3 / Error=4 / Refresh=5。
//  - LFLiveVideoConfiguration：videoSize/videoFrameRate/videoBitRate/videoMaxKeyframeInterval/
//    sessionPreset 可直接设置；sessionPreset 最高 720x1280（1080p 会被采集端降级，见 README 已知限制）。
//  - LFLiveKit 未提供实时码率/帧率统计回调，netstatus 仅回填配置值（码率字段为 0）。
//  - session.currentImage（readonly, nullable UIImage）已核对：经 LFVideoCapture 的
//    GPUImage filter.imageFromCurrentFramebuffer 直读当前帧，对 OpenGL ES 预览截图可靠。
//

#import "ELiveRTMPPusher.h"

#import <LFLiveKit/LFLiveSession.h>
#import <AVFoundation/AVFoundation.h>

@interface ELiveRTMPPusher () <LFLiveSessionDelegate>

@property (nonatomic, copy) ELivePusherEventBlock events;

// LFLiveKit 会话与预览
@property (nonatomic, strong) LFLiveSession *session;
@property (nonatomic, strong) UIView *previewWrap; // 自建包装视图，session.preView 挂载于此
@property (nonatomic, strong) UIView *container;   // 组件提供的渲染容器

// 配置（对齐 Android RtmpPusher）
@property (nonatomic, assign) NSInteger targetWidth;   // 竖屏目标分辨率（最终编码输出宽）
@property (nonatomic, assign) NSInteger targetHeight;  // 竖屏目标分辨率（最终编码输出高）
@property (nonatomic, assign) NSInteger fps;
@property (nonatomic, assign) NSInteger maxBitrateKbps;
@property (nonatomic, assign) NSInteger videoGopSec;
@property (nonatomic, assign) BOOL beauty;
@property (nonatomic, assign) BOOL mirror;
@property (nonatomic, assign) BOOL frontCamera;

// 运行状态
@property (nonatomic, copy) NSString *lastUrl;
@property (nonatomic, assign) BOOL streaming;
@property (nonatomic, assign) BOOL manualStopping;
@property (nonatomic, assign) BOOL destroyed;
@property (nonatomic, assign) BOOL cameraStarted;
@property (nonatomic, strong) NSTimer *netTimer;

@end

@implementation ELiveRTMPPusher

- (instancetype)initWithEventBlock:(ELivePusherEventBlock)eventBlock {
    self = [super init];
    if (self) {
        _events = eventBlock;
        _targetWidth = 720;
        _targetHeight = 1280;
        _fps = 20;
        _maxBitrateKbps = 1500;
        _videoGopSec = 2;
        _beauty = NO;
        _mirror = YES;
        _frontCamera = YES;
    }
    return self;
}

#pragma mark - config

- (void)applyConfig:(NSDictionary *)cfg {
    if (![cfg isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSString *devicePosition = [cfg objectForKey:@"devicePosition"];
    if ([devicePosition isKindOfClass:[NSString class]]) {
        self.frontCamera = ![devicePosition isEqualToString:@"back"];
    }
    if ([cfg objectForKey:@"mirror"] != nil) {
        self.mirror = [cfg[@"mirror"] boolValue];
    }
    if ([cfg objectForKey:@"beauty"] != nil) {
        self.beauty = [cfg[@"beauty"] integerValue] > 0;
    }
    NSInteger maxBr = [cfg[@"maxBitrate"] isKindOfClass:[NSNumber class]] ? [cfg[@"maxBitrate"] integerValue] : 0;
    if (maxBr > 0) self.maxBitrateKbps = maxBr;
    NSInteger gop = [cfg[@"videoGop"] isKindOfClass:[NSNumber class]] ? [cfg[@"videoGop"] integerValue] : 0;
    if (gop > 0) self.videoGopSec = gop;
    NSInteger f = [cfg[@"fps"] isKindOfClass:[NSNumber class]] ? [cfg[@"fps"] integerValue] : 0;
    if (f > 0) self.fps = f;

    NSInteger w = [cfg[@"width"] isKindOfClass:[NSNumber class]] ? [cfg[@"width"] integerValue] : 0;
    NSInteger h = [cfg[@"height"] isKindOfClass:[NSNumber class]] ? [cfg[@"height"] integerValue] : 0;
    if (w > 0 && h > 0) {
        // width/height 传入时取 min/max 归一为竖屏（对齐 Android）
        self.targetWidth = MIN(w, h);
        self.targetHeight = MAX(w, h);
    } else {
        // mode/aspect -> 分辨率（竖屏推流，与页面 aspect 3:4 / mode HD 对应）
        NSString *mode = [cfg objectForKey:@"mode"];
        NSString *aspect = [cfg objectForKey:@"aspect"];
        if ([aspect isEqualToString:@"3:4"]) {
            self.targetWidth = 720; self.targetHeight = 960;
        } else if ([aspect isEqualToString:@"9:16"]) {
            self.targetWidth = 720; self.targetHeight = 1280;
        } else if ([mode isEqualToString:@"FHD"]) {
            self.targetWidth = 1080; self.targetHeight = 1920;
        } else if ([mode isEqualToString:@"SD"]) {
            self.targetWidth = 540; self.targetHeight = 960;
        } else { // HD 默认
            self.targetWidth = 720; self.targetHeight = 1280;
        }
    }
}

#pragma mark - ELiveCorePusher

- (void)startPreviewWithContainer:(UIView *)container config:(NSDictionary *)cfg {
    [self applyConfig:cfg];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.container = container;
        [self doStartPreview];
    });
}

- (void)reattachToContainer:(UIView *)container {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed || !container) {
            return;
        }
        self.container = container;
        if (self.previewWrap && self.previewWrap.superview != container) {
            [self.previewWrap removeFromSuperview];
            self.previewWrap.frame = container.bounds;
            self.previewWrap.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [container addSubview:self.previewWrap];
        }
    });
}

- (void)doStartPreview {
    if (self.destroyed || !self.container) {
        return;
    }
    @try {
        // 每次预览都重建核心，保证状态干净（LFLiveKit 要求采集/推流均处于停止态再初始化）
        [self releaseSession];

        LFLiveAudioConfiguration *audioConfig = [LFLiveAudioConfiguration defaultConfiguration]; // 44.1kHz / 96Kbps，对齐 Android 常量
        LFLiveVideoConfiguration *videoConfig = [LFLiveVideoConfiguration new];
        videoConfig.videoSize = CGSizeMake(self.targetWidth, self.targetHeight);
        videoConfig.videoFrameRate = (NSUInteger)self.fps;
        videoConfig.videoBitRate = (NSUInteger)(self.maxBitrateKbps * 1024);
        videoConfig.videoMaxKeyframeInterval = (NSUInteger)self.videoGopSec;
        videoConfig.outputImageOrientation = UIInterfaceOrientationPortrait;
        // sessionPreset 控制采集端分辨率，最高 720x1280；FHD 等更高目标会被采集端限制在 720p
        if (self.targetWidth >= 720) {
            videoConfig.sessionPreset = LFCaptureSessionPreset720x1280;
        } else if (self.targetWidth >= 540) {
            videoConfig.sessionPreset = LFCaptureSessionPreset540x960;
        } else {
            videoConfig.sessionPreset = LFCaptureSessionPreset360x640;
        }

        self.session = [[LFLiveSession alloc] initWithAudioConfiguration:audioConfig
                                                      videoConfiguration:videoConfig];
        if (!self.session) {
            [self emitError:@"创建推流会话失败" code:ELiveStateCameraFailed];
            return;
        }
        self.session.delegate = self;
        self.session.beautyFace = self.beauty;
        if (self.beauty) {
            self.session.beautyLevel = 0.7;
        }
        self.session.mirror = self.mirror;
        self.session.muted = NO;
        self.session.captureDevicePosition =
            self.frontCamera ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
        self.session.reconnectInterval = 1; // 秒
        self.session.reconnectCount = 5;

        // 包装视图承载 OpenGL ES 预览（session.preView 是 null_resettable 容器）
        UIView *wrap = [[UIView alloc] initWithFrame:self.container.bounds];
        wrap.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        wrap.backgroundColor = [UIColor blackColor];
        [self.container addSubview:wrap];
        self.previewWrap = wrap;
        self.session.preView = wrap;
        self.session.running = YES; // 开始采集
        self.cameraStarted = YES;
        [self emitState:ELiveStateCameraStarted message:@"摄像头已开启"];
    } @catch (NSException *e) {
        [self emitError:[NSString stringWithFormat:@"预览失败: %@", e.reason] code:ELiveStateCameraFailed];
    }
}

- (void)start:(NSString *)pushUrl {
    if (pushUrl.length > 0) {
        self.lastUrl = pushUrl;
    }
    if (self.lastUrl.length == 0) {
        [self emitError:@"推流地址为空" code:-1];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed) {
            return;
        }
        @try {
            if (!self.session || !self.session.running) {
                // 未开预览时先补齐预览（含采集初始化），再推流
                if (!self.container) {
                    [self emitError:@"预览未开启，无法推流" code:-1];
                    return;
                }
                [self doStartPreview];
            }
            if (!self.session || self.streaming) {
                return;
            }
            self.manualStopping = NO;
            LFLiveStreamInfo *info = [LFLiveStreamInfo new];
            info.url = self.lastUrl;
            [self.session startLive:info];
            self.streaming = YES;
            [self startNetTimer];
        } @catch (NSException *e) {
            [self emitError:[NSString stringWithFormat:@"推流失败: %@", e.reason] code:ELiveStateConnectionLost];
        }
    });
}

- (void)stop {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopLiveKeepPreview];
    });
}

- (void)pause {
    // RTMP 无协议级暂停：断开推流但保留预览，resume 时重新连接（对齐 Android 方案）
    [self stop];
}

- (void)resume {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed || !self.session || self.streaming || self.lastUrl.length == 0) {
            return;
        }
        @try {
            if (!self.session.running) {
                if (!self.container) {
                    return;
                }
                [self doStartPreview];
            }
            self.manualStopping = NO;
            LFLiveStreamInfo *info = [LFLiveStreamInfo new];
            info.url = self.lastUrl;
            [self.session startLive:info];
            self.streaming = YES;
            [self startNetTimer];
        } @catch (NSException *e) {
            [self emitError:[NSString stringWithFormat:@"恢复推流失败: %@", e.reason] code:ELiveStateConnectionLost];
        }
    });
}

- (void)switchCameraToFront:(BOOL)front {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed || !self.session) {
            return;
        }
        @try {
            self.session.captureDevicePosition =
                front ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
            self.frontCamera = front;
            [self emitState:ELiveStateCameraStarted
                     message:front ? @"已切换到前置摄像头" : @"已切换到后置摄像头"];
        } @catch (NSException *e) {
            [self emitError:[NSString stringWithFormat:@"切换摄像头失败: %@", e.reason] code:ELiveStateCameraFailed];
        }
    });
}

- (void)snapshot:(ELiveSnapshotCallback)callback {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *view = self.previewWrap;
        if (self.destroyed || !view || view.bounds.size.width <= 0) {
            if (callback) callback(nil, @"预览未开启");
            return;
        }
        // LFLiveKit 预览为 OpenGL ES 渲染，drawViewHierarchyInRect 截取 GL 内容随系统版本可能得到黑帧；
        // session.currentImage 经 GPUImage framebuffer 直读当前帧（2.6 源码已核对），优先使用，
        // 取不到（如尚无渲染帧）时再退回视图层级截图。
        UIImage *image = self.session.currentImage;
        if (!image) {
            UIGraphicsBeginImageContextWithOptions(view.bounds.size, NO, [UIScreen mainScreen].scale);
            [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:YES];
            image = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        }
        if (!image) {
            if (callback) callback(nil, @"截图失败：无画面");
            return;
        }
        NSString *file = [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                [NSString stringWithFormat:@"elive_snapshot_%lld.jpg",
                 (long long)([[NSDate date] timeIntervalSince1970] * 1000)]];
        NSData *jpeg = UIImageJPEGRepresentation(image, 0.9);
        if (![jpeg writeToFile:file atomically:YES]) {
            if (callback) callback(nil, @"截图保存失败");
            return;
        }
        if (callback) callback(file, nil);
    });
}

- (void)stopPreview {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed || !self.session) {
            return;
        }
        @try {
            self.manualStopping = YES;
            if (self.streaming) {
                [self.session stopLive];
                self.streaming = NO;
                [self stopNetTimer];
            }
            self.session.running = NO; // 停止采集
            self.session.preView = nil; // 移除 GL 预览视图
        } @catch (NSException *ignore) {
        } @finally {
            self.manualStopping = NO;
        }
        [self.previewWrap removeFromSuperview];
        self.previewWrap = nil;
        self.cameraStarted = NO;
    });
}

- (BOOL)isPushing {
    return _streaming;
}

- (void)destroy {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed) return;
        self.destroyed = YES;
        [self stopNetTimer];
        [self releaseSession];
        self.container = nil;
    });
}

#pragma mark - inner

/// 停止推流、保留预览（LFLiveKit stopLive 仅断 socket，不停采集）
- (void)stopLiveKeepPreview {
    if (self.destroyed || !self.session || !self.streaming) {
        return;
    }
    @try {
        self.manualStopping = YES;
        [self.session stopLive];
        self.streaming = NO;
        [self stopNetTimer];
    } @catch (NSException *ignore) {
    } @finally {
        self.manualStopping = NO;
    }
}

- (void)releaseSession {
    [self stopNetTimer];
    if (self.session) {
        @try {
            self.manualStopping = YES;
            if (self.streaming) {
                [self.session stopLive];
                self.streaming = NO;
            }
            self.session.running = NO;
            self.session.delegate = nil;
        } @catch (NSException *ignore) {
        } @finally {
            self.manualStopping = NO;
        }
        self.session = nil;
    }
    [self.previewWrap removeFromSuperview];
    self.previewWrap = nil;
    self.cameraStarted = NO;
}

#pragma mark - netstatus（LFLiveKit 无实时码率回调，仅回填配置值）

- (void)startNetTimer {
    if (self.netTimer) {
        return;
    }
    self.netTimer = [NSTimer timerWithTimeInterval:1.0
                                            target:self
                                          selector:@selector(tickNetStatus)
                                          userInfo:nil
                                           repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.netTimer forMode:NSRunLoopCommonModes];
}

- (void)stopNetTimer {
    [self.netTimer invalidate];
    self.netTimer = nil;
}

- (void)tickNetStatus {
    if (!self.streaming || self.destroyed) {
        return;
    }
    if (self.events) {
        self.events(ELiveEventNetstatus, @{
            @"videoBitrate": @(0),
            @"audioBitrate": @(0),
            @"videoFPS"    : @((int)self.fps),
            @"videoGOP"    : @((int)self.videoGopSec),
            @"netSpeed"    : @(0),
            @"netJitter"   : @(0),
            @"videoWidth"  : @((int)self.targetWidth),
            @"videoHeight" : @((int)self.targetHeight),
        });
    }
}

#pragma mark - LFLiveSessionDelegate

- (void)liveSession:(LFLiveSession *)session liveStateDidChange:(LFLiveState)state {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed) return;
        switch (state) {
            case LFLivePending: // 连接中
                [self emitState:ELiveStateConnectServer message:@"连接服务器"];
                break;
            case LFLiveStart: // 已连接
                self.streaming = YES;
                [self emitState:ELiveStateHandshakeOk message:@"握手完成，开始推流"];
                break;
            case LFLiveStop: // 已断开
                self.streaming = NO;
                [self stopNetTimer];
                break;
            case LFLiveError: // 连接出错
                self.streaming = NO;
                [self stopNetTimer];
                if (self.manualStopping) break;
                [self emitError:@"推流连接失败" code:ELiveStateConnectionLost];
                break;
            case LFLiveRefresh: // 正在刷新（自动重连中）
                [self emitState:ELiveStateNetworkDisconnect message:@"推流网络不稳定/断开（自动重连中）"];
                break;
            case LFLiveReady:
            default:
                break;
        }
    });
}

- (void)liveSession:(LFLiveSession *)session errorCode:(LFLiveSocketErrorCode)errorCode {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed || self.manualStopping) return;
        [self emitError:[NSString stringWithFormat:@"推流连接失败: %lu", (unsigned long)errorCode]
                   code:ELiveStateConnectionLost];
    });
}

#pragma mark - event

- (void)emitState:(NSInteger)code message:(NSString *)message {
    if (!self.events) return;
    self.events(ELiveEventStatechange, @{ @"code": @(code), @"message": message ?: @"" });
}

- (void)emitError:(NSString *)errMsg code:(NSInteger)errCode {
    if (!self.events) return;
    self.events(ELiveEventError, @{ @"errMsg": errMsg ?: @"", @"errCode": @(errCode) });
    // 同步 statechange 便于页面感知失败（与 live-pusher 行为对齐）
    self.events(ELiveEventStatechange, @{ @"code": @(errCode), @"message": errMsg ?: @"" });
}

@end
