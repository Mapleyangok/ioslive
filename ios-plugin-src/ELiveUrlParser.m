//
//  ELiveUrlParser.m
//  ELivePusher
//
//  完整复刻 Android 端 UrlParser.java 的 parse/buildApiUrl 逻辑
//  （其源自 hybrid/html/srsRtcClient.js 的 parse/prepareUrl）。
//

#import "ELiveUrlParser.h"

@implementation ELiveUrlResult
@end

@implementation ELiveUrlParser

+ (ELiveUrlResult *)parse:(NSString *)webrtcUrl {
    ELiveUrlResult *ret = [ELiveUrlResult new];
    ret.url = webrtcUrl;
    ret.query = [NSMutableDictionary dictionary];
    ret.userQuery = [NSMutableDictionary dictionary];
    if (webrtcUrl.length == 0) {
        return ret;
    }

    // ---- schema（无 :// 时默认 rtmp，对齐 js/java 实现）
    NSString *schema = @"rtmp";
    NSRange schemeRange = [webrtcUrl rangeOfString:@"://"];
    if (schemeRange.location > 0 && schemeRange.location != NSNotFound) {
        schema = [webrtcUrl substringToIndex:schemeRange.location];
    }
    ret.schema = schema;

    // ---- 等价于 js 里 replace("webrtc://","http://") 后的 URL 解析：
    //      将任意 scheme 前缀替换为 http:// 后交给 NSURL 解析
    NSURL *a = nil;
    if (schemeRange.location != NSNotFound && schemeRange.location > 0) {
        NSString *replaced = [NSString stringWithFormat:@"http://%@",
                              [webrtcUrl substringFromIndex:schemeRange.location + 3]];
        a = [NSURL URLWithString:replaced];
    }
    if (!a) {
        return ret;
    }

    NSString *host = a.host ?: @"";
    NSString *path = a.path ?: @"";
    if (path.length == 0) {
        path = @"/";
    }

    // ---- app/stream：/app/stream -> app="app", stream="stream"
    //      （java: path.substring(1, path.lastIndexOf("/"))；此处对 "/stream" 等异常路径做安全兜底）
    NSRange lastSlash = [path rangeOfString:@"/" options:NSBackwardsSearch];
    NSString *app = @"";
    if (path.length > 1 && lastSlash.location != NSNotFound && lastSlash.location > 0) {
        app = [path substringWithRange:NSMakeRange(1, lastSlash.location - 1)];
    }
    NSString *stream = @"";
    if (lastSlash.location != NSNotFound) {
        stream = [path substringFromIndex:lastSlash.location + 1];
    }

    // ---- vhost 解析
    NSString *vhost = host;

    // 解析 app 中携带的 ...vhost... 参数（srs 特性）
    app = [app stringByReplacingOccurrencesOfString:@"...vhost..." withString:@"?vhost="];
    NSRange qRange = [app rangeOfString:@"?"];
    if (qRange.location != NSNotFound) {
        NSString *params = [app substringFromIndex:qRange.location];
        app = [app substringToIndex:qRange.location];
        NSRange vhr = [params rangeOfString:@"vhost="];
        if (vhr.location != NSNotFound && vhr.location > 0) {
            NSString *vh = [params substringFromIndex:vhr.location + vhr.length];
            NSRange amp = [vh rangeOfString:@"&"];
            if (amp.location != NSNotFound && amp.location > 0) {
                vh = [vh substringToIndex:amp.location];
            }
            vhost = vh;
        }
    }

    // server 为 ip 且未单独指定 vhost 时，默认 __defaultVhost__
    static NSPredicate *ipPred = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ipPred = [NSPredicate predicateWithFormat:@"SELF MATCHES %@",
                  @"^(\\d+)\\.(\\d+)\\.(\\d+)\\.(\\d+)$"];
    });
    if (host.length > 0 && [host isEqualToString:vhost] &&
        [ipPred evaluateWithObject:host]) {
        vhost = @"__defaultVhost__";
    }

    // ---- 端口推断（对齐 java：-1 表示未指定）
    NSInteger port = a.port.integerValue; // 未指定时为 0
    if (port <= 0) {
        if ([schema isEqualToString:@"webrtc"] &&
            [webrtcUrl hasPrefix:[NSString stringWithFormat:@"webrtc://%@:", host]]) {
            port = [webrtcUrl hasPrefix:[NSString stringWithFormat:@"webrtc://%@:80", host]] ? 80 : 443;
        } else if ([schema isEqualToString:@"http"]) {
            port = 80;
        } else if ([schema isEqualToString:@"https"]) {
            port = 443;
        } else if ([schema isEqualToString:@"rtmp"]) {
            port = 1935;
        }
    }

    ret.server = host;
    ret.port = port;
    ret.vhost = vhost;
    ret.app = app;
    ret.stream = stream;

    // ---- 查询参数（对齐 java getRawQuery 分割逻辑；缺失值以 @"" 代替 java 的 null）
    NSString *qs = a.query ?: @"";
    if (qs.length > 0) {
        for (NSString *elem in [qs componentsSeparatedByString:@"&"]) {
            if (elem.length == 0) {
                continue;
            }
            NSRange eq = [elem rangeOfString:@"="];
            NSString *k = (eq.location == NSNotFound) ? elem : [elem substringToIndex:eq.location];
            NSString *v = (eq.location == NSNotFound) ? @"" : [elem substringFromIndex:eq.location + 1];
            ret.query[k] = v;
            ret.userQuery[k] = v;
        }
        if (ret.query[@"domain"] != nil) {
            ret.vhost = ret.query[@"domain"];
        }
    }
    return ret;
}

