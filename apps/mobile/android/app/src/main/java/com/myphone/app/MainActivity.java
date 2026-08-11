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
        // 冷启动（进程被杀后全屏拉起）：app 已在最前台，
        // 必须停原生响铃 + 重发挂起来电，否则"接听后仍响铃 + 超时断线"。
        CallService.onActivityBackToTask();
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
                    case "stopNativeRing": {
                        CallService.stopNativeRing();
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

        // v0.4: 电池白名单引导（方案A：检测状态 + 华为/vivo 专属路径）
        new MethodChannel(messenger, "myphone/system")
            .setMethodCallHandler((call, result) -> {
                switch (call.method) {
                    case "openBatterySettings": {
                        openBatterySettings(result);
                        break;
                    }
                    case "getBatteryStatus": {
                        java.util.HashMap<String, Object> status = new java.util.HashMap<>();
                        status.put("ignoringOptimization", isIgnoringBatteryOptimizations());
                        status.put("manufacturer", manufacturer());
                        result.success(status);
                        break;
                    }
                    default:
                        result.notImplemented();
                }
            });
    }

    /** 是否已加入"忽略电池优化"白名单。 */
    private boolean isIgnoringBatteryOptimizations() {
        try {
            android.os.PowerManager pm =
                (android.os.PowerManager) getSystemService(POWER_SERVICE);
            String pkg = getPackageName();
            return pm != null && pm.isIgnoringBatteryOptimizations(pkg);
        } catch (Exception e) {
            return false;
        }
    }

    /** 设备厂商（huawei/vivo/xiaomi/oppo 等）。 */
    private String manufacturer() {
        String m = android.os.Build.MANUFACTURER;
        return m == null ? "" : m.toLowerCase();
    }

    /** 打开电池白名单设置：优先厂商专属路径，fallback 通用"忽略电池优化"列表。 */
    private void openBatterySettings(MethodChannel.Result result) {
        String m = manufacturer();
        try {
            Intent intent = null;
            // 华为/荣耀：应用启动管理（自启动+后台弹窗管理）
            if (m.contains("huawei") || m.contains("honor")) {
                intent = new Intent("com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity");
            }
            // vivo/iQOO：自启动管理
            else if (m.contains("vivo") || m.contains("bbk") || m.contains("iqoo")) {
                intent = new Intent("com.vivo.permissionmanager.activity.BgStartUpManagerActivity");
            }
            // 小米/Redmi/POCO：自启动管理
            else if (m.contains("xiaomi") || m.contains("redmi") || m.contains("poco")) {
                intent = new Intent("miui.intent.action.OP_AUTO_START");
            }
            // OPPO/realme/一加/OPPO系：自启动 + 电池
            else if (m.contains("oppo") || m.contains("realme") || m.contains("oneplus")) {
                intent = new Intent("com.coloros.safecenter.startupapp.StartupAppListActivity");
            }
            // 三星：应用管理→电池
            else if (m.contains("samsung")) {
                intent = new Intent(android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
            }
            // 魅族：自启动管理
            else if (m.contains("meizu")) {
                intent = new Intent("com.meizu.safe.security.SHOW_APPSEC");
            }
            // 中兴/Nubia：自启动
            else if (m.contains("zte") || m.contains("nubia")) {
                intent = new Intent(android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
            }
            // 联想：电池优化
            else if (m.contains("lenovo") || m.contains("motorola")) {
                intent = new Intent(android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
            }
            // 其他：通用忽略电池优化列表
            if (intent == null) {
                intent = new Intent(android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
            }
            if (intent.getAction() == null) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            } else if ("miui.intent.action.OP_AUTO_START".equals(intent.getAction())) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            }
            startActivity(intent);
            result.success(true);
        } catch (Exception e) {
            // 专属路径不存在 → fallback 通用设置
            try {
                Intent generic = new Intent(
                    android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
                generic.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                startActivity(generic);
                result.success(true);
            } catch (Exception e2) {
                result.error("open_failed", e2.getMessage(), null);
            }
        }
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
