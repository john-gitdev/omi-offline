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
        private const val AUTO_CONNECT_TIMEOUT_MS = 30_000L
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

        // A probe that heard no advertisements is repeated after this many further failures.
        // An Omi that was out of range when the outage began can walk back into range and
        // start failing at establishment, and nothing else would ever re-examine it: the
        // streak does not clear until services are discovered. The interval is far wider than
        // WEDGE_NOTIFY_AFTER because the common reason for silence is an Omi that is simply
        // switched off or at home, and each probe is an 8 s full-duty scan. Past
        // AUTONOMOUS_RETRY_STOP_AFTER native no longer drives the cadence, so reprobes for a
        // still-silent device follow the sync-schedule reconnect interval; the common
        // ADVERTISING/UNAVAILABLE verdict posts the alert at the first probe anyway.
        // No further probes run once the alert is posted — the verdict is in by then.
        private const val WEDGE_REPROBE_AFTER = 30
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
        // Failure count at which the next advertising probe runs: WEDGE_NOTIFY_AFTER for the
        // first, then every WEDGE_REPROBE_AFTER further failures until the probe hears the
        // Omi and the alert goes out. A probe that hears nothing must not mute the outage
        // forever — see WEDGE_REPROBE_AFTER.
        var nextWedgeProbeAt: Int = WEDGE_NOTIFY_AFTER,
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
                managed.wedgeStartedAtMs = 0
                managed.lastRealGattStatus = null
            }

            // Retire this device's toggle-Bluetooth alert if one is showing (no-op otherwise).
            cancelWedgeAlert(addr)

            // Close the outage record. Dart's _finishDeviceSetup appends the peripheral's
            // own establishment-failure counter to the same log moments from now, which is
            // the half of the picture that can only be read once the link is back up.
            if (recoveredFromWedge) {
                WedgeDiagnostics.captureRecovery(
                    context = this@OmiBleForegroundService,
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
        // defaults OFF. When disabled, clear any existing association so the OS stops
        // treating us as a companion — some OEMs (OnePlus/Oppo/Realme) auto-connect
        // associated devices, contending for the firmware's single slot. Read from
        // Flutter's SharedPreferences; default false (off).
        val companionEnabled = applicationContext
            .getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            .getBoolean("flutter.companionDeviceEnabled", false)
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
        if (existing != null && bleManager.isPeripheralConnected(addr)) {
            // Dart may have restarted (e.g. hot restart) while native kept the connection alive.
            // Re-fire onDeviceReady so the new Dart layer discovers this existing connection.
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

        if (existing != null) {
            // The guard (currentGattHash / pendingReconnect) and the kick must be atomic
            // relative to onGattConnected (binder thread) and the retry runnable (main),
            // both of which mutate these fields. Without the lock, we can read stale nulls
            // and spawn a duplicate connect on top of an in-flight one.
            synchronized(syncLock) {
                if (bond && !existing.requiresBond) existing.requiresBond = true
                if (existing.currentGattHash != null || existing.pendingReconnect != null) {
                    Log.d(TAG, "manageDevice($addr): skipping — gattHash=${existing.currentGattHash} pendingReconnect=${existing.pendingReconnect != null} (native already handling it)")
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
     * No-ops if the user manually disconnected, if Bluetooth is off, if already
     * connected, or if a connect is already in flight (manageDevice's guard handles the
     * last two idempotently).
     */
    fun ensureManagedReconnectFromAlarm() {
        val cfg = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        if (cfg.getBoolean(PREFS_USER_DISCONNECTED, false)) return
        val managed = cfg.getString(PREFS_KEY, null) ?: return
        val parts = managed.split("|")
        val addr = parts.getOrNull(0)?.uppercase()?.takeIf { it.isNotEmpty() } ?: return
        val bond = parts.getOrNull(1)?.toBoolean() ?: false
        if (!isBluetoothEnabled) return
        if (bleManager.isPeripheralConnected(addr)) return
        Log.i(TAG, "Sync alarm: driving native reconnect for $addr (Flutter-independent)")
        manageDevice(addr, bond)
    }

    fun unmanageDevice(address: String) {
        val addr = address.uppercase()
        val managed = managedDevices.remove(addr) ?: return

        Log.i(TAG, "unmanageDevice: $addr")

        managed.pendingReconnect?.let { handler.removeCallbacks(it) }
        managed.stabilityTimerRunnable?.let { handler.removeCallbacks(it) }

        // Intentional disconnect ends the outage this device's alert was about.
        cancelWedgeAlert(addr)

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
        if (managed != null && status != -1 && status != 0) {
            managed.lastRealGattStatus = status
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
        synchronized(syncLock) {
            // Any failed attempt counts. The previous rule (only status -1) keyed the outage
            // detector on our own local timeout, which fired before Android could deliver a
            // real status — so a genuine 0x3e storm looked like stack silence and never
            // tripped the streak. See the timeout constants and NOTES.md.
            managed.consecutiveConnectFailures++
            // Re-probe only while the probe still has something to decide. Once the alert is
            // posted the verdict is in, and further 8 s low-latency scans would add radio load
            // to an outage this service is otherwise trying to stop aggravating.
            if (managed.consecutiveConnectFailures >= managed.nextWedgeProbeAt && !managed.wedgeAlertPosted) {
                managed.nextWedgeProbeAt = managed.consecutiveConnectFailures + WEDGE_REPROBE_AFTER
                if (!managed.wedgeDetected) {
                    managed.wedgeDetected = true
                    managed.wedgeStartedAtMs = android.os.SystemClock.elapsedRealtime()
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
                lastRealStatus = managed.lastRealGattStatus,
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
                            // Pull the schedule in: the wide interval is priced for a device we
                            // established is absent, and we established nothing.
                            m.nextWedgeProbeAt =
                                minOf(m.nextWedgeProbeAt, m.consecutiveConnectFailures + WEDGE_NOTIFY_AFTER)
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
                            connectToDevice(addr, "retry_${managed.retryCount}_postpurge")
                        }
                    }
                    // Keep the guard invariant satisfied across the settle window.
                    managed.pendingReconnect = connectRunnable
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
                    bleManager.mainHandler.post {
                        bleManager.flutterApi?.onBluetoothStateChanged("off") {}
                    }
                    for ((addr, managed) in managedDevices) {
                        managed.pendingReconnect?.let { handler.removeCallbacks(it) }
                        managed.pendingReconnect = null
                        managed.stabilityTimerRunnable?.let { handler.removeCallbacks(it) }
                        managed.stabilityTimerRunnable = null
                        bleManager.stopRssiKeepAlive()
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
        val address = intent?.getStringExtra("device_address")
        if (intent?.getBooleanExtra("persistent_only", false) == true) persistent = true

        if (address != null) {
            val requiresBond = intent.getBooleanExtra("requires_bond", false)
            manageDevice(address, requiresBond)
        } else if (persistent && managedDevices.isEmpty()) {
            // Persistent restart with no explicit device — the sync alarm's
            // startServicePersistent path, or a START_STICKY relaunch after a kill.
            // Restore the bound device from prefs and reconnect natively so recovery
            // doesn't depend on the Flutter isolate (which may be frozen/dead under
            // Doze). No-ops if the user disconnected or nothing is bound.
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
        syncTimerActive = timestampMs > 0
        nextSyncTimeMs = timestampMs
        SyncAlarmReceiver.schedule(this, timestampMs)
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
