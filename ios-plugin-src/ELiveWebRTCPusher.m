//
//  ELiveWebRTCPusher.m
//  ELivePusher
//
//  本文件 API 均已与 webrtc-sdk/webrtc 仓库 m104_release 分支（GoogleWebRTC 1.1.32000 对应 M104）
//  的源码头文件逐一核对：
//  - sdk/objc/base/RTCVideoRenderer.h：协议方法 setSize: / renderFrame:
//  - sdk/objc/base/RTCVideoFrame.h：rotation 属性（RTCVideoRotation_0/90/180/270）与 buffer 属性
//  - sdk/objc/components/video_frame_buffer/RTCCVPixelBuffer.h：pixelBuffer 属性（CVPixelBufferRef）
//  - sdk/objc/api/peerconnection/RTCVideoTrack.h：addRenderer: / removeRenderer:
//

#import "ELiveWebRTCPusher.h"
#import "ELiveUrlParser.h"
#import "ELiveSrsSignaling.h"

#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>

static NSString * const kVideoTrackId = @"elive_video0";
static NSString * const kAudioTrackId = @"elive_audio0";
static NSString * const kStreamId     = @"elive_stream";

#pragma mark - PeerConnectionFactory（全局单例，初始化一次）

static RTC_OBJC_TYPE(RTCPeerConnectionFactory) *_gFactory = nil;
static dispatch_once_t _gFactoryOnce;

static RTC_OBJC_TYPE(RTCPeerConnectionFactory) *ELiveEnsureFactory(void) {
    dispatch_once(&_gFactoryOnce, ^{
        // RTCInitializeSSL 已核对 RTCSSLAdapter.h；返回 NO 表示已初始化，不阻断
        BOOL sslOk = RTCInitializeSSL();
        (void)sslOk;
        RTC_OBJC_TYPE(RTCDefaultVideoEncoderFactory) *encoder =
            [[RTC_OBJC_TYPE(RTCDefaultVideoEncoderFactory) alloc] init];
        RTC_OBJC_TYPE(RTCDefaultVideoDecoderFactory) *decoder =
            [[RTC_OBJC_TYPE(RTCDefaultVideoDecoderFactory) alloc] init];
        _gFactory = [[RTC_OBJC_TYPE(RTCPeerConnectionFactory) alloc]
                     initWithEncoderFactory:encoder decoderFactory:decoder];
    });
    return _gFactory;
}

#pragma mark - 一次性抓帧渲染器（截图用）

// 实现 RTCVideoRenderer 协议（M104 头文件已核对：setSize: / renderFrame:；
// renderFrame: 内使用的 frame.rotation/buffer 与 RTCCVPixelBuffer.pixelBuffer 亦已核对）
@interface ELiveFrameGrabber : NSObject <RTC_OBJC_TYPE(RTCVideoRenderer)>

@property (nonatomic, copy) void (^done)(UIImage *image, NSString *error);
@property (nonatomic, assign) BOOL finished;

- (instancetype)initWithCompletion:(void (^)(UIImage *image, NSString *error))done;

@end

@implementation ELiveFrameGrabber

- (instancetype)initWithCompletion:(void (^)(UIImage *, NSString *))done {
    self = [super init];
    if (self) {
        _done = done;
    }
    return self;
}

- (void)setSize:(CGSize)size {
}

