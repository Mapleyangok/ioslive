//
//  ELiveSrsSignaling.h
//  ELivePusher
//
//  SRS(rtcdn-draft) 信令客户端。
//  复刻项目 hybrid/html/srsRtcClient.js 的 publish 流程（对齐 Android 端 SrsSignalingClient）：
//  1. POST {apiBase}/stream/publish（后端代理，带 authorization token）；
//     body: { api: <SRS信令API>, tid(7位随机hex), streamurl, clientip: null, sdp: <offer.sdp> }
//  2. 后端返回 { code: 0, sdp: <answer.sdp> }。
//  若未配置 apiBase（直连模式），则直接 POST 到解析出的 SRS 信令 API 地址。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 信令结果回调：answerSdp 为应答 SDP；error 为失败原因（二者互斥）。回调在网络线程执行，调用方自行切线程。
typedef void (^ELiveSignalingCompletion)(NSString * _Nullable answerSdp, NSString * _Nullable error);

@interface ELiveSrsSignaling : NSObject

/// 发起 publish 信令
/// @param confUrl 原始 webrtc:// 推流地址
/// @param offerSdp 本端 offer SDP
/// @param apiBase 业务后端地址（如 https://api.xxx.com），为空则直连 SRS
/// @param token 业务后端鉴权 token（authorization 头）
/// @param apiProtocol 直连时信令 API 的协议（http/https），默认 http
/// @param completion 结果回调（网络线程执行）
+ (void)publishWithUrl:(NSString *)confUrl
              offerSdp:(NSString *)offerSdp
               apiBase:(nullable NSString *)apiBase
                 token:(nullable NSString *)token
           apiProtocol:(nullable NSString *)apiProtocol
            completion:(ELiveSignalingCompletion)completion;

@end

NS_ASSUME_NONNULL_END
