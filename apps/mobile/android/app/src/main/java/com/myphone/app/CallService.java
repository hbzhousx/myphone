package com.myphone.app;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.media.MediaPlayer;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.util.Log;

import org.json.JSONException;
import org.json.JSONObject;

import java.util.concurrent.TimeUnit;

import io.flutter.plugin.common.EventChannel;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;

/**
 * v0.4 常驻前台服务，独占信令 WebSocket。
 *
 * 定位：app 登录/进入拨号盘后由 Flutter 拉起（startForegroundService），
 * 上滑杀掉 UI（stopWithTask=false）后服务与进程仍存活，负责保持登录
 * （心跳 + 断线重连，WS 活着即服务端 presence 在线）与后续来电唤醒。
 *
 * 全链路只有这一条 WS：Flutter 永不自己建连，发送经 MethodChannel
 * （MainActivity 转发到本服务），接收经 EventChannel 推送。
 */
public class CallService extends Service {
    private static final String TAG = "CallService";
    public static final String EXTRA_TOKEN = "token";
    public static final String EXTRA_HOST = "host";
    public static final String EXTRA_PORT = "port";
    public static final String EXTRA_USE_TLS = "useTls";

    /** MainActivity 冷启动读到的来电 extras key。 */
    public static final String EXTRA_INCOMING_CALL_ID = "incoming_call_id";
    public static final String EXTRA_INCOMING_JSON = "incoming_call_json";

    /** 服务器配置持久化（BootReceiver 开机自启读取）。 */
    private static final String PREFS = "myphone_config";
    public static final String PREF_HOST = "server_host";
    public static final String PREF_PORT = "server_port";
    public static final String PREF_TLS = "server_tls";

    /** Flutter ensureStarted 时写入服务器配置，供开机自启恢复。 */
    public static void persistServerConfig(String host, int port, boolean useTls) {
        CallService svc = instance;
        if (svc == null) return;
        svc.getSharedPreferences(PREFS, MODE_PRIVATE)
            .edit()
            .putString(PREF_HOST, host)
            .putInt(PREF_PORT, port)
            .putBoolean(PREF_TLS, useTls)
            .apply();
    }

    private static final String CHANNEL_RESIDENT = "resident";
    private static final String CHANNEL_INCOMING = "incoming_call";
    private static final int NOTIF_ID_RESIDENT = 1001;
    private static final int NOTIF_ID_INCOMING = 1002;

    /** 来电全屏后，Flutter 未接管则响铃 X ms 自动挂断并回 busy。 */
    private static final long INCOMING_RING_TIMEOUT_MS = 30_000;
    /** Flutter 心跳间隔；超过 3 个周期未到则视为 app 进程已死。 */
    private static final long APP_HEARTBEAT_INTERVAL_MS = 10_000;
    private static final long APP_DEAD_AFTER_MS = 30_000;

    private static final String PING = "{\"type\":\"ping\"}";
    private static final long PING_INTERVAL_MS = 15_000;
    /** 断线重连退避：2s, 4s, 8s, 16s, 30s（与服务端 read 超时 60s 兼容）。 */
    private static final long[] RECONNECT_BACKOFF_MS = {
        2_000, 4_000, 8_000, 16_000, 30_000
    };

    /** 运行中的服务实例；null 表示未运行。 */
    private static CallService instance;
    /** Flutter 侧 EventChannel 的 sink；app 被杀时可能为 null。 */
    private static volatile EventChannel.EventSink eventSink;

    private final OkHttpClient client = new OkHttpClient.Builder()
        // OkHttp 自动应答服务端 ping；15s 客户端心跳见 pingTask。
        .pingInterval(15, TimeUnit.SECONDS)
        .build();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable pingTask = new Runnable() {
        @Override public void run() {
            if (!shuttingDown && socket != null) {
                try {
                    socket.send(PING);
                } catch (Exception ignored) {
                    // 连接已死，交由 WebSocketListener.onFailure 触发重连。
                }
            }
            handler.postDelayed(this, PING_INTERVAL_MS);
        }
    };

    private volatile boolean appActive;
    private long lastAppActiveTs;
    /** app 进程心跳看门狗：Flutter 心跳停止则 appActive 回落为 false。 */
    private final Runnable appWatchdog = new Runnable() {
        @Override public void run() {
            if (!shuttingDown
                && appActive
                && System.currentTimeMillis() - lastAppActiveTs > APP_DEAD_AFTER_MS) {
                appActive = false;
                Log.w(TAG, "flutter heartbeat lost, appActive=false");
            }
            handler.postDelayed(this, APP_HEARTBEAT_INTERVAL_MS);
        }
    };