// 在 WebRTC 渲染线程回调；抓到第一帧后立即置位 finished 并异步完成回调
- (void)renderFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame {
    if (self.finished || !self.done) {
        return;
    }
    self.finished = YES;

    UIImage *result = nil;
    NSString *error = nil;
    @try {
        id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)> buffer = frame.buffer;
        if ([buffer isKindOfClass:[RTC_OBJC_TYPE(RTCCVPixelBuffer) class]]) {
            RTC_OBJC_TYPE(RTCCVPixelBuffer) *cvb = (RTC_OBJC_TYPE(RTCCVPixelBuffer) *)buffer;
            CVPixelBufferRef pb = cvb.pixelBuffer;
            CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            @try {
                CIImage *ci = [CIImage imageWithCVImageBuffer:pb];
                // 方向修正（帧缓冲为横向，rotation 指示展示方向）
                switch (frame.rotation) {
                    case RTCVideoRotation_90:
                        ci = [ci imageByApplyingTransform:CGAffineTransformMakeRotation(M_PI_2)];
                        break;
                    case RTCVideoRotation_180:
                        ci = [ci imageByApplyingTransform:CGAffineTransformMakeRotation(M_PI)];
                        break;
                    case RTCVideoRotation_270:
                        ci = [ci imageByApplyingTransform:CGAffineTransformMakeRotation(-M_PI_2)];
                        break;
                    default:
                        break;
                }
                CIContext *ctx = [CIContext contextWithOptions:nil];
                CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
                if (cg) {
                    result = [UIImage imageWithCGImage:cg];
                    CGImageRelease(cg);
                } else {
                    error = @"截图失败：图像转换失败";
                }
            } @finally {
                CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            }
        } else {
            error = @"截图失败：不支持的帧格式";
        }
    } @catch (NSException *e) {
        error = [NSString stringWithFormat:@"截图失败: %@", e.reason];
    }

    UIImage *image = result;
    NSString *err = error;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.done(image, err);
    });
}

@end

#pragma mark - ELiveWebRTCPusher

@interface ELiveWebRTCPusher () <RTC_OBJC_TYPE(RTCPeerConnectionDelegate)>

@property (nonatomic, copy) ELivePusherEventBlock events;

// WebRTC 对象
@property (nonatomic, strong) RTC_OBJC_TYPE(RTCPeerConnection) *pc;
@property (nonatomic, strong) RTC_OBJC_TYPE(RTCVideoSource) *videoSource;
@property (nonatomic, strong) RTC_OBJC_TYPE(RTCAudioSource) *audioSource;
@property (nonatomic, strong) RTC_OBJC_TYPE(RTCCameraVideoCapturer) *capturer;
@property (nonatomic, strong) RTC_OBJC_TYPE(RTCVideoTrack) *videoTrack;
@property (nonatomic, strong) RTC_OBJC_TYPE(RTCAudioTrack) *audioTrack;
@property (nonatomic, strong) RTC_OBJC_TYPE(RTCMTLVideoView) *renderer;

// 截图状态
@property (nonatomic, strong) ELiveFrameGrabber *snapshotGrabber;
@property (nonatomic, strong) NSTimer *snapshotTimeout;
@property (nonatomic, copy) ELiveSnapshotCallback snapshotCallback;

// 渲染容器与配置
@property (nonatomic, strong) UIView *container;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *apiBase;
@property (nonatomic, copy) NSString *token;
@property (nonatomic, copy) NSString *apiProtocol;
@property (nonatomic, assign) BOOL frontCamera;
@property (nonatomic, assign) BOOL mirror;
@property (nonatomic, assign) NSInteger width;
@property (nonatomic, assign) NSInteger height;
@property (nonatomic, assign) NSInteger fps;
@property (nonatomic, assign) NSInteger maxBitrateKbps;
@property (nonatomic, assign) NSInteger minBitrateKbps;

// 运行状态
@property (nonatomic, assign) BOOL cameraStarted;
@property (nonatomic, assign) BOOL pushing;
@property (nonatomic, assign) BOOL signaling;
@property (nonatomic, assign) BOOL destroyed;
@property (nonatomic, assign) BOOL firstFrameEmitted;

// stats 轮询
@property (nonatomic, strong) NSTimer *statsTimer;
@property (nonatomic, assign) long long lastVideoBytes;
@property (nonatomic, assign) long long lastAudioBytes;
@property (nonatomic, assign) long long lastTs;

@end

@implementation ELiveWebRTCPusher

- (instancetype)initWithEventBlock:(ELivePusherEventBlock)eventBlock {
    self = [super init];
    if (self) {
        _events = eventBlock;
        _apiBase = @"";
        _token = @"";
        _apiProtocol = @"http";
        _frontCamera = YES;
        _mirror = YES;
        _width = 720;
        _height = 1280;
        _fps = 20;
        _maxBitrateKbps = 1500;
        _minBitrateKbps = 300;
    }
    return self;
}

#pragma mark - config

