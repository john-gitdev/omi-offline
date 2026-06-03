package com.omi.offline

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.*
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class BackgroundSyncWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {

    companion object {
        private const val TAG = "OmiBle.BgSync"
        private const val TASK_NAME = "omi.backgroundSync"
        private const val NOTIF_ID = 3001
        private const val NOTIF_CHANNEL_ID = "omi_bg_sync_channel"

        fun schedule(context: Context, intervalMinutes: Int) {
            val wm = WorkManager.getInstance(context.applicationContext)
            if (intervalMinutes <= 0) {
                wm.cancelUniqueWork(TASK_NAME)
                Log.d(TAG, "schedule: cancelled (Manual Only)")
                return
            }
            val periodMinutes = maxOf(15, intervalMinutes).toLong()
            val request = PeriodicWorkRequestBuilder<BackgroundSyncWorker>(periodMinutes, TimeUnit.MINUTES)
                .build()
            wm.enqueueUniquePeriodicWork(TASK_NAME, ExistingPeriodicWorkPolicy.UPDATE, request)
            Log.d(TAG, "schedule: registered period=${periodMinutes}min (requested=${intervalMinutes}min)")
        }

        // Called from MyApp.onCreate — reads the saved interval from FlutterSharedPreferences.
        fun scheduleFromPrefs(context: Context) {
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val intervalMinutes = prefs.getLong("flutter.backgroundSyncIntervalMinutes", 30L).toInt()
            schedule(context, intervalMinutes)
        }
    }

    override suspend fun doWork(): Result {
        val ctx = applicationContext
        val prefs = ctx.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

        val intervalMinutes = prefs.getLong("flutter.backgroundSyncIntervalMinutes", 30L).toInt()
        if (intervalMinutes <= 0) return Result.success()

        // Check if a sync is actually due before waking anything up.
        val lastSyncMs = prefs.getLong("flutter.lastSyncCompletedMs", 0L)
        val nowMs = System.currentTimeMillis()
        if (lastSyncMs > 0 && nowMs - lastSyncMs < intervalMinutes * 60_000L) {
            Log.d(TAG, "doWork: sync not due yet")
            return Result.success()
        }

        val btDeviceJson = prefs.getString("flutter.btDevice", "") ?: ""
        if (btDeviceJson.isBlank()) return Result.success()
        val deviceId = try { JSONObject(btDeviceJson).getString("id") } catch (e: Exception) { "" }
        if (deviceId.isBlank()) return Result.success()

        Log.d(TAG, "doWork: sync due for device=$deviceId")

        if (!OmiBleManager.isInitialized) OmiBleManager.initialize(ctx)
        val flutterApi = OmiBleManager.instance.flutterApi

        return if (flutterApi != null) {
            // Flutter engine is alive — deliver the sync request to Dart and let
            // DeviceProvider._onBackgroundSyncRequested handle the full pipeline.
            try {
                suspendCancellableCoroutine { cont ->
                    Handler(Looper.getMainLooper()).post {
                        flutterApi.onBackgroundSyncRequested { result ->
                            if (result.isSuccess) cont.resume(Unit)
                            else cont.resumeWithException(result.exceptionOrNull() ?: Exception("onBackgroundSyncRequested failed"))
                        }
                    }
                }
                Log.d(TAG, "doWork: onBackgroundSyncRequested delivered to Dart")
                Result.success()
            } catch (e: Exception) {
                Log.w(TAG, "doWork: failed to deliver to Dart: $e")
                Result.retry()
            }
        } else {
            // Flutter engine is not running (process was killed) — post a notification
            // so the user knows recordings are waiting and can open the app to sync.
            Log.d(TAG, "doWork: Flutter engine not running — posting sync notification")
            postSyncNotification(ctx)
            Result.success()
        }
    }

    private fun postSyncNotification(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(NOTIF_CHANNEL_ID, "Omi Background Sync", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        val pi = PendingIntent.getActivity(
            context, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notif = NotificationCompat.Builder(context, NOTIF_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_popup_sync)
            .setContentTitle("Omi Offline")
            .setContentText("Recordings ready to sync — tap to open")
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        nm.notify(NOTIF_ID, notif)
    }
}
