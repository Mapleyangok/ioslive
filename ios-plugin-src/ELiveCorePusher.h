//
//  ELiveCorePusher.h
//  ELivePusher
//
//  推流核心协议：由 ELiveWebRTCPusher（webrtc://）与 ELiveRTMPPusher（rtmp://）实现。
//  与 Android 端 ICorePusher 一一对应；所有方法均应在主线程调用（内部自行处理线程切换）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 截图回调：path 为临时 JPEG 文件路径，error 为失败原因（二者互斥，均可能为空串之外的场景见实现）
typedef void (^ELiveSnapshotCallback)(NSString * _Nullable path, NSString * _Nullable error);

/// 推流核心事件回调（由 ELivePusherManager 提供，统一转发给 JS 长连接回调）
typedef void (^ELivePusherEventBlock)(NSString *eventName, NSDictionary *detail);

// ---------------------------------------------------------------------------
// 与 uni-app 内置 live-pusher 对齐的状态码（对齐 Android 端 StateCodes）
// ---------------------------------------------------------------------------
/// 已连接推流服务器
static const NSInteger ELiveStateConnectServer   = 1001;
/// 已经完成握手，开始推流
static const NSInteger ELiveStateHandshakeOk     = 1002;
/// 打开摄像头成功
static const NSInteger ELiveStateCameraStarted   = 1003;
/// 视频编码成功/首帧已发送
static const NSInteger ELiveStateVideoEncodeOk   = 2004;
/// 打开摄像头失败
static const NSInteger ELiveStateCameraFailed    = 3001;
/// 推流过程中网络断开（会自动重连）
static const NSInteger ELiveStateNetworkDisconnect = 3002;
/// 连接中断
static const NSInteger ELiveStateConnectionLost  = 3005;

/// 事件名（对齐 Android 端 StateCodes.EVENT_*）
static NSString * const ELiveEventStatechange = @"statechange";
static NSString * const ELiveEventNetstatus   = @"netstatus";
static NSString * const ELiveEventError       = @"error";

@protocol ELiveCorePusher <NSObject>

/// 创建渲染视图并开启摄像头/麦克风预览
/// @param container 组件提供的容器（组件宿主视图）
/// @param cfg 推流配置（url/mode/aspect/devicePosition/mirror/beauty/bitrate/gop/fps/resolution 等）
- (void)startPreviewWithContainer:(nullable UIView *)container config:(nullable NSDictionary *)cfg;

/// 组件销毁重建后，将渲染视图重新挂到新的容器
- (void)reattachToContainer:(nullable UIView *)container;

/// 开始推流（复用 startPreview 创建的采集），可传新的推流地址覆盖
- (void)start:(nullable NSString *)url;

/// 停止推流，保留预览
- (void)stop;

/// 暂停（保持连接，停发画面/声音）
- (void)pause;

/// 恢复
- (void)resume;

/// 切换前后置摄像头，结果通过事件 statechange(1003) 通知
- (void)switchCameraToFront:(BOOL)front;

/// 截图（临时 JPEG 文件路径通过回调返回）
- (void)snapshot:(ELiveSnapshotCallback)callback;

/// 停止摄像头预览
- (void)stopPreview;

/// 是否正在推流
- (BOOL)isPushing;

/// 释放全部资源
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
