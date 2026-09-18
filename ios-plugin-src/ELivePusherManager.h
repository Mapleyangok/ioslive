//
//  ELivePusherManager.h
//  ELivePusher
//
//  推流管理器：模块（ELivePusherModule）与组件（ELivePusherComponent）的桥接层。
//  - 组件把渲染容器注册进来（按 pusherId）；
//  - 模块的操作方法按 pusherId 找到对应推流核心执行；
//  - 推流核心的事件统一转发给 JS（registerEvents 注册的长连接回调）。
//  行为对齐 Android 端 PusherManager；所有操作统一在主线程执行。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "DCUniModule.h"
#import "ELiveCorePusher.h"

NS_ASSUME_NONNULL_BEGIN

@class ELivePusherComponent;

/// 模块操作结果回调
typedef void (^ELiveActionCallback)(BOOL ok, NSString *msg);

/// 推流实例条目（对齐 Android 端 PusherManager.Entry）
@interface ELivePusherEntry : NSObject

@property (nonatomic, copy) NSString *pusherId;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *config;
@property (nonatomic, strong) id<ELiveCorePusher> core;
@property (nonatomic, strong) ELivePusherComponent *viewComp;
/// JS 注册的长连接事件回调（keepAlive=YES，可连续触发）
@property (nonatomic, copy) UniModuleKeepAliveCallback eventCallback;
@property (nonatomic, assign) BOOL pendingPreview; // 组件未挂载时暂存预览请求
@property (nonatomic, assign) BOOL destroyed;

@end

@interface ELivePusherManager : NSObject

+ (instancetype)sharedInstance;

// ------------------------------------------------------------------ view

- (void)attachView:(NSString *)pusherId component:(ELivePusherComponent *)comp;
- (void)detachView:(NSString *)pusherId component:(ELivePusherComponent *)comp;
- (void)setMirror:(NSString *)pusherId mirror:(BOOL)mirror;

// ----------------------------------------------------------------- events

/// 注册事件长连接回调（对应 live-pusher 的 @statechange/@netstatus/@error）
- (void)registerEvents:(NSString *)pusherId callback:(UniModuleKeepAliveCallback)callback;

// ------------------------------------------------------------------- api

/// 初始化推流实例（options 需包含 url 等配置；组件未挂载时返回失败）
- (void)initPusher:(NSString *)pusherId options:(nullable NSDictionary *)options callback:(ELiveActionCallback)cb;

/// 更新推流地址（协议变化时自动切换推流核心）
- (void)setUrl:(NSString *)pusherId url:(NSString *)url callback:(ELiveActionCallback)cb;

/// 开启摄像头/麦克风预览（内部处理动态权限申请）
- (void)startPreview:(NSString *)pusherId options:(nullable NSDictionary *)options callback:(ELiveActionCallback)cb;

/// 开始推流（options 可覆盖 url）
- (void)start:(NSString *)pusherId options:(nullable NSDictionary *)options callback:(ELiveActionCallback)cb;

- (void)stop:(NSString *)pusherId callback:(ELiveActionCallback)cb;
- (void)pause:(NSString *)pusherId callback:(ELiveActionCallback)cb;
- (void)resume:(NSString *)pusherId callback:(ELiveActionCallback)cb;

/// 切换前后置摄像头；cb 的 msg 为切换结果 "front"/"back"
- (void)switchCamera:(NSString *)pusherId callback:(ELiveActionCallback)cb;

/// 截图，path 为临时 JPEG 路径
- (void)snapshot:(NSString *)pusherId callback:(ELiveSnapshotCallback)cb;

- (void)stopPreview:(NSString *)pusherId callback:(ELiveActionCallback)cb;

/// 销毁推流实例（页面卸载时调用）
- (void)destroy:(NSString *)pusherId;

@end

NS_ASSUME_NONNULL_END
