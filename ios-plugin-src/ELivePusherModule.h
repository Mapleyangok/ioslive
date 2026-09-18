//
//  ELivePusherModule.h
//  ELivePusher
//
//  推流模块（uni.requireNativePlugin('ELivePusher-Module')）。
//  方法签名与 uni.createLivePusherContext 的 context 方法对齐：
//  init / startPreview / start / stop / pause / resume / switchCamera /
//  snapshot / stopPreview / close / setUrl / registerEvents / destroy
//
//  所有异步方法均可携带一个回调函数参数，回调参数形如 { code: 0, msg: 'ok', ... }。
//  行为对齐 Android 端 ELivePusherModule.java。
//

#import "DCUniModule.h"

NS_ASSUME_NONNULL_BEGIN

@interface ELivePusherModule : DCUniModule

@end

NS_ASSUME_NONNULL_END
