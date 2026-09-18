package com.elive.pusher;

import android.text.TextUtils;

import com.alibaba.fastjson.JSONObject;
import com.elive.pusher.core.ICorePusher;

import io.dcloud.feature.uniapp.annotation.UniJSMethod;
import io.dcloud.feature.uniapp.bridge.UniJSCallback;
import io.dcloud.feature.uniapp.common.UniModule;

/**
 * 推流模块（uni.requireNativePlugin('ELivePusher-Module')）。
 * 方法签名与 uni.createLivePusherContext 的 context 方法对齐：
 * init / startPreview / start / stop / pause / resume / switchCamera /
 * snapshot / stopPreview / close / setUrl / registerEvents / destroy
 *
 * 所有异步方法均可携带一个回调函数参数，回调参数形如 { code: 0, msg: 'ok', ... }。
 */
public class ELivePusherModule extends UniModule {

    private static String id(JSONObject options) {
        return options != null && !TextUtils.isEmpty(options.getString("pusherId"))
                ? options.getString("pusherId") : "livePusher";
    }

    private void done(UniJSCallback callback, boolean ok, String msg) {
        if (callback != null) {
            JSONObject ret = new JSONObject();
            ret.put("code", ok ? 0 : -1);
            ret.put("msg", msg == null ? (ok ? "ok" : "fail") : msg);
            callback.invoke(ret);
        }
    }

    /**
     * 初始化推流实例。options 支持：
     * pusherId, url, mode, aspect, beauty, whiteness, videoGop,
     * minBitrate, maxBitrate, devicePosition, mirror, width, height, fps,
     * apiBase(业务后端地址), token(authorization), apiProtocol(直连 SRS 信令协议, 默认 http)
     */
    @UniJSMethod(uiThread = true)
    public void init(JSONObject options, UniJSCallback callback) {
        PusherManager.getInstance().init(id(options), options,
                (ok, msg) -> done(callback, ok, msg));
    }

    /** 开启摄像头/麦克风预览（内部处理动态权限申请） */
    @UniJSMethod(uiThread = true)
    public void startPreview(JSONObject options, UniJSCallback callback) {
        PusherManager.getInstance().startPreview(id(options), options,
                (ok, msg) -> done(callback, ok, msg));
    }

    /** 开始推流。options 可覆盖 url */
    @UniJSMethod(uiThread = true)
    public void start(JSONObject options, UniJSCallback callback) {
        PusherManager.getInstance().start(id(options), options,
                (ok, msg) -> done(callback, ok, msg));
    }

    /** 停止推流（保留预览） */
    @UniJSMethod(uiThread = true)
    public void stop(JSONObject options, UniJSCallback callback) {
        PusherManager.getInstance().stop(id(options), (ok, msg) -> done(callback, ok, msg));
    }

    /** 暂停推流（保持连接，停发画面与声音） */
    @UniJSMethod(uiThread = true)
    public void pause(JSONObject options, UniJSCallback callback) {
        PusherManager.getInstance().pause(id(options), (ok, msg) -> done(callback, ok, msg));
    }

    /** 恢复推流 */
    @UniJSMethod(uiThread = true)
    public void resume(JSONObject options, UniJSCallback callback) {
        PusherManager.getInstance().resume(id(options), (ok, msg) -> done(callback, ok, msg));
    }

    /** 切换前后置摄像头 */
    @UniJSMethod(uiThread = true)
    public void switchCamera(JSONObject options, UniJSCallback callback) {
        PusherManager.getInstance().switchCamera(id(options), (ok, msg) -> {
            if (callback != null) {
                JSONObject ret = new JSONObject();
                ret.put("code", ok ? 0 : -1);
                ret.put("msg", msg);
                if (ok && ("front".equals(msg) || "back".equals(msg))) {
                    ret.put("devicePosition", msg);
                }
                callback.invoke(ret);
            }
        });
    }

    /** 截图，回调 { code: 0, path: '/.../xxx.jpg' } */
    @UniJSMethod(uiThread = true)
    public void snapshot(JSONObject options, UniJSCallback callback) {
        PusherManager.getInstance().snapshot(id(options), (path, error) -> {
            if (callback != null) {
                JSONObject ret = new JSONObject();
                ret.put("code", path != null ? 0 : -1);
                ret.put("msg", path != null ? "ok" : error);
                if (path != null) {
                    ret.put("path", path);
                }
                callback.invoke(ret);
            }
        });
    }

    /** 关闭摄像头预览 */
    @UniJSMethod(uiThread = true)
    public void stopPreview(JSONObject options, UniJSCallback callback) {
        PusherManager.getInstance().stopPreview(id(options), (ok, msg) -> done(callback, ok, msg));
    }

    /** 更新推流地址（协议变化时自动切换推流核心） */
    @UniJSMethod(uiThread = true)
    public void setUrl(JSONObject options, UniJSCallback callback) {
        if (options == null || TextUtils.isEmpty(options.getString("url"))) {
            done(callback, false, "url is empty");
            return;
        }
        PusherManager.getInstance().setUrl(id(options), options.getString("url"),
                (ok, msg) -> done(callback, ok, msg));
    }

    /**
     * 注册事件长连接回调（对应 live-pusher 的 @statechange/@netstatus/@error）。
     * 回调参数：{ event: 'statechange'|'netstatus'|'error', detail: {...} }
     */
    @UniJSMethod(uiThread = true)
    public void registerEvents(JSONObject options, UniJSCallback callback) {
        PusherManager.getInstance().registerEvents(id(options), callback);
    }

    /** 销毁推流实例（页面卸载时调用） */
    @UniJSMethod(uiThread = true)
    public void destroy(JSONObject options, UniJSCallback callback) {
        PusherManager.getInstance().destroy(id(options));
        done(callback, true, "ok");
    }

    /** 与 live-pusher.close 对齐：销毁实例 */
    @UniJSMethod(uiThread = true)
    public void close(JSONObject options, UniJSCallback callback) {
        PusherManager.getInstance().destroy(id(options));
        done(callback, true, "ok");
    }
}
