package com.myphone.app;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import android.util.Log;

/**
 * 开机自启：BOOT_COMPLETED 后若曾启用常驻且有登录态（token 在安全存储），
 * 则拉起 CallService 恢复"保持登录 + 来电唤醒"。
 *
 * 服务器配置由 Flutter ensureStarted 时经 CallService.persistServerConfig
 * 写入 SharedPreferences（myphone_config），开机时读取恢复。
 * token 存 flutter_secure_storage（EncryptedSharedPreferences）；读不到则跳过，
 * app 手动打开后会由 ensureStarted 自动拉起。
 */
public class BootReceiver extends BroadcastReceiver {
    private static final String TAG = "BootReceiver";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) return;

        // 常驻开关曾关闭则不恢复
        SharedPreferences prefs = context.getSharedPreferences("FlutterSecureStorage", Context.MODE_PRIVATE);
        if ("false".equals(prefs.getString("flutter.settings_resident", null))) {
            Log.d(TAG, "resident disabled, skip boot start");
            return;
        }

        // 尝试读 token（flutter_secure_storage 加密存储，可能读不到）
        String token = prefs.getString("flutter.auth_token", null);
        if (token == null || token.isEmpty()) {
            Log.d(TAG, "no token at boot, skip");
            return;
        }

        // 服务器配置（Flutter 写入的）
        SharedPreferences cfg = context.getSharedPreferences("myphone_config", Context.MODE_PRIVATE);
        String host = cfg.getString(CallService.PREF_HOST, null);
        int port = cfg.getInt(CallService.PREF_PORT, 8080);
        boolean useTls = cfg.getBoolean(CallService.PREF_TLS, false);
        if (host == null || host.isEmpty()) {
            Log.d(TAG, "no server config at boot, skip");
            return;
        }

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