- (void)applyConfig:(NSDictionary *)cfg {
    if (![cfg isKindOfClass:[NSDictionary class]]) {
        return;
    }
    if ([cfg objectForKey:@"url"]) {
        self.url = [cfg objectForKey:@"url"];
    }
    if ([cfg objectForKey:@"apiBase"]) {
        self.apiBase = [cfg objectForKey:@"apiBase"] ?: @"";
    }
    if ([cfg objectForKey:@"token"]) {
        self.token = [cfg objectForKey:@"token"] ?: @"";
    }
    NSString *apiProtocol = [cfg objectForKey:@"apiProtocol"];
    if ([apiProtocol isKindOfClass:[NSString class]] && apiProtocol.length > 0) {
        self.apiProtocol = apiProtocol;
    }
    NSString *devicePosition = [cfg objectForKey:@"devicePosition"];
    if ([devicePosition isKindOfClass:[NSString class]]) {
        self.frontCamera = ![devicePosition isEqualToString:@"back"];
    }
    if ([cfg objectForKey:@"mirror"] != nil) {
        self.mirror = [cfg[@"mirror"] boolValue];
    }
    NSInteger maxBr = [cfg[@"maxBitrate"] isKindOfClass:[NSNumber class]] ? [cfg[@"maxBitrate"] integerValue] : 0;
    if (maxBr > 0) self.maxBitrateKbps = maxBr;
    NSInteger minBr = [cfg[@"minBitrate"] isKindOfClass:[NSNumber class]] ? [cfg[@"minBitrate"] integerValue] : 0;
    if (minBr > 0) self.minBitrateKbps = minBr;

    NSInteger w = [cfg[@"width"] isKindOfClass:[NSNumber class]] ? [cfg[@"width"] integerValue] : 0;
    NSInteger h = [cfg[@"height"] isKindOfClass:[NSNumber class]] ? [cfg[@"height"] integerValue] : 0;
    if (w > 0 && h > 0) {
        self.width = w;
        self.height = h;
    } else {
        // mode/aspect -> 分辨率（竖屏推流，与页面 aspect 3:4 / mode HD 对应）
        NSString *mode = [cfg objectForKey:@"mode"];
        NSString *aspect = [cfg objectForKey:@"aspect"];
        if ([aspect isEqualToString:@"3:4"]) {
            self.width = 720; self.height = 960;
        } else if ([aspect isEqualToString:@"9:16"]) {
            self.width = 720; self.height = 1280;
        } else if ([mode isEqualToString:@"FHD"]) {
            self.width = 1080; self.height = 1920;
        } else if ([mode isEqualToString:@"SD"]) {
            self.width = 540; self.height = 960;
        } else { // HD 默认
            self.width = 720; self.height = 1280;
        }
    }
    NSInteger f = [cfg[@"fps"] isKindOfClass:[NSNumber class]] ? [cfg[@"fps"] integerValue] : 0;
    if (f > 0) self.fps = f;
}

#pragma mark - ELiveCorePusher

- (void)startPreviewWithContainer:(UIView *)container config:(NSDictionary *)cfg {
    [self applyConfig:cfg];
    self.container = container;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed || !container) {
            return;
        }
        @try {
            [self ensureRenderer:container];
            [self ensureCapturerAndTracks];
        } @catch (NSException *e) {
            [self emitError:[NSString stringWithFormat:@"预览失败: %@", e.reason] code:ELiveStateCameraFailed];
        }
    });
}

- (void)reattachToContainer:(UIView *)container {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed || !container) {
            return;
        }
        self.container = container;
        if (self.renderer && self.renderer.superview != container) {
            [self.renderer removeFromSuperview];
            self.renderer.frame = container.bounds;
            self.renderer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [container addSubview:self.renderer];
        }
    });
}

- (void)start:(NSString *)pushUrl {
    if (pushUrl.length > 0) {
        self.url = pushUrl;
    }
    if (self.url.length == 0) {
        [self emitError:@"推流地址为空" code:-1];
        return;
    }
    if (![ELiveUrlParser isWebrtcUrl:self.url]) {
        [self emitError:[NSString stringWithFormat:@"WebRTC 推流仅支持 webrtc:// 地址: %@", self.url] code:-2];
        return;
    }
    if (self.signaling) {
        return;
    }
    self.signaling = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self doStartPush];
    });
}