    // 来电唤醒状态（app 后台/被杀时由本服务发起原生响铃 + 全屏）
    private MediaPlayer ringPlayer;
    private boolean incomingRingActive;
    private String ringCallId;
    private String ringFromUser;
    private String ringToUser;
    private String pendingOffer;
    private final Runnable ringTimeout = new Runnable() {
        @Override public void run() {
            if (!incomingRingActive) return;
            Log.d(TAG, "incoming ring timeout, sending busy");
            sendBusyFromService();
            stopIncomingRing();
        }
    };

    private String token;
    private String host;
    private int port;
    private boolean useTls;
    private WebSocket socket;
    private int reconnectAttempts;
    private boolean shuttingDown;

    // ---- 静态入口（MainActivity 转发 MethodChannel 调用） ----

    public static void setEventSink(EventChannel.EventSink sink) {
        eventSink = sink;
    }

    public static void setAppActive(boolean active) {
        CallService svc = instance;
        if (svc != null) {
            svc.appActive = active;
            svc.lastAppActiveTs = System.currentTimeMillis();
        }
    }

    /** Flutter 每 10s 心跳上报（M3）；超过看门狗阈值则 appActive 回落 false。 */
    public static void onHeartbeat() {
        CallService svc = instance;
        if (svc != null) svc.lastAppActiveTs = System.currentTimeMillis();
    }

    /** Flutter 启动完成/回前台时调用，立即重发挂起的来电 offer。 */
    public static void onActivityResumed() {
        CallService svc = instance;
        if (svc != null) {
            svc.appActive = true;
            svc.lastAppActiveTs = System.currentTimeMillis();
            svc.replayPendingIncoming();
        }
    }

    /** Flutter 上滑退出后再次进入 app（后台→前台）时调用。 */
    public static void onActivityBackToTask() {
        CallService svc = instance;
        if (svc != null) {
            svc.appActive = true;
            svc.lastAppActiveTs = System.currentTimeMillis();
            svc.replayPendingIncoming();
        }
    }

    public static void sendSignal(String json) {
        CallService svc = instance;
        if (svc == null || json == null) return;
        WebSocket ws = svc.socket;
        if (ws != null) {
            try {
                ws.send(json);
            } catch (Exception e) {
                Log.w(TAG, "send failed", e);
            }
        }
    }

    public static void logout() {
        CallService svc = instance;
        if (svc != null) svc.stopResident();
    }

