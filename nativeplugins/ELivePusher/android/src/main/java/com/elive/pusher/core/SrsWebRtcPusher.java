package com.elive.pusher.core;

import android.content.Context;
import android.graphics.Bitmap;
import android.os.Handler;
import android.os.Looper;
import android.view.ViewGroup;
import android.widget.FrameLayout;

import com.alibaba.fastjson.JSONObject;

import org.webrtc.AudioSource;
import org.webrtc.AudioTrack;
import org.webrtc.Camera1Enumerator;
import org.webrtc.Camera2Enumerator;
import org.webrtc.CameraVideoCapturer;
import org.webrtc.DefaultVideoDecoderFactory;
import org.webrtc.DefaultVideoEncoderFactory;
import org.webrtc.EglBase;
import org.webrtc.IceCandidate;
import org.webrtc.MediaConstraints;
import org.webrtc.MediaStream;
import org.webrtc.MediaStreamTrack;
import org.webrtc.PeerConnection;
import org.webrtc.PeerConnectionFactory;
import org.webrtc.RTCStats;
import org.webrtc.RTCStatsReport;
import org.webrtc.RtpSender;
import org.webrtc.RtpParameters;
import org.webrtc.RtpReceiver;
import org.webrtc.RtpTransceiver;
import org.webrtc.SdpObserver;
import org.webrtc.SessionDescription;
import org.webrtc.SurfaceTextureHelper;
// stream-webrtc-android（getstream 重打包）不提供 TextureViewRenderer，使用 SurfaceViewRenderer
import org.webrtc.SurfaceViewRenderer;
import org.webrtc.VideoSource;
import org.webrtc.VideoTrack;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * SRS WebRTC 推流核心（webrtc:// 地址）。
 * 流程与项目 webview 内 srsRtcClient.js 完全一致：
 * getUserMedia(摄像头+麦克风) -> createOffer -> setLocalDescription ->
 * POST /stream/publish(后端代理) -> setRemoteDescription(answer)
 */
public class SrsWebRtcPusher implements ICorePusher {

    private static final String VIDEO_TRACK_ID = "elive_video0";
    private static final String AUDIO_TRACK_ID = "elive_audio0";
    private static final String STREAM_ID = "elive_stream";

    private final Context appContext;
    private final PusherEvents events;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService executor = Executors.newSingleThreadExecutor();

    private EglBase eglBase;
    private PeerConnectionFactory factory;
    private PeerConnection pc;
    private VideoSource videoSource;
    private AudioSource audioSource;
    private SurfaceTextureHelper surfaceHelper;
    private CameraVideoCapturer capturer;
    private VideoTrack videoTrack;
    private AudioTrack audioTrack;
    private SurfaceViewRenderer renderer;
    private ViewGroup container;

    private String url;
    private String apiBase = "";
    private String token = "";
    private String apiProtocol = "http";
    private boolean frontCamera = true;
    private boolean mirror = true;
    private int width = 720;
    private int height = 1280;
    private int fps = 20;
    private int maxBitrateKbps = 1500;
    private int minBitrateKbps = 300;

    private final AtomicBoolean cameraStarted = new AtomicBoolean(false);
    private final AtomicBoolean pushing = new AtomicBoolean(false);
    private final AtomicBoolean signaling = new AtomicBoolean(false);
    private volatile boolean destroyed = false;
    private volatile boolean firstFrameEmitted = false;
    private volatile boolean statsRunning = false;
    private long lastVideoBytes = 0;
    private long lastAudioBytes = 0;
    private long lastTs = 0;

    /** 事件回调（由 PusherManager 提供，转发到 JS） */
    public interface PusherEvents {
        void onEvent(String name, Object detail);
    }

    public SrsWebRtcPusher(Context appContext, PusherEvents events) {
        this.appContext = appContext.getApplicationContext();
        this.events = events;
    }

    // ---------------------------------------------------------------- config

