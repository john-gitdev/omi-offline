package com.omi.offline

import android.annotation.SuppressLint
import android.app.*
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothManager
import android.content.*
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import android.content.pm.ServiceInfo
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/**
 * Single owner of the BLE connection lifecycle.
 * Dart tells this service "manage device X" / "unmanage device X".
 * The service handles: connect, bond (if needed), MTU, retry on disconnect,
 * and Bluetooth state changes.
 *
 * OmiBleManager is a pure GATT wrapper — it never decides when to connect or retry.
 */
@SuppressLint("MissingPermission")
class OmiBleForegroundService : Service() {

    companion object {
        private const val TAG = "OmiBle.FgService"
        private const val CHANNEL_ID = "omi_ble_channel"
        private const val NOTIFICATION_ID = 2001
        private const val MTU_REQUEST_DELAY_MS = 100L
        private const val MTU_SIZE = 512
        private const val STABILITY_TIMER_MS = 60_000L
        private const val RECONNECT_DELAY_MS = 1_500L
        // Local connect-attempt backstops. These must NOT preempt Android's own connect
        // timeout, or we cancelOpen() an in-flight attempt and never learn why it failed:
        // handleDisconnection() then synthesizes status -1 ("we gave up"), which is
        // indistinguishable from a real stack fault. Android gives up on a direct connect
        // at ~30 s and reports a real status (133, 62/0x3e, …), so ours sits above that.
        // autoConnect=true attempts never time out in the framework — the accept-list
        // initiator waits forever — so those need a backstop of our own.
        private const val DIRECT_CONNECT_TIMEOUT_MS = 40_000L
        // Longer than the direct backstop, not shorter. These were inverted: the
        // accept-list initiator is the one that never self-terminates, so it is the one
        // that needs room — while a direct connect Android already gives up on at ~30 s
        // was handed 40 s. Cutting the patient mode off at 30 s meant it was destroyed and
        // rebuilt (handleDisconnection closes the GATT unconditionally) before a
        // low-duty-cycle background scan could plausibly land, so it paid autoConnect's
        // slowness while never delivering its patience — and added connectGatt/closeGatt
        // churn on top. Must stay below Dart's connect backstop; see
        // native_ble_transport.dart _kConnectBackstop.
        private const val AUTO_CONNECT_TIMEOUT_MS = 45_000L
        // Mid-retry ghost-GATT purge: if a stale system link is holding the firmware's
        // single connection slot, drop it (purgeGhostGattForAddress) before reconnecting.
        // Only fires when such a link actually exists. Capped to once per
        // GHOST_PURGE_MIN_INTERVAL_MS to bound client-interface churn;
        // GHOST_PURGE_SETTLE_MS lets the firmware re-advertise after the purge.
        private const val GHOST_PURGE_MIN_INTERVAL_MS = 10_000L
        private const val GHOST_PURGE_SETTLE_MS = 500L
        // After this many consecutive failed connect attempts, consider the device wedged:
        // snapshot the outage, and — if the Omi is still advertising, i.e. present but
        // unreachable — tell the user to toggle Bluetooth. Apps can't cycle the adapter
        // themselves since Android 13, and a toggle empirically clears the outage. It does so
        // by tearing down every other host-side LE link, not by repairing the Omi: the failure
        // is `0x3e`, a link that comes up and dies before the first six connection events.
        // Counted on any failed attempt, not on our synthetic -1 — see the timeout constants
        // above. The alert is posted at most once per outage; the streak, the alert latch and
        // the probe schedule all clear only once services are discovered.
        private const val WEDGE_NOTIFY_AFTER = 6

        // Failures after which native stops its own fast reconnect loop and hands reconnection
        // to the sync schedule. Set equal to WEDGE_NOTIFY_AFTER so the outage is already detected
        // and the toggle-Bluetooth probe has fired before native steps back — and so a transient
        // blip (which the fast backoff clears well inside 6 attempts) is never handed off. Past
        // this point, reconnection is driven by Dart: the foreground connection-check timer, and
        // in the background the sync timer / SyncAlarmReceiver at the auto-sync interval. This is
        // what bounds a multi-hour wedge to ~one connect attempt per sync window instead of the
        // ~120/hour that dominated the battery cost of an outage.
        private const val AUTONOMOUS_RETRY_STOP_AFTER = WEDGE_NOTIFY_AFTER

        // Eligibility floor for repeating a probe that heard no advertisements. An Omi that was
        // out of range when the outage began can walk back into range and start failing at
        // establishment, and nothing else would ever re-examine it: the streak does not clear
        // until services are discovered. Keyed on wall-clock time, not failure count, because
        // once native hands reconnection to the sync schedule (AUTONOMOUS_RETRY_STOP_AFTER)
        // failures accrue only once per sync interval — a failure-count schedule (the old
        // WEDGE_REPROBE_AFTER = 30) would stretch re-examination to ~15 h.
        //
        // This is a *floor*, not a self-scheduled timer: a probe is an 8 s full-duty scan and
        // only runs alongside a reconnect attempt (handleRetryLogic), so the re-probe rides the
        // next attempt at/after the floor rather than arming its own wake. Effective cadence is
        // therefore max(15 min, next-attempt), which converges toward the sync interval as the
        // recovery backoff relaxes — deliberately: this only fires for a device the first probe
        // found *absent* (switched off / at home), and polling that every 15 min all day would
        // re-add the battery cost AUTONOMOUS_RETRY_STOP_AFTER exists to remove. The point here is
        // to kill the ~15 h pathology, not to guarantee a 15 min beat; a device that returns
        // *reachable* is picked up by the recovery/sync attempts regardless of this probe. The
        // common ADVERTISING/UNAVAILABLE verdict posts the alert at the *first* (failure-count-
        // gated) probe anyway, and no further probes run once the alert is posted.
        private const val WEDGE_REPROBE_INTERVAL_MS = 15 * 60_000L
        // Outage-recovery alarm cadence. When native pauses its retry loop, the first recovery
        // alarm fires this long after the handoff, then doubles each step (2 → 4 → 8 → 16 min)
        // until the step would reach the sync interval, at which point it self-terminates and
        // the periodic sync alarm carries on. Bounds recovery of a *cleared* wedge to a few
        // minutes instead of a full sync interval, while a genuinely-absent device converges to
        // the battery-friendly sync cadence. Under deep Doze the OS ~9 min setExactAndAllowWhileIdle
        // floor caps the real frequency anyway; the tight steps mainly help when the phone is
        // awake (being carried back into range) — exactly when fast recovery matters most.
        private const val RECOVERY_PROBE_MIN_MS = 2 * 60_000L
        private const val ALERT_CHANNEL_ID = "omi_ble_alerts"
        private const val ALERT_NOTIFICATION_ID = 2002
        private const val COMPANION_RATE_LIMIT_MS = 15_000L
        private const val PREFS_NAME = "ble_config"
        private const val PREFS_KEY = "managed_device"
        private const val PREFS_USER_DISCONNECTED = "user_disconnected"
        private const val DEFAULT_NOTIF_TITLE = "Omi Offline"
        private const val DEFAULT_NOTIF_TEXT = "Connecting..."
        // Settle a stranded "Connecting…" notification this long after it's shown.
        // Deliberately slightly longer than Dart's 150 s connect-settle watchdog so a
        // genuinely slow connect isn't cut short and native never preempts Dart's own
        // handling — do NOT reduce this below 150 s. A disconnect pulls it in sooner
        // without that risk (see DISCONNECT_SETTLE_GRACE_MS / handleDisconnection).
        private const val CONNECT_SETTLE_MS = 160_000L
        // When a disconnect strands a Dart-driven "Connecting…", pull the settle alarm in
        // to this grace from the drop (never later than the connect-start deadline), so a
        // frozen-Dart recovery doesn't wait out the full window — or a Doze-throttled alarm.
        private const val DISCONNECT_SETTLE_GRACE_MS = 60_000L
        private const val ACTION_NOTIFICATION_DISMISSED = "com.omi.offline.NOTIFICATION_DISMISSED"
        @Volatile
        var instance: OmiBleForegroundService? = null
            private set

        @Volatile
        private var lastCompanionRequestTimestamp: Long = 0

        // Guard against re-entry during onDestroy: if the service fires
        // onPeripheralDisconnected("service_destroyed") and the Dart layer immediately
        // calls manageDevice, we must not call startForegroundService() while the
        // service is still tearing down — the system queues the start but onStartCommand
        // won't fire in time, causing ForegroundServiceDidNotStartInTimeException.
        @Volatile
        private var isDestroyingStatic = false

        fun isActive(): Boolean = instance != null

        fun startService(context: Context, deviceAddress: String, requiresBond: Boolean = false, caller: String = "unknown") {
            if (caller.startsWith("CompanionSvc")) {
                val now = System.currentTimeMillis()
                if (now - lastCompanionRequestTimestamp < COMPANION_RATE_LIMIT_MS) {
                    Log.d(TAG, "startService($caller): rate-limited, skipping")
                    return
                }
                lastCompanionRequestTimestamp = now
            }

            val inst = instance
            if (inst != null) {
                Log.d(TAG, "startService($caller): service already running, managing $deviceAddress directly")
                inst.manageDevice(deviceAddress, requiresBond)
                return
            }

            if (isDestroyingStatic) {
                Log.w(TAG, "startService($caller): service is still destroying, skipping startForegroundService")
                return
            }

            Log.d(TAG, "startService($caller): address=$deviceAddress, requiresBond=$requiresBond")
            val intent = Intent(context, OmiBleForegroundService::class.java).apply {
                putExtra("device_address", deviceAddress)
                putExtra("requires_bond", requiresBond)
                putExtra("caller", caller)
            }
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start foreground service", e)
            }
        }

        fun stopService(context: Context) {
            try {
                context.stopService(Intent(context, OmiBleForegroundService::class.java))
            } catch (e: Exception) {
                Log.e(TAG, "Failed to stop service", e)
            }
        }

