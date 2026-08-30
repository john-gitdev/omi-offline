package com.omi.offline

import android.content.Context
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

        // Check if a sync is actually due before waking anything up. Same rule as Dart's
        // _shouldSyncNow(), reading the same two prefs, because this worker is a peer of
        // the Dart timer and the exact alarm rather than a schedule of its own — its
        // period is only a floor (15 min minimum, fired inexactly), so "is it due" has to
        // come from lastSyncCompletedMs either way.
        //
        // lastSyncSkipped is part of that rule: a skip moved no data and deliberately
        // leaves lastSyncCompletedMs alone, so without this the worker reads the previous
        // *successful* sync's timestamp and reports "not due" for a full interval after a
        // sync that fetched nothing. Dart retries a skip at the next opportunity; so does
        // this now.
        val lastSyncMs = prefs.getLong("flutter.lastSyncCompletedMs", 0L)
        val lastSyncSkipped = prefs.getBoolean("flutter.lastSyncSkipped", false)
        val nowMs = System.currentTimeMillis()
        if (!lastSyncSkipped && lastSyncMs > 0 && nowMs - lastSyncMs < intervalMinutes * 60_000L) {
            Log.d(TAG, "doWork: sync not due yet")
            return Result.success()
        }

        val btDeviceJson = prefs.getString("flutter.btDevice", "") ?: ""
        if (btDeviceJson.isBlank()) return Result.success()
        val deviceId = try { JSONObject(btDeviceJson).getString("id") } catch (e: Exception) { "" }
        if (deviceId.isBlank()) return Result.success()

        Log.d(TAG, "doWork: sync due for device=$deviceId")

        if (!OmiBleManager.isInitialized) OmiBleManager.initialize(ctx as android.app.Application)

        // Promote the single foreground service so Dart's setSyncStatus updates an
        // existing notification rather than cold-starting one from the background.
        // Best-effort: if the OS refuses the start here (worker is a background
        // context), the exact-alarm path — scheduled for the same instant — is the
        // primary promoter. No-ops (just flags persistent) when already running.
        try {
            OmiBleForegroundService.startServicePersistent(ctx)
        } catch (e: Exception) {
            Log.w(TAG, "doWork: could not promote foreground service: $e")
        }

        // Gate on isFlutterAlive: after an OS-reclaim Activity destroy, flutterApi
        // dangles at a dead dartExecutor messenger (cleanUpFlutterEngine nulls it,
        // but guard regardless), so posting would silently no-op. Treat as not-running.
        val flutterApi = if (OmiBleManager.isFlutterAlive) OmiBleManager.instance.flutterApi else null

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
            // Flutter engine is not running (process was killed). Sync-on-open
            // will handle it the next time the user opens the app.
            Log.d(TAG, "doWork: Flutter engine not running — sync deferred to next app open")
            Result.success()
        }
    }
}
