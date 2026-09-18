package com.elive.pusher.core;

import android.content.Context;
import android.graphics.Bitmap;
import android.os.Handler;
import android.os.Looper;
import android.view.TextureView;
import android.view.ViewGroup;
import android.widget.FrameLayout;

import com.alibaba.fastjson.JSONObject;
import com.pedro.common.ConnectChecker;
import com.pedro.encoder.input.gl.render.filters.BeautyFilterRender;
import com.pedro.encoder.input.sources.audio.MicrophoneSource;
import com.pedro.encoder.input.sources.video.Camera2Source;
import com.pedro.encoder.input.video.CameraHelper;
import com.pedro.library.generic.GenericStream;

import java.io.File;
import java.io.FileOutputStream;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * RTMP 推流核心（rtmp:// 地址），基于 RootEncoder 2.8.1。
 *
 * 与 2.8.1 源码核对过的 API 约定：
 * - prepareVideo(width, height, bitrateBps, fps, iFrameInterval, rotation)：rotation=90 时
 *   编码器实际输出 (height x width)，因此竖屏目标分辨率 targetW x targetH 需要传
 *   (targetH, targetW, ..., rotation=90)，摄像头按横向缓冲采集后由 GL 旋转。
 * - stopStream() 在预览开启(isOnPreview)时不会关闭摄像头，预览得以保留；
 *   且会自动重新 prepare 编码器，可直接再次 startStream。
 * - RTMP 协议无真正的“暂停”，pause() 采用断开连接（保留预览）实现，resume() 重新连接。
 * - 镜像通过 GlStreamInterface 的水平翻转实现（预览+推流同步）。
 * - 美颜通过 BeautyFilterRender 实现（无强度参数）；whiteness 不支持。
 */
public class RtmpPusher implements ICorePusher {

    private static final int AUDIO_SAMPLE_RATE = 44100;
    private static final int AUDIO_BITRATE_BPS = 96000;

    private final Context appContext;
    private final SrsWebRtcPusher.PusherEvents events;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService executor = Executors.newSingleThreadExecutor();

    private GenericStream stream;
    private Camera2Source camera2Source;
    private MicrophoneSource microphoneSource;
    private TextureView textureView;
    private ViewGroup container;

    // 配置
    private int targetWidth = 720;   // 竖屏目标分辨率（最终编码输出宽）
    private int targetHeight = 1280; // 竖屏目标分辨率（最终编码输出高）
    private int fps = 20;
    private int maxBitrateKbps = 1500;
    private int videoGopSec = 2;
    private boolean beauty = false;
    private boolean mirror = true;
    private boolean frontCamera = true;

    private String lastUrl;
    private boolean manualStopping = false;
    private volatile boolean destroyed = false;

    private final AtomicBoolean cameraStarted = new AtomicBoolean(false);

    public RtmpPusher(Context appContext, SrsWebRtcPusher.PusherEvents events) {
        this.appContext = appContext.getApplicationContext();
        this.events = events;
    }

    // ---------------------------------------------------------------- config

    private void applyConfig(JSONObject cfg) {
        if (cfg == null) {
            return;
        }
        String devicePosition = cfg.getString("devicePosition");
        if ("back".equals(devicePosition)) {
            frontCamera = false;
        }
        Boolean mirrorObj = cfg.getBoolean("mirror");
        if (mirrorObj != null) {
            mirror = mirrorObj;
        }
        Integer beautyObj = cfg.getInteger("beauty");
        if (beautyObj != null) {
            beauty = beautyObj > 0;
        }
        Integer maxBr = cfg.getInteger("maxBitrate");
        if (maxBr != null && maxBr > 0) {
            maxBitrateKbps = maxBr;
        }
        Integer gop = cfg.getInteger("videoGop");
        if (gop != null && gop > 0) {
            videoGopSec = gop;
        }
        Integer f = cfg.getInteger("fps");
        if (f != null && f > 0) {
            fps = f;
        }
        Integer w = cfg.getInteger("width");
        Integer h = cfg.getInteger("height");
        if (w != null && h != null && w > 0 && h > 0) {
            targetWidth = Math.min(w, h);
            targetHeight = Math.max(w, h);
        } else {
            // mode/aspect -> 分辨率（竖屏推流，与页面 aspect 3:4 / mode HD 对应）
            String mode = cfg.getString("mode");
            String aspect = cfg.getString("aspect");
            if ("3:4".equals(aspect)) {
                targetWidth = 720;
                targetHeight = 960;
            } else if ("9:16".equals(aspect)) {
                targetWidth = 720;
                targetHeight = 1280;
            } else if ("FHD".equals(mode)) {
                targetWidth = 1080;
                targetHeight = 1920;
            } else if ("SD".equals(mode)) {
                targetWidth = 540;
                targetHeight = 960;
            } else { // HD 默认
                targetWidth = 720;
                targetHeight = 1280;
            }
        }
    }

    // ------------------------------------------------------------- ICorePusher

    @Override
    public void startPreview(ViewGroup container, JSONObject cfg) {
        applyConfig(cfg);
        this.container = container;
        main.post(this::doStartPreview);
    }

