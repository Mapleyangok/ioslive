package com.elive.pusher;

import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.ViewGroup;

import com.alibaba.fastjson.JSONObject;
import com.elive.pusher.core.ICorePusher;
import com.elive.pusher.core.RtmpPusher;
import com.elive.pusher.core.SrsSignalingClient;
import com.elive.pusher.core.SrsWebRtcPusher;
import com.elive.pusher.core.StateCodes;
import com.elive.pusher.core.UrlParser;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import io.dcloud.feature.uniapp.bridge.UniJSCallback;

/**
 * 推流管理器：模块（ELivePusherModule）与组件（ELivePusherComponent）的桥接层。
 * - 组件把渲染容器注册进来（按 pusherId）；
 * - 模块的操作方法按 pusherId 找到对应推流核心执行；
 * - 推流核心的事件统一转发给 JS（registerEvents 注册的长连接回调）。
 */
public final class PusherManager {

    public static class Entry {
        public String pusherId;
        public JSONObject config = new JSONObject();
        public ICorePusher core;
        public ELivePusherComponent viewComp;
        public UniJSCallback eventCallback;
        public boolean pendingPreview = false;
        public boolean destroyed = false;
    }

    public interface ActionCallback {
        void onResult(boolean ok, String msg);
    }

    private static final PusherManager INSTANCE = new PusherManager();
    private final Map<String, Entry> entries = new ConcurrentHashMap<>();
    private final Handler main = new Handler(Looper.getMainLooper());

    private PusherManager() {
    }

    public static PusherManager getInstance() {
        return INSTANCE;
    }

    // ------------------------------------------------------------------ entry

    private Entry getOrCreate(String pusherId) {
        String id = pusherId == null || pusherId.length() == 0 ? "livePusher" : pusherId;
        synchronized (entries) {
            Entry e = entries.get(id);
            if (e == null) {
                e = new Entry();
                e.pusherId = id;
                entries.put(id, e);
            }
            return e;
        }
    }

    public Entry get(String pusherId) {
        String id = pusherId == null || pusherId.length() == 0 ? "livePusher" : pusherId;
        return entries.get(id);
    }

    private synchronized void ensureCore(Entry e) {
        if (e.core != null) {
            return;
        }
        String url = e.config.getString("url");
        Context ctx = e.viewComp != null ? e.viewComp.getApplicationContext() : null;
        if (ctx == null) {
            return;
        }
        SrsWebRtcPusher.PusherEvents events = (name, detail) -> fireEntryEvent(e, name, detail);
        if (UrlParser.isRtmpUrl(url)) {
            e.core = new RtmpPusher(ctx, events);
        } else {
            // webrtc:// / rtc:// / 空地址（先预览后设置地址）默认走 WebRTC
            e.core = new SrsWebRtcPusher(ctx, events);
        }
        if (e.pendingPreview && e.viewComp != null) {
            final ICorePusher core = e.core;
            final JSONObject cfg = e.config;
            final ViewGroup container = e.viewComp.getContainer();
            main.post(() -> core.startPreview(container, cfg));
            e.pendingPreview = false;
        }
    }

    // ------------------------------------------------------------------ view

    public void attachView(String pusherId, ELivePusherComponent comp) {
        Entry e = getOrCreate(pusherId);
        e.viewComp = comp;
        if (e.core != null && comp.getContainer() != null) {
            e.core.reattach(comp.getContainer());
        }
    }

    public void detachView(String pusherId, ELivePusherComponent comp) {
        Entry e = get(pusherId);
        if (e != null && e.viewComp == comp) {
            e.viewComp = null;
        }
    }

    public void setMirror(String pusherId, boolean mirror) {
        Entry e = get(pusherId);
        if (e == null) {
            return;
        }
        e.config.put("mirror", mirror);
    }

    // ----------------------------------------------------------------- events

    public void registerEvents(String pusherId, UniJSCallback callback) {
        Entry e = getOrCreate(pusherId);
        e.eventCallback = callback;
    }

    private void fireEntryEvent(Entry e, String name, Object detail) {
        UniJSCallback cb = e.eventCallback;
        if (cb != null) {
            JSONObject payload = new JSONObject();
            payload.put("event", name);
            payload.put("detail", detail);
            try {
                cb.invokeAndKeepAlive(payload);
            } catch (Exception ignore) {
            }
        }
    }

    // ------------------------------------------------------------------- api

    public void init(String pusherId, JSONObject options, ActionCallback cb) {
        final Entry e = getOrCreate(pusherId);
        if (options != null) {
            e.config.putAll(options);
        }
        main.post(() -> {
            synchronized (e) {
                ensureCore(e);
            }
            if (e.core == null) {
                cb.onResult(false, "组件尚未挂载，无法创建推流核心");
            } else {
                cb.onResult(true, "ok");
            }
        });
    }