- (void)stop {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pushing = NO;
        [self stopStatsLoop];
        if (self.pc) {
            [self.pc close];
            self.pc = nil;
        }
    });
}

- (void)pause {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.videoTrack.isEnabled = NO;
        self.audioTrack.isEnabled = NO;
    });
}

- (void)resume {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.videoTrack.isEnabled = YES;
        self.audioTrack.isEnabled = YES;
    });
}

- (void)switchCameraToFront:(BOOL)front {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.capturer || self.destroyed) {
            return;
        }
        AVCaptureDevice *device = [self findDevice:front];
        if (!device) {
            [self emitError:[NSString stringWithFormat:@"未找到%@摄像头", front ? @"前置" : @"后置"]
                       code:ELiveStateCameraFailed];
            return;
        }
        AVCaptureDeviceFormat *format = [self bestFormatForDevice:device];
        NSInteger fps = [self clampFpsForFormat:format];
        self.frontCamera = front;
        [self.capturer stopCaptureWithCompletionHandler:^(void) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self || self.destroyed) return;
                [self.capturer startCaptureWithDevice:device format:format fps:fps
                                    completionHandler:^(NSError *_Nullable error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!self) return;
                        if (error) {
                            self.frontCamera = !front;
                            [self emitError:[NSString stringWithFormat:@"切换摄像头失败: %@", error.localizedDescription]
                                       code:ELiveStateCameraFailed];
                        } else {
                            [self emitState:ELiveStateCameraStarted
                                     message:front ? @"已切换到前置摄像头" : @"已切换到后置摄像头"];
                        }
                    });
                }];
            });
        }];
    });
}

- (void)snapshot:(ELiveSnapshotCallback)callback {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.videoTrack || self.destroyed) {
            if (callback) callback(nil, @"预览未开启");
            return;
        }
        [self grabSnapshotWithCallback:callback];
    });
}

- (void)stopPreview {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopCaptureInternal];
    });
}

- (BOOL)isPushing {
    return _pushing;
}

- (void)destroy {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed) return;
        self.destroyed = YES;
        self.pushing = NO;
        [self stopStatsLoop];
        [self stopCaptureInternal];
        if (self.pc) {
            [self.pc close];
            self.pc = nil;
        }
        [self.renderer removeFromSuperview];
        self.renderer = nil;
        self.container = nil;
        // PeerConnectionFactory 为进程级单例，随 App 生命周期存续，不做销毁（ARC 自动管理）
    });
}

#pragma mark - preview inner

- (void)ensureRenderer:(UIView *)container {
    if (self.renderer && self.renderer.superview == container) {
        return;
    }
    [self.renderer removeFromSuperview];
    if (!self.renderer) {
        self.renderer = [[RTC_OBJC_TYPE(RTCMTLVideoView) alloc] initWithFrame:container.bounds];
    }
    self.renderer.frame = container.bounds;
    self.renderer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // RTCMTLVideoView 无 mirror 属性（已核对 RTCMTLVideoView.h），用 transform 实现本地预览镜像
    [self applyMirrorToRenderer];
    [container addSubview:self.renderer];
}

- (void)applyMirrorToRenderer {
    if (!self.renderer) return;
    self.renderer.transform = self.mirror ? CGAffineTransformMakeScale(-1, 1) : CGAffineTransformIdentity;
}

- (void)ensureCapturerAndTracks {
    if (self.destroyed) {
        return;
    }
    RTC_OBJC_TYPE(RTCPeerConnectionFactory) *factory = ELiveEnsureFactory();
    if (self.videoTrack == nil) {
        AVCaptureDevice *device = [self findDevice:self.frontCamera];
        if (!device) {
            [self emitError:@"未找到可用摄像头" code:ELiveStateCameraFailed];
            return;
        }
        AVCaptureDeviceFormat *format = [self bestFormatForDevice:device];
        if (!format) {
            [self emitError:@"未找到可用的摄像头格式" code:ELiveStateCameraFailed];
            return;
        }
        NSInteger fps = [self clampFpsForFormat:format];

        self.videoSource = [factory videoSource];
        // 限制编码输出分辨率/帧率（宽高为竖屏目标；WebRTC 侧方向无关，自动匹配横竖采集）
        [self.videoSource adaptOutputFormatToWidth:(int)self.width height:(int)self.height fps:(int)self.fps];
        self.capturer = [[RTC_OBJC_TYPE(RTCCameraVideoCapturer) alloc] initWithDelegate:self.videoSource];
        [self.capturer startCaptureWithDevice:device format:format fps:fps];
        self.videoTrack = [factory videoTrackWithSource:self.videoSource trackId:kVideoTrackId];
        self.cameraStarted = YES;
        [self emitState:ELiveStateCameraStarted message:@"打开摄像头成功"];
    }
    if (self.audioTrack == nil) {
        self.audioSource = [factory audioSourceWithConstraints:nil];
        self.audioTrack = [factory audioTrackWithSource:self.audioSource trackId:kAudioTrackId];
    }
}