        /// Start (or flag) the service in persistent mode with no device to manage,
        /// so the idle "Next sync / Last Sync" notification stays up across BLE
        /// disconnect and app background. Safe to call from an exempt background
        /// context (exact alarm / WorkManager) where starting an FGS is allowed.
        fun startServicePersistent(context: Context) {
            val inst = instance
            if (inst != null) {
                inst.persistent = true
                return
            }
            if (isDestroyingStatic) {
                Log.w(TAG, "startServicePersistent: still destroying, skipping")
                return
            }
            val intent = Intent(context, OmiBleForegroundService::class.java).apply {
                putExtra("persistent_only", true)
            }
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start persistent foreground service", e)
            }
        }
    }

    // ── Per-device state ──

    data class ManagedDevice(
        val address: String,
        var requiresBond: Boolean,
        var retryCount: Int = 0,
        var connectionStartTime: Long? = null,
        var currentGattHash: Int? = null,
        var hasEverConnected: Boolean = false,
        var pendingReconnect: Runnable? = null,
        // Deadline (elapsedRealtime) until which [pendingReconnect] is the post-ghost-purge
        // settle rather than an ordinary retry backoff. The two share the field (the settle
        // sets it to keep manageDevice's guard invariant satisfied across the window), but
        // they are not interchangeable: a backoff is a delay we are free to cut short, while
        // the settle is waiting on the *firmware* to start advertising again after a stale
        // link holding its single connection slot was dropped. Preempting the settle
        // reconnects into that gap and undoes the purge it was protecting.
        //
        // A deadline rather than a boolean deliberately. Five separate paths cancel
        // pendingReconnect (onGattConnected, triggerReconnection, handleDisconnection, the
        // adapter-off sweep, the retry runnable), and a flag any of them forgot to reset
        // would suppress every future preempt for the life of the process. This expires on
        // its own, so the worst a missed reset can cost is the 500 ms already budgeted.
        var postPurgeSettleUntilMs: Long = 0,
        var stabilityTimerRunnable: Runnable? = null,
        var connectionTimeoutRunnable: Runnable? = null,
        // Stale-bond recovery: when GATT disconnects with status 5 (INSUF_AUTHENTICATION)
        // and the device is BOND_BONDED, we removeBond() and wait for BOND_NONE before
        // reconnecting. bondRemovalAttempted prevents loops; resets on services discovered.
        var bondRemovalAttempted: Boolean = false,
        var pendingPostBondClearReconnect: Boolean = false,
        var bondClearTimeoutRunnable: Runnable? = null,
        // Timestamp of the last mid-retry ghost-GATT purge; rate-limits purges so a
        // persistent ghost can't churn Android client interfaces every retry tick.
        var lastGhostPurgeMs: Long = 0,
        // Consecutive failed connect attempts, of any status. Reset only on a successful
        // connect, NOT on re-manage: Dart re-manages every sync cycle and an outage
        // survives those, so resetting there would keep the count forever below the
        // notify threshold.
        var consecutiveConnectFailures: Int = 0,
        // The most recent *real* GATT status Android delivered during the current outage —
        // i.e. not our synthetic -1 connect-timeout backstop, and not 0 (a clean disconnect).
        // Lets the wedge event tell "stack actively rejecting with a real code (e.g. 147)"
        // apart from "initiator wedged solid, zero Android callbacks the whole outage (only
        // our -1 timeouts)". Reset once services are discovered, i.e. the outage is over.
        var lastRealGattStatus: Int? = null,
        // True once the current outage has been detected and captured. Note this latches at
        // *detection*, not at notification — whether the alert is posted depends on the
        // advertising probe. Cleared once services are discovered on a later connect.
        var wedgeDetected: Boolean = false,
        // Failure count at which the *first* advertising probe runs (WEDGE_NOTIFY_AFTER):
        // outage confirmation, while failures still accrue fast under native's own retry loop.
        var nextWedgeProbeAt: Int = WEDGE_NOTIFY_AFTER,
        // elapsedRealtime() at/after which the next *re*-probe runs, once the first probe has
        // fired. 0 until then. Wall-clock-keyed (WEDGE_REPROBE_INTERVAL_MS) because after native
        // hands off, failures accrue too slowly for a failure-count schedule — see the constant.
        var nextWedgeReprobeAtMs: Long = 0,
        // True once the toggle-Bluetooth alert has been posted for the current outage, so a
        // re-probe that confirms the same wedge doesn't re-raise a notification the user
        // already dismissed.
        var wedgeAlertPosted: Boolean = false,
        // elapsedRealtime() when the current outage was first detected, so recovery can
        // report how long it lasted. 0 when no outage is open.
        var wedgeStartedAtMs: Long = 0
    )

    private val managedDevices = ConcurrentHashMap<String, ManagedDevice>()
    private val handler = Handler(Looper.getMainLooper())
    private var isDestroying = false
    private var isBluetoothEnabled = true
    private val syncLock = Any()
    private val bleManager get() = OmiBleManager.instance
    private var currentNotificationTitle = DEFAULT_NOTIF_TITLE
    private var currentNotificationText = DEFAULT_NOTIF_TEXT
    // Mirrors Dart's nextSyncTime (pushed via setNextSyncTime) so the native
    // settle can render the "Next sync at H:MM" title without a live isolate.
    private var nextSyncTimeMs: Long = 0L
    // True while auto-sync is scheduled. Suppresses transient "Connecting…"/"Connected"
    // text updates so the "Next sync at…" label stays stable through the brief
    // connect→sync→disconnect cycle.
    private var syncTimerActive = false

    // How many outage-recovery alarms have been armed in the current confirmed outage.
    // Drives the 2 → 4 → 8 → 16 min backed-off cadence; reset to 0 on reconnect or when
    // recovery is cancelled. Only one Omi is managed and the recovery alarm is a single
    // app-wide PendingIntent, so this is service-level, not per-device. Touched only on the
    // main thread: the alarm broadcast is delivered there, and the handleRetryLogic handoff
    // (a binder thread) posts its schedule call to `handler`, so there's no cross-thread race.
    private var recoveryProbeAttempts = 0

    // ── Single-notification / persistent mode ──
    // When persistent, the service is the app's one foreground notification and
    // survives BLE disconnect + app background (it stops only when persistence is
    // turned off and no device is managed). Set true while auto-sync is on and a
    // device is bound (Dart drives it via setPersistentNotification).
    @Volatile
    private var persistent = false

    // While true, the Dart sync state machine owns the notification text (idle /
    // connecting / syncing / processing / …). The service's own connection-state
    // text updates are suppressed so the two don't fight.
    @Volatile
    private var dartDrivesNotification = false
    // Absolute due-time of the connect-settle alarm (0 = none). Tracked so a disconnect
    // can pull the alarm in without ever pushing it later (see handleDisconnection).
    // @Volatile: written by setSyncStatus (Dart platform-channel thread), read+written by
    // handleDisconnection (GATT binder thread) — same cross-thread pattern as dartDrivesNotification.
    @Volatile
    private var connectSettleDeadlineMs: Long = 0L

    private val notificationDismissedReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ACTION_NOTIFICATION_DISMISSED) return
            // User swiped away the foreground notification — repost it so it returns
            // on the next connection-state update (Android 14+ allows dismissing ongoing notifs).
            try {
                val notif = buildNotification(currentNotificationTitle, currentNotificationText)
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                    startForeground(NOTIFICATION_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
                } else {
                    startForeground(NOTIFICATION_ID, notif)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to repost notification after dismiss: ${e.message}")
            }
        }
    }

    // ── Connection listener — receives GATT events from OmiBleManager ──

    private val connectionListener = object : OmiBleManager.BleConnectionListener {

        override fun onGattConnected(address: String, gatt: BluetoothGatt) {
            val addr = address.uppercase()
            // Fires on the binder thread pool, not main. Hold syncLock so writes to
            // managed.* are visible to readers on other threads (manageDevice, retry runnable).
            synchronized(syncLock) {
                val managed = managedDevices[addr] ?: return

                Log.i(TAG, "onGattConnected: $addr")
                managed.lastGhostPurgeMs = 0
                managed.hasEverConnected = true
                managed.pendingReconnect?.let { handler.removeCallbacks(it) }
                managed.pendingReconnect = null
                managed.connectionTimeoutRunnable?.let { handler.removeCallbacks(it) }
                managed.connectionTimeoutRunnable = null
                managed.connectionStartTime = System.currentTimeMillis()
                managed.currentGattHash = gatt.hashCode()
            }

            // NOTE: neither the outage streak nor the retry backoff is cleared here. This
            // callback fires on newState == STATE_CONNECTED with the GATT `status` ignored
            // (see OmiBleManager.createGattCallback), so a link that comes up and immediately
            // dies — precisely the failure this detector exists to catch — would reset both on
            // the way past: the streak could never reach WEDGE_NOTIFY_AFTER, and retryCount
            // would pin the backoff at its 1.5 s floor, churning connectGatt/closeGatt at the
            // rate that wedges the Bluetooth daemon in the first place. The observed "connects,
            // then service discovery times out at 30 s" loop does exactly this. Both clear in
            // onGattServicesDiscovered, where the link is proven to have carried traffic.
            // A link that stays up but never discovers services is still covered: the stability
            // timer below, and handleDisconnection's duration check, both clear retryCount once
            // the connection has lasted STABILITY_TIMER_MS.

            startStabilityTimer(addr)
            bleManager.startRssiKeepAlive(addr)
            bleManager.startStorageKeepAlive(addr)
        }

        override fun onGattDisconnected(address: String, gattHash: Int, status: Int) {
            val addr = address.uppercase()
            Log.i(TAG, "onGattDisconnected: $addr (status=$status)")
            handleDisconnection(addr, gattHash, status)
        }


        override fun onGattServicesDiscovered(address: String, services: List<BleService>) {
            val addr = address.uppercase()
            val managed = managedDevices[addr] ?: return

            Log.i(TAG, "onGattServicesDiscovered: $addr (${services.size} services)")
            // Link survived the auth-gated ops, so any prior stale bond is resolved.
            managed.bondRemovalAttempted = false

            // The outage ends here, not at onGattConnected: this is the first point at which
            // the link has demonstrably carried traffic, so a link that comes up and dies can
            // never clear the streak or the backoff. Snapshot under the lock, emit after.
            var recoveredFromWedge = false
            var wedgeStartedAtMs = 0L
            var failuresBeforeRecovery = 0
            synchronized(syncLock) {
                recoveredFromWedge = managed.wedgeDetected
                wedgeStartedAtMs = managed.wedgeStartedAtMs
                failuresBeforeRecovery = managed.consecutiveConnectFailures
                managed.consecutiveConnectFailures = 0
                managed.retryCount = 0
                managed.wedgeDetected = false
                managed.wedgeAlertPosted = false
                managed.nextWedgeProbeAt = WEDGE_NOTIFY_AFTER
                managed.nextWedgeReprobeAtMs = 0
                managed.wedgeStartedAtMs = 0
                managed.lastRealGattStatus = null
            }

            // The outage is over — stop the tight recovery alarm and reset its backoff. Posted
            // to the main handler where recoveryProbeAttempts lives (we're on a binder thread).
            handler.post { cancelRecoveryProbe() }

            // Retire this device's toggle-Bluetooth alert if one is showing (no-op otherwise).
            cancelWedgeAlert(addr)

            // Close the outage record. Dart's _finishDeviceSetup appends the peripheral's
            // own establishment-failure counter to the same log moments from now, which is
            // the half of the picture that can only be read once the link is back up.
            if (recoveredFromWedge) {
                WedgeDiagnostics.captureRecovery(
                    context = this@OmiBleForegroundService,
                    bleManager = bleManager,
                    address = addr,
                    wedgeStartedAtMs = wedgeStartedAtMs,
                    failuresBeforeRecovery = failuresBeforeRecovery,
                )
            }

            if (services.isEmpty()) {
                Log.w(TAG, "No services discovered for $addr")
            }

            if (managed.requiresBond) {
                bleManager.requestBond(addr) { result: Result<Boolean> ->
                    val bonded = result.getOrDefault(false)
                    Log.i(TAG, "Bond result for $addr: $bonded")
                    if (bonded) {
                        synchronized(syncLock) {
                            managed.retryCount = 0
                            managed.requiresBond = false
                        }
                    }
                    requestMtuThenNotifyReady(addr, services)
                }
            } else {
                requestMtuThenNotifyReady(addr, services)
            }
        }

        override fun onMtuChanged(address: String, mtu: Int, status: Int) {
            // Handled inline via the MTU flow in requestMtuThenNotifyReady
        }

        override fun onCharacteristicChanged(address: String, serviceUuid: String, charUuid: String, value: ByteArray) {
            // Storage data characteristic: route to active native download session on the
            // binder thread — zero main-thread dispatch, which is the bottleneck in background.
            if (charUuid == "30295781-4301-eabd-2904-2849adfeae43") {
                val session = bleManager.activeDownloads[address.uppercase()]
                if (session != null) {
                    session.onPacket(value)
                    return
                }
            }
            bleManager.mainHandler.post {
                bleManager.flutterApi?.onCharacteristicValueUpdated(address, serviceUuid, charUuid, value) {}
            }
        }
    }

    // ── Post-discovery pipeline ──

    private fun requestMtuThenNotifyReady(address: String, services: List<BleService>) {
        val addr = address.uppercase()
        val gatt = bleManager.connectedGatts[addr] ?: run {
            Log.e(TAG, "requestMtuThenNotifyReady: no GATT for $addr")
            return
        }

        val originalListener = bleManager.connectionListener
        bleManager.connectionListener = object : OmiBleManager.BleConnectionListener by (originalListener ?: connectionListener) {
            override fun onMtuChanged(address: String, mtu: Int, status: Int) {
                bleManager.connectionListener = originalListener
                Log.i(TAG, "MTU done for $address (mtu=$mtu, status=$status)")
                fireDeviceReady(addr, services)
            }
        }

        handler.postDelayed({
            bleManager.enqueueCommand {
                try {
                    val currentGatt = bleManager.connectedGatts[addr]
                    if (currentGatt == null || !currentGatt.requestMtu(MTU_SIZE)) {
                        Log.e(TAG, "requestMtu failed for $addr")
                        bleManager.completeCommand()
                        bleManager.connectionListener = originalListener
                        fireDeviceReady(addr, services)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "requestMtu exception for $addr: ${e.message}")
                    bleManager.completeCommand()
                    bleManager.connectionListener = originalListener
                    fireDeviceReady(addr, services)
                }
            }
        }, MTU_REQUEST_DELAY_MS)
    }

    private fun fireDeviceReady(address: String, services: List<BleService>) {
        val addr = address.uppercase()
        // Ensure device is still connected before firing "Ready"
        if (!bleManager.isPeripheralConnected(addr)) {
            Log.w(TAG, "fireDeviceReady: $addr disconnected during pipeline, skipping")
            return
        }
        if (!dartDrivesNotification) updateNativeNotification("Connected")
        bleManager.mainHandler.post {
            bleManager.flutterApi?.onDeviceReady(addr, services) {}
        }
    }

    // ── Managed device lifecycle ──

    fun manageDevice(address: String, requiresBond: Boolean) {
        val addr = address.uppercase()
        // Bonding on Android 12 and below causes an endless pairing loop: the OS fails to persist
        // bond keys, so every reconnect triggers a new pairing dialog. Gate here (not just in
        // BleHostApiImpl) so the BleCompanionService restore-from-prefs path is also covered.
        val bond = requiresBond && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU
        Log.i(TAG, "manageDevice: $addr (requiresBond=$bond)")

        getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit()
            .putString(PREFS_KEY, "$addr|$bond")
            .putBoolean(PREFS_USER_DISCONNECTED, false)
            .apply()

        // CDM presence observation is intentionally NOT armed. On OnePlus/Oplus/Realme
        // stacks it makes the OS hold a passive LE link that contends for the firmware's
        // single connection slot (CONFIG_BT_MAX_CONN=1), wedging reconnection into an
        // "advertising but won't connect" state recoverable only by toggling phone BT.
        // Always stop CDM presence observation (never armed; releases any passive link a
        // prior app version left). Background reconnect runs on the periodic sync
        // alarm/worker, not on CDM.
        OmiCompanionManager.stopObservingForAddress(applicationContext, addr)

        // Honor the app-side "Companion Device Pairing" toggle (App Settings), which
        // defaults ON. When disabled, clear any existing association so the OS stops
        // treating us as a companion — the fallback for the rare OEM where a bare
        // association still hurts. Read from Flutter's SharedPreferences; the default
        // here MUST match SharedPreferencesUtil.companionDeviceEnabled (also true), or a
        // fresh install (key absent) would have Dart think companion is on while native
        // disassociates every connect. Note this is only the disassociate gate — the
        // association itself is created by the Dart find_devices / settings chooser flow.
        val companionEnabled = applicationContext
            .getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            .getBoolean("flutter.companionDeviceEnabled", true)
        Log.i(TAG, "Companion pairing enabled=$companionEnabled for $addr")
        if (!companionEnabled) {
            OmiCompanionManager.disassociateAddress(applicationContext, addr)
        }

        if (!isBluetoothEnabled) {
            managedDevices[addr] = ManagedDevice(address = addr, requiresBond = bond)
            bleManager.mainHandler.post {
                bleManager.flutterApi?.onPeripheralDisconnected(addr, "bluetooth_off") {}
            }
            return
        }

        val existing = managedDevices[addr]
        if (existing != null && bleManager.isPeripheralConnected(addr) && bleManager.hasDiscoveredServices(addr)) {
            // Dart may have restarted (e.g. hot restart, or a process kill from an APK
            // update) while native kept the connection alive. Re-fire onDeviceReady so the
            // new Dart layer discovers this existing connection.
            //
            // Gated on hasDiscoveredServices, NOT on isPeripheralConnected alone: that only
            // reports the ACL/GATT link state, which goes true at onConnectionStateChange
            // (STATE_CONNECTED) — before discoverServices() completes. Taking this shortcut
            // inside that window hands Dart an EMPTY gatt.services, and Dart latches
            // "connected" on it: every characteristic read then short-circuits to [] without
            // touching the radio, so the capability read comes back 0 (Customization collapses
            // to its one ungated row) and every storage write throws (no file sync) until the
            // app is force-closed. When discovery is still pending we fall through instead and
            // let native's own onServicesDiscovered fire the ready with the real table.
            val gatt = bleManager.connectedGatts[addr]
            val services = gatt?.services?.map { svc ->
                BleService(
                    svc.uuid.toString().lowercase(),
                    svc.characteristics?.map { it.uuid.toString().lowercase() } ?: emptyList()
                )
            } ?: emptyList()
            fireDeviceReady(addr, services)
            return
        }
        if (existing != null && bleManager.isPeripheralConnected(addr)) {
            // Link up, discovery still in flight. Return rather than falling through: the
            // reconnect logic below only holds off while currentGattHash/pendingReconnect are
            // set, and currentGattHash is set by onGattConnected — which runs on the binder
            // thread AFTER OmiBleManager records the gatt, so a manageDevice landing between
            // the two would read a null hash and tear down a link that is coming up fine.
            // Nothing to do here anyway: onServicesDiscovered fires the ready on its own, and
            // if discovery never lands, DISCOVERY_TIMEOUT_MS (15 s, inside Dart's 30 s ready
            // timeout) drops the link into the normal disconnect/retry path.
            // Unlike the already-discovered branch above, the bond flag is still live here:
            // onGattServicesDiscovered reads it when discovery lands, so a caller asking for
            // a bond must not lose that by arriving a few milliseconds early.
            synchronized(syncLock) { if (bond && !existing.requiresBond) existing.requiresBond = true }
            Log.i(TAG, "manageDevice($addr): link up but discovery still pending — waiting for onServicesDiscovered")
            return
        }

        if (existing != null) {
            // The guard (currentGattHash / pendingReconnect) and the kick must be atomic
            // relative to onGattConnected (binder thread) and the retry runnable (main),
            // both of which mutate these fields. Without the lock, we can read stale nulls
            // and spawn a duplicate connect on top of an in-flight one.
            synchronized(syncLock) {
                if (bond && !existing.requiresBond) existing.requiresBond = true
                // An attempt is already on the radio: join it. Dart's device-ready completer
                // is fulfilled by whichever attempt lands, so tearing this one down to start
                // another gains nothing and throws away the establishment progress made so
                // far — the phase where a link is most fragile (HCI 0x3e is declared if no
                // data-channel packet arrives within six connection events).
                if (existing.currentGattHash != null) {
                    Log.d(TAG, "manageDevice($addr): joining in-flight attempt (gattHash=${existing.currentGattHash})")
                    return
                }
                // Sitting out a retry backoff. Every manageDevice is an explicit "connect
                // now" from a caller with a reason — the sync window opened, or the user
                // opened the app — and that is information the backoff was not priced for:
                // the phone may have just been carried back into range. Waiting out up to
                // 30 s of backoff made the user's own tap a no-op, and Dart's connect
                // timeout would then report the request as failed while native was still
                // mid-ladder. Preempt the wait and attempt now.
                //
                // retryCount is deliberately NOT reset (so this cannot call
                // triggerReconnection, which does): the ladder's escalation is what keeps
                // repeated failures from churning connectGatt/closeGatt at the 1.5 s floor,
                // which is what wedged the Android BT daemon before c4ebcbde. Preempting
                // skips the *waiting*, not the escalation — the next failure still backs
                // off one step further than the last.
                //
                // This is safe only because Dart no longer runs a retry loop of its own
                // (device_provider._startBackgroundSyncTimer). Reintroducing one would put
                // a preempt on every attempt and reopen exactly that churn.
                // ...except the post-ghost-purge settle, which is not a backoff. A stale
                // system link holding the firmware's single connection slot was just
                // dropped, and this delay is waiting on the firmware to get back on the
                // air. Connecting into that gap reconnects before it is advertising and
                // throws away the purge that made reconnection possible at all — so this
                // one waits its 500 ms out, and the caller joins it.
                if (existing.pendingReconnect != null &&
                    android.os.SystemClock.elapsedRealtime() < existing.postPurgeSettleUntilMs
                ) {
                    Log.d(TAG, "manageDevice($addr): joining post-purge settle — not preempting")
                    return
                }
                if (existing.pendingReconnect != null) {
                    Log.i(TAG, "manageDevice($addr): preempting retry backoff (retryCount=${existing.retryCount}) — connecting now")
                    existing.pendingReconnect?.let { handler.removeCallbacks(it) }
                    existing.pendingReconnect = null
                    existing.connectionTimeoutRunnable?.let { handler.removeCallbacks(it) }
                    existing.connectionTimeoutRunnable = null
                    connectToDevice(addr, "preempt")
                    return
                }
                triggerReconnection(addr, "re-manage")
            }
            return
        }

        managedDevices[addr] = ManagedDevice(address = addr, requiresBond = bond)
        connectToDevice(addr, "manageDevice")
    }

    /**
     * Drive a reconnect for the bound device from a Doze-exempt context (the sync
     * alarm / a persistent service restart), independent of the Flutter isolate.
     *
     * Native pauses its own fast retry loop once an outage is confirmed
     * (AUTONOMOUS_RETRY_STOP_AFTER), leaving no pending reconnect. After that the only
     * thing that re-triggers a connect is a manageDevice call — and every other caller
     * routes through Dart (ensureConnection), which may be frozen or dead under Doze.
     * Without this, a background outage that clears would sit un-reconnected until the
     * next successful Dart wake or the user opening the app. The SyncAlarmReceiver's
     * setExactAndAllowWhileIdle broadcast runs even when Dart is frozen, so re-managing
     * from here restores the reliable, Flutter-independent reconnect trigger native's
     * own retry loop used to provide — but at the battery-friendly sync cadence rather
     * than the ~120/hour storm.
     *
     * No-ops if auto-sync is off ("Manual Only"), if the user manually disconnected, if
     * Bluetooth is off, if already connected, or if a connect is already in flight
     * (manageDevice's guard handles the last two idempotently). The auto-sync gate keeps
     * every background-reconnect path interval-consistent: the alarm only fires when
     * auto-sync is on, and this guards the sticky-relaunch path (below) against a stale
     * persistent flag left by an auto-sync→Manual-Only switch within the same process.
     */
    fun ensureManagedReconnectFromAlarm() {
        val cfg = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        if (cfg.getBoolean(PREFS_USER_DISCONNECTED, false)) return
        // Only background-reconnect when auto-sync is enabled; Manual Only syncs on
        // demand (app open / manual), so it must not hold a background link.
        if (autoSyncIntervalMinutes() <= 0) return
        val managed = cfg.getString(PREFS_KEY, null) ?: return
        val parts = managed.split("|")
        val addr = parts.getOrNull(0)?.uppercase()?.takeIf { it.isNotEmpty() } ?: return
        val bond = parts.getOrNull(1)?.toBoolean() ?: false
        if (!isBluetoothEnabled) return
        if (bleManager.isPeripheralConnected(addr)) return
        Log.i(TAG, "Sync alarm: driving native reconnect for $addr (Flutter-independent)")
        manageDevice(addr, bond)
    }

    /** The auto-sync interval in minutes (Flutter's pref; ≤ 0 = "Manual Only"). Same source
     *  the sync alarm's cadence comes from. */
    private fun autoSyncIntervalMinutes(): Long = applicationContext
        .getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        .getLong("flutter.backgroundSyncIntervalMinutes", 30L)

    /**
     * Arm the next outage-recovery alarm during a confirmed outage. Called with reset=true at
     * the native handoff (handleRetryLogic stops its own retries), and reset=false from each
     * recovery firing to schedule the next backed-off step.
     *
     * Cadence doubles from RECOVERY_PROBE_MIN_MS (2 → 4 → 8 → 16 min). Once the next step would
     * reach the sync interval the alarm self-terminates: past that point it's redundant with the
     * periodic sync alarm, which already drives ensureManagedReconnectFromAlarm at that cadence.
     * So a cleared wedge reconnects within a few minutes, while a genuinely-absent device costs
     * only ~4 extra attempts before converging to the battery-friendly sync cadence.
     *
     * Main-thread only (see recoveryProbeAttempts). No-op in Manual Only — there's no background
     * link to recover; the next firing's ensureManagedReconnectFromAlarm would no-op anyway.
     */
    private fun scheduleRecoveryProbe(reset: Boolean) {
        if (reset) recoveryProbeAttempts = 0
        // Re-validate on the main thread before every arm. The reset=true call is posted from the
        // failure-AUTONOMOUS_RETRY_STOP_AFTER handoff (a binder thread), so a user-disconnect /
        // BT-off / Manual-Only cancellation can land between the post and here; recoveryWanted()
        // keeps that cancellation final instead of letting the in-flight sixth failure re-arm a wake.
        if (!recoveryWanted()) { cancelRecoveryProbe(); return }
        val intervalMs = autoSyncIntervalMinutes() * 60_000L
        // Double each step (2, 4, 8, 16 min …). The shift is capped only to keep a corrupt
        // interval pref from overflowing; convergence below stops it well before that for any
        // real interval (60 min → converges at the 64 min step).
        val stepMs = RECOVERY_PROBE_MIN_MS shl minOf(recoveryProbeAttempts, 10)
        if (stepMs >= intervalMs) {
            // Converged on the sync cadence: hand back to the periodic sync alarm, which already
            // drives ensureManagedReconnectFromAlarm at this interval, so the recovery alarm is
            // now redundant. cancelRecoveryProbe() only clears the alarm + backoff counter — the
            // outage itself is still open; onGattServicesDiscovered is what ends it.
            Log.i(TAG, "Recovery probe reached sync interval — sync alarm now drives reconnection")
            cancelRecoveryProbe()
            return
        }
        recoveryProbeAttempts++
        SyncAlarmReceiver.scheduleRecover(this, System.currentTimeMillis() + stepMs)
        Log.i(TAG, "Recovery probe #$recoveryProbeAttempts armed in ${stepMs}ms")
    }

    private fun cancelRecoveryProbe() {
        recoveryProbeAttempts = 0
        SyncAlarmReceiver.cancelRecover(this)
    }

    /**
     * Whether the outage-recovery alarm should be running right now: auto-sync on, the user hasn't
     * disconnected, Bluetooth is on, and a managed device still has an open (wedgeDetected) outage.
     * The single source of truth for the recovery lifecycle — consulted by the alarm handler,
     * before each (re)arm in scheduleRecoveryProbe (so a cancellation stays final against a
     * concurrently posted handoff), and on the auto-sync inactive→active transition. Main thread.
     */
    private fun recoveryWanted(): Boolean {
        val cfg = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        if (cfg.getBoolean(PREFS_USER_DISCONNECTED, false)) return false
        if (autoSyncIntervalMinutes() <= 0 || !isBluetoothEnabled) return false
        val addr = cfg.getString(PREFS_KEY, null)?.split("|")?.getOrNull(0)?.uppercase() ?: return false
        return synchronized(syncLock) { managedDevices[addr]?.wedgeDetected == true }
    }

    /**
     * Cancel recovery AND reset each managed device's outage streak. For state changes that
     * abandon recovery while the outage may still be open — the radio turning off, or the sync
     * schedule being turned off (Manual Only). Resetting the streak preserves the invariant that
     * recovery arms exactly when `consecutiveConnectFailures` *crosses* AUTONOMOUS_RETRY_STOP_AFTER
     * (the handoff's `== ` guard, which fires once per detection episode since the streak clears
     * only on a successful connect). Without the reset the streak stays past the threshold, so
     * after the radio/schedule returns the next failure is threshold+1, the `==` handoff never
     * re-fires, and the fast recovery burst is lost for the rest of the outage (Bluetooth-toggle
     * regression). A toggle/mode-flip is a fresh intervention, so re-detecting from zero is also
     * the right semantics. NOT used by: onGattServicesDiscovered (already zeroes the streak on
     * success), unmanageDevice (device removed), or the convergence path (must keep the streak so
     * the sync alarm keeps driving without re-arming the burst).
     */
    private fun cancelRecoveryProbeAndResetStreak() {
        cancelRecoveryProbe()
        synchronized(syncLock) {
            for ((_, managed) in managedDevices) {
                managed.consecutiveConnectFailures = 0
                managed.retryCount = 0
            }
        }
    }

    /**
     * Outage-recovery alarm fired (SyncAlarmReceiver, Doze-exempt). Drive one reconnect and
     * re-arm the next backed-off step, until the link is back or recovery is no longer wanted.
     *
     * The "outage is still open" test is wedgeDetected, NOT a link-layer poll: isPeripheralConnected()
     * goes true the instant GATT connects, before services are discovered, and a link that comes up
     * and dies before discovery is the exact wedge this service detects — cancelling on that transient
     * half-connection would strand recovery (the streak is already past AUTONOMOUS_RETRY_STOP_AFTER, so
     * the pre-discovery disconnect lands as failure 7+ and the `==` handoff never re-arms). wedgeDetected
     * is set with the recovery handoff at failure AUTONOMOUS_RETRY_STOP_AFTER and cleared only by
     * onGattServicesDiscovered (the link proven usable), so it stays true across a transient half-
     * connection yet flips false the moment the outage genuinely ends. Keying on it also closes the
     * race where a recovery alarm delivered concurrently with service discovery would otherwise re-arm
     * after the outage ended and wake needlessly until convergence.
     */
    fun onRecoveryProbeAlarm() {
        if (!recoveryWanted()) {
            cancelRecoveryProbe()
            return
        }
        ensureManagedReconnectFromAlarm()
        scheduleRecoveryProbe(reset = false)
    }

    fun unmanageDevice(address: String) {
        val addr = address.uppercase()
        val managed = managedDevices.remove(addr) ?: return

        Log.i(TAG, "unmanageDevice: $addr")

        managed.pendingReconnect?.let { handler.removeCallbacks(it) }
        managed.stabilityTimerRunnable?.let { handler.removeCallbacks(it) }

        // Intentional disconnect ends the outage this device's alert was about.
        cancelWedgeAlert(addr)
        // ...and its recovery alarm; the user asked to be off, so stop background reconnects.
        cancelRecoveryProbe()

        // Stop OS-level presence observation BEFORE closing the GATT. Without
        // this, OnePlus/Xiaomi stacks immediately re-establish a passive LE link
        // to satisfy the observation, keeping the firmware's is_connected true
        // and the LED blue even after our gatt.close() — defeating maximize-battery.
        // Per-MAC so any other managed device's observation is untouched.
        OmiCompanionManager.stopObservingForAddress(applicationContext, addr)
        OmiCompanionManager.disassociateAddress(applicationContext, addr)

        bleManager.disconnectGatt(addr)
        bleManager.closeGatt(addr)

        // The OS bond is no longer removed here to prevent background disconnects
        // from permanently unpairing the device. Use removeBond() instead.
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit()
            .putBoolean(PREFS_USER_DISCONNECTED, true)
            .apply()

        bleManager.mainHandler.post {
            bleManager.flutterApi?.onPeripheralDisconnected(addr, "unmanaged") {}
        }

        if (managedDevices.isEmpty() && !persistent) {
            handler.postDelayed({
                if (managedDevices.isEmpty() && !persistent) {
                    Log.i(TAG, "No more devices managed, stopping service")
                    stopSelf()
                }
            }, 5000)
        }
    }

    // ── Connection ──

    private fun connectToDevice(address: String, source: String) {
        synchronized(syncLock) {
            val addr = address.uppercase()
            val managed = managedDevices[addr] ?: return
            if (!isBluetoothEnabled || bleManager.isPeripheralConnected(addr)) return

            if (bleManager.connectedGatts.containsKey(addr)) {
                // disconnect() before close() so a link the OS still thinks is alive is
                // torn down at the radio level, not just released app-side (ghost-slot guard).
                bleManager.disconnectGatt(addr)
                bleManager.closeGatt(addr)
            } else if (source == "manageDevice") {
                // Fresh connection attempt from Dart. No propagation lag to worry about since we haven't
                // held a GATT handle recently. Proactively purge any ghost before we start.
                val now = System.currentTimeMillis()
                if (now - managed.lastGhostPurgeMs >= GHOST_PURGE_MIN_INTERVAL_MS && bleManager.purgeGhostGattForAddress(addr)) {
                    managed.lastGhostPurgeMs = now
                    Log.i(TAG, "Ghost GATT proactively purged for $addr before initial connect")
                }
            }

            // Use autoConnect=false for initial connection and first 3 retries (direct connection, faster).
            // Switch to autoConnect=true for later retries (passive scan, more robust for background).
            val autoConnect = when {
                source == "manageDevice" -> false
                managed.retryCount <= 3 -> false
                else -> true
            }

            val timeoutMs = if (autoConnect) AUTO_CONNECT_TIMEOUT_MS else DIRECT_CONNECT_TIMEOUT_MS

            Log.i(TAG, "connectToDevice($source): $addr (autoConnect=$autoConnect, timeout=${timeoutMs}ms)")
            // Flip back to "Connecting..." when retrying after a disconnect.
            // Skip for the initial manageDevice call since onCreate already set "Connecting...".
            if (source != "manageDevice" && !dartDrivesNotification) updateNativeNotification(DEFAULT_NOTIF_TEXT)
            val gatt = try {
                bleManager.connectGatt(addr, autoConnect = autoConnect)
            } catch (e: SecurityException) {
                Log.e(TAG, "connectToDevice($source): BLUETOOTH_CONNECT permission denied for $addr")
                bleManager.mainHandler.post {
                    bleManager.flutterApi?.onPeripheralDisconnected(addr, "permission_denied") {}
                }
                return
            }
            if (gatt == null) {
                Log.e(TAG, "connectToDevice($source): connectGatt returned null for $addr")
                return
            }

            managed.currentGattHash = gatt.hashCode()
            managed.connectionStartTime = System.currentTimeMillis()

            managed.connectionTimeoutRunnable?.let { handler.removeCallbacks(it) }
            val timeoutRunnable = Runnable {
                Log.w(TAG, "Connection timeout for $addr after ${timeoutMs}ms (source=$source)")
                managed.connectionTimeoutRunnable = null
                handleDisconnection(addr, managed.currentGattHash ?: 0, -1)
            }
            managed.connectionTimeoutRunnable = timeoutRunnable
            handler.postDelayed(timeoutRunnable, timeoutMs)
        }
    }

    /**
     * Takes syncLock over the guard fields and the backoff counter. manageDevice already holds
     * it when it calls this; the monitor is reentrant, and the bluetoothOn path does not.
     */
    private fun triggerReconnection(address: String, source: String) {
        val addr = address.uppercase()
        val managed = managedDevices[addr] ?: return

        synchronized(syncLock) {
            managed.pendingReconnect?.let { handler.removeCallbacks(it) }
            managed.pendingReconnect = null
            managed.connectionTimeoutRunnable?.let { handler.removeCallbacks(it) }
            managed.connectionTimeoutRunnable = null
            managed.retryCount = 0
            connectToDevice(addr, source)
        }
    }

    // ── Disconnect handling + retry ──

    private fun handleDisconnection(address: String, gattHash: Int, status: Int) {
        synchronized(syncLock) {
            val addr = address.uppercase()
            val managed = managedDevices[addr] ?: return

            // Reject stale disconnect callbacks from old GATT objects
            if (managed.currentGattHash != null && managed.currentGattHash != gattHash) {
                Log.w(TAG, "Stale disconnect for $addr, ignoring")
                return
            }

            managed.pendingReconnect?.let { handler.removeCallbacks(it) }
            managed.pendingReconnect = null
            managed.connectionTimeoutRunnable?.let { handler.removeCallbacks(it) }
            managed.connectionTimeoutRunnable = null
            managed.stabilityTimerRunnable?.let { handler.removeCallbacks(it) }
            managed.stabilityTimerRunnable = null
            managed.bondClearTimeoutRunnable?.let { handler.removeCallbacks(it) }
            managed.bondClearTimeoutRunnable = null

            val duration = managed.connectionStartTime?.let { System.currentTimeMillis() - it } ?: 0
            if (duration >= STABILITY_TIMER_MS) {
                managed.retryCount = 0
            }

            bleManager.disconnectGatt(addr)
            bleManager.closeGatt(addr)
            managed.currentGattHash = null
        }

        val addr = address.uppercase()

        val error = when {
            status == 22 -> {
                Log.w(TAG, "Disconnection status 22 (LOCAL_HOST_TERM) for $addr - often a bonding/pairing mismatch.")
                "bonding_issue_or_terminated"
            }
            status != 0 -> "gatt_status_$status"
            else -> null
        }

        val managed = managedDevices[addr]
        if (managed != null && !managed.hasEverConnected && status != -1) {
            Log.w(TAG, "Device $addr disconnected before ever connecting (status=$status)")
        }

        // Remember the last real Android status of this outage for the wedge diagnostics.
        // -1 is our own timeout backstop and 0 is a clean disconnect; neither is a failure
        // code worth surfacing, so an all-timeout outage keeps this null (itself the signal).
        // Written under syncLock — the same lock onGattServicesDiscovered clears it under and
        // handleRetryLogic snapshots it under — so a disconnect callback on one binder thread
        // can't clobber a recovery that just reset it to null on another (both run off the
        // GATT binder pool).
        if (managed != null && status != -1 && status != 0) {
            synchronized(syncLock) {
                managed.lastRealGattStatus = status
            }
        }

        // Reflect the drop on the notification immediately instead of leaving the
        // stale "Connected" text until the delayed retry's connectToDevice flips
        // it (see connectToDevice's source != "manageDevice" branch). This path
        // only runs for genuine drops we're about to retry — intentional
        // disconnects early-return above (managed entry removed by unmanageDevice).
        if (!dartDrivesNotification) {
            updateNativeNotification(DEFAULT_NOTIF_TEXT)
        } else if (currentNotificationText.startsWith("Connecting") && connectSettleDeadlineMs > 0L) {
            // Dart owns the notification and last pushed "Connecting…", but the link just
            // dropped. If Dart is frozen by Doze it can't run its ~150 s connect-settle
            // watchdog, so the line would otherwise stay stuck until the connect-start
            // settle alarm (which can itself be Doze-throttled out to ~9 min). The
            // disconnect is direct, native evidence the attempt dropped, so pull the settle
            // alarm in toward now — but never later than the original deadline, so a
            // flapping link still settles on schedule rather than sliding forever. The
            // receiver re-checks the live text and no-ops unless it's still "Connecting…",
            // so a reconnect that resolves (Dart thaws → "Syncing…") within the grace is
            // never mislabelled.
            val pulledIn = minOf(connectSettleDeadlineMs, System.currentTimeMillis() + DISCONNECT_SETTLE_GRACE_MS)
            if (pulledIn < connectSettleDeadlineMs) {
                connectSettleDeadlineMs = pulledIn
                SyncAlarmReceiver.scheduleSettle(this, pulledIn)
            }
        }

        bleManager.mainHandler.post {
            bleManager.flutterApi?.onPeripheralDisconnected(addr, error) {}
        }

        // We are disabling aggressive bond recovery here. When a characteristic is marked
        // BT_GATT_PERM_READ_ENCRYPT, Android first receives an Insufficient Authentication
        // error (status 5) and then automatically attempts to elevate security. If we intercept
        // status 5 and manually wipe the bond, we sabotage the OS's native encryption process!
        // if (status == 5 && tryRecoverFromStaleBond(addr)) {
        //     return
        // }

        handleRetryLogic(addr, status)
    }

    // ── Stale-bond recovery ──
    //
    // Status 5 (GATT_INSUF_AUTHENTICATION) on a bonded device almost always means the
    // phone's cached LTK no longer matches the peripheral — typically because the
    // device was reflashed via OTA (the firmware's NVS bond store sits inside the
    // mcuboot app slot and gets wiped on swap). Clear the bond and reconnect; the
    // peripheral will re-pair from scratch.
    //
    // Returns true if recovery was kicked off (caller must skip the normal retry).
    private fun tryRecoverFromStaleBond(addr: String): Boolean {
        val managed = managedDevices[addr] ?: return false
        if (managed.bondRemovalAttempted) return false

        val device = remoteDeviceOrNull(addr) ?: return false
        if (device.bondState != BluetoothDevice.BOND_BONDED) return false

        Log.w(TAG, "gatt_status_5 on bonded $addr — removing stale bond and reconnecting")
        managed.bondRemovalAttempted = true
        managed.pendingPostBondClearReconnect = true

        val removed = removeBondViaReflection(device)
        if (!removed) {
            Log.w(TAG, "removeBond reflection failed for $addr — falling back to normal retry")
            managed.pendingPostBondClearReconnect = false
            return false
        }

        // Fallback in case the BOND_NONE broadcast never arrives (some OEM stacks
        // silently drop it). Without this, we'd hang with retry suppressed.
        val timeout = Runnable {
            val m = managedDevices[addr] ?: return@Runnable
            if (m.pendingPostBondClearReconnect) {
                Log.w(TAG, "BOND_NONE timeout for $addr — proceeding with retry anyway")
                m.pendingPostBondClearReconnect = false
                m.bondClearTimeoutRunnable = null
                handleRetryLogic(addr, 5)
            }
        }
        managed.bondClearTimeoutRunnable = timeout
        handler.postDelayed(timeout, 3_000L)
        return true
    }

    private fun remoteDeviceOrNull(addr: String): BluetoothDevice? {
        return try {
            val bm = application.getSystemService(Application.BLUETOOTH_SERVICE) as? BluetoothManager
            bm?.adapter?.getRemoteDevice(addr)
        } catch (e: Exception) {
            Log.w(TAG, "remoteDeviceOrNull failed for $addr: ${e.message}")
            null
        }
    }

    fun removeBond(addr: String) {
        try {
            val adapter = BluetoothAdapter.getDefaultAdapter()
            if (adapter != null) {
                val device = adapter.getRemoteDevice(addr)
                if (device.bondState != BluetoothDevice.BOND_NONE) {
                    removeBondViaReflection(device)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to remove bond manually: ${e.message}")
        }
    }

    private fun removeBondViaReflection(device: BluetoothDevice): Boolean {
        return try {
            val method = device.javaClass.getMethod("removeBond")
            val result = method.invoke(device) as? Boolean ?: false
            Log.i(TAG, "removeBond() returned $result for ${device.address}")
            result
        } catch (e: Exception) {
            Log.e(TAG, "removeBond reflection failed: ${e.message}")
            false
        }
    }

    private fun handleRetryLogic(address: String, status: Int) {
        val addr = address.uppercase()
        val managed = managedDevices[addr] ?: return

        if (isDestroying || !isBluetoothEnabled) return

        val runnable = buildReconnectRunnable(addr, managed)

        // These counters are read and cleared under syncLock by onGattServicesDiscovered, on a
        // different binder thread, so the writes take the lock too. The probe is started after
        // the lock is released: it kicks off an LE scan and posts to the main thread, and none
        // of that belongs under a lock this hot.
        //
        // pendingReconnect is installed in this same block. manageDevice treats "currentGattHash
        // and pendingReconnect both null" as "nobody is handling this device" and kicks off its
        // own connect, resetting the backoff — so the guard must go up at the instant the
        // counters move, not one lock acquisition later. (A window remains between
        // handleDisconnection clearing the guard and this block taking it; that one predates the
        // retry counters and is not closed here.)
        var startProbe = false
        var failures = 0
        var retries = 0
        var backoffDelay = 0L
        var willRetry = false
        var lastRealStatus: Int? = null
        synchronized(syncLock) {
            // Any failed attempt counts. The previous rule (only status -1) keyed the outage
            // detector on our own local timeout, which fired before Android could deliver a
            // real status — so a genuine 0x3e storm looked like stack silence and never
            // tripped the streak. See the timeout constants and NOTES.md.
            managed.consecutiveConnectFailures++
            // Re-probe only while the probe still has something to decide. Once the alert is
            // posted the verdict is in, and further 8 s low-latency scans would add radio load
            // to an outage this service is otherwise trying to stop aggravating.
            val nowMs = android.os.SystemClock.elapsedRealtime()
            // First probe: failure-count-gated (outage confirmation, while failures still accrue
            // fast). Subsequent re-probes: gated by a wall-clock *floor* (nextWedgeReprobeAtMs) —
            // this runs on the next attempt at/after the floor, it does not arm its own wake, so
            // effective cadence is max(15 min, next-attempt). That's deliberate; see
            // WEDGE_REPROBE_INTERVAL_MS for why it rides the attempt schedule rather than the 15 h
            // a failure-count schedule would cost once native hands off.
            val probeDue = if (managed.nextWedgeReprobeAtMs == 0L) {
                managed.consecutiveConnectFailures >= managed.nextWedgeProbeAt
            } else {
                nowMs >= managed.nextWedgeReprobeAtMs
            }
            if (probeDue && !managed.wedgeAlertPosted) {
                managed.nextWedgeReprobeAtMs = nowMs + WEDGE_REPROBE_INTERVAL_MS
                if (!managed.wedgeDetected) {
                    managed.wedgeDetected = true
                    managed.wedgeStartedAtMs = nowMs
                }
                startProbe = true
            }
            managed.retryCount++
            failures = managed.consecutiveConnectFailures
            retries = managed.retryCount
            // Exponential backoff: 1.5 → 3 → 6 → 12 → 24 → 30 s (capped). Replaces the prior
            // fixed 1.5 s delay, whose rapid connectGatt/closeGatt churn was the most common
            // trigger for the Android Bluetooth daemon wedging on Samsung/Qualcomm/MediaTek
            // stacks. retryCount resets once services are discovered, so the backoff resets
            // with the streak rather than on a link that merely came up.
            backoffDelay = minOf(RECONNECT_DELAY_MS shl minOf(managed.retryCount - 1, 5), 30_000L)
            // Keep native's own fast retry loop only through the first AUTONOMOUS_RETRY_STOP_AFTER
            // failures; past that the outage is confirmed and native steps back (see the constant).
            // Critically, when we stop we must leave NO pending retry: pendingReconnect and the
            // posted runnable move together. Setting pendingReconnect here without posting it would
            // wedge reconnection permanently — manageDevice's guard treats a non-null
            // pendingReconnect as "native is handling it" and skips, so every foreground /
            // sync-window connect request would be dropped and the device would never reconnect.
            // Leaving both null is the correct resting state: the next manageDevice falls through
            // to triggerReconnection().
            willRetry = failures < AUTONOMOUS_RETRY_STOP_AFTER
            if (willRetry) managed.pendingReconnect = runnable
            // Snapshot the real GATT status under the lock so the captureWedge call below
            // reports a value consistent with this streak, not one a concurrent recovery
            // (onGattServicesDiscovered) or a later disconnect could reset/overwrite mid-read.
            lastRealStatus = managed.lastRealGattStatus
        }

        if (startProbe) {
            // Snapshot the outage into the debug log now, while it is happening. An outage
            // that starts overnight is over by the time anyone can attach adb, and its most
            // informative state — whether we can still hear the peripheral advertising —
            // exists only while it lasts. Written from native: Dart may be Doze-frozen.
            WedgeDiagnostics.captureWedge(
                context = this,
                bleManager = bleManager,
                address = addr,
                consecutiveFailures = failures,
                retryCount = retries,
                lastStatus = status,
                lastRealStatus = lastRealStatus,
            ) { verdict ->
                // The alert tells the user to toggle Bluetooth, which only helps when the Omi
                // is present and reachable. Six failures alone don't mean that: an Omi that is
                // out of range, powered off, or connected to another phone produces the same
                // streak, and Android reports the same generic status (133) for a device that
                // isn't there as for one whose links keep dying at establishment. The probe is
                // what separates them — advertisements heard means the Omi is right there and
                // we still can't reach it, which is the only case the advice fits.
                //
                // UNAVAILABLE is treated as present: the probe can never run on this phone, and
                // withholding the alert forever is worse than the pre-probe behaviour of
                // alerting on the streak alone. INCONCLUSIVE is not — a scan the framework
                // refused says nothing, and latching the alert on it would both cry wolf and
                // stop us ever looking again. Ask again a few failures from now instead.
                when (verdict) {
                    WedgeDiagnostics.ProbeVerdict.SILENT -> {
                        Log.i(TAG, "Outage on $addr but no advertisements heard — device absent, not a wedge; no alert")
                        return@captureWedge
                    }
                    WedgeDiagnostics.ProbeVerdict.INCONCLUSIVE -> {
                        Log.i(TAG, "Outage on $addr but the probe could not run — no verdict; will re-probe")
                        synchronized(syncLock) {
                            val m = managedDevices[addr] ?: return@synchronized
                            // Only pull the schedule in if this outage is still open — same
                            // wedgeDetected guard the alert path below uses. The probe is async
                            // (~8 s scan), so onGattServicesDiscovered may have ended the outage and
                            // reset nextWedgeReprobeAtMs to 0 meanwhile; overwriting it here with a
                            // past timestamp would make the *next* unrelated disconnect fire a wedge
                            // probe on its first failure (the wall-clock branch treats a stale
                            // past deadline as immediately due). The wide interval is priced for a
                            // device we established is absent, and we established nothing — re-probe
                            // on the very next attempt (attempts are slow now, so this is soon enough).
                            if (m.wedgeDetected) m.nextWedgeReprobeAtMs = android.os.SystemClock.elapsedRealtime()
                        }
                        return@captureWedge
                    }
                    else -> Unit // ADVERTISING, UNAVAILABLE — fall through and alert.
                }
                // 8 s elapsed inside the probe; re-check nothing resolved meanwhile. The test
                // is wedgeDetected, the same criterion the recovery path uses — asking
                // isPeripheralConnected() would call the outage over the moment the link layer
                // came up, and a link that comes up and dies before service discovery is the
                // exact failure being detected. With a backoff floor of 1.5 s that link can
                // easily reappear inside the 8 s probe window, and the alert would be
                // suppressed for an outage that never ends.
                val post = synchronized(syncLock) {
                    val m = managedDevices[addr]
                    if (m != null && m.wedgeDetected && !m.wedgeAlertPosted) {
                        m.wedgeAlertPosted = true
                        true
                    } else {
                        false
                    }
                }
                if (post) postWedgeNotification(addr)
            }
        }

        if (willRetry) {
            Log.i(TAG, "Retry #$retries for $addr in ${backoffDelay}ms (status=$status)")
            handler.postDelayed(runnable, backoffDelay)
        } else {
            // Outage confirmed: native pauses its own retries and lets the sync schedule drive
            // reconnection (foreground: Dart's connection-check timer; background: the sync timer /
            // SyncAlarmReceiver). No pending retry is left behind, so the next manageDevice
            // triggerReconnection()s a fresh attempt rather than being skipped by the guard.
            Log.i(TAG, "Outage on $addr past $AUTONOMOUS_RETRY_STOP_AFTER failures ($failures) — pausing native retries; sync schedule now drives reconnection")
            // But bound the recovery latency: without this, a wedge that clears seconds later
            // sits un-reconnected until the next sync alarm (up to a full interval). Kick off the
            // tight, backing-off recovery alarm — but exactly ONCE per outage, at the transition
            // failure. consecutiveConnectFailures increments by 1 per call and resets only on
            // reconnect, so `== AUTONOMOUS_RETRY_STOP_AFTER` fires here just once; the later
            // failures the recovery loop itself produces (7, 8, …) fall through without restarting
            // the backoff (which would otherwise pin it at the 2 min floor forever). Posted to the
            // main handler — we're on a binder thread and recoveryProbeAttempts lives there.
            if (failures == AUTONOMOUS_RETRY_STOP_AFTER) {
                handler.post { scheduleRecoveryProbe(reset = true) }
            }
        }
    }

    /** The delayed reconnect attempt. Installed as `pendingReconnect` before it is posted. */
    private fun buildReconnectRunnable(addr: String, managed: ManagedDevice): Runnable {
        return Runnable {
            // Atomic with manageDevice's guard: an external manageDevice call must see
            // either pendingReconnect != null (we haven't fired yet) or currentGattHash != null
            // (connectToDevice has registered the new gatt) — never both null.
            synchronized(syncLock) {
                managed.pendingReconnect = null
                // Evaluated here (~RECONNECT_DELAY_MS after the disconnect), not on the
                // disconnect event itself, so the system's getConnectedDevices view has
                // settled — avoids false positives from propagation lag right after our own
                // closeGatt. If a stale system link still holds the firmware's slot, purge
                // it, then reconnect after a short settle so the firmware can re-advertise.
                // Rate-limited so a persistent ghost can't churn client interfaces per tick.
                // The purge no longer runs when no such link exists: during the 2026-07-08
                // outage the peripheral held zero connections, so every forced purge was a
                // dummy connectGatt + cancelOpen against a device that was failing 0x3e.
                val now = System.currentTimeMillis()
                if (now - managed.lastGhostPurgeMs >= GHOST_PURGE_MIN_INTERVAL_MS &&
                    bleManager.purgeGhostGattForAddress(addr)
                ) {
                    managed.lastGhostPurgeMs = now
                    Log.i(TAG, "Ghost GATT purged for $addr; reconnecting after ${GHOST_PURGE_SETTLE_MS}ms settle")
                    val connectRunnable = Runnable {
                        synchronized(syncLock) {
                            managed.pendingReconnect = null
                            managed.postPurgeSettleUntilMs = 0
                            connectToDevice(addr, "retry_${managed.retryCount}_postpurge")
                        }
                    }
                    // Keep the guard invariant satisfied across the settle window, and mark
                    // it as a settle so manageDevice's preempt leaves it alone — this delay
                    // is waiting on the firmware to re-advertise, not on a backoff clock.
                    managed.pendingReconnect = connectRunnable
                    managed.postPurgeSettleUntilMs =
                        android.os.SystemClock.elapsedRealtime() + GHOST_PURGE_SETTLE_MS
                    handler.postDelayed(connectRunnable, GHOST_PURGE_SETTLE_MS)
                } else {
                    connectToDevice(addr, "retry_${managed.retryCount}")
                }
            }
        }
    }

    // ── Stability timer ──

    private fun startStabilityTimer(address: String) {
        val addr = address.uppercase()
        val managed = managedDevices[addr] ?: return

        managed.stabilityTimerRunnable?.let { handler.removeCallbacks(it) }
        // Main thread. handleRetryLogic increments retryCount on a binder thread, and
        // handleDisconnection cancels this runnable — but only after it may already be running.
        val runnable = Runnable {
            synchronized(syncLock) { managed.retryCount = 0 }
        }
        managed.stabilityTimerRunnable = runnable
        handler.postDelayed(runnable, STABILITY_TIMER_MS)
    }

    // ── Bond state receiver ──

    private val bondStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
            val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE) ?: return
            val bondState = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)
            val address = device.address.uppercase()

            val managed = managedDevices[address] ?: return

            when (bondState) {
                BluetoothDevice.BOND_BONDED -> {
                    Log.i(TAG, "Bond completed for $address")
                    synchronized(syncLock) { managed.retryCount = 0 }
                }
                BluetoothDevice.BOND_NONE -> {
                    Log.w(TAG, "Bond removed/failed for $address")
                    if (managed.pendingPostBondClearReconnect) {
                        managed.pendingPostBondClearReconnect = false
                        managed.bondClearTimeoutRunnable?.let { handler.removeCallbacks(it) }
                        managed.bondClearTimeoutRunnable = null
                        Log.i(TAG, "Stale bond cleared for $address — reconnecting")
                        handler.postDelayed({ connectToDevice(address, "post_bond_clear") }, 500L)
                    }
                }
            }
        }
    }

    // ── Bluetooth state receiver ──

    private val bluetoothReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)

            when (state) {
                BluetoothAdapter.STATE_TURNING_OFF -> {
                    Log.i(TAG, "Bluetooth turning off, cleaning up GATT")
                    isBluetoothEnabled = false
                    // Nothing can reconnect with the radio off; cancel the outage-recovery alarm
                    // rather than leaving it armed to fire once and self-cancel (a needless wake).
                    // Reset the streak too, so once BT returns the re-detected outage crosses the
                    // handoff threshold again and re-arms recovery — otherwise a toggle mid-outage
                    // would strand recovery at the sync cadence for the rest of it.
                    cancelRecoveryProbeAndResetStreak()
                    bleManager.mainHandler.post {
                        bleManager.flutterApi?.onBluetoothStateChanged("off") {}
                    }
                    for ((addr, managed) in managedDevices) {
                        managed.pendingReconnect?.let { handler.removeCallbacks(it) }
                        managed.pendingReconnect = null
                        managed.stabilityTimerRunnable?.let { handler.removeCallbacks(it) }
                        managed.stabilityTimerRunnable = null
                        bleManager.stopRssiKeepAlive()
                        // Was omitted: with the radio going down the storage keep-alive
                        // otherwise kept reposting every 5 s against a dead gatt until
                        // the next connect happened to replace it.
                        bleManager.stopStorageKeepAlive()
                        bleManager.disconnectGatt(addr)
                        bleManager.closeGatt(addr)
                        managed.currentGattHash = null
                        bleManager.mainHandler.post {
                            bleManager.flutterApi?.onPeripheralDisconnected(addr, "bluetooth_off") {}
                        }
                    }
                }
                BluetoothAdapter.STATE_OFF -> {
                    isBluetoothEnabled = false
                    for ((addr, managed) in managedDevices) {
                        if (managed.currentGattHash != null) {
                            bleManager.disconnectGatt(addr)
                            bleManager.closeGatt(addr)
                            managed.currentGattHash = null
                        }
                    }
                }
                BluetoothAdapter.STATE_TURNING_ON -> {
                    isBluetoothEnabled = false
                }
                BluetoothAdapter.STATE_ON -> {
                    Log.i(TAG, "Bluetooth on, reconnecting in 2s")
                    isBluetoothEnabled = true
                    bleManager.mainHandler.post {
                        bleManager.flutterApi?.onBluetoothStateChanged("on") {}
                    }
                    handler.postDelayed({
                        for ((addr, _) in managedDevices) {
                            triggerReconnection(addr, "bluetoothOn")
                        }
                    }, 2000)
                }
            }
        }
    }

    // ── Service lifecycle ──

    override fun onCreate() {
        super.onCreate()
        instance = this

        val bluetoothAdapter = (application.getSystemService(Application.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        isBluetoothEnabled = bluetoothAdapter?.isEnabled ?: false

        // Transition guard: old builds used START_STICKY, so Android may re-deliver
        // a pending intent after process death before MainActivity initializes OmiBleManager.
        if (!OmiBleManager.isInitialized) OmiBleManager.initialize(application)
        createNotificationChannel()

        // Call startForeground in onCreate to satisfy the OS requirement as early as possible.
        // Android 14+ requires providing the service type.
        val notif = buildNotification(DEFAULT_NOTIF_TITLE, DEFAULT_NOTIF_TEXT)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIFICATION_ID, notif)
        }

        registerReceiver(
            bluetoothReceiver,
            IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
            RECEIVER_NOT_EXPORTED
        )
        registerReceiver(
            bondStateReceiver,
            IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED),
            RECEIVER_NOT_EXPORTED
        )
        registerReceiver(
            notificationDismissedReceiver,
            IntentFilter(ACTION_NOTIFICATION_DISMISSED),
            RECEIVER_NOT_EXPORTED
        )
        bleManager.connectionListener = connectionListener
        Log.d(TAG, "Service created and promoted to foreground")

        if (!isBluetoothEnabled) {
            bleManager.mainHandler.post {
                bleManager.flutterApi?.onBluetoothStateChanged("off") {}
            }
        }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A null intent is Android relaunching a previously-START_STICKY service after a
        // process kill (the app always starts us WITH an intent — device_address or
        // persistent_only). We only return START_STICKY when persistent, so a null intent
        // unambiguously means the service was persistent: restore the flag so the restore
        // branch below reconnects and we return START_STICKY again rather than stopping.
        if (intent == null) persistent = true
        val address = intent?.getStringExtra("device_address")
        if (intent?.getBooleanExtra("persistent_only", false) == true) persistent = true

        if (address != null) {
            val requiresBond = intent.getBooleanExtra("requires_bond", false)
            manageDevice(address, requiresBond)
        } else if (persistent && managedDevices.isEmpty()) {
            // Persistent restart with no explicit device — the sync alarm's
            // startServicePersistent path (persistent_only intent), or a START_STICKY
            // relaunch after a kill (null intent, handled just above). Restore the bound
            // device from prefs and reconnect natively so recovery doesn't depend on the
            // Flutter isolate (which may be frozen/dead under Doze). No-ops if auto-sync
            // is off, the user disconnected, or nothing is bound.
            ensureManagedReconnectFromAlarm()
        } else if (!persistent && managedDevices.isEmpty()) {
            // No device and not pinned persistent — nothing to keep alive.
            Log.i(TAG, "onStartCommand: no device address and no managed devices, stopping")
            stopSelf()
        }

        // START_STICKY in persistent mode so the OS relaunches the notification
        // after a low-memory kill (a user force-stop still wins, by design).
        return if (persistent) START_STICKY else START_NOT_STICKY
    }

    override fun onDestroy() {
        Log.d(TAG, "Service destroying")
        isDestroying = true
        isDestroyingStatic = true

        for ((addr, managed) in managedDevices) {
            managed.pendingReconnect?.let { handler.removeCallbacks(it) }
            managed.stabilityTimerRunnable?.let { handler.removeCallbacks(it) }
            bleManager.disconnectGatt(addr)
            bleManager.closeGatt(addr)
            bleManager.mainHandler.post {
                bleManager.flutterApi?.onPeripheralDisconnected(addr, "service_destroyed") {}
            }
        }
        managedDevices.clear()

        bleManager.connectionListener = null
        instance = null

        try { unregisterReceiver(bluetoothReceiver) } catch (_: Exception) {}
        try { unregisterReceiver(bondStateReceiver) } catch (_: Exception) {}
        try { unregisterReceiver(notificationDismissedReceiver) } catch (_: Exception) {}

        // Clear the re-entry guard after a short delay so any in-flight Dart callbacks
        // (e.g. onPeripheralDisconnected → manageDevice) that arrive during teardown
        // are still blocked, but the service can be restarted once fully torn down.
        handler.postDelayed({ isDestroyingStatic = false }, 500)

        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── Notification ──

    fun setNextSyncTime(timestampMs: Long) {
        val wasActive = syncTimerActive
        syncTimerActive = timestampMs > 0
        nextSyncTimeMs = timestampMs
        SyncAlarmReceiver.schedule(this, timestampMs)
        // timestampMs <= 0 is Dart turning the sync schedule off — i.e. Manual Only
        // (device_provider setNextSyncTime(0)). The recovery alarm exists only to bridge a
        // confirmed outage back onto that schedule, so cancel it now rather than leaving an
        // armed exact alarm to fire once and self-cancel (a needless Doze wake). Reset the streak
        // too so a later switch back to auto-sync while still wedged re-arms recovery cleanly.
        if (timestampMs <= 0) {
            cancelRecoveryProbeAndResetStreak()
        } else if (!wasActive && recoveryWanted()) {
            // Auto-sync just went inactive→active (e.g. Manual Only → 15/30/60 min) while an outage
            // is still open. The Manual-Only switch reset the streak, so without this the fast
            // recovery path would only re-arm after the streak crawls back to the handoff threshold
            // over slow sync-interval attempts — potentially hours. Restart it now.
            scheduleRecoveryProbe(reset = true)
        }
    }

    fun setDeviceBattery(level: Int, timestampMs: Long) {
        // Battery info is surfaced in the idle notification text (built by Dart and
        // pushed via setSyncStatus); the native service no longer renders it itself.
    }

    /// Pin/unpin the service so it survives BLE disconnect + app background.
    fun setPersistent(enabled: Boolean) {
        persistent = enabled
        if (!enabled && managedDevices.isEmpty()) {
            // Allow normal teardown now that nothing pins it.
            handler.postDelayed({
                if (!persistent && managedDevices.isEmpty()) {
                    Log.i(TAG, "setPersistent(false): no managed devices, stopping service")
                    stopSelf()
                }
            }, 5000)
        }
    }

    /// Dart sync state machine takes over the notification text. Suppresses the
    /// service's own connection-state updates while a status is set.
    fun setSyncStatus(title: String, text: String) {
        dartDrivesNotification = true
        updateNativeNotification(text, title)
        // A "Connecting…" transient can be stranded if Dart freezes (Doze) or its
        // engine is torn down before the attempt resolves. Arm a Doze-exempt exact
        // alarm to settle it back to the idle line on its own. Re-arming collapses
        // onto the single PendingIntent; any later push that resolves the connect
        // (Syncing/idle/…) leaves the alarm to fire once and no-op (the receiver
        // re-checks the live text). See SyncAlarmReceiver.scheduleSettle.
        if (text.startsWith("Connecting")) {
            connectSettleDeadlineMs = System.currentTimeMillis() + CONNECT_SETTLE_MS
            SyncAlarmReceiver.scheduleSettle(this, connectSettleDeadlineMs)
        } else {
            // Connect resolved / moved on (Syncing, idle, …) — drop the pending settle.
            connectSettleDeadlineMs = 0L
            SyncAlarmReceiver.cancelSettle(this)
        }
    }

    /// Settle a stranded "Connecting…" notification back to the idle line. Invoked
    /// from SyncAlarmReceiver, which runs in the alarm's Doze-exempt wakelock window
    /// with no dependence on a live Flutter isolate — so it recovers the stuck
    /// notification even when the engine is frozen or gone. No-op unless a connect
    /// transient is actually showing, so a legit in-flight connect is left alone.
    fun settleStaleConnectingToIdle() {
        if (!currentNotificationText.startsWith("Connecting")) return
        Log.i(TAG, "settleStaleConnectingToIdle: reverting stranded '$currentNotificationText' to idle")
        // The connect never resolved — the app's UI engine was frozen or torn down
        // before its give-up/watchdog could run. By definition that cycle synced
        // nothing, so record it as a Skip *now*, into the same prefs Dart reads, so
        // it reads back "Skipped" here and stays consistent when the app next opens.
        // Recording it only at this confirmed-strand point (rather than eagerly at
        // connect start) means a cycle that connected fine but deferred — e.g.
        // processing already running — is never mislabelled. Safe to write from
        // native: in this state no live isolate is racing us.
        getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE).edit()
            .putBoolean("flutter.lastSyncSkipped", true)
            .putLong("flutter.lastSyncStatusMs", System.currentTimeMillis())
            .apply()
        renderIdleFromPrefs()
    }

    /// Render the resting "Next sync / Last Sync" line from the same
    /// FlutterSharedPreferences keys Dart's SyncNotification.idle reads. Keep the
    /// title/body format in sync with that method (note: this recovery path does
    /// not reproduce the muted-state line that idle() renders first). The strand is
    /// recorded as a Skip just above, so it reads back as "Last Sync: Skipped • <time>".
    private fun renderIdleFromPrefs() {
        val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        val fmt = SimpleDateFormat("h:mm a", Locale.getDefault())
        val title = if (nextSyncTimeMs > 0) "Next sync at ${fmt.format(Date(nextSyncTimeMs))}" else DEFAULT_NOTIF_TITLE
        val lastMs = prefs.getLong("flutter.lastSyncStatusMs", 0L)
        val text: String
        if (lastMs > 0) {
            val status = when {
                prefs.getBoolean("flutter.lastSyncSkipped", false) -> "Skipped"
                prefs.getBoolean("flutter.lastSyncPartial", false) -> "Partial"
                else -> "Complete"
            }
            val time = fmt.format(Date(lastMs))
            val battery = prefs.getLong("flutter.lastBatteryLevel", -1L).toInt()
            text = if (battery >= 0) "Last Sync: $status • $time • $battery% Battery" else "Last Sync: $status • $time"
        } else {
            text = DEFAULT_NOTIF_TEXT
        }
        updateNativeNotification(text, title)
    }

    /// Release Dart ownership; native resumes connection-state text on the next
    /// event. Reflect the current state immediately so the line isn't stale.
    fun clearSyncStatus() {
        dartDrivesNotification = false
        val connected = managedDevices.keys.any { bleManager.isPeripheralConnected(it) }
        updateNativeNotification(if (connected) "Connected" else DEFAULT_NOTIF_TEXT)
    }

    private fun updateNativeNotification(text: String, title: String = DEFAULT_NOTIF_TITLE) {
        currentNotificationTitle = title
        currentNotificationText = text
        try {
            getSystemService(NotificationManager::class.java)
                ?.notify(NOTIFICATION_ID, buildNotification(title, text))
        } catch (e: Exception) {
            Log.w(TAG, "updateNativeNotification failed: ${e.message}")
        }
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(CHANNEL_ID, "Omi BLE", NotificationManager.IMPORTANCE_LOW)
        channel.setSound(null, null)
        channel.enableVibration(false)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)

        // Separate channel for the rare actionable alert (toggle Bluetooth). Distinct
        // from the silent ongoing status channel so the user can tune or disable it
        // independently, and so it may actually alert (DEFAULT importance).
        val alerts = NotificationChannel(ALERT_CHANNEL_ID, "Connection problems", NotificationManager.IMPORTANCE_DEFAULT)
        alerts.enableVibration(false)
        getSystemService(NotificationManager::class.java).createNotificationChannel(alerts)
    }

    /// One-shot, dismissible alert telling the user how to break the wedge. Deliberately
    /// NOT routed through updateNativeNotification: that renders the ongoing foreground
    /// status line, whose text Dart may own (dartDrivesNotification) and whose settle
    /// machinery (SyncAlarmReceiver) rewrites it — a separate notification can't be
    /// clobbered by either. Posted at most once per outage (wedgeAlertPosted guard), and only
    /// when the advertising probe confirms the Omi is actually present — see handleRetryLogic.
    private fun postWedgeNotification(address: String) {
        Log.w(TAG, "Wedge suspected for $address — posting toggle-Bluetooth alert")
        try {
            val intent = packageManager.getLaunchIntentForPackage(packageName)
            // requestCode 1: distinct from the status notification's PendingIntent
            // (requestCode 0) so the two never collapse onto one another.
            val pi = PendingIntent.getActivity(this, 1, intent, PendingIntent.FLAG_IMMUTABLE)
            val text = "Your phone's Bluetooth may be stuck. If your Omi is nearby, " +
                "toggle Bluetooth off and on to reconnect."
            val notif = NotificationCompat.Builder(this, ALERT_CHANNEL_ID)
                .setContentTitle("Omi can't reconnect")
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setSmallIcon(applicationInfo.icon)
                .setAutoCancel(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(pi)
                .build()
            // Tagged with the device address so one alert per wedged device: with two
            // managed Omis, device A reconnecting must not clear device B's still-valid
            // alert (cancelWedgeAlert cancels only its own tag).
            getSystemService(NotificationManager::class.java)?.notify(address, ALERT_NOTIFICATION_ID, notif)
        } catch (e: Exception) {
            Log.w(TAG, "postWedgeNotification failed: ${e.message}")
        }
    }

    private fun cancelWedgeAlert(address: String) {
        try {
            getSystemService(NotificationManager::class.java)?.cancel(address, ALERT_NOTIFICATION_ID)
        } catch (_: Exception) {}
    }

    private fun buildNotification(title: String, text: String): Notification {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)
        val deletePi = PendingIntent.getBroadcast(
            this, 0,
            Intent(ACTION_NOTIFICATION_DISMISSED).setPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            // Multi-line bodies (the upload status pushes "summary\nOmi…\nHeyPocket…")
            // collapse to the first line and expand to all lines. Single-line sync/
            // processing text is unaffected.
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setContentIntent(pi)
            .setDeleteIntent(deletePi)
            .build()
    }
}