+ (NSString *)buildApiUrl:(ELiveUrlResult *)r defaultProtocol:(NSString *)defaultProtocol {
    if (!r) {
        return @"";
    }

    // schema：user_query.schema 可覆盖默认协议
    NSString *schema = nil;
    if (r.userQuery[@"schema"] != nil) {
        schema = [r.userQuery[@"schema"] stringByAppendingString:@":"];
    } else {
        schema = (defaultProtocol.length > 0) ? defaultProtocol : @"http";
    }
    if (![schema hasSuffix:@":"]) {
        schema = [schema stringByAppendingString:@":"];
    }

    NSInteger port = r.port > 0 ? r.port : 1985;
    if ([schema isEqualToString:@"https:"]) {
        port = r.port > 0 ? r.port : 443;
    }

    // rtcdn-draft：publish 默认路径 /rtc/v1/publish/（user_query.play 可覆盖）
    NSString *api = (r.userQuery[@"play"] != nil) ? r.userQuery[@"play"] : @"/rtc/v1/publish/";
    if (![api hasSuffix:@"/"]) {
        api = [api stringByAppendingString:@"/"];
    }

    NSMutableString *apiUrl = [NSMutableString stringWithFormat:@"%@//%@:%ld%@",
                               schema, r.server ?: @"", (long)port, api];

    // 追加其余查询参数（跳过 api/play）
    BOOL first = YES;
    for (NSString *k in r.userQuery) {
        if ([k isEqualToString:@"api"] || [k isEqualToString:@"play"]) {
            continue;
        }
        NSString *v = r.userQuery[k] ?: @"";
        [apiUrl appendFormat:@"&%@=%@", k, v];
        first = NO;
    }
    if (!first) {
        // 将 /rtc/v1/publish/&k=v 修正为 /rtc/v1/publish/?k=v
        NSString *needle = [NSString stringWithFormat:@"%@&", api];
        NSRange idx = [apiUrl rangeOfString:needle];
        if (idx.location != NSNotFound) {
            return [apiUrl stringByReplacingCharactersInRange:idx
                                                   withString:[NSString stringWithFormat:@"%@?", api]];
        }
    }
    return apiUrl;
}

+ (BOOL)isWebrtcUrl:(NSString *)url {
    return url != nil && ([url hasPrefix:@"webrtc://"] || [url hasPrefix:@"rtc://"]);
}

+ (BOOL)isRtmpUrl:(NSString *)url {
    return url != nil && [url hasPrefix:@"rtmp://"];
}

@end
