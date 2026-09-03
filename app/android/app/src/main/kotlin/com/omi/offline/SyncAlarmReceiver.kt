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
        // RETIRED: the connect-settle alarm, action "com.omi.offline.SETTLE_NOTIFICATION"
        // at broadcast requestCode 1. It existed only to un-stick a stranded "Connecting…"
        // notification, and there is no longer such a transient to strand. Its manifest
        // <action> is gone too, so an alarm an older build left armed is simply not
        // delivered. Do not reuse the action string or requestCode 1 for a broadcast: a
        // one-shot PendingIntent from that older build could still be pending, and reusing
        // either would let it fire into whatever took its place.
        // A tight, backing-off reconnect alarm that runs only during a *confirmed*
        // outage — after native has paused its own retry loop (AUTONOMOUS_RETRY_STOP_AFTER)
        // and handed reconnection to the sync schedule. Without it, a wedge that clears
        // sits un-reconnected until the next sync alarm (up to one full sync interval).
        // Self-terminates once its step reaches the sync interval; see
        // OmiBleForegroundService.scheduleRecoveryProbe.
        private const val ACTION_RECOVER = "com.omi.offline.RECOVER_CONNECTION"

        fun pendingIntent(context: Context): PendingIntent {
            val intent = Intent(ACTION).setPackage(context.packageName)
            return PendingIntent.getBroadcast(
                context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun recoverPendingIntent(context: Context): PendingIntent {
            val intent = Intent(ACTION_RECOVER).setPackage(context.packageName)
            return PendingIntent.getBroadcast(
                context, 2, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        /// Arm (or cancel, at `timestampMs <= 0`) the periodic sync alarm.
        ///
        /// The single funnel for that alarm — DeviceProvider reaches it through
        /// `setNextSyncTime`, and the receiver's own re-arm below calls it directly — so it
        /// is also the right place to mirror the due-time to disk. `idleNotificationContent`
        /// reads it back to render "Next sync at H:MM" on a headless start, where nothing
        /// Dart-side has pushed a status yet. Persisting here rather than at the call sites
        /// is what makes the rendered time and the armed alarm unable to disagree.
        fun schedule(context: Context, timestampMs: Long) {
            val am = context.getSystemService(AlarmManager::class.java)
            val pi = pendingIntent(context)
            context.getSharedPreferences(OmiBleForegroundService.PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putLong(OmiBleForegroundService.PREFS_NEXT_SYNC_MS, if (timestampMs > 0) timestampMs else 0L)
                .apply()
            if (timestampMs > 0) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, timestampMs, pi)
                Log.d(TAG, "schedule: armed for ${java.util.Date(timestampMs)}")
            } else {
                am.cancel(pi)
                Log.d(TAG, "schedule: cancelled")
            }
        }

        /// Arm the Doze-exempt outage-recovery alarm. Re-arming collapses onto the
        /// single PendingIntent, so the service just pushes the next backed-off
        /// timestamp each firing (see OmiBleForegroundService.scheduleRecoveryProbe).
        fun scheduleRecover(context: Context, timestampMs: Long) {
            try {
                val am = context.getSystemService(AlarmManager::class.java)
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, timestampMs, recoverPendingIntent(context))
                Log.d(TAG, "scheduleRecover: armed for ${java.util.Date(timestampMs)}")
            } catch (e: Exception) {
                // Non-critical: the periodic sync alarm still drives reconnection, just slower.
                Log.w(TAG, "scheduleRecover: could not arm: ${e.message}")
            }
        }

        /// Cancel the outage-recovery alarm — the link is back, or recovery is no longer
        /// wanted (user disconnect / auto-sync off / self-terminated at the sync interval).
        fun cancelRecover(context: Context) {
            try {
                context.getSystemService(AlarmManager::class.java).cancel(recoverPendingIntent(context))
            } catch (e: Exception) {
                Log.w(TAG, "cancelRecover: ${e.message}")
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        // Outage-recovery alarm: drive a reconnect and re-arm the next backed-off step,
        // independent of the Flutter isolate. Runs in this broadcast's Doze-exempt wakelock
        // window, so it recovers a cleared wedge even when Dart is frozen. Unlike the sync
        // alarm it does NOT cold-start the service (`instance?.`): it's an optimization for the
        // common case where the service is alive (persistent during auto-sync), and only ever
        // runs after that service armed it. If the process was killed, the pending recovery
        // alarm no-ops here and the periodic sync alarm below is the reliable cold-start
        // backstop — so recovery gracefully degrades to the sync cadence rather than spinning
        // the whole FGS up every couple of minutes, which would undo the battery intent.
        if (intent.action == ACTION_RECOVER) {
            Log.d(TAG, "onReceive: recovery alarm fired")
            if (!OmiBleManager.isInitialized) {
                OmiBleManager.initialize(context.applicationContext as android.app.Application)
            }
            OmiBleForegroundService.instance?.onRecoveryProbeAlarm()
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

        // Resolved ONCE, and reused for both the skip decision and the delivery below, so
        // the two cannot disagree. Nothing between here and there can change it: onReceive
        // runs on the main thread and `dartReady` (the only writer of isFlutterAlive)
        // arrives on the same thread via MethodChannel.
        val flutterApi = if (OmiBleManager.isFlutterAlive) OmiBleManager.instance.flutterApi else null

        // No Dart, no cycle: every sync path is Dart-side, so this alarm will pull nothing.
        // Record it as a Skip in the same prefs Dart reads, BEFORE promoting the service —
        // on a cold start `startServicePersistent` runs onCreate, whose startForeground
        // renders from exactly these keys, and we want it to render this outcome rather
        // than the previous one.
        //
        // This replaces a settle that inferred the same thing from the notification saying
        // "Connecting…". Inferring it from the text needed native to have written that text
        // in the first place, which is what stranded the line; and it could only conclude
        // anything on the NEXT alarm, one full interval later. The signal here is direct and
        // lands on the cycle it describes.
        //
        // Writing flutter.* prefs from native is only safe with no live isolate to race, and
        // that is exactly the branch we are in. lastSyncCompletedMs is deliberately untouched
        // — nothing was pulled, and a skip must not push the schedule out (CLAUDE.md).
        if (flutterApi == null) {
            Log.i(TAG, "onReceive: Dart is not up — recording this cycle as a skip")
            prefs.edit()
                .putBoolean("flutter.lastSyncSkipped", true)
                .putLong("flutter.lastSyncStatusMs", System.currentTimeMillis())
                .apply()
        }

        // Promote the single foreground service NOW, from the exact-alarm context
        // where starting an FGS is exempt from the Android 12+ background-start
        // restriction. With the service already foreground, the subsequent Dart
        // setSyncStatus calls are just notification updates (never a refused cold
        // start). See gap #2 in the single-notification design.
        OmiBleForegroundService.startServicePersistent(context.applicationContext)

        // Refresh the resting line for a service that was ALREADY running (its onCreate ran
        // long ago, so the write above would otherwise not show until something else pushed).
        // Guarded by the same branch: with no Dart there is no sync in flight, so this cannot
        // clobber live "Syncing…"/"Processing…" progress. Unconditional here would.
        if (flutterApi == null) OmiBleForegroundService.instance?.renderIdleFromPrefs()

        // Drive a native reconnect from this Doze-exempt alarm window, independent of
        // the Flutter isolate. Native pauses its own retry loop once an outage is
        // confirmed (AUTONOMOUS_RETRY_STOP_AFTER), so if Dart is frozen/dead this is
        // the only thing that re-triggers the connect until the user opens the app.
        // Idempotent: no-ops if already connected or the user disconnected. When the
        // service was cold-started just above, `instance` isn't set yet — that path is
        // covered by onStartCommand's persistent restore.
        OmiBleForegroundService.instance?.ensureManagedReconnectFromAlarm()

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