- (AVCaptureDevice *)findDevice:(BOOL)front {
    AVCaptureDevicePosition want = front ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
    for (AVCaptureDevice *device in [RTC_OBJC_TYPE(RTCCameraVideoCapturer) captureDevices]) {
        if (device.position == want) {
            return device;
        }
    }
    return nil;
}

/// 选择面积最接近竖屏目标分辨率（width x height）的摄像头格式
/// （摄像头原生格式为横向，例如 1280x720 对应竖屏 720x1280，面积相同）
- (AVCaptureDeviceFormat *)bestFormatForDevice:(AVCaptureDevice *)device {
    NSArray<AVCaptureDeviceFormat *> *formats =
        [RTC_OBJC_TYPE(RTCCameraVideoCapturer) supportedFormatsForDevice:device];
    AVCaptureDeviceFormat *best = nil;
    long bestDiff = LONG_MAX;
    long target = (long)self.width * (long)self.height;
    for (AVCaptureDeviceFormat *f in formats) {
        CMVideoDimensions d = f.dimensions;
        long area = (long)d.width * (long)d.height;
        long diff = labs(area - target);
        if (diff < bestDiff) {
            bestDiff = diff;
            best = f;
        }
    }
    return best;
}

/// 将目标 fps 收敛到格式支持的帧率区间内
- (NSInteger)clampFpsForFormat:(AVCaptureDeviceFormat *)format {
    if (!format) return (NSInteger)self.fps;
    NSInteger wanted = (NSInteger)self.fps;
    for (AVFrameRateRange *r in format.videoSupportedFrameRateRanges) {
        if (wanted >= r.minFrameRate && wanted <= r.maxFrameRate) {
            return wanted;
        }
    }
    AVFrameRateRange *closest = nil;
    double bestDiff = DBL_MAX;
    for (AVFrameRateRange *r in format.videoSupportedFrameRateRanges) {
        double diff = (wanted < r.minFrameRate) ? (r.minFrameRate - wanted)
                    : (wanted > r.maxFrameRate) ? (wanted - r.maxFrameRate) : 0;
        if (diff < bestDiff) {
            bestDiff = diff;
            closest = r;
        }
    }
    if (!closest) return wanted;
    return (wanted < closest.minFrameRate) ? (NSInteger)closest.minFrameRate : (NSInteger)closest.maxFrameRate;
}

- (void)stopCaptureInternal {
    if (self.capturer) {
        [self.capturer stopCapture];
        self.capturer = nil;
    }
    self.videoTrack = nil;
    self.audioTrack = nil;
    self.videoSource = nil;
    self.audioSource = nil;
    self.cameraStarted = NO;
}

#pragma mark - push inner

- (void)doStartPush {
    if (self.destroyed) {
        self.signaling = NO;
        return;
    }
    @try {
        [self ensurePc];
        // tracks 在预览阶段已创建；若尚未创建（未 startPreview 直接 start），此处补建
        [self ensureCapturerAndTracks];
        [self attachTracksAndOffer];
    } @catch (NSException *e) {
        self.signaling = NO;
        [self emitError:[NSString stringWithFormat:@"推流失败: %@", e.reason] code:ELiveStateCameraFailed];
    }
}

