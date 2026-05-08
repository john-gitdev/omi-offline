package com.omi.offline

import android.annotation.SuppressLint
import android.app.*
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
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
        private const val RECONNECT_DELAY_MS = 3_000L
        private const val CONNECTION_TIMEOUT_MS = 30_000L
        private const val COMPANION_RATE_LIMIT_MS = 15_000L
        private const val PREFS_NAME = "ble_config"
        private const val PREFS_KEY = "managed_device"
        private const val PREFS_USER_DISCONNECTED = "user_disconnected"
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
        var connectionTimeoutRunnable: Runnable? = null
    )

    private val managedDevices = ConcurrentHashMap<String, ManagedDevice>()
    private val handler = Handler(Looper.getMainLooper())
    private var isDestroying = false
    private var isBluetoothEnabled = true
    private val syncLock = Any()
    private val bleManager get() = OmiBleManager.instance

    // ── Connection listener — receives GATT events from OmiBleManager ──

    private val connectionListener = object : OmiBleManager.BleConnectionListener {

        override fun onGattConnected(address: String, gatt: BluetoothGatt) {
            val addr = address.uppercase()
            val managed = managedDevices[addr] ?: return

            Log.i(TAG, "onGattConnected: $addr")
            managed.retryCount = 0
            managed.hasEverConnected = true
            managed.pendingReconnect?.let { handler.removeCallbacks(it) }
            managed.pendingReconnect = null
            managed.connectionTimeoutRunnable?.let { handler.removeCallbacks(it) }
            managed.connectionTimeoutRunnable = null
            managed.connectionStartTime = System.currentTimeMillis()
            managed.currentGattHash = gatt.hashCode()

            startStabilityTimer(addr)
            bleManager.startRssiKeepAlive(addr)
            updateNotification("Connected to Omi")
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

        if (!isBluetoothEnabled) {
            managedDevices[addr] = ManagedDevice(address = addr, requiresBond = bond)
            updateNotification("Bluetooth is off")
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
            if (bond && !existing.requiresBond) existing.requiresBond = true
            // Don't interfere with pending GATT connection or scheduled retry
            if (existing.currentGattHash != null || existing.pendingReconnect != null) return
            triggerReconnection(addr, "re-manage")
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

        bleManager.disconnectGatt(addr)
        bleManager.closeGatt(addr)

        getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit()
            .putBoolean(PREFS_USER_DISCONNECTED, true)
            .apply()

        bleManager.mainHandler.post {
            bleManager.flutterApi?.onPeripheralDisconnected(addr, "unmanaged") {}
        }

        if (managedDevices.isEmpty()) {
            handler.postDelayed({
                if (managedDevices.isEmpty()) {
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

            // autoConnect=false for initial manual connection (fast).
            // autoConnect=true for background/retries (passive scan, more robust).
            val autoConnect = source != "manageDevice"

            Log.i(TAG, "connectToDevice($source): $addr (autoConnect=$autoConnect)")
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
                Log.w(TAG, "Connection timeout for $addr after ${CONNECTION_TIMEOUT_MS}ms")
                managed.connectionTimeoutRunnable = null
                handleDisconnection(addr, managed.currentGattHash ?: 0, -1)
            }
            managed.connectionTimeoutRunnable = timeoutRunnable
            handler.postDelayed(timeoutRunnable, CONNECTION_TIMEOUT_MS)

            updateNotification("Connecting to Omi...")
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

        bleManager.mainHandler.post {
            bleManager.flutterApi?.onPeripheralDisconnected(addr, error) {}
        }

        updateNotification("Disconnected")
        handleRetryLogic(addr, status)
    }

    private fun handleRetryLogic(address: String, status: Int) {
        val addr = address.uppercase()
        val managed = managedDevices[addr] ?: return

        if (isDestroying || !isBluetoothEnabled) return

        managed.retryCount++
        Log.i(TAG, "Retry #${managed.retryCount} for $addr in ${RECONNECT_DELAY_MS}ms (status=$status)")

        val runnable = Runnable {
            managed.pendingReconnect = null
            connectToDevice(addr, "retry_${managed.retryCount}")
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
                    updateNotification("Bluetooth is off")
                }
                BluetoothAdapter.STATE_TURNING_ON -> {
                    isBluetoothEnabled = false
                }
                BluetoothAdapter.STATE_ON -> {
                    Log.i(TAG, "Bluetooth on, reconnecting in 2s")
                    isBluetoothEnabled = true
                    updateNotification("Reconnecting...")
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
        // Transition guard: old builds used START_STICKY, so Android may re-deliver
        // a pending intent after process death before MainActivity initializes OmiBleManager.
        if (!OmiBleManager.isInitialized) OmiBleManager.initialize(application)
        createNotificationChannel()

        // Call startForeground in onCreate to satisfy the OS requirement as early as possible.
        // Android 14+ requires providing the service type.
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID, 
                buildNotification("Connecting to Omi..."),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIFICATION_ID, buildNotification("Connecting to Omi..."))
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
        bleManager.connectionListener = connectionListener
        Log.d(TAG, "Service created and promoted to foreground")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val address = intent?.getStringExtra("device_address")

        if (address != null) {
            val requiresBond = intent.getBooleanExtra("requires_bond", false)
            manageDevice(address, requiresBond)
        } else {
            // No device specified — Omi streams via WebSocket which needs the app.
            // No point keeping BLE alive without it.
            if (managedDevices.isEmpty()) {
                Log.i(TAG, "onStartCommand: no device address and no managed devices, stopping")
                stopSelf()
            }
        }

        return START_NOT_STICKY
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

        // Clear the re-entry guard after a short delay so any in-flight Dart callbacks
        // (e.g. onPeripheralDisconnected → manageDevice) that arrive during teardown
        // are still blocked, but the service can be restarted once fully torn down.
        handler.postDelayed({ isDestroyingStatic = false }, 500)

        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── Notification ──

    private fun updateNotification(text: String) {
        try {
            val nm = getSystemService(NotificationManager::class.java)
            nm.notify(NOTIFICATION_ID, buildNotification(text))
        } catch (e: Exception) {
            Log.w(TAG, "updateNotification failed: ${e.message}")
        }
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(CHANNEL_ID, "Omi BLE", NotificationManager.IMPORTANCE_LOW)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Omi")
            .setContentText(text)
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setContentIntent(pi)
            .build()
    }
}
