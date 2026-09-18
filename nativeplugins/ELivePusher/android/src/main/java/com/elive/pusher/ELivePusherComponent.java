package com.elive.pusher;

import android.app.Activity;
import android.content.Context;
import android.content.ContextWrapper;
import android.view.ViewGroup;
import android.widget.FrameLayout;

import androidx.annotation.NonNull;

import com.alibaba.fastjson.JSONObject;
import com.elive.pusher.core.ICorePusher;

import io.dcloud.feature.uniapp.annotation.UniComponentProp;
import io.dcloud.feature.uniapp.ui.component.UniComponent;

/**
 * 原生推流预览组件（对应 nvue 标签 <elive-pusher-view>）。
 * 仅负责承载原生渲染视图并处理权限申请；所有推流操作走 ELivePusher-Module。
 *
 * 属性：
 * - pusherId: 绑定的推流实例 id（与 module 调用保持一致，如 "livePusher"）
 * - mirror:   本地预览是否镜像
 */
public class ELivePusherComponent extends UniComponent<FrameLayout> {

    public interface PermissionResultCallback {
        void onResult(boolean granted);
    }

    private String pusherId;
    private PermissionResultCallback permissionCallback;
    private static final int PERMISSION_REQUEST_CODE = 0x4501;

    @Override
    protected FrameLayout initComponentHostView(@NonNull Context context) {
        FrameLayout container = new FrameLayout(context);
        return container;
    }

    @Override
    protected void onHostDestroy() {
        if (pusherId != null) {
            PusherManager.getInstance().detachView(pusherId, this);
        }
        super.onHostDestroy();
    }

    @UniComponentProp(name = "pusherId")
    public void setPusherId(String id) {
        pusherId = id == null || id.length() == 0 ? "livePusher" : id;
        PusherManager.getInstance().attachView(pusherId, this);
    }

    @UniComponentProp(name = "mirror")
    public void setMirror(Object value) {
        Boolean b = asBoolean(value);
        if (b != null && pusherId != null) {
            PusherManager.getInstance().setMirror(pusherId, b);
        }
    }

    public ViewGroup getContainer() {
        return getHostView();
    }

    public Context getApplicationContext() {
        Context c = mUniSDKInstance.getContext();
        return c != null ? c.getApplicationContext() : null;
    }

    public Activity getActivity() {
        Context c = mUniSDKInstance.getContext();
        while (c instanceof ContextWrapper) {
            if (c instanceof Activity) {
                return (Activity) c;
            }
            c = ((ContextWrapper) c).getBaseContext();
        }
        return null;
    }

    /** 向宿主 Activity 申请摄像头与麦克风权限（结果异步回调） */
    public void requestPushPermissions(PermissionResultCallback callback) {
        Activity activity = getActivity();
        if (activity == null) {
            if (callback != null) {
                callback.onResult(false);
            }
            return;
        }
        permissionCallback = callback;
        try {
            activity.requestPermissions(
                    new String[]{"android.permission.CAMERA", "android.permission.RECORD_AUDIO"},
                    PERMISSION_REQUEST_CODE);
        } catch (Exception e) {
            permissionCallback = null;
            if (callback != null) {
                callback.onResult(false);
            }
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode != PERMISSION_REQUEST_CODE) {
            return;
        }
        boolean granted = true;
        if (grantResults == null || grantResults.length == 0) {
            granted = false;
        } else {
            for (int r : grantResults) {
                if (r != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    granted = false;
                    break;
                }
            }
        }
        PermissionResultCallback cb = permissionCallback;
        permissionCallback = null;
        if (cb != null) {
            cb.onResult(granted);
        }
    }

    private static Boolean asBoolean(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Boolean) {
            return (Boolean) value;
        }
        if (value instanceof String) {
            return Boolean.parseBoolean((String) value);
        }
        if (value instanceof Number) {
            return ((Number) value).intValue() != 0;
        }
        return null;
    }
}