- (void)ensurePc {
    if (self.pc) {
        return;
    }
    RTC_OBJC_TYPE(RTCPeerConnectionFactory) *factory = ELiveEnsureFactory();
    RTC_OBJC_TYPE(RTCConfiguration) *config = [[RTC_OBJC_TYPE(RTCConfiguration) alloc] init];
    config.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    RTC_OBJC_TYPE(RTCIceServer) *stun =
        [[RTC_OBJC_TYPE(RTCIceServer) alloc] initWithURLStrings:@[ @"stun:stun.l.google.com:19302" ]];
    config.iceServers = @[ stun ];
    self.pc = [factory peerConnectionWithConfiguration:config constraints:nil delegate:self];
}

- (void)attachTracksAndOffer {
    if (self.pc == nil || self.destroyed) {
        self.signaling = NO;
        return;
    }
    @try {
        if (self.videoTrack) {
            [self.pc addTrack:self.videoTrack streamIds:@[ kStreamId ]];
        }
        if (self.audioTrack) {
            [self.pc addTrack:self.audioTrack streamIds:@[ kStreamId ]];
        }
        [self applyBitrate];

        RTC_OBJC_TYPE(RTCMediaConstraints) *constraints =
            [[RTC_OBJC_TYPE(RTCMediaConstraints) alloc]
             initWithMandatoryConstraints:@{
                 kRTCMediaConstraintsOfferToReceiveAudio : kRTCMediaConstraintsValueFalse,
                 kRTCMediaConstraintsOfferToReceiveVideo : kRTCMediaConstraintsValueFalse,
             }
                       optionalConstraints:nil];

        [self emitState:ELiveStateConnectServer message:@"开始连接推流服务器"];
        [self.pc offerForConstraints:constraints
                   completionHandler:^(RTC_OBJC_TYPE(RTCSessionDescription) *_Nullable sdp, NSError *_Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self || self.destroyed) {
                    if (self) self.signaling = NO;
                    return;
                }
                if (error || sdp == nil) {
                    self.signaling = NO;
                    [self emitError:[NSString stringWithFormat:@"createOffer 失败: %@", error.localizedDescription] code:-4];
                    return;
                }
                [self.pc setLocalDescription:sdp completionHandler:^(NSError *_Nullable setErr) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!self || self.destroyed) {
                            if (self) self.signaling = NO;
                            return;
                        }
                        if (setErr) {
                            self.signaling = NO;
                            [self emitError:[NSString stringWithFormat:@"setLocalDescription 失败: %@", setErr.localizedDescription] code:-4];
                            return;
                        }
                        // setLocalDescription 成功后取 localDescription.sdp 发起信令
                        RTC_OBJC_TYPE(RTCSessionDescription) *local = self.pc.localDescription;
                        NSString *offerSdp = local.sdp ?: sdp.sdp;
                        [self signalAndSetRemoteWithOffer:offerSdp];
                    });
                }];
            });
        }];
    } @catch (NSException *e) {
        self.signaling = NO;
        [self emitError:[NSString stringWithFormat:@"推流异常: %@", e.reason] code:-5];
    }
}

- (void)signalAndSetRemoteWithOffer:(NSString *)offerSdp {
    [ELiveSrsSignaling publishWithUrl:self.url
                             offerSdp:offerSdp
                              apiBase:self.apiBase
                                token:self.token
                          apiProtocol:self.apiProtocol
                           completion:^(NSString *answerSdp, NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self) return;
            if (self.destroyed || self.pc == nil) {
                self.signaling = NO;
                return;
            }
            if (error) {
                self.signaling = NO;
                [self emitError:error code:ELiveStateConnectionLost];
                return;
            }
            RTC_OBJC_TYPE(RTCSessionDescription) *answer =
                [[RTC_OBJC_TYPE(RTCSessionDescription) alloc] initWithType:RTCSdpTypeAnswer sdp:answerSdp];
            [self.pc setRemoteDescription:answer completionHandler:^(NSError *_Nullable remoteErr) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!self || self.destroyed) return;
                    if (remoteErr) {
                        [self emitError:[NSString stringWithFormat:@"setRemoteDescription 失败: %@", remoteErr.localizedDescription]
                                   code:ELiveStateConnectionLost];
                    }
                });
            }];
            self.pushing = YES;
            [self startStatsLoop];
            self.signaling = NO;
        });
    }];
}

