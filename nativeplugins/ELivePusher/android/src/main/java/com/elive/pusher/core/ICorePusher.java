package com.elive.pusher.core;

import android.view.ViewGroup;

import com.alibaba.fastjson.JSONObject;

/**
 * 推流核心接口：由 SrsWebRtcPusher（webrtc://）与 RtmpPusher（rtmp://）实现。
 * 所有方法应在主线程调用（内部自行处理线程切换）。
 */
public interface ICorePusher {

    interface SnapshotCallback {
        void onResult(String path, String error);
    }

    /**
     * 创建渲染视图并开启摄像头/麦克风预览。
     *
     * @param container 组件提供的容器（组件 hostView）
     * @param cfg       推流配置（url/mode/aspect/devicePosition/mirror/beauty/bitrate/gop/fps/resolution 等）
     */
    void startPreview(ViewGroup container, JSONObject cfg);

    /** 组件销毁重建后，将渲染视图重新挂到新的容器 */
    void reattach(ViewGroup container);

    /** 开始推流（复用 startPreview 创建的采集） */
    void start(String url);

    /** 停止推流，保留预览 */
    void stop();

    /** 暂停（保持连接，停发画面/声音） */
    void pause();

    /** 恢复 */
    void resume();

    /** 切换前后置摄像头，结果通过事件 statechange(1003) 通知 */
    void switchCamera(boolean front);

    /** 截图（临时文件路径通过回调返回） */
    void snapshot(SnapshotCallback callback);

    /** 停止摄像头预览 */
    void stopPreview();

    /** 是否正在推流 */
    boolean isPushing();

    /** 释放全部资源 */
    void destroy();
}
