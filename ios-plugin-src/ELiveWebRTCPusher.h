//
//  ELiveWebRTCPusher.h
//  ELivePusher
//
//  SRS WebRTC 推流核心（webrtc:// 地址），基于 GoogleWebRTC 1.1.32000（WebRTC M104）。
//  流程与项目 webview 内 srsRtcClient.js 完全一致（对齐 Android 端 SrsWebRtcPusher）：
//  getUserMedia(摄像头+麦克风) -> createOffer -> setLocalDescription ->
//  POST /stream/publish(后端代理) -> setRemoteDescription(answer)
//

#import <Foundation/Foundation.h>
#import "ELiveCorePusher.h"

NS_ASSUME_NONNULL_BEGIN

@interface ELiveWebRTCPusher : NSObject <ELiveCorePusher>

/// @param eventBlock 事件回调（由 ELivePusherManager 提供，转发到 JS）
- (instancetype)initWithEventBlock:(nullable ELivePusherEventBlock)eventBlock;

@end

NS_ASSUME_NONNULL_END