- (void)applyBitrate {
    if (!self.pc) {
        return;
    }
    for (RTC_OBJC_TYPE(RTCRtpSender) *sender in self.pc.senders) {
        if (![sender.track.kind isEqualToString:@"video"]) {
            continue;
        }
        RTC_OBJC_TYPE(RTCRtpParameters) *params = sender.parameters;
        if (params.encodings.count > 0) {
            RTC_OBJC_TYPE(RTCRtpEncodingParameters) *enc = params.encodings[0];
            enc.maxBitrateBps = @(self.maxBitrateKbps * 1000);
            enc.minBitrateBps = @(self.minBitrateKbps * 1000);
            @try {
                sender.parameters = params;
            } @catch (NSException *ignore) {
            }
        }
    }
}

#pragma mark - stats loop（1 秒轮询，对齐 Android 实现）

- (void)startStatsLoop {
    if (self.statsTimer) {
        return;
    }
    self.firstFrameEmitted = NO;
    self.lastVideoBytes = 0;
    self.lastAudioBytes = 0;
    self.lastTs = 0;
    self.statsTimer = [NSTimer timerWithTimeInterval:1.0
                                              target:self
                                            selector:@selector(tickStats)
                                            userInfo:nil
                                             repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.statsTimer forMode:NSRunLoopCommonModes];
}

- (void)stopStatsLoop {
    [self.statsTimer invalidate];
    self.statsTimer = nil;
}

- (void)tickStats {
    if (!self.pushing || !self.pc || self.destroyed) {
        return;
    }
    __weak typeof(self) ws = self;
    [self.pc statisticsWithCompletionHandler:^(RTC_OBJC_TYPE(RTCStatisticsReport) *report) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self = ws;
            if (!self || !self.pushing || self.destroyed) return;
            [self handleStatsReport:report];
        });
    }];
}

- (void)handleStatsReport:(RTC_OBJC_TYPE(RTCStatisticsReport) *)report {
    long long videoBytes = 0;
    long long audioBytes = 0;
    double outFps = 0;
    int outW = 0;
    int outH = 0;

    for (RTC_OBJC_TYPE(RTCStatistics) *stat in report.statistics.allValues) {
        if (![stat.type isEqualToString:@"outbound-rtp"]) {
            continue;
        }
        NSDictionary *m = stat.values;
        NSString *kind = nil;
        if ([m[@"kind"] isKindOfClass:[NSString class]]) {
            kind = m[@"kind"];
        } else if ([m[@"mediaType"] isKindOfClass:[NSString class]]) {
            kind = m[@"mediaType"];
        }
        long long b = [m[@"bytesSent"] isKindOfClass:[NSNumber class]] ? [m[@"bytesSent"] longLongValue] : 0;
        if ([kind isEqualToString:@"video"]) {
            videoBytes = b;
            if ([m[@"framesPerSecond"] isKindOfClass:[NSNumber class]]) {
                outFps = [m[@"framesPerSecond"] doubleValue];
            }
            if ([m[@"frameWidth"] isKindOfClass:[NSNumber class]]) {
                outW = [m[@"frameWidth"] intValue];
            }
            if ([m[@"frameHeight"] isKindOfClass:[NSNumber class]]) {
                outH = [m[@"frameHeight"] intValue];
            }
        } else if ([kind isEqualToString:@"audio"]) {
            audioBytes = b;
        }
    }

    long long now = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
    if (self.lastTs > 0) {
        double sec = MAX(0.001, (now - self.lastTs) / 1000.0);
        long long videoDelta = MAX(0, videoBytes - self.lastVideoBytes);
        long long audioDelta = MAX(0, audioBytes - self.lastAudioBytes);
        NSDictionary *info = @{
            @"videoBitrate": @((int)(videoDelta / sec / 1000)),
            @"audioBitrate": @((int)(audioDelta / sec / 1000)),
            @"videoFPS"    : @((int)outFps),
            @"videoGOP"    : @(0),
            @"netSpeed"    : @((int)((videoDelta + audioDelta) / sec / 1000)),
            @"netJitter"   : @(0),
            @"videoWidth"  : @(outW),
            @"videoHeight" : @(outH),
        };
        if (self.events) self.events(ELiveEventNetstatus, info);
        if (!self.firstFrameEmitted && videoBytes > 0) {
            self.firstFrameEmitted = YES;
            [self emitState:ELiveStateVideoEncodeOk message:@"视频推流中"];
        }
    }
    self.lastVideoBytes = videoBytes;
    self.lastAudioBytes = audioBytes;
    self.lastTs = now;
}

