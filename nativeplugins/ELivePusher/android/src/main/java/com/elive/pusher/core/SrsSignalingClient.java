package com.elive.pusher.core;

import com.alibaba.fastjson.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.Charset;

/**
 * SRS(rtcdn-draft) 信令客户端。
 * 复刻项目 hybrid/html/srsRtcClient.js 的 publish 流程：
 * 1. POST {apiBase}/stream/publish（后端代理，带 authorization token）；
 *    body: { api: <SRS信令API>, tid, streamurl, clientip: null, sdp: <offer.sdp> }
 * 2. 后端返回 { code: 0, sdp: <answer.sdp> }。
 * 若未配置 apiBase（直连模式），则直接 POST 到解析出的 SRS 信令 API 地址。
 */
public final class SrsSignalingClient {

    public interface Callback {
        void onSuccess(String answerSdp);

        void onError(String message);
    }

    private SrsSignalingClient() {
    }

    /**
     * @param confUrl    原始 webrtc:// 推流地址
     * @param offerSdp   本端 offer SDP
     * @param apiBase    业务后端地址（如 https://api.xxx.com），为空则直连 SRS
     * @param token      业务后端鉴权 token（authorization 头）
     * @param apiProtocol 直连时信令 API 的协议（http/https），默认 http
     * @param callback   结果回调（网络线程执行）
     */
    public static void publish(final String confUrl, final String offerSdp,
                               final String apiBase, final String token,
                               final String apiProtocol, final Callback callback) {
        Thread t = new Thread(() -> {
            HttpURLConnection conn = null;
            try {
                UrlParser.Result r = UrlParser.parse(confUrl);
                String srsApiUrl = UrlParser.buildApiUrl(r, apiProtocol == null ? "http" : apiProtocol);

                String postUrl;
                if (apiBase != null && apiBase.trim().length() > 0) {
                    String base = apiBase.trim();
                    if (base.endsWith("/")) {
                        base = base.substring(0, base.length() - 1);
                    }
                    postUrl = base + "/stream/publish";
                } else {
                    postUrl = srsApiUrl;
                }

                JSONObject body = new JSONObject();
                body.put("api", srsApiUrl);
                body.put("tid", String.valueOf(Long.toHexString((long) (System.currentTimeMillis() * Math.random() * 100))));
                body.put("streamurl", confUrl);
                body.put("clientip", null);
                body.put("sdp", offerSdp);

                byte[] payload = body.toJSONString().getBytes(Charset.forName("UTF-8"));
                conn = (HttpURLConnection) new URL(postUrl).openConnection();
                conn.setRequestMethod("POST");
                conn.setConnectTimeout(10000);
                conn.setReadTimeout(10000);
                conn.setDoOutput(true);
                conn.setRequestProperty("Content-Type", "application/json");
                if (token != null && token.trim().length() > 0) {
                    conn.setRequestProperty("authorization", token.trim());
                }
                OutputStream os = conn.getOutputStream();
                os.write(payload);
                os.flush();
                os.close();

                int status = conn.getResponseCode();
                InputStream is = status >= 400 ? conn.getErrorStream() : conn.getInputStream();
                StringBuilder sb = new StringBuilder();
                if (is != null) {
                    BufferedReader reader = new BufferedReader(new InputStreamReader(is, Charset.forName("UTF-8")));
                    String line;
                    while ((line = reader.readLine()) != null) {
                        sb.append(line);
                    }
                    reader.close();
                }
                String respText = sb.toString();
                if (status != 200 && status != 201) {
                    callback.onError("signaling http " + status + ": " + respText);
                    return;
                }
                JSONObject resp = JSONObject.parseObject(respText);
                if (resp == null) {
                    callback.onError("signaling empty response");
                    return;
                }
                Integer code = resp.getInteger("code");
                String sdp = resp.getString("sdp");
                // 与 js 保持一致：data.code 非空非 0 视为失败
                if (code != null && code != 0) {
                    callback.onError("signaling code=" + code);
                    return;
                }
                if (sdp == null || sdp.length() == 0) {
                    callback.onError("signaling no sdp in response");
                    return;
                }
                callback.onSuccess(sdp);
            } catch (Exception e) {
                callback.onError("signaling error: " + e.getMessage());
            } finally {
                if (conn != null) {
                    try {
                        conn.disconnect();
                    } catch (Exception ignore) {
                    }
                }
            }
        }, "elive-srs-signaling");
        t.start();
    }
}
