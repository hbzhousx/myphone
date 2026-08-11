package com.myphone.app;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import android.util.Log;

/**
 * 开机自启：BOOT_COMPLETED 后恢复"保持登录 + 来电唤醒"。
 *
 * 读取 CallService 持久化的 myphone_config（host/port/tls/token/resident_enabled）：
 * - 用户关闭常驻或登出（resident_enabled=false）→ 跳过；
 * - 无 token → 跳过（app 手动打开后 ensureStarted 会自动拉起）。
 */
public class BootReceiver extends BroadcastReceiver {
    private static final String TAG = "BootReceiver";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) return;

        // 用户关闭常驻或登出则不恢复
        if (!CallService.isResidentEnabled(context)) {
            Log.d(TAG, "resident disabled, skip boot start");
            return;
        }

        SharedPreferences cfg = context.getSharedPreferences("myphone_config", Context.MODE_PRIVATE);
        String token = cfg.getString(CallService.PREF_TOKEN, null);
        String host = cfg.getString(CallService.PREF_HOST, null);
        if (token == null || token.isEmpty() || host == null || host.isEmpty()) {
            Log.d(TAG, "no token/config at boot, skip (app will re-inject on open)");
            return;
        }
        int port = cfg.getInt(CallService.PREF_PORT, 8080);
        boolean useTls = cfg.getBoolean(CallService.PREF_TLS, false);

        Intent svc = new Intent(context, CallService.class);
        svc.putExtra(CallService.EXTRA_TOKEN, token);
        svc.putExtra(CallService.EXTRA_HOST, host);
        svc.putExtra(CallService.EXTRA_PORT, port);
        svc.putExtra(CallService.EXTRA_USE_TLS, useTls);
        if (Build.VERSION.SDK_INT >= 26) {
            context.startForegroundService(svc);
        } else {
            context.startService(svc);
        }
        Log.d(TAG, "boot start CallService requested (host=" + host + ")");
    }
}
