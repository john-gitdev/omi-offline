package com.omi.offline

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log

class SyncAlarmReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "OmiBle.SyncAlarm"
        private const val ACTION = "com.omi.offline.SYNC_ALARM"

        fun pendingIntent(context: Context): PendingIntent {
            val intent = Intent(ACTION).setPackage(context.packageName)
            return PendingIntent.getBroadcast(
                context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        fun schedule(context: Context, timestampMs: Long) {
            val am = context.getSystemService(AlarmManager::class.java)
            val pi = pendingIntent(context)
            if (timestampMs > 0) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, timestampMs, pi)
                Log.d(TAG, "schedule: armed for ${java.util.Date(timestampMs)}")
            } else {
                am.cancel(pi)
                Log.d(TAG, "schedule: cancelled")
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        Log.d(TAG, "onReceive: alarm fired")

        // Re-arm for next cycle. Dart will call setNextSyncTime again after the
        // sync completes, which overwrites this with the exact post-sync timestamp
        // (FLAG_UPDATE_CURRENT). This re-arm only fires if Dart is frozen and
        // can't make that call.
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val intervalMinutes = prefs.getLong("flutter.backgroundSyncIntervalMinutes", 30L).toInt()
        if (intervalMinutes > 0) {
            val nextMs = System.currentTimeMillis() + intervalMinutes * 60_000L
            schedule(context, nextMs)
        }

        if (!OmiBleManager.isInitialized) {
            OmiBleManager.initialize(context.applicationContext as android.app.Application)
        }

        // Promote the single foreground service NOW, from the exact-alarm context
        // where starting an FGS is exempt from the Android 12+ background-start
        // restriction. With the service already foreground, the subsequent Dart
        // setSyncStatus calls are just notification updates (never a refused cold
        // start). See gap #2 in the single-notification design.
        OmiBleForegroundService.startServicePersistent(context.applicationContext)

        val flutterApi = OmiBleManager.instance.flutterApi
        if (flutterApi != null) {
            Handler(Looper.getMainLooper()).post {
                flutterApi.onBackgroundSyncRequested {}
            }
            Log.d(TAG, "onReceive: delivered to Dart")
        } else {
            Log.d(TAG, "onReceive: Flutter engine not running — sync deferred to next app open")
        }
    }
}
