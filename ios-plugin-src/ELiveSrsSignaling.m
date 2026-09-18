//
//  ELiveSrsSignaling.m
//  ELivePusher
//

#import "ELiveSrsSignaling.h"
#import "ELiveUrlParser.h"

@implementation ELiveSrsSignaling

+ (void)publishWithUrl:(NSString *)confUrl
              offerSdp:(NSString *)offerSdp
               apiBase:(NSString *)apiBase
                 token:(NSString *)token
           apiProtocol:(NSString *)apiProtocol
            completion:(ELiveSignalingCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @try {
            ELiveUrlResult *r = [ELiveUrlParser parse:confUrl];
            NSString *srsApiUrl = [ELiveUrlParser buildApiUrl:r
                                             defaultProtocol:(apiProtocol.length > 0 ? apiProtocol : @"http")];

            NSString *postUrl;
            NSString *base = [apiBase stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (base.length > 0) {
                while ([base hasSuffix:@"/"]) {
                    base = [base substringToIndex:base.length - 1];
                }
                postUrl = [base stringByAppendingString:@"/stream/publish"];
            } else {
                postUrl = srsApiUrl;
            }

            // tid：7 位随机 hex（对齐 srsRtcClient.js 的
            // parseInt(new Date().getTime()*Math.random()*100).toString(16).slice(0,7) 长度）
            NSString *tid = [NSString stringWithFormat:@"%07x", arc4random_uniform(0x10000000)];

            NSDictionary *body = @{
                @"api"      : srsApiUrl ?: @"",
                @"tid"      : tid,
                @"streamurl": confUrl ?: @"",
                @"clientip" : [NSNull null],
                @"sdp"      : offerSdp ?: @"",
            };
            NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:postUrl]];
            request.HTTPMethod = @"POST";
            request.timeoutInterval = 10; // 对齐 java 的 10s 连接/读取超时
            request.HTTPBody = payload;
            [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            NSString *trimmedToken = [token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (trimmedToken.length > 0) {
                [request setValue:trimmedToken forHTTPHeaderField:@"authorization"];
            }

            __block NSString *respText = @"";
            __block NSInteger status = 0;
            __block NSError *httpError = nil;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                         completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                status = [((NSHTTPURLResponse *)response) statusCode];
                httpError = error;
                if (data) {
                    respText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
                }
                dispatch_semaphore_signal(sem);
            }];
            [task resume];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)));

            if (httpError) {
                if (completion) completion(nil, [NSString stringWithFormat:@"signaling error: %@", httpError.localizedDescription]);
                return;
            }
            if (status != 200 && status != 201) {
                if (completion) completion(nil, [NSString stringWithFormat:@"signaling http %ld: %@", (long)status, respText]);
                return;
            }
            NSData *jsonData = [respText dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *resp = jsonData ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil] : nil;
            if (![resp isKindOfClass:[NSDictionary class]]) {
                if (completion) completion(nil, @"signaling empty response");
                return;
            }
            // 与 js 保持一致：data.code 非空非 0 视为失败
            NSNumber *code = resp[@"code"] ? @(  [resp[@"code"] isKindOfClass:[NSNumber class]] ? [resp[@"code"] integerValue] : [NSString stringWithFormat:@"%@", resp[@"code"]].integerValue ) : nil;
            if (code != nil && code.integerValue != 0) {
                if (completion) completion(nil, [NSString stringWithFormat:@"signaling code=%ld", (long)code.integerValue]);
                return;
            }
            NSString *sdp = [resp[@"sdp"] isKindOfClass:[NSString class]] ? resp[@"sdp"] : nil;
            if (sdp.length == 0) {
                if (completion) completion(nil, @"signaling no sdp in response");
                return;
            }
            if (completion) completion(sdp, nil);
        } @catch (NSException *exception) {
            if (completion) completion(nil, [NSString stringWithFormat:@"signaling error: %@", exception.reason]);
        }
    });
}

@end