#pragma mark - snapshot（一次性抓帧渲染器）

- (void)grabSnapshotWithCallback:(ELiveSnapshotCallback)callback {
    self.snapshotCallback = callback;
    if (!self.snapshotGrabber) {
        self.snapshotGrabber = [[ELiveFrameGrabber alloc]
            initWithCompletion:^(UIImage *image, NSString *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self finishSnapshotWithImage:image error:error];
                });
            }];
    } else {
        self.snapshotGrabber.finished = NO;
    }
    if (!self.snapshotTimeout) {
        // 3 秒超时兜底，避免无帧（摄像头未开）时回调悬挂
        self.snapshotTimeout = [NSTimer timerWithTimeInterval:3.0
                                                       target:self
                                                     selector:@selector(snapshotTimeoutTick)
                                                     userInfo:nil
                                                      repeats:NO];
        [[NSRunLoop mainRunLoop] addTimer:self.snapshotTimeout forMode:NSRunLoopCommonModes];
    }
    [self.videoTrack addRenderer:self.snapshotGrabber];
}

- (void)snapshotTimeoutTick {
    if (self.snapshotGrabber && !self.snapshotGrabber.finished) {
        self.snapshotGrabber.finished = YES;
        [self finishSnapshotWithImage:nil error:@"截图失败：等待画面超时"];
    }
}

- (void)finishSnapshotWithImage:(UIImage *)image error:(NSString *)error {
    [self.snapshotTimeout invalidate];
    self.snapshotTimeout = nil;
    if (self.snapshotGrabber && self.videoTrack) {
        [self.videoTrack removeRenderer:self.snapshotGrabber];
    }
    ELiveSnapshotCallback cb = self.snapshotCallback;
    self.snapshotCallback = nil;
    if (!cb) return;
    if (!image) {
        cb(nil, error ?: @"截图失败：无画面");
        return;
    }
    NSString *file = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"elive_snapshot_%lld.jpg",
             (long long)([[NSDate date] timeIntervalSince1970] * 1000)]];
    NSData *jpeg = UIImageJPEGRepresentation(image, 0.9);
    if (![jpeg writeToFile:file atomically:YES]) {
        cb(nil, @"截图保存失败");
        return;
    }
    cb(file, nil);
}

#pragma mark - RTCPeerConnectionDelegate

// 以下委托方法由 WebRTC 内部线程回调，统一切回主线程再发事件

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
    didChangeSignalingState:(RTCSignalingState)stateChanged {
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
          didAddStream:(RTC_OBJC_TYPE(RTCMediaStream) *)stream {
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
       didRemoveStream:(RTC_OBJC_TYPE(RTCMediaStream) *)stream {
}

- (void)peerConnectionShouldNegotiate:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection {
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
    didChangeIceConnectionState:(RTCIceConnectionState)newState {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.destroyed) return;
        if (newState == RTCIceConnectionStateConnected ||
            newState == RTCIceConnectionStateCompleted) {
            [self emitState:ELiveStateHandshakeOk message:@"推流已连接"];
        } else if (newState == RTCIceConnectionStateDisconnected) {
            [self emitState:ELiveStateNetworkDisconnect message:@"推流网络不稳定/断开"];
        } else if (newState == RTCIceConnectionStateFailed) {
            [self emitState:ELiveStateConnectionLost message:@"推流连接失败"];
        }
    });
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
    didChangeIceGatheringState:(RTCIceGatheringState)newState {
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
    didGenerateIceCandidate:(RTC_OBJC_TYPE(RTCIceCandidate) *)candidate {
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
    didRemoveIceCandidates:(NSArray<RTC_OBJC_TYPE(RTCIceCandidate) *> *)candidates {
}

- (void)peerConnection:(RTC_OBJC_TYPE(RTCPeerConnection) *)peerConnection
     didOpenDataChannel:(RTC_OBJC_TYPE(RTCDataChannel) *)dataChannel {
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
