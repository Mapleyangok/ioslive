//
//  ELiveUrlParser.h
//  ELivePusher
//
//  复刻项目 hybrid/html/srsRtcClient.js 中 SrsRtcPublisherAsync.__internal.parse/prepareUrl 的逻辑，
//  将 webrtc:// 地址解析为 SRS(rtcdn-draft) 信令 API 地址与原始流地址。
//  行为对齐 Android 端 UrlParser.java。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 解析结果（对应 srsRtcClient.js 的 urlObject）
@interface ELiveUrlResult : NSObject

/// 原始完整地址（即 srsRtcClient 中的 urlObject.url / streamUrl）
@property (nonatomic, copy, nullable) NSString *url;
@property (nonatomic, copy, nullable) NSString *schema;
@property (nonatomic, copy, nullable) NSString *server;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, copy, nullable) NSString *vhost;
@property (nonatomic, copy, nullable) NSString *app;
@property (nonatomic, copy, nullable) NSString *stream;
/// 查询参数（JS 端为保持原序的对象；ObjC 字典无序，仅影响生成 URL 中参数顺序，不影响功能）
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *query;
/// user_query
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *userQuery;

@end

@interface ELiveUrlParser : NSObject

/// 解析 webrtc://host[:port]/app/stream?k=v 形式地址
+ (ELiveUrlResult *)parse:(nullable NSString *)webrtcUrl;

/// 等价 srsRtcClient publish 的 prepareUrl：由解析结果生成信令 API 地址。
/// JS 中 schema 取 window.location.protocol，原生无此概念，由 defaultProtocol 传入
/// （与推流页面 webview 所在协议保持一致，默认 http，可配置 https）。
+ (NSString *)buildApiUrl:(ELiveUrlResult *)result defaultProtocol:(nullable NSString *)defaultProtocol;

/// 判断地址是否为 WebRTC（SRS）地址
+ (BOOL)isWebrtcUrl:(nullable NSString *)url;

/// 判断地址是否为 RTMP 地址
+ (BOOL)isRtmpUrl:(nullable NSString *)url;

@end

NS_ASSUME_NONNULL_END
