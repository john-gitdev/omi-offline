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
        // Separate action/requestCode so the settle alarm doesn't clobber the sync
        // alarm's PendingIntent. Settles a stranded "Connecting…" notification when
        // Dart can't (frozen/torn-down engine); see OmiBleForegroundService.
        private const val ACTION_SETTLE = "com.omi.offline.SETTLE_NOTIFICATION"

        fun pendingIntent(context: Context): PendingIntent {
            val intent = Intent(ACTION).setPackage(context.packageName)
            return PendingIntent.getBroadcast(
                context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun settlePendingIntent(context: Context): PendingIntent {
            val intent = Intent(ACTION_SETTLE).setPackage(context.packageName)
            return PendingIntent.getBroadcast(
                context, 1, intent,
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

        /// Arm a one-shot, Doze-exempt alarm to settle a stranded "Connecting…"
        /// notification. Re-arming collapses onto the single PendingIntent.
        fun scheduleSettle(context: Context, timestampMs: Long) {
            try {
                val am = context.getSystemService(AlarmManager::class.java)
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, timestampMs, settlePendingIntent(context))
                Log.d(TAG, "scheduleSettle: armed for ${java.util.Date(timestampMs)}")
            } catch (e: Exception) {
                // Non-critical recovery aid; the periodic sync alarm settles too.
                Log.w(TAG, "scheduleSettle: could not arm: ${e.message}")
            }
        }

        /// Cancel a pending settle alarm — the connect resolved (or moved on), so the
        /// notification is no longer a stranded "Connecting…". Avoids a spurious wake.
        fun cancelSettle(context: Context) {
            try {
                context.getSystemService(AlarmManager::class.java).cancel(settlePendingIntent(context))
            } catch (e: Exception) {
                Log.w(TAG, "cancelSettle: ${e.message}")
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        // Settle alarm: just un-stick a stranded "Connecting…" notification. Runs in
        // this broadcast's Doze-exempt wakelock window with no live isolate needed,
        // so it recovers the stuck notification even when Dart is frozen or gone.
        if (intent.action == ACTION_SETTLE) {
            Log.d(TAG, "onReceive: settle alarm fired")
            if (!OmiBleManager.isInitialized) {
                OmiBleManager.initialize(context.applicationContext as android.app.Application)
            }
            OmiBleForegroundService.instance?.settleStaleConnectingToIdle()
            return
        }
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

        // First, un-stick any "Connecting…" left stranded by a previous cycle whose
        // Dart never resolved it (also catches the cold-start default that the
        // dedicated settle alarm doesn't arm for). If Dart is alive it repaints
        // "Connecting…" for the new attempt right below, harmlessly overwriting this.
        OmiBleForegroundService.instance?.settleStaleConnectingToIdle()

        val flutterApi = if (OmiBleManager.isFlutterAlive) OmiBleManager.instance.flutterApi else null
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
