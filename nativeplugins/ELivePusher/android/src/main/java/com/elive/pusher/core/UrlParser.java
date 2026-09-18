package com.elive.pusher.core;

import java.net.URI;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 复刻项目 hybrid/html/srsRtcClient.js 中 SrsRtcPublisherAsync.__internal.parse/prepareUrl 的逻辑，
 * 将 webrtc:// 地址解析为 SRS(rtcdn-draft) 信令 API 地址与原始流地址。
 */
public final class UrlParser {

    public static class Result {
        /** 原始完整地址（即 srsRtcClient 中的 urlObject.url / streamUrl） */
        public String url;
        public String schema;
        public String server;
        public int port = 0;
        public String vhost;
        public String app;
        public String stream;
        /** 查询参数（保持原顺序） */
        public Map<String, String> query = new LinkedHashMap<>();
        /** user_query */
        public Map<String, String> userQuery = new LinkedHashMap<>();
    }

    private UrlParser() {
    }

    /**
     * @param webrtcUrl 形如 webrtc://host[:port]/app/stream?k=v
     */
    public static Result parse(String webrtcUrl) {
        Result ret = new Result();
        ret.url = webrtcUrl;
        if (webrtcUrl == null) {
            return ret;
        }

        // schema
        String schema = "rtmp";
        int schemeIdx = webrtcUrl.indexOf("://");
        if (schemeIdx > 0) {
            schema = webrtcUrl.substring(0, schemeIdx);
        }
        ret.schema = schema;

        // 用 URI 解析（等价于 js 里 replace("webrtc://","http://") 后的 URL 解析）
        URI a;
        try {
            a = URI.create(webrtcUrl.replaceFirst("^(webrtc|rtc|rtmp)://", "http://"));
        } catch (Exception e) {
            return ret;
        }

        String vhost = a.getHost() == null ? "" : a.getHost();
        String path = a.getPath() == null ? "/" : a.getPath();
        String app = path.length() > 1 ? path.substring(1, path.lastIndexOf("/")) : "";
        String stream = path.contains("/") ? path.substring(path.lastIndexOf("/") + 1) : "";

        // 解析 app 中携带的 ...vhost... 参数（srs 特性）
        if (app.contains("...vhost...")) {
            app = app.replace("...vhost...", "?vhost=");
        }
        if (app.contains("?")) {
            String params = app.substring(app.indexOf("?"));
            app = app.substring(0, app.indexOf("?"));
            int vh = params.indexOf("vhost=");
            if (vh > 0) {
                vhost = params.substring(vh + "vhost=".length());
                int amp = vhost.indexOf("&");
                if (amp > 0) {
                    vhost = vhost.substring(0, amp);
                }
            }
        }

        // server 为 ip 时 vhost 默认 __defaultVhost__
        if (a.getHost() != null && a.getHost().equals(vhost) && a.getHost().matches("^(\\d+)\\.(\\d+)\\.(\\d+)\\.(\\d+)$")) {
            vhost = "__defaultVhost__";
        }

        // 端口推断
        int port = a.getPort(); // -1 表示未指定
        if (port <= 0) {
            if ("webrtc".equals(schema) && webrtcUrl.startsWith("webrtc://" + a.getHost() + ":")) {
                port = webrtcUrl.startsWith("webrtc://" + a.getHost() + ":80") ? 80 : 443;
            } else if ("http".equals(schema)) {
                port = 80;
            } else if ("https".equals(schema)) {
                port = 443;
            } else if ("rtmp".equals(schema)) {
                port = 1935;
            }
        }

        ret.server = a.getHost();
        ret.port = port;
        ret.vhost = vhost;
        ret.app = app;
        ret.stream = stream;

        // 查询参数
        String qs = a.getRawQuery();
        if (qs != null && qs.length() > 0) {
            for (String elem : qs.split("&")) {
                String[] kv = elem.split("=", 2);
                String k = kv[0];
                String v = kv.length > 1 ? kv[1] : null;
                ret.query.put(k, v);
                ret.userQuery.put(k, v);
            }
            if (ret.query.containsKey("domain")) {
                ret.vhost = ret.query.get("domain");
            }
        }
        return ret;
    }

    /**
     * 等价 srsRtcClient publish 的 prepareUrl：由 webrtc:// 地址生成信令 API 地址。
     * js 中 schema 取 window.location.protocol，原生无此概念，由 defaultProtocol 传入
     * （与推流页面 webview 所在协议保持一致，默认 http，可配置 https）。
     */
    public static String buildApiUrl(Result r, String defaultProtocol) {
        String schema = r.userQuery.containsKey("schema") && r.userQuery.get("schema") != null
                ? r.userQuery.get("schema") + ":" : defaultProtocol;
        if (!schema.endsWith(":")) {
            schema = schema + ":";
        }
        int port = r.port > 0 ? r.port : 1985;
        if ("https:".equals(schema)) {
            port = r.port > 0 ? r.port : 443;
        }

        // rtcdn-draft：publish 默认路径 /rtc/v1/publish/（与 srsRtcClient.js 一致，取 user_query.play 覆盖）
        String api = r.userQuery.containsKey("play") && r.userQuery.get("play") != null
                ? r.userQuery.get("play") : "/rtc/v1/publish/";
        if (!api.endsWith("/")) {
            api += "/";
        }

        StringBuilder apiUrl = new StringBuilder(schema).append("//").append(r.server).append(":").append(port).append(api);
        boolean first = true;
        for (Map.Entry<String, String> e : r.userQuery.entrySet()) {
            if ("api".equals(e.getKey()) || "play".equals(e.getKey())) {
                continue;
            }
            apiUrl.append("&").append(e.getKey()).append("=").append(e.getValue() == null ? "" : e.getValue());
            first = false;
        }
        if (!first) {
            // Replace /rtc/v1/publish/&k=v to /rtc/v1/publish/?k=v
            String s = apiUrl.toString();
            int idx = s.indexOf(api + "&");
            if (idx >= 0) {
                s = s.substring(0, idx) + api + "?" + s.substring(idx + (api + "&").length());
            }
            return s;
        }
        return apiUrl.toString();
    }

    /** 判断地址是否为 WebRTC（SRS）地址 */
    public static boolean isWebrtcUrl(String url) {
        return url != null && (url.startsWith("webrtc://") || url.startsWith("rtc://"));
    }

    /** 判断地址是否为 RTMP 地址 */
    public static boolean isRtmpUrl(String url) {
        return url != null && url.startsWith("rtmp://");
    }
}