    public void setUrl(String pusherId, String url, ActionCallback cb) {
        final Entry e = getOrCreate(pusherId);
        e.config.put("url", url);
        if (e.core == null) {
            main.post(() -> {
                synchronized (e) {
                    ensureCore(e);
                }
                cb.onResult(e.core != null, e.core != null ? "ok" : "组件尚未挂载");
            });
        } else {
            // 协议变化时重建核心
            String newUrl = url;
            boolean isRtmp = UrlParser.isRtmpUrl(newUrl);
            boolean coreIsRtmp = e.core instanceof RtmpPusher;
            if (e.core.isPushing()) {
                e.core.stop();
            }
            if (isRtmp != coreIsRtmp) {
                e.core.destroy();
                synchronized (e) {
                    e.core = null;
                    ensureCore(e);
                }
            }
            cb.onResult(e.core != null, e.core != null ? "ok" : "组件尚未挂载");
        }
    }

    public void startPreview(String pusherId, JSONObject options, ActionCallback cb) {
        final Entry e = getOrCreate(pusherId);
        if (options != null) {
            e.config.putAll(options);
        }
        main.post(() -> {
            if (e.viewComp == null) {
                e.pendingPreview = true;
                cb.onResult(true, "等待组件挂载后自动开启预览");
                return;
            }
            ensureCore(e);
            if (e.core == null) {
                cb.onResult(false, "无法创建推流核心");
                return;
            }
            Activity activity = e.viewComp.getActivity();
            if (needRequestPermissions(activity)) {
                e.viewComp.requestPushPermissions(granted -> {
                    if (granted) {
                        main.post(() -> {
                            e.core.startPreview(e.viewComp.getContainer(), e.config);
                            cb.onResult(true, "ok");
                        });
                    } else {
                        fireEntryEvent(e, StateCodes.EVENT_ERROR, err("摄像头/麦克风权限被拒绝", StateCodes.CAMERA_FAILED));
                        cb.onResult(false, "权限被拒绝");
                    }
                });
            } else {
                e.core.startPreview(e.viewComp.getContainer(), e.config);
                cb.onResult(true, "ok");
            }
        });
    }

    public void start(String pusherId, JSONObject options, ActionCallback cb) {
        final Entry e = getOrCreate(pusherId);
        if (options != null && options.getString("url") != null) {
            e.config.put("url", options.getString("url"));
        }
        main.post(() -> {
            ensureCore(e);
            if (e.core == null) {
                cb.onResult(false, "推流核心未就绪");
                return;
            }
            e.core.start(e.config.getString("url"));
            cb.onResult(true, "ok");
        });
    }

    public void stop(String pusherId, ActionCallback cb) {
        final Entry e = get(pusherId);
        if (e != null && e.core != null) {
            e.core.stop();
        }
        cb.onResult(true, "ok");
    }

    public void pause(String pusherId, ActionCallback cb) {
        final Entry e = get(pusherId);
        if (e != null && e.core != null) {
            e.core.pause();
        }
        cb.onResult(true, "ok");
    }

    public void resume(String pusherId, ActionCallback cb) {
        final Entry e = get(pusherId);
        if (e != null && e.core != null) {
            e.core.resume();
        }
        cb.onResult(true, "ok");
    }

    public void switchCamera(String pusherId, ActionCallback cb) {
        final Entry e = getOrCreate(pusherId);
        String cur = e.config.getString("devicePosition");
        boolean toFront = !"back".equals(cur);
        e.config.put("devicePosition", toFront ? "front" : "back");
        main.post(() -> {
            ensureCore(e);
            if (e.core == null) {
                cb.onResult(false, "推流核心未就绪");
                return;
            }
            e.core.switchCamera(toFront);
            cb.onResult(true, toFront ? "front" : "back");
        });
    }

    public void snapshot(String pusherId, ICorePusher.SnapshotCallback cb) {
        final Entry e = get(pusherId);
        if (e != null && e.core != null) {
            e.core.snapshot(cb);
        } else {
            cb.onResult(null, "预览未开启");
        }
    }

    public void stopPreview(String pusherId, ActionCallback cb) {
        final Entry e = get(pusherId);
        if (e != null && e.core != null) {
            e.core.stopPreview();
        }
        cb.onResult(true, "ok");
    }

    public void destroy(String pusherId) {
        final Entry e = get(pusherId);
        if (e != null) {
            e.destroyed = true;
            if (e.core != null) {
                try {
                    e.core.destroy();
                } catch (Exception ignore) {
                }
                e.core = null;
            }
            e.viewComp = null;
            e.eventCallback = null;
            synchronized (entries) {
                entries.remove(e.pusherId);
            }
        }
    }

    // ----------------------------------------------------------- permissions

    private static final String[] PUSH_PERMISSIONS = new String[]{
            "android.permission.CAMERA",
            "android.permission.RECORD_AUDIO"
    };

    private boolean needRequestPermissions(Activity activity) {
        if (activity == null || Build.VERSION.SDK_INT < 23) {
            return false;
        }
        return activity.checkSelfPermission(PUSH_PERMISSIONS[0]) != PackageManager.PERMISSION_GRANTED
                || activity.checkSelfPermission(PUSH_PERMISSIONS[1]) != PackageManager.PERMISSION_GRANTED;
    }

    // ----------------------------------------------------------------- helper

    private JSONObject err(String msg, int code) {
        JSONObject d = new JSONObject();
        d.put("errMsg", msg);
        d.put("errCode", code);
        return d;
    }
}
