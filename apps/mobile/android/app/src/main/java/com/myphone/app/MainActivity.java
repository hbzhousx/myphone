package com.myphone.app;

import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import androidx.core.content.FileProvider;

import io.flutter.embedding.android.FlutterFragmentActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;

import java.io.File;

public class MainActivity extends FlutterFragmentActivity {
    private static final String CHANNEL_INSTALL = "myphone/install";
    private static final String CHANNEL_SERVICE = "myphone/service";
    private static final String CHANNEL_EVENTS = "myphone/service_events";

    /** 冷启动来电 extras（全屏唤醒时由 CallService 注入）；Flutter 读取后清除。 */
    private static volatile Intent pendingIncoming;

    @Override
    public void onCreate(android.os.Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        cacheIncomingExtras(getIntent());
    }

    @Override
    public void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        cacheIncomingExtras(intent);
        // 上滑退出后再次进入：通知服务 app 已回前台，重发挂起来电。
        CallService.onActivityBackToTask();
    }

    private void cacheIncomingExtras(Intent intent) {
        if (intent != null && intent.hasExtra(CallService.EXTRA_INCOMING_JSON)) {
            pendingIncoming = intent;
        }
    }

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        BinaryMessenger messenger = flutterEngine.getDartExecutor().getBinaryMessenger();

        new MethodChannel(messenger, CHANNEL_INSTALL)
            .setMethodCallHandler((call, result) -> {
                if ("installApk".equals(call.method)) {
                    String path = call.argument("path");
                    if (path == null) {
                        result.error("bad_args", "path is null", null);
                        return;
                    }
                    boolean ok = installApk(path);
                    result.success(ok);
                } else {
                    result.notImplemented();
                }
            });

        // v0.4 常驻服务：Flutter ↔ CallService 桥接
        new MethodChannel(messenger, CHANNEL_SERVICE)
            .setMethodCallHandler((call, result) -> {
                switch (call.method) {
                    case "startForegroundService": {
                        String token = call.argument("token");
                        String host = call.argument("host");
                        if (token == null || host == null) {
                            result.error("bad_args", "token/host required", null);
                            return;
                        }
                        int port = call.argument("port");
                        boolean useTls = Boolean.TRUE.equals(call.argument("useTls"));
                        Intent intent = new Intent(this, CallService.class);
                        intent.putExtra(CallService.EXTRA_TOKEN, token);
                        intent.putExtra(CallService.EXTRA_HOST, host);
                        intent.putExtra(CallService.EXTRA_PORT, port);
                        intent.putExtra(CallService.EXTRA_USE_TLS, useTls);
                        if (Build.VERSION.SDK_INT >= 26) {
                            startForegroundService(intent);
                        } else {
                            startService(intent);
                        }
                        // 持久化服务器配置 + 常驻开启标记，供开机自启（BootReceiver）恢复。
                        CallService.setResidentEnabled(true);
                        result.success(null);
                        break;
                    }
                    case "sendSignal": {
                        CallService.sendSignal(call.argument("signal"));
                        result.success(null);
                        break;
                    }
                    case "setAppActive": {
                        CallService.setAppActive(Boolean.TRUE.equals(call.argument("active")));
                        result.success(null);
                        break;
                    }
                    case "heartbeat": {
                        CallService.onHeartbeat();
                        result.success(null);
                        break;
                    }
                    case "appForegrounded": {
                        CallService.onActivityResumed();
                        result.success(null);
                        break;
                    }
                    case "getIncomingExtras": {
                        Intent inc = pendingIncoming;
                        if (inc == null) {
                            result.success(null);
                            break;
                        }
                        String callId = inc.getStringExtra(CallService.EXTRA_INCOMING_CALL_ID);
                        String json = inc.getStringExtra(CallService.EXTRA_INCOMING_JSON);
                        result.success(new java.util.HashMap<String, Object>() {{
                            put("callId", callId);
                            put("offerJson", json);
                        }});
                        break;
                    }
                    case "clearIncomingExtras": {
                        pendingIncoming = null;
                        result.success(null);
                        break;
                    }
                    case "logout": {
                        CallService.logout();
                        result.success(null);
                        break;
                    }
                    default:
                        result.notImplemented();
                }
            });

        new EventChannel(messenger, CHANNEL_EVENTS)
            .setStreamHandler(new EventChannel.StreamHandler() {
                @Override
                public void onListen(Object args, EventChannel.EventSink events) {
                    CallService.setEventSink(events);
                }

                @Override
                public void onCancel(Object args) {
                    CallService.setEventSink(null);
                }
            });

        // v0.4: 打开系统设置页（电池白名单引导）
        new MethodChannel(messenger, "myphone/system")
            .setMethodCallHandler((call, result) -> {
                if ("openSettings".equals(call.method)) {
                    String action = call.argument("action");
                    Intent intent = new Intent(action);
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    try {
                        startActivity(intent);
                        result.success(true);
                    } catch (Exception e) {
                        result.error("open_failed", e.getMessage(), null);
                    }
                } else {
                    result.notImplemented();
                }
            });
    }

    private boolean installApk(String path) {
        try {
            File apk = new File(path);
            Uri apkUri = FileProvider.getUriForFile(this, getPackageName() + ".fileprovider", apk);
            Intent intent = new Intent(Intent.ACTION_VIEW);
            intent.setDataAndType(apkUri, "application/vnd.android.package-archive");
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(intent);
            return true;
        } catch (Exception e) {
            android.util.Log.e("APK-INSTALL", "install failed: " + e.getMessage());
            return false;
        }
    }
}
