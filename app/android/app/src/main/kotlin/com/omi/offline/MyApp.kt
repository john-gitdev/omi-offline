package com.omi.offline

import android.app.Activity
import android.app.Application
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Owns the one Flutter engine, for the whole life of the process.
 *
 * **Why the engine cannot belong to MainActivity.** Android reclaims a backgrounded
 * Activity under memory pressure, which destroys its FlutterEngine — but
 * [OmiBleForegroundService] keeps the PROCESS alive, and it only stops on a deliberate
 * swipe-away (`isFinishing`). So the device stays connected and the native BLE layer
 * keeps working while Dart is simply gone. Every path that can sync is Dart-side, and
 * both wake paths — [BackgroundSyncWorker] and [SyncAlarmReceiver] — then took their
 * "Flutter engine not running — sync deferred to next app open" branch and returned
 * success without doing anything.
 *
 * Measured on device (2026-08-28): seventeen consecutive hours in which the native side
 * logged 300+ records and Dart logged two. WorkManager fired on time throughout; every
 * firing hit the dead-engine branch. Opening the app then drained 68 files / 125 MB /
 * 11.3 h of audio in one go.
 *
 * Creating the engine here — cached, and adopted by MainActivity rather than owned by it
 * — means an Activity reclaim detaches the UI and leaves Dart running, so a scheduled
 * sync has something to deliver to. There is deliberately exactly ONE engine: a second,
 * headless engine spun up per-sync would race the Activity's over the BLE stack, and a
 * single always-present engine has no such state to reconcile.
 *
 * Everything registered here is engine-scoped and Activity-free. Anything that genuinely
 * needs an Activity reads [currentActivity], which MainActivity sets on attach and clears
 * on detach — a null there means "no UI right now", not "broken".
 */
class MyApp : Application() {
    companion object {
        private const val TAG = "OmiBle.MyApp"

        /** Cache key MainActivity adopts the engine by. */
        const val ENGINE_ID = "omi.main.engine"

        /**
         * The foreground Activity, or null when there is no UI attached.
         *
         * Volatile and nulled on detach: this is read from background threads, and
         * holding a destroyed Activity here would leak the whole view hierarchy for as
         * long as the process lives — which, with the foreground service running, is
         * potentially days.
         */
        @Volatile
        var currentActivity: Activity? = null

        /**
         * True once a UI has attached to the engine at least one time.
         *
         * A SECOND attach means the user reopened the app against an engine that never
         * stopped running — `main()` will not run again, so the launch housekeeping it
         * does (temp-file cleanup, the discard recovery sweep, the version stamp that
         * heads a launch's log lines) would silently drop from per-open to once per
         * process, and the process can now live for days. MainActivity signals Dart on
         * a re-attach so that work still happens when a user opens the app.
         */
        @Volatile
        var hasAttachedOnce: Boolean = false

        /** Kotlin -> Dart signalling channel; also carries `moveTaskToBack` the other way. */
        @Volatile
        var systemChannel: MethodChannel? = null
    }

    override fun onCreate() {
        super.onCreate()
        // Re-register the WorkManager periodic sync task on every app start so
        // the interval stays current (UPDATE policy is idempotent if unchanged).
        BackgroundSyncWorker.scheduleFromPrefs(this)

        val engine = FlutterEngine(this)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        registerEngineScopedApis(engine)

        // isFlutterAlive is deliberately NOT set here. Creating the engine and running
        // its entrypoint are not the same thing: executeDartEntrypoint only schedules
        // main(), so at this instant no Pigeon handler is registered and no
        // DeviceProvider exists. Dart calls `dartReady` when the sync path is actually
        // up (see main.dart) — which also means a Dart main() that throws leaves the flag
        // false, and the wake paths correctly skip instead of posting into a broken
        // engine. It used to be set from MainActivity, where it tracked the ACTIVITY and
        // so went false on a reclaim even though nothing was wrong with Dart.
        Log.d(TAG, "onCreate: Flutter engine created and cached as $ENGINE_ID")
    }

    /**
     * Wires the platform APIs that belong to the engine rather than to any Activity.
     *
     * [BleHostApiImpl] is constructed with the application context and an Activity
     * *supplier*, not an Activity: the calls a background sync makes (manage/unmanage a
     * device, reschedule, take a wake lock) resolve against the application context and
     * work with no UI, while the genuinely Activity-bound ones (companion-device pairing,
     * permission dialogs) return early exactly as before when there is nothing to show a
     * dialog on.
     */
    private fun registerEngineScopedApis(engine: FlutterEngine) {
        OmiBleManager.initialize(this)
        val messenger = engine.dartExecutor.binaryMessenger
        val flutterApi = BleFlutterApi(messenger)
        val hostApi = BleHostApiImpl({ currentActivity }, flutterApi, applicationContext)
        BleHostApi.setUp(messenger, hostApi)
        OmiBleManager.bleHostApi = hostApi

        AacEncoderChannel(messenger)

        // Android-only; iOS stays on the per-window fallback.
        //
        // Deliberately never destroyed. It used to be torn down in MainActivity.onDestroy
        // on a swipe-away, which was right while it belonged to the Activity; it belongs
        // to the engine now, and destroying it would leave every later BACKGROUND sync
        // without a batch runner — the exact runs this change exists to enable. The
        // expensive part, the ORT session, is released by Dart's own `dispose` after each
        // processing run; what stays resident is an idle worker thread.
        VadBatchRunner(messenger)

        // Lets the root Flutter page minimize the app on Back instead of finishing
        // MainActivity — finishing tears down the BLE foreground service. With no
        // Activity attached there is nothing to minimize, so this reports false rather
        // than failing: Dart treats that as "could not minimize" and does nothing.
        systemChannel = MethodChannel(messenger, "com.omi.offline/system").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "moveTaskToBack" -> result.success(currentActivity?.moveTaskToBack(true) ?: false)
                    // Whether a UI is attached RIGHT NOW. Dart asks at startup because
                    // its own lifecycleState is null until the first lifecycle event, and
                    // in a process with no Activity that null never resolves — so "no
                    // answer yet" and "no screen at all" are indistinguishable from
                    // Dart's side. This is the difference.
                    "hasUi" -> result.success(currentActivity != null)
                    "dartReady" -> {
                        OmiBleManager.isFlutterAlive = true
                        Log.d(TAG, "dartReady: Dart is up — background wake paths may deliver")
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}
