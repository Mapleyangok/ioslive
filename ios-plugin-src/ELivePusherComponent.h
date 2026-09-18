//
//  ELivePusherComponent.h
//  ELivePusher
//
//  原生推流预览组件（对应 nvue 标签 <elive-pusher-view>）。
//  仅负责承载原生渲染视图；所有推流操作走 ELivePusher-Module。
//
//  属性：
//  - pusherId: 绑定的推流实例 id（与 module 调用保持一致，如 "livePusher"）
//  - mirror:   本地预览是否镜像
//

#import "DCUniComponent.h"

NS_ASSUME_NONNULL_BEGIN

@interface ELivePusherComponent : DCUniComponent

/// 渲染容器（推流核心把预览视图 add 到该视图上）
- (nullable UIView *)containerView;

@end

NS_ASSUME_NONNULL_END
