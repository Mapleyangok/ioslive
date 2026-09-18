//
//  ELivePusherComponent.m
//  ELivePusher
//
//  组件 API 已核对：
//  - DCUniComponent 的 view（UIView 宿主视图）为 DCloud 官方文档列出的属性
//    （nativesupport.dcloud.net.cn/NativePlugin/api/ios.html 的 DCUniComponent 属性表）；
//  - loadView / updateAttributes: 与同源基类 WXComponent 头文件
//    （apache/incubator-weex ios/sdk/WeexSDK/Sources/Model/WXComponent.h）逐一核对：
//    loadView 自定义实现"不应调用 super"（当前实现正确），
//    updateAttributes: 允许覆写并按惯例调用 super；
//  - 云打包接入后仍需真机验证组件整体渲染与属性更新时序。
//

#import "ELivePusherComponent.h"
#import "ELivePusherManager.h"

static NSString * const kDefaultPusherId = @"livePusher";

@implementation ELivePusherComponent {
    NSString *_pusherId;
}

#pragma mark - 生命周期

// 创建组件宿主视图（黑色背景容器，推流渲染视图将加入其中）
- (UIView *)loadView {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = [UIColor blackColor];
    view.clipsToBounds = YES;
    return view;
}

- (void)dealloc {
    if (_pusherId.length > 0) {
        [[ELivePusherManager sharedInstance] detachView:_pusherId component:self];
    }
}

#pragma mark - 属性更新

// 属性变更回调（nvue 模板上的 :attr 绑定更新时触发）
- (void)updateAttributes:(NSDictionary *)attributes {
    // 基类实现存在（WXComponent.h: - (void)updateAttributes:），覆写时按惯例先调 super
    [super updateAttributes:attributes];
    if (![attributes isKindOfClass:[NSDictionary class]] || attributes.count == 0) {
        return;
    }
    id pusherIdAttr = attributes[@"pusherId"];
    if (pusherIdAttr != nil) {
        NSString *pid = [NSString stringWithFormat:@"%@", pusherIdAttr];
        if (pid.length == 0 || [pid isEqualToString:@"(null)"] || [pid isEqualToString:@"<null>"]) {
            pid = kDefaultPusherId;
        }
        _pusherId = pid;
        [[ELivePusherManager sharedInstance] attachView:pid component:self];
    }
    id mirrorAttr = attributes[@"mirror"];
    if (mirrorAttr != nil && _pusherId.length > 0) {
        [[ELivePusherManager sharedInstance] setMirror:_pusherId mirror:[self asBoolean:mirrorAttr]];
    }
}

#pragma mark - 访问器

- (UIView *)containerView {
    // view 为组件宿主视图（DCloud 官方文档属性表确认；访问时懒加载触发 loadView）
    return self.view;
}

#pragma mark - helper

- (BOOL)asBoolean:(id)value {
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value boolValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)value lowercaseString];
        return [s isEqualToString:@"true"] || [s isEqualToString:@"1"] || [s isEqualToString:@"yes"];
    }
    return NO;
}

@end