    private void applyConfig(JSONObject cfg) {
        if (cfg == null) {
            return;
        }
        url = cfg.getString("url");
        String apiBaseStr = cfg.getString("apiBase");
        if (apiBaseStr != null) {
            apiBase = apiBaseStr;
        }
        String tokenStr = cfg.getString("token");
        if (tokenStr != null) {
            token = tokenStr;
        }
        String apiProtocolStr = cfg.getString("apiProtocol");
        if (apiProtocolStr != null && apiProtocolStr.length() > 0) {
            apiProtocol = apiProtocolStr;
        }
        String devicePosition = cfg.getString("devicePosition");
        if ("back".equals(devicePosition)) {
            frontCamera = false;
        }
        Boolean mirrorObj = cfg.getBoolean("mirror");
        if (mirrorObj != null) {
            mirror = mirrorObj;
        }
        Integer maxBr = cfg.getInteger("maxBitrate");
        if (maxBr != null && maxBr > 0) {
            maxBitrateKbps = maxBr;
        }
        Integer minBr = cfg.getInteger("minBitrate");
        if (minBr != null && minBr > 0) {
            minBitrateKbps = minBr;
        }
        Integer w = cfg.getInteger("width");
        Integer h = cfg.getInteger("height");
        Integer f = cfg.getInteger("fps");
        if (w != null && h != null && w > 0 && h > 0) {
            width = w;
            height = h;
        } else {
            // mode/aspect -> 分辨率（竖屏推流，与页面 aspect 3:4 / mode HD 对应）
            String mode = cfg.getString("mode");
            String aspect = cfg.getString("aspect");
            if ("3:4".equals(aspect)) {
                width = 720;
                height = 960;
            } else if ("9:16".equals(aspect)) {
                width = 720;
                height = 1280;
            } else if ("FHD".equals(mode)) {
                width = 1080;
                height = 1920;
            } else if ("SD".equals(mode)) {
                width = 540;
                height = 960;
            } else { // HD 默认
                width = 720;
                height = 1280;
            }
        }
        if (f != null && f > 0) {
            fps = f;
        }
    }

    // ------------------------------------------------------------- ICorePusher

    @Override
    public void startPreview(ViewGroup container, JSONObject cfg) {
        applyConfig(cfg);
        this.container = container;
        main.post(() -> {
            if (destroyed) {
                return;
            }
            try {
                ensureFactory();
                ensureRenderer(container);
                ensureCapturerAndTracks();
            } catch (Exception e) {
                emitError("预览失败: " + e.getMessage(), StateCodes.CAMERA_FAILED);
            }
        });
    }