    // ---- Service 生命周期 ----

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        createNotificationChannels();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // 重新拉起（START_STICKY / 重复登录）时配置可能更新。
        if (intent != null) {
            applyConfig(intent);
        }
        Notification notif = buildResidentNotification();
        if (Build.VERSION.SDK_INT >= 34) {
            // API34: phoneCall 类型仅限默认拨号器（需 MANAGE_OWN_CALLS/DIALER role）；
            // microphone 类型需 RECORD_AUDIO 运行时权限且常驻时显示 mic 图标。
            // 常驻保活 + 响铃用 mediaPlayback：纯 install-time 权限，无运行时校验。
            startForeground(NOTIF_ID_RESIDENT, notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
        } else {
            startForeground(NOTIF_ID_RESIDENT, notif);
        }
        handler.removeCallbacks(appWatchdog);
        handler.post(appWatchdog);
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        shuttingDown = true;
        stopIncomingRing();
        disconnect();
        handler.removeCallbacksAndMessages(null);
        instance = null;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    // ---- 连接管理 ----

    private void applyConfig(Intent intent) {
        String newToken = intent.getStringExtra(EXTRA_TOKEN);
        String newHost = intent.getStringExtra(EXTRA_HOST);
        if (newToken == null || newHost == null) return;
        int newPort = intent.getIntExtra(EXTRA_PORT, 8080);
        boolean newTls = intent.getBooleanExtra(EXTRA_USE_TLS, false);

        boolean changed = !newToken.equals(token)
            || !newHost.equals(host)
            || newPort != port
            || newTls != useTls;
        token = newToken;
        host = newHost;
        port = newPort;
        useTls = newTls;
        // 持久化服务器配置，供开机自启（BootReceiver）恢复。
        getSharedPreferences(PREFS, MODE_PRIVATE)
            .edit()
            .putString(PREF_HOST, host)
            .putInt(PREF_PORT, port)
            .putBoolean(PREF_TLS, useTls)
            .apply();

        // 配置更新（重新登录）时重建连接；已用同一配置则忽略。
        if (changed || socket == null) {
            reconnectAttempts = 0;
            reconnect();
        }
    }

    private String wsUrl() {
        String scheme = useTls ? "wss" : "ws";
        return scheme + "://" + host + ":" + port + "/ws?token=" + token;
    }

    private void reconnect() {
        if (shuttingDown || host == null || token == null) return;
        disconnect();
        Log.d(TAG, "connecting to " + host + ":" + port);
        Request request = new Request.Builder().url(wsUrl()).build();
        socket = client.newWebSocket(request, wsListener);
        reconnectAttempts++;
        handler.postDelayed(pingTask, PING_INTERVAL_MS);
    }

    private void disconnect() {
        WebSocket ws = socket;
        socket = null;
        if (ws != null) {
            try {
                ws.close(1000, "bye");
            } catch (Exception ignored) {
            }
        }
        handler.removeCallbacks(pingTask);
    }

    private void scheduleReconnect() {
        if (shuttingDown) return;
        int idx = Math.min(reconnectAttempts, RECONNECT_BACKOFF_MS.length - 1);
        long delay = RECONNECT_BACKOFF_MS[idx];
        Log.d(TAG, "ws closed, reconnect in " + delay + "ms (attempt " + reconnectAttempts + ")");
        handler.postDelayed(new Runnable() {
            @Override public void run() {
                if (!shuttingDown) reconnect();
            }
        }, delay);
    }

    private void stopResident() {
        shuttingDown = true;
        stopIncomingRing();
        disconnect();
        stopForeground(true);
        stopSelf();
    }

    // ---- WebSocket ----

    private final WebSocketListener wsListener = new WebSocketListener() {
        @Override
        public void onOpen(WebSocket ws, Response response) {
            Log.d(TAG, "ws connected");
            reconnectAttempts = 0;
        }

        @Override
        public void onMessage(WebSocket ws, String text) {
            // OkHttp 回调在 OkHttp 线程；EventChannel/通知都必须在主线程。
            handler.post(() -> onMessageMain(text));
        }

        @Override
        public void onFailure(WebSocket ws, Throwable t, Response response) {
            Log.w(TAG, "ws failure: " + t);
            socket = null;
            scheduleReconnect();
        }

        @Override
        public void onClosed(WebSocket ws, int code, String reason) {
            Log.d(TAG, "ws closed: " + code + " " + reason);
            socket = null;
            scheduleReconnect();
        }
    };

    /** 主线程处理收到的信令：透传 Flutter + offer 检测。 */
    private void onMessageMain(String text) {
        EventChannel.EventSink sink = eventSink;
        if (sink != null) {
            try {
                sink.success(text);
            } catch (Exception e) {
                Log.w(TAG, "push to flutter failed", e);
            }
        }
        try {
            JSONObject msg = new JSONObject(text);
            String type = msg.optString("type");
            if ("offer".equals(type)) {
                onOfferReceived(msg);
            } else if (("hangup".equals(type) || "answer".equals(type) || "busy".equals(type))
                    && incomingRingActive
                    && msg.optString("call_id", "").equals(ringCallId)) {
                // 对端已挂断/已接：停响铃、清 pending，交由 Flutter 处理。
                stopIncomingRing();
                pendingOffer = null;
            }
        } catch (JSONException ignored) {
        }
    }

    // ---- 来电唤醒（M2） ----

    /** app 后台/被杀时，原生响铃 + 全屏来电 + 注入 offer。 */
    private void onOfferReceived(JSONObject msg) {
        String callId = msg.optString("call_id", "");
        String from = msg.optString("from_user_id", "");
        String to = msg.optString("to_user_id", "");
        if (callId.isEmpty() || from.isEmpty() || to.isEmpty()) return;

        // 已在本服务响铃的同款来电：忽略（EventChannel 已透传，Flutter 负责去重）。
        if (incomingRingActive && callId.equals(ringCallId)) return;

        if (appActive) {
            // Flutter 前台已接管（EventChannel 已把 offer 推给它），无需原生 UI。
            Log.d(TAG, "offer (app active) call=" + callId + " -> flutter path");
            return;
        }
        Log.d(TAG, "offer (app inactive) call=" + callId + " -> native ring+fullscreen");

        // 后台/被杀：原生响铃 + 全屏 + 存 offer 供冷启动注入。
        startIncomingRing(callId, from, to);
        pendingOffer = msg.toString();
        postFullScreenIncoming(callId);
        scheduleRingTimeout();
    }

    private void startIncomingRing(String callId, String from, String to) {
        incomingRingActive = true;
        ringCallId = callId;
        ringFromUser = from;
        ringToUser = to;
        // 系统来电铃声
        try {
            Uri uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE);
            ringPlayer = MediaPlayer.create(getApplicationContext(), uri);
            if (ringPlayer != null) {
                ringPlayer.setLooping(true);
                ringPlayer.start();
            }
        } catch (Exception e) {
            Log.w(TAG, "ring start failed: " + e);
        }
        // 震动
        try {
            Vibrator v = (Vibrator) getSystemService(Context.VIBRATOR_SERVICE);
            if (v != null) {
                if (Build.VERSION.SDK_INT >= 26) {
                    v.vibrate(VibrationEffect.createWaveform(
                        new long[]{0, 500, 800, 500, 800}, 0));
                } else {
                    v.vibrate(new long[]{0, 500, 800, 500, 800}, 0);
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "vibrate failed: " + e);
        }
    }

    /** 后台/被杀时发送 busy（响铃超时或 Flutter 接管前 app 被拉起来又拒了）。 */
    private void sendBusyFromService() {
        if (ringToUser == null || ringFromUser == null || ringCallId == null) return;
        JSONObject busy = new JSONObject();
        try {
            busy.put("type", "busy")
                .put("call_id", ringCallId)
                .put("from_user_id", ringToUser)
                .put("to_user_id", ringFromUser);
        } catch (JSONException e) {
            return;
        }
        WebSocket ws = socket;
        if (ws != null) {
            try {
                ws.send(busy.toString());
            } catch (Exception e) {
                Log.w(TAG, "send busy failed", e);
            }
        }
    }

    private void stopIncomingRing() {
        incomingRingActive = false;
        ringCallId = null;
        ringFromUser = null;
        ringToUser = null;
        handler.removeCallbacks(ringTimeout);
        if (ringPlayer != null) {
            try {
                ringPlayer.stop();
            } catch (Exception ignored) {
            }
            ringPlayer.release();
            ringPlayer = null;
        }
        stopVibration();
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.cancel(NOTIF_ID_INCOMING);
    }

    private void stopVibration() {
        try {
            Vibrator v = (Vibrator) getSystemService(Context.VIBRATOR_SERVICE);
            if (v != null) v.cancel();
        } catch (Exception ignored) {
        }
    }

    private void scheduleRingTimeout() {
        handler.removeCallbacks(ringTimeout);
        handler.postDelayed(ringTimeout, INCOMING_RING_TIMEOUT_MS);
    }

    private void postFullScreenIncoming(String callId) {
        Intent fullScreen = new Intent(this, MainActivity.class);
        fullScreen.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        fullScreen.putExtra(EXTRA_INCOMING_CALL_ID, callId);
        fullScreen.putExtra(EXTRA_INCOMING_JSON, pendingOffer);
        PendingIntent pi = PendingIntent.getActivity(
            this, 0, fullScreen,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification.Builder b = Build.VERSION.SDK_INT >= 26
            ? new Notification.Builder(this, CHANNEL_INCOMING)
            : new Notification.Builder(this);
        b.setContentTitle("MyPhone 来电")
            .setContentText("接听")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setCategory(Notification.CATEGORY_CALL)
            .setContentIntent(pi)
            .setFullScreenIntent(pi, true)
            .setAutoCancel(true)
            .setPriority(Notification.PRIORITY_MAX);

        NotificationManager nm = getSystemService(NotificationManager.class);
        try {
            nm.notify(NOTIF_ID_INCOMING, b.build());
        } catch (Exception e) {
            Log.w(TAG, "incoming notif failed: " + e);
        }
    }

    /** Flutter 回前台/启动完成时：重新注入 pending 来电 offer 并停原生响铃。 */
    private void replayPendingIncoming() {
        if (!incomingRingActive) return;
        String json = pendingOffer;
        EventChannel.EventSink sink = eventSink;
        if (json != null && sink != null) {
            try {
                sink.success(json);
            } catch (Exception e) {
                Log.w(TAG, "replay offer failed: " + e);
            }
        }
        stopIncomingRing();
    }

    // ---- 通知 ----

    private void createNotificationChannels() {
        if (Build.VERSION.SDK_INT < 26) return;
        NotificationManager nm = getSystemService(NotificationManager.class);
        NotificationChannel resident = new NotificationChannel(
            CHANNEL_RESIDENT, "常驻服务", NotificationManager.IMPORTANCE_LOW);
        resident.setDescription("保持来电在线");
        resident.setShowBadge(false);
        nm.createNotificationChannel(resident);
        NotificationChannel incoming = new NotificationChannel(
            CHANNEL_INCOMING, "来电", NotificationManager.IMPORTANCE_HIGH);
        incoming.setDescription("来电响铃与全屏");
        incoming.setBypassDnd(true);
        incoming.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
        nm.createNotificationChannel(incoming);
    }

    private Notification buildResidentNotification() {
        Notification.Builder b;
        if (Build.VERSION.SDK_INT >= 26) {
            b = new Notification.Builder(this, CHANNEL_RESIDENT);
        } else {
            b = new Notification.Builder(this);
        }
        return b
            .setContentTitle("MyPhone")
            .setContentText("正在运行，保持来电在线")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setPriority(Notification.PRIORITY_MIN)
            .build();
    }
}
