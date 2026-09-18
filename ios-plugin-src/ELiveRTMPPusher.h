//
//  ELiveRTMPPusher.h
//  ELivePusher
//
//  RTMP 推流核心（rtmp:// 地址），基于 LFLiveKit 2.6。
//  行为对齐 Android 端 RtmpPusher（RootEncoder 实现）。
//

#import <Foundation/Foundation.h>
#import "ELiveCorePusher.h"

NS_ASSUME_NONNULL_BEGIN

@interface ELiveRTMPPusher : NSObject <ELiveCorePusher>

/// @param eventBlock 事件回调（由 ELivePusherManager 提供，转发到 JS）
- (instancetype)initWithEventBlock:(nullable ELivePusherEventBlock)eventBlock;

@end

NS_ASSUME_NONNULL_END