    @Override
    public void reattach(ViewGroup container) {
        main.post(() -> {
            if (destroyed || container == null) {
                return;
            }
            this.container = container;
            if (renderer != null && renderer.getParent() != container) {
                if (renderer.getParent() instanceof ViewGroup) {
                    ((ViewGroup) renderer.getParent()).removeView(renderer);
                }
                container.addView(renderer, new FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
            }
        });
    }

    @Override
    public void start(String pushUrl) {
        if (pushUrl != null && pushUrl.length() > 0) {
            url = pushUrl;
        }
        if (url == null || url.length() == 0) {
            emitError("推流地址为空", -1);
            return;
        }
        if (!UrlParser.isWebrtcUrl(url)) {
            emitError("WebRTC 推流仅支持 webrtc:// 地址: " + url, -2);
            return;
        }
        if (signaling.compareAndSet(false, true)) {
            executor.execute(this::doStartPush);
        }
    }

    private void doStartPush() {
        try {
            ensurePc();
            // tracks 在预览阶段已创建；若尚未创建（未 startPreview 直接 start），此处补建
            main.post(() -> {
                try {
                    ensureCapturerAndTracks();
                    attachTracksAndOffer();
                } catch (Exception e) {
                    signaling.set(false);
                    emitError("推流失败: " + e.getMessage(), StateCodes.CAMERA_FAILED);
                }
            });
        } catch (Exception e) {
            signaling.set(false);
            emitError("创建 PeerConnection 失败: " + e.getMessage(), -3);
        }
    }

    private void attachTracksAndOffer() {
        if (pc == null || destroyed) {
            signaling.set(false);
            return;
        }
        try {
            if (videoTrack != null) {
                pc.addTrack(videoTrack, Collections.singletonList(STREAM_ID));
            }
            if (audioTrack != null) {
                pc.addTrack(audioTrack, Collections.singletonList(STREAM_ID));
            }
            applyBitrate();

            MediaConstraints constraints = new MediaConstraints();
            // getstream 版 webrtc：addMandatory 改为可变列表 mandatory/optional
            constraints.mandatory.add(new MediaConstraints.KeyValuePair("OfferToReceiveAudio", "false"));
            constraints.mandatory.add(new MediaConstraints.KeyValuePair("OfferToReceiveVideo", "false"));

            emitState(StateCodes.CONNECT_SERVER, "开始连接推流服务器");
            pc.createOffer(new SdpAdapter() {
                @Override
                public void onCreateSuccess(SessionDescription sdp) {
                    pc.setLocalDescription(new SdpAdapter() {
                        @Override
                        public void onSetSuccess() {
                            final String offerSdp = pc.getLocalDescription() != null
                                    ? pc.getLocalDescription().description : sdp.description;
                            SrsSignalingClient.publish(url, offerSdp, apiBase, token, apiProtocol,
                                    new SrsSignalingClient.Callback() {
                                        @Override
                                        public void onSuccess(String answerSdp) {
                                            main.post(() -> {
                                                if (pc != null && !destroyed) {
                                                    pc.setRemoteDescription(new SdpAdapter(),
                                                            new SessionDescription(SessionDescription.Type.ANSWER, answerSdp));
                                                    pushing.set(true);
                                                    startStatsLoop();
                                                }
                                                signaling.set(false);
                                            });
                                        }

                                        @Override
                                        public void onError(String message) {
                                            signaling.set(false);
                                            emitError(message, StateCodes.CONNECTION_LOST);
                                        }
                                    });
                        }
                    }, sdp);
                }

                @Override
                public void onCreateFailure(String error) {
                    signaling.set(false);
                    emitError("createOffer 失败: " + error, -4);
                }
            }, constraints);
        } catch (Exception e) {
            signaling.set(false);
            emitError("推流异常: " + e.getMessage(), -5);
        }
    }

    @Override
    public void stop() {
        main.post(() -> {
            pushing.set(false);
            statsRunning = false;
            firstFrameEmitted = false;
            if (pc != null) {
                try {
                    pc.close();
                } catch (Exception ignore) {
                }
                pc = null;
            }
        });
    }

    @Override
    public void pause() {
        main.post(() -> {
            if (videoTrack != null) {
                videoTrack.setEnabled(false);
            }
            if (audioTrack != null) {
                audioTrack.setEnabled(false);
            }
        });
    }

    @Override
    public void resume() {
        main.post(() -> {
            if (videoTrack != null) {
                videoTrack.setEnabled(true);
            }
            if (audioTrack != null) {
                audioTrack.setEnabled(true);
            }
        });
    }

    @Override
    public void switchCamera(boolean toFront) {
        main.post(() -> {
            if (capturer == null || destroyed) {
                return;
            }
            String deviceName = findDeviceName(toFront);
            if (deviceName == null) {
                emitError("未找到" + (toFront ? "前置" : "后置") + "摄像头", StateCodes.CAMERA_FAILED);
                return;
            }
            frontCamera = toFront;
            capturer.switchCamera(new CameraVideoCapturer.CameraSwitchHandler() {
                @Override
                public void onCameraSwitchDone(boolean isFrontCamera) {
                    emitState(StateCodes.CAMERA_STARTED, isFrontCamera ? "已切换到前置摄像头" : "已切换到后置摄像头");
                }

                @Override
                public void onCameraSwitchError(String errorDescription) {
                    frontCamera = !toFront;
                    emitError("切换摄像头失败: " + errorDescription, StateCodes.CAMERA_FAILED);
                }
            }, deviceName);
        });
    }

    @Override
    public void snapshot(SnapshotCallback callback) {
        main.post(() -> {
            if (renderer == null || destroyed) {
                callback.onResult(null, "预览未开启");
                return;
            }
            // getstream 版 webrtc 无 getBitmap()，改走 EglRenderer.FrameListener 回调帧
            renderer.addFrameListener(bmp -> {
                try {
                    if (bmp == null) {
                        callback.onResult(null, "截图失败：无画面");
                        return;
                    }
                    File dir = appContext.getCacheDir();
                    File out = new File(dir, "elive_snapshot_" + System.currentTimeMillis() + ".jpg");
                    FileOutputStream fos = new FileOutputStream(out);
                    bmp.compress(Bitmap.CompressFormat.JPEG, 90, fos);
                    fos.flush();
                    fos.close();
                    bmp.recycle();
                    callback.onResult(out.getAbsolutePath(), null);
                } catch (Exception e) {
                    callback.onResult(null, "截图失败: " + e.getMessage());
                }
            }, 1.0f);
        });
    }

    @Override
    public void stopPreview() {
        main.post(() -> {
            stopCaptureInternal();
        });
    }

    @Override
    public boolean isPushing() {
        return pushing.get();
    }

    @Override
    public void destroy() {
        main.post(() -> {
            destroyed = true;
            pushing.set(false);
            statsRunning = false;
            stopCaptureInternal();
            if (pc != null) {
                try {
                    pc.close();
                } catch (Exception ignore) {
                }
                try {
                    pc.dispose();
                } catch (Exception ignore) {
                }
                pc = null;
            }
            if (videoSource != null) {
                try {
                    videoSource.dispose();
                } catch (Exception ignore) {
                }
                videoSource = null;
            }
            if (audioSource != null) {
                try {
                    audioSource.dispose();
                } catch (Exception ignore) {
                }
                audioSource = null;
            }
            if (factory != null) {
                try {
                    factory.dispose();
                } catch (Exception ignore) {
                }
                factory = null;
            }
            if (renderer != null) {
                try {
                    renderer.release();
                } catch (Exception ignore) {
                }
                renderer = null;
            }
            if (eglBase != null) {
                try {
                    eglBase.release();
                } catch (Exception ignore) {
                }
                eglBase = null;
            }
        });
    }

    // ------------------------------------------------------------------ inner

    private synchronized void ensureFactory() {
        if (factory != null) {
            return;
        }
        PeerConnectionFactory.InitializationOptions initOptions =
                PeerConnectionFactory.InitializationOptions.builder(appContext)
                        .setEnableInternalTracer(false)
                        .createInitializationOptions();
        PeerConnectionFactory.initialize(initOptions);
        eglBase = EglBase.create();
        factory = PeerConnectionFactory.builder()
                .setVideoEncoderFactory(new DefaultVideoEncoderFactory(eglBase.getEglBaseContext(), true, true))
                .setVideoDecoderFactory(new DefaultVideoDecoderFactory(eglBase.getEglBaseContext()))
                .createPeerConnectionFactory();
    }

    private void ensureRenderer(ViewGroup container) {
        if (renderer != null && renderer.getParent() == container) {
            return;
        }
        if (renderer != null && renderer.getParent() instanceof ViewGroup) {
            ((ViewGroup) renderer.getParent()).removeView(renderer);
        }
        if (renderer == null) {
            renderer = new SurfaceViewRenderer(appContext);
            renderer.init(eglBase.getEglBaseContext(), null);
            renderer.setMirror(mirror);
        }
        container.addView(renderer, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
    }

    private synchronized void ensureCapturerAndTracks() {
        if (destroyed || factory == null) {
            return;
        }
        if (videoTrack == null) {
            videoSource = factory.createVideoSource(false);
            String deviceName = findDeviceName(frontCamera);
            if (deviceName == null) {
                emitError("未找到可用摄像头", StateCodes.CAMERA_FAILED);
                return;
            }
            CameraVideoCapturer c = createCapturer(deviceName);
            if (c == null) {
                emitError("创建摄像头采集失败", StateCodes.CAMERA_FAILED);
                return;
            }
            capturer = c;
            surfaceHelper = SurfaceTextureHelper.create("elive-capture", eglBase.getEglBaseContext());
            capturer.initialize(surfaceHelper, appContext, videoSource.getCapturerObserver());
            try {
                capturer.startCapture(width, height, fps);
            } catch (Exception e) {
                emitError("打开摄像头失败: " + e.getMessage(), StateCodes.CAMERA_FAILED);
                return;
            }
            videoTrack = factory.createVideoTrack(VIDEO_TRACK_ID, videoSource);
            cameraStarted.set(true);
            emitState(StateCodes.CAMERA_STARTED, "打开摄像头成功");
        }
        if (audioTrack == null) {
            audioSource = factory.createAudioSource(new MediaConstraints());
            audioTrack = factory.createAudioTrack(AUDIO_TRACK_ID, audioSource);
        }
    }

    private CameraVideoCapturer createCapturer(String deviceName) {
        Camera2Enumerator e2 = new Camera2Enumerator(appContext);
        if (e2.getDeviceNames().length > 0) {
            try {
                CameraVideoCapturer c = e2.createCapturer(deviceName, null);
                if (c != null) {
                    return c;
                }
            } catch (Exception ignore) {
            }
        }
        Camera1Enumerator e1 = new Camera1Enumerator(false);
        for (String name : e1.getDeviceNames()) {
            if (name.equals(deviceName)) {
                return e1.createCapturer(name, null);
            }
        }
        return null;
    }

    private String findDeviceName(boolean front) {
        Camera2Enumerator e2 = new Camera2Enumerator(appContext);
        for (String name : e2.getDeviceNames()) {
            if (front ? e2.isFrontFacing(name) : e2.isBackFacing(name)) {
                return name;
            }
        }
        Camera1Enumerator e1 = new Camera1Enumerator(false);
        for (String name : e1.getDeviceNames()) {
            if (front ? e1.isFrontFacing(name) : e1.isBackFacing(name)) {
                return name;
            }
        }
        return null;
    }

    private synchronized void ensurePc() {
        if (pc != null || factory == null) {
            return;
        }
        List<PeerConnection.IceServer> iceServers = Collections.singletonList(
                PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer());
        PeerConnection.RTCConfiguration config = new PeerConnection.RTCConfiguration(iceServers);
        config.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN;
        config.enableCpuOveruseDetection = false;
        pc = factory.createPeerConnection(config, new PeerConnectionObserverAdapter());
    }

    private void applyBitrate() {
        if (pc == null) {
            return;
        }
        for (RtpSender sender : pc.getSenders()) {
            if (sender.track() == null || sender.track().kind() != MediaStreamTrack.VIDEO_TRACK_KIND) {
                continue;
            }
            RtpParameters params = sender.getParameters();
            if (params.encodings != null && !params.encodings.isEmpty()) {
                params.encodings.get(0).maxBitrateBps = maxBitrateKbps * 1000;
                params.encodings.get(0).minBitrateBps = minBitrateKbps * 1000;
                try {
                    sender.setParameters(params);
                } catch (Exception ignore) {
                }
            }
        }
    }

    private void stopCaptureInternal() {
        if (capturer != null) {
            try {
                capturer.stopCapture();
            } catch (Exception ignore) {
            }
            try {
                capturer.dispose();
            } catch (Exception ignore) {
            }
            capturer = null;
        }
        if (surfaceHelper != null) {
            try {
                surfaceHelper.dispose();
            } catch (Exception ignore) {
            }
            surfaceHelper = null;
        }
        if (videoTrack != null) {
            try {
                videoTrack.dispose();
            } catch (Exception ignore) {
            }
            videoTrack = null;
        }
        if (audioTrack != null) {
            try {
                audioTrack.dispose();
            } catch (Exception ignore) {
            }
            audioTrack = null;
        }
        if (videoSource != null) {
            try {
                videoSource.dispose();
            } catch (Exception ignore) {
            }
            videoSource = null;
        }
        if (audioSource != null) {
            try {
                audioSource.dispose();
            } catch (Exception ignore) {
            }
            audioSource = null;
        }
        cameraStarted.set(false);
    }

    // ------------------------------------------------------------- stats loop

    private void startStatsLoop() {
        if (statsRunning) {
            return;
        }
        statsRunning = true;
        lastVideoBytes = 0;
        lastAudioBytes = 0;
        lastTs = 0;
        Runnable loop = new Runnable() {
            @Override
            public void run() {
                if (!statsRunning || pc == null || destroyed) {
                    return;
                }
                pc.getStats(report -> {
                    if (!statsRunning || destroyed) {
                        return;
                    }
                    long videoBytes = 0;
                    long audioBytes = 0;
                    double outFps = 0;
                    int outW = 0;
                    int outH = 0;
                    if (report != null) {
                        Map<String, RTCStats> statsMap = report.getStatsMap();
                        for (RTCStats stat : statsMap.values()) {
                            if (!"outbound-rtp".equals(stat.getType())) {
                                continue;
                            }
                            Map<String, Object> m = stat.getMembers();
                            String kind = m.get("kind") != null ? String.valueOf(m.get("kind"))
                                    : (m.get("mediaType") != null ? String.valueOf(m.get("mediaType")) : "");
                            Object bytes = m.get("bytesSent");
                            long b = bytes instanceof Number ? ((Number) bytes).longValue() : 0;
                            if ("video".equals(kind)) {
                                videoBytes = b;
                                Object f = m.get("framesPerSecond");
                                if (f instanceof Number) {
                                    outFps = ((Number) f).doubleValue();
                                }
                                Object w = m.get("frameWidth");
                                Object h = m.get("frameHeight");
                                if (w instanceof Number) {
                                    outW = ((Number) w).intValue();
                                }
                                if (h instanceof Number) {
                                    outH = ((Number) h).intValue();
                                }
                            } else if ("audio".equals(kind)) {
                                audioBytes = b;
                            }
                        }
                    }
                    long now = System.currentTimeMillis();
                    if (lastTs > 0) {
                        double sec = Math.max(0.001, (now - lastTs) / 1000.0);
                        long videoDelta = Math.max(0, videoBytes - lastVideoBytes);
                        long audioDelta = Math.max(0, audioBytes - lastAudioBytes);
                        JSONObject info = new JSONObject();
                        info.put("videoBitrate", (int) (videoDelta / sec / 1000));
                        info.put("audioBitrate", (int) (audioDelta / sec / 1000));
                        info.put("videoFPS", (int) outFps);
                        info.put("videoGOP", 0);
                        info.put("netSpeed", (int) ((videoDelta + audioDelta) / sec / 1000));
                        info.put("netJitter", 0);
                        info.put("videoWidth", outW);
                        info.put("videoHeight", outH);
                        events.onEvent(StateCodes.EVENT_NETSTATUS, info);
                        if (!firstFrameEmitted && videoBytes > 0) {
                            firstFrameEmitted = true;
                            emitState(StateCodes.VIDEO_ENCODE_OK, "视频推流中");
                        }
                    }
                    lastVideoBytes = videoBytes;
                    lastAudioBytes = audioBytes;
                    lastTs = now;
                });
                main.postDelayed(this, 1000);
            }
        };
        main.postDelayed(loop, 1000);
    }

    // ------------------------------------------------------------------ event

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

    // ---------------------------------------------------------------- adapters

    private static class SdpAdapter implements SdpObserver {
        @Override
        public void onCreateSuccess(SessionDescription sdp) {
        }

        @Override
        public void onSetSuccess() {
        }

        @Override
        public void onCreateFailure(String error) {
        }

        @Override
        public void onSetFailure(String error) {
        }
    }

    private class PeerConnectionObserverAdapter implements PeerConnection.Observer {
        @Override
        public void onSignalingChange(PeerConnection.SignalingState signalingState) {
        }

        @Override
        public void onIceConnectionChange(PeerConnection.IceConnectionState state) {
            if (destroyed) {
                return;
            }
            if (state == PeerConnection.IceConnectionState.CONNECTED
                    || state == PeerConnection.IceConnectionState.COMPLETED) {
                emitState(StateCodes.HANDSHAKE_OK, "推流已连接");
            } else if (state == PeerConnection.IceConnectionState.DISCONNECTED) {
                emitState(StateCodes.NETWORK_DISCONNECT, "推流网络不稳定/断开");
            } else if (state == PeerConnection.IceConnectionState.FAILED) {
                emitState(StateCodes.CONNECTION_LOST, "推流连接失败");
            }
        }

        @Override
        public void onIceConnectionReceivingChange(boolean b) {
        }

        @Override
        public void onIceGatheringChange(PeerConnection.IceGatheringState iceGatheringState) {
        }

        @Override
        public void onIceCandidate(IceCandidate iceCandidate) {
        }

        @Override
        public void onIceCandidatesRemoved(IceCandidate[] iceCandidates) {
        }

        @Override
        public void onAddStream(MediaStream mediaStream) {
        }

        @Override
        public void onRemoveStream(MediaStream mediaStream) {
        }

        @Override
        public void onDataChannel(org.webrtc.DataChannel dataChannel) {
        }

        @Override
        public void onRenegotiationNeeded() {
        }

        @Override
        public void onAddTrack(RtpReceiver rtpReceiver, MediaStream[] mediaStreams) {
        }

        @Override
        public void onTrack(RtpTransceiver rtpTransceiver) {
        }

        @Override
        public void onRemoveTrack(RtpReceiver rtpReceiver) {
        }
    }
}
