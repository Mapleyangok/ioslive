package com.elive.pusher.core;

/**
 * 与 uni-app 内置 live-pusher 对齐的状态码（参考 html5plus LivePusher statechange 定义），
 * 便于页面无感替换。
 */
public final class StateCodes {
    private StateCodes() {
    }

    /** 已连接推流服务器 */
    public static final int CONNECT_SERVER = 1001;
    /** 已经完成握手，开始推流 */
    public static final int HANDSHAKE_OK = 1002;
    /** 打开摄像头成功 */
    public static final int CAMERA_STARTED = 1003;
    /** 视频编码成功/首帧已发送 */
    public static final int VIDEO_ENCODE_OK = 2004;
    /** 打开摄像头失败 */
    public static final int CAMERA_FAILED = 3001;
    /** 推流过程中网络断开（会自动重连） */
    public static final int NETWORK_DISCONNECT = 3002;
    /** 连接中断 */
    public static final int CONNECTION_LOST = 3005;

    public static final String EVENT_STATECHANGE = "statechange";
    public static final String EVENT_NETSTATUS = "netstatus";
    public static final String EVENT_ERROR = "error";
}
