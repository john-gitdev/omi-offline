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
        private const val CONNECTION_TIMEOUT_MS = 30_000L
        // Mid-retry ghost-GATT purge: if a stale system link is holding the firmware's
        // single connection slot, drop it (purgeGhostGattForAddress) before reconnecting.
        // Capped to once per GHOST_PURGE_MIN_INTERVAL_MS to bound client-interface churn;
        // GHOST_PURGE_SETTLE_MS lets the firmware re-advertise after the purge.
        private const val GHOST_PURGE_MIN_INTERVAL_MS = 30_000L
        private const val GHOST_PURGE_SETTLE_MS = 500L
        private const val COMPANION_RATE_LIMIT_MS = 15_000L
        private const val PREFS_NAME = "ble_config"
        private const val PREFS_KEY = "managed_device"
        private const val PREFS_USER_DISCONNECTED = "user_disconnected"
        private const val DEFAULT_NOTIF_TITLE = "Omi Offline"
        private const val DEFAULT_NOTIF_TEXT = "Connecting..."
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
        var lastGhostPurgeMs: Long = 0
    )

    private val managedDevices = ConcurrentHashMap<String, ManagedDevice>()
    private val handler = Handler(Looper.getMainLooper())
    private var isDestroying = false
    private var isBluetoothEnabled = true
    private val syncLock = Any()
    private val bleManager get() = OmiBleManager.instance
    private var currentNotificationTitle = DEFAULT_NOTIF_TITLE
    private var currentNotificationText = DEFAULT_NOTIF_TEXT
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
                managed.retryCount = 0
                managed.lastGhostPurgeMs = 0
                managed.hasEverConnected = true
                managed.pendingReconnect?.let { handler.removeCallbacks(it) }
                managed.pendingReconnect = null
                managed.connectionTimeoutRunnable?.let { handler.removeCallbacks(it) }
                managed.connectionTimeoutRunnable = null
                managed.connectionStartTime = System.currentTimeMillis()
                managed.currentGattHash = gatt.hashCode()
            }

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

            if (services.isEmpty()) {
                Log.w(TAG, "No services discovered for $addr")
            }

            if (managed.requiresBond) {
                bleManager.requestBond(addr) { result: Result<Boolean> ->
                    val bonded = result.getOrDefault(false)
                    Log.i(TAG, "Bond result for $addr: $bonded")
                    if (bonded) {
                        managed.retryCount = 0
                        managed.requiresBond = false
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
        // We keep the CDM association (background-run grant / companion status) but drive
        // background reconnect via the periodic sync alarm/worker instead. Proactively
        // stop any observation a previous app version left armed so the passive link is
        // released on upgrade without requiring a re-pair.
        OmiCompanionManager.stopObservingForAddress(applicationContext, addr)

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

    fun unmanageDevice(address: String) {
        val addr = address.uppercase()
        val managed = managedDevices.remove(addr) ?: return

        Log.i(TAG, "unmanageDevice: $addr")

        managed.pendingReconnect?.let { handler.removeCallbacks(it) }
        managed.stabilityTimerRunnable?.let { handler.removeCallbacks(it) }

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

            if (bleManager.connectedGatts.containsKey(addr)) bleManager.closeGatt(addr)

            // Use autoConnect=false for initial connection and first 3 retries (direct connection, faster).
            // Switch to autoConnect=true for later retries (passive scan, more robust for background).
            val autoConnect = when {
                source == "manageDevice" -> false
                managed.retryCount <= 3 -> false
                else -> true
            }
            
            // Use shorter timeout for direct connection attempts.
            val timeoutMs = if (autoConnect) CONNECTION_TIMEOUT_MS else 15_000L

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

    private fun triggerReconnection(address: String, source: String) {
        val addr = address.uppercase()
        val managed = managedDevices[addr] ?: return

        managed.pendingReconnect?.let { handler.removeCallbacks(it) }
        managed.pendingReconnect = null
        managed.connectionTimeoutRunnable?.let { handler.removeCallbacks(it) }
        managed.connectionTimeoutRunnable = null
        managed.retryCount = 0
        connectToDevice(addr, source)
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

        // Reflect the drop on the notification immediately instead of leaving the
        // stale "Connected" text until the delayed retry's connectToDevice flips
        // it (see connectToDevice's source != "manageDevice" branch). This path
        // only runs for genuine drops we're about to retry — intentional
        // disconnects early-return above (managed entry removed by unmanageDevice).
        if (!dartDrivesNotification) updateNativeNotification(DEFAULT_NOTIF_TEXT)

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

        managed.retryCount++
        Log.i(TAG, "Retry #${managed.retryCount} for $addr in ${RECONNECT_DELAY_MS}ms (status=$status)")

        val runnable = Runnable {
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
        managed.pendingReconnect = runnable
        handler.postDelayed(runnable, RECONNECT_DELAY_MS)
    }

    // ── Stability timer ──

    private fun startStabilityTimer(address: String) {
        val addr = address.uppercase()
        val managed = managedDevices[addr] ?: return

        managed.stabilityTimerRunnable?.let { handler.removeCallbacks(it) }
        val runnable = Runnable {
            managed.retryCount = 0
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
                    managed.retryCount = 0
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
