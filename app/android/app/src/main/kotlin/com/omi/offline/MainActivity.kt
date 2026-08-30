package com.omi.offline

import android.content.Intent
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * The UI host. It no longer OWNS the Flutter engine — [MyApp] creates and caches it, and
 * this adopts it by id.
 *
 * That is the whole point: an OS memory-reclaim destroy used to take the engine with it,
 * leaving the process and the BLE link alive with no Dart to run a sync. See [MyApp] for
 * the measurement. Everything registered on the engine now lives in [MyApp]; what remains
 * here is only what genuinely needs an Activity.
 */
class MainActivity : FlutterActivity() {

    /**
     * Adopt the process-wide engine rather than building one per Activity.
     *
     * FlutterActivity then attaches and detaches it around this Activity's lifecycle
     * instead of creating and destroying it, which is what lets Dart outlive a reclaim.
     */
    override fun getCachedEngineId(): String = MyApp.ENGINE_ID

    /**
     * Never tear the engine down with this Activity — not even on a deliberate finish.
     *
     * A swipe-away stops the foreground service (see [onDestroy]) and the process is then
     * free to die on its own, taking the engine with it. Destroying it here instead would
     * also cover the RECLAIM case, which is exactly the one that must not destroy it.
     */
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Publish the Activity for the engine-scoped APIs that can use one when it exists
        // (companion-device pairing, permission dialogs, moveTaskToBack).
        MyApp.currentActivity = this
        OmiBleManager.bleHostApi?.initCompanionManager(this)

        // A re-attach means the user reopened the app against an engine that kept
        // running, so `main()` will not run again. Tell Dart, so the launch housekeeping
        // still happens per open rather than once per process — see MyApp.hasAttachedOnce.
        if (MyApp.hasAttachedOnce) {
            MyApp.systemChannel?.invokeMethod("uiReattached", null)
        }
        MyApp.hasAttachedOnce = true
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        OmiBleManager.bleHostApi?.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        // When the user closes the app (swipe away), stop the foreground service. The
        // service handles disconnecting all managed devices in its own onDestroy.
        //
        // Gated on isFinishing, and that distinction now carries the whole feature: a
        // reclaim (isFinishing == false) must leave the service — and therefore the
        // process, and therefore the engine — running, which is what lets a background
        // sync happen at all.
        if (isFinishing) {
            OmiBleForegroundService.stopService(this)
        }
        super.onDestroy()
    }

    /**
     * Fires on every engine DETACH, including an OS memory-reclaim destroy.
     *
     * It used to null `flutterApi` and clear `isFlutterAlive` here, because the engine
     * really was going away with the Activity. It no longer is, so doing that would tell
     * both wake paths Dart is dead while it is running perfectly well — reintroducing the
     * exact bug this change removes. All that is released is the Activity reference,
     * which must not outlive the Activity.
     */
    override fun cleanUpFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        MyApp.currentActivity = null
        OmiBleManager.bleHostApi?.releaseCompanionManager()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