    private void doStartPreview() {
        if (destroyed || container == null) {
            return;
        }
        try {
            // 每次预览都重建核心，保证状态干净（prepare 要求 stream/preview 均处于停止态）
            releaseStream();
            camera2Source = new Camera2Source(appContext);
            microphoneSource = new MicrophoneSource();
            // Camera2Source 默认后置；需要前置时先翻转（未运行时仅改变 facing）
            if (frontCamera && camera2Source.getCameraFacing() != CameraHelper.Facing.FRONT) {
                camera2Source.switchCamera();
            }

            final ConnectChecker checker = new ConnectChecker() {
                @Override
                public void onConnectionStarted(String url) {
                    emitState(StateCodes.CONNECT_SERVER, "连接服务器");
                }

                @Override
                public void onConnectionSuccess() {
                    emitState(StateCodes.HANDSHAKE_OK, "握手完成，开始推流");
                }

                @Override
                public void onConnectionFailed(String reason) {
                    if (manualStopping) {
                        return;
                    }
                    emitError("推流连接失败: " + reason, StateCodes.CONNECTION_LOST);
                }

                @Override
                public void onDisconnect() {
                    if (manualStopping) {
                        return;
                    }
                    emitState(StateCodes.CONNECTION_LOST, "连接中断");
                }

                @Override
                public void onAuthError() {
                    emitError("推流鉴权失败", -1);
                }

                @Override
                public void onAuthSuccess() {
                }

                @Override
                public void onNewBitrate(long bitrate) {
                    // RootEncoder 每秒回调一次总码率（bps）
                    JSONObject info = new JSONObject();
                    info.put("videoBitrate", (int) (bitrate / 1024));
                    info.put("audioBitrate", 0);
                    info.put("videoFPS", fps);
                    info.put("videoGOP", videoGopSec);
                    info.put("netSpeed", (int) (bitrate / 1024));
                    info.put("netJitter", 0);
                    info.put("videoWidth", targetWidth);
                    info.put("videoHeight", targetHeight);
                    events.onEvent(StateCodes.EVENT_NETSTATUS, info);
                }
            };

            stream = new GenericStream(appContext, checker, camera2Source, microphoneSource);

            // 竖屏：rotation=90 时编码器输出 (height x width)，故传 (targetH, targetW)
            boolean videoOk = stream.prepareVideo(targetHeight, targetWidth,
                    maxBitrateKbps * 1024, fps, videoGopSec, 90);
            boolean audioOk = stream.prepareAudio(AUDIO_SAMPLE_RATE, true, AUDIO_BITRATE_BPS);
            if (!videoOk) {
                emitError("视频编码器初始化失败", StateCodes.CAMERA_FAILED);
                return;
            }
            if (!audioOk) {
                emitError("音频编码器初始化失败", -1);
                return;
            }

            if (mirror) {
                stream.getGlInterface().setIsPreviewHorizontalFlip(true);
                stream.getGlInterface().setIsStreamHorizontalFlip(true);
            }
            if (beauty) {
                stream.getGlInterface().setFilter(new BeautyFilterRender());
            }

            TextureView tv = new TextureView(appContext);
            tv.setLayoutParams(new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
            container.addView(tv, 0, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
            textureView = tv;

            // autoHandle=true：surface 尚未就绪时自动等待（程序化创建的 TextureView 常见）
            stream.startPreview(tv, true);
            cameraStarted.set(true);
            emitState(StateCodes.CAMERA_STARTED, "摄像头已开启");
        } catch (Exception e) {
            emitError("预览失败: " + e.getMessage(), StateCodes.CAMERA_FAILED);
        }
    }

    @Override
    public void reattach(ViewGroup container) {
        main.post(() -> {
            if (destroyed || container == null) {
                return;
            }
            this.container = container;
            if (textureView != null && textureView.getParent() != container) {
                if (textureView.getParent() instanceof ViewGroup) {
                    ((ViewGroup) textureView.getParent()).removeView(textureView);
                }
                container.addView(textureView, new FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
            }
        });
    }

    @Override
    public void start(String pushUrl) {
        if (pushUrl != null && pushUrl.length() > 0) {
            lastUrl = pushUrl;
        }
        if (lastUrl == null || lastUrl.length() == 0) {
            emitError("推流地址为空", -1);
            return;
        }
        main.post(() -> {
            if (destroyed) {
                return;
            }
            try {
                if (stream == null || !stream.isOnPreview()) {
                    // 未开预览时先补齐预览（含 prepare），再推流
                    if (container == null) {
                        emitError("预览未开启，无法推流", -1);
                        return;
                    }
                    doStartPreview();
                }
                if (stream == null || stream.isStreaming()) {
                    return;
                }
                manualStopping = false;
                stream.startStream(lastUrl);
            } catch (Exception e) {
                emitError("推流失败: " + e.getMessage(), StateCodes.CONNECTION_LOST);
            }
        });
    }

    @Override
    public void stop() {
        main.post(() -> {
            if (destroyed || stream == null || !stream.isStreaming()) {
                return;
            }
            try {
                manualStopping = true;
                stream.stopStream(); // 预览保留（isOnPreview 时摄像头不关闭），编码器自动重新 prepare
            } catch (Exception ignore) {
            } finally {
                manualStopping = false;
            }
        });
    }

    @Override
    public void pause() {
        // RTMP 无协议级暂停：断开推流但保留预览，resume 时重新连接
        stop();
    }

    @Override
    public void resume() {
        main.post(() -> {
            if (destroyed || stream == null || stream.isStreaming()
                    || lastUrl == null || lastUrl.length() == 0) {
                return;
            }
            try {
                manualStopping = false;
                if (!stream.isOnPreview() && container != null) {
                    doStartPreview();
                }
                stream.startStream(lastUrl);
            } catch (Exception e) {
                emitError("恢复推流失败: " + e.getMessage(), StateCodes.CONNECTION_LOST);
            }
        });
    }

    @Override
    public void switchCamera(boolean front) {
        main.post(() -> {
            if (destroyed || stream == null || camera2Source == null) {
                return;
            }
            try {
                boolean currentFront = camera2Source.getCameraFacing() == CameraHelper.Facing.FRONT;
                if (front != currentFront) {
                    camera2Source.switchCamera();
                }
                frontCamera = front;
                emitState(StateCodes.CAMERA_STARTED, front ? "已切换到前置摄像头" : "已切换到后置摄像头");
            } catch (Exception e) {
                emitError("切换摄像头失败: " + e.getMessage(), StateCodes.CAMERA_FAILED);
            }
        });
    }

    @Override
    public void snapshot(SnapshotCallback callback) {
        main.post(() -> {
            if (destroyed || textureView == null || !textureView.isAvailable()) {
                callback.onResult(null, "预览未开启");
                return;
            }
            try {
                Bitmap bitmap = textureView.getBitmap();
                if (bitmap == null) {
                    callback.onResult(null, "截图失败");
                    return;
                }
                executor.execute(() -> {
                    File dir = appContext.getCacheDir();
                    File file = new File(dir, "elive_snapshot_" + System.currentTimeMillis() + ".jpg");
                    FileOutputStream fos = null;
                    try {
                        fos = new FileOutputStream(file);
                        bitmap.compress(Bitmap.CompressFormat.JPEG, 90, fos);
                        fos.flush();
                        callback.onResult(file.getAbsolutePath(), null);
                    } catch (Exception e) {
                        callback.onResult(null, "截图保存失败: " + e.getMessage());
                    } finally {
                        bitmap.recycle();
                        if (fos != null) {
                            try {
                                fos.close();
                            } catch (Exception ignore) {
                            }
                        }
                    }
                });
            } catch (Exception e) {
                callback.onResult(null, "截图失败: " + e.getMessage());
            }
        });
    }

    @Override
    public void stopPreview() {
        main.post(() -> {
            if (destroyed || stream == null || !stream.isOnPreview()) {
                return;
            }
            try {
                manualStopping = true;
                if (stream.isStreaming()) {
                    stream.stopStream();
                }
                stream.stopPreview();
                if (textureView != null && textureView.getParent() instanceof ViewGroup) {
                    ((ViewGroup) textureView.getParent()).removeView(textureView);
                }
                textureView = null;
                cameraStarted.set(false);
            } catch (Exception ignore) {
            } finally {
                manualStopping = false;
            }
        });
    }

    @Override
    public boolean isPushing() {
        return stream != null && stream.isStreaming();
    }

    @Override
    public void destroy() {
        main.post(() -> {
            destroyed = true;
            releaseStream();
            executor.shutdown();
        });
    }

    // ----------------------------------------------------------------- helper

    private void releaseStream() {
        if (stream == null) {
            return;
        }
        try {
            manualStopping = true;
            if (stream.isStreaming()) {
                stream.stopStream();
            }
            if (stream.isOnPreview()) {
                stream.stopPreview();
            }
        } catch (Exception ignore) {
        } finally {
            manualStopping = false;
        }
        if (textureView != null && textureView.getParent() instanceof ViewGroup) {
            ((ViewGroup) textureView.getParent()).removeView(textureView);
        }
        textureView = null;
        camera2Source = null;
        microphoneSource = null;
        stream = null;
        cameraStarted.set(false);
    }

    private void emitState(int code, String message) {
        if (events == null) {
            return;
        }
        JSONObject d = new JSONObject();
        d.put("code", code);
        d.put("message", message);
        events.onEvent(StateCodes.EVENT_STATECHANGE, d);
    }

    private void emitError(String errMsg, int errCode) {
        if (events == null) {
            return;
        }
        JSONObject e = new JSONObject();
        e.put("errMsg", errMsg);
        e.put("errCode", errCode);
        events.onEvent(StateCodes.EVENT_ERROR, e);
        // 同步 statechange 便于页面感知失败（与 live-pusher 行为对齐）
        JSONObject d = new JSONObject();
        d.put("code", errCode);
        d.put("message", errMsg);
        events.onEvent(StateCodes.EVENT_STATECHANGE, d);
    }
}
