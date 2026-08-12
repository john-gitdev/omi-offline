package com.omi.offline

import android.annotation.SuppressLint
import android.app.Application
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.core.content.ContextCompat
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue

@SuppressLint("MissingPermission")
class OmiBleManager private constructor(private val application: Application) {

    companion object {
        private const val TAG = "OmiBle"
        private const val BOND_TIMEOUT_MS = 15000L
        private const val DISCOVERY_TIMEOUT_MS = 15000L

        // Upper bound on a single storage-download protocol gap we will zero-pad.
        // A legitimate gap is the span of BLE notifications dropped within one
        // (<=5-min) bin transfer — at most a few MB. A larger value means a bad /
        // desynced offset (firmware fault or corruption), so we fail the transfer
        // (resume re-fetches) instead of allocating a giant zero buffer.
        private const val MAX_PROTOCOL_GAP_BYTES = 8 * 1024 * 1024L

        @Volatile
        private var _instance: OmiBleManager? = null

        val instance: OmiBleManager
            get() = _instance ?: throw IllegalStateException("OmiBleManager not initialized")

        val isInitialized: Boolean
            get() = _instance != null

        @Volatile
        var isFlutterAlive: Boolean = false

        fun initialize(application: Application) {
            if (_instance == null) {
                synchronized(this) {
                    if (_instance == null) {
                        _instance = OmiBleManager(application).apply {
                            purgeGhostGatts()
                        }
                    }
                }
            }
        }

        private val CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    interface BleConnectionListener {
        fun onGattConnected(address: String, gatt: BluetoothGatt)
        fun onGattDisconnected(address: String, gattHash: Int, status: Int)
        fun onGattServicesDiscovered(address: String, services: List<BleService>)
        fun onMtuChanged(address: String, mtu: Int, status: Int)
        fun onCharacteristicChanged(address: String, serviceUuid: String, charUuid: String, value: ByteArray)
    }

    @Volatile
    var connectionListener: BleConnectionListener? = null

    @Volatile
    var flutterApi: BleFlutterApi? = null

    /// Application context for components (e.g. BleHostApiImpl) that need to start
    /// the foreground service when no Activity is available (background).
    val app: Application get() = application

    private val bluetoothManager = application.getSystemService(Application.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter
    val mainHandler = Handler(Looper.getMainLooper())

    val connectedGatts = ConcurrentHashMap<String, BluetoothGatt>()
    private val discoveryTimeouts = ConcurrentHashMap<String, Runnable>()
    private val readCompletions = ConcurrentHashMap<String, (Result<ByteArray>) -> Unit>()
    private val writeCompletions = ConcurrentHashMap<String, (Result<Unit>) -> Unit>()

    private val servicesDiscoveredFor = ConcurrentHashMap.newKeySet<String>()

    private var isScanning = false
    private var scanCallback: ScanCallback? = null
    private var scanTimeoutRunnable: Runnable? = null

    private val gattQueue: ConcurrentLinkedQueue<GattCommand> = ConcurrentLinkedQueue()
    @Volatile
    private var isProcessingCommand = false

    // Single field, not keyed by address: the app manages exactly one peripheral at a
    // time (one paired device in prefs, one NativeBleTransport), so there is never a
    // second device whose start could cancel this one's callback.
    private var rssiKeepAliveRunnable: Runnable? = null
    private val rssiKeepAliveInterval = 3000L

    private var storageKeepAliveRunnable: Runnable? = null
    // Paired with the firmware's idle-disconnect window (transport.c
    // IDLE_DISCONNECT_TIMEOUT_MS, 60 s) and with Dart's own keep-alive
    // (device_provider._startForegroundKeepAlive, 10 s). All three move together.
    //
    // The margin is the point, and it is load-bearing for a reason found the hard way:
    // a cadence equal to the idle window leaves none, and a single silently-dropped
    // write — Android flow-control backoff will do it — was enough to trip the
    // idle-drop. At 10 s against 60 s, six beats fit the window and five may be missed.
    // (The previous pairing was 5 s against 15 s, three beats.)
    //
    // This is also the tick that actually dominates GATT wake traffic, not Dart's:
    // there are two keep-alives, and lowering only the Dart one changes nothing.
    private val storageKeepAliveInterval = 10_000L
    private val STORAGE_SERVICE_UUID = UUID.fromString("30295780-4301-eabd-2904-2849adfeae43")
    private val STORAGE_CHAR_UUID    = UUID.fromString("30295781-4301-eabd-2904-2849adfeae43")

    private var bondCompletionCallback: ((Boolean) -> Unit)? = null
    private var bondTimeoutRunnable: Runnable? = null
    private var bondingAddress: String? = null

    val activeDownloads = ConcurrentHashMap<String, StorageDownloadSession>()

    private val bondStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
            val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE) ?: return
            val bondState = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)
            val address = device.address.uppercase()

            if (address != bondingAddress) return
            when (bondState) {
                BluetoothDevice.BOND_BONDED -> completeBond(true)
                BluetoothDevice.BOND_NONE -> completeBond(false)
            }
        }
    }

    init {
        application.registerReceiver(bondStateReceiver, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED))
    }

    @SuppressLint("MissingPermission")
    private fun purgeGhostGatts() {
        try {
            val systemConnectedDevices = bluetoothManager.getConnectedDevices(BluetoothProfile.GATT)
            for (device in systemConnectedDevices) {
                val addr = device.address.uppercase()
                // Only target Omi devices to avoid disconnecting user's other smart devices (e.g. Garmin, HR monitors)
                if (device.name?.startsWith("Omi", ignoreCase = true) == true) {
                    if (!connectedGatts.containsKey(addr)) {
                        Log.w(TAG, "Found ghost GATT client for $addr on launch. Purging via dummy connect-close.")
                        val dummyGatt = device.connectGatt(application, false, object : BluetoothGattCallback() {}, BluetoothDevice.TRANSPORT_LE)

                        // Immediately disconnect and close to flush the OS daemon state
                        dummyGatt?.disconnect()
                        dummyGatt?.close()
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to purge ghost GATTs: ${e.message}")
        }
    }

    // ACL-level connection check via the hidden BluetoothDevice.isConnected() API.
    // getConnectedDevices(GATT) only lists links with a registered GATT client; OEM
    // stacks can hold a bare ACL link (e.g. a passive reconnect surviving gatt.close())
    // that never appears there — the exact state seen in the 2026-07-08 wedge, where
    // the GATT list stayed empty for 30+ minutes while the firmware's slot was held.
    // Reflection failure (API removed/blocked) degrades to false, i.e. pre-fix behavior.
    private fun isAclConnected(device: BluetoothDevice): Boolean {
        return try {
            device.javaClass.getMethod("isConnected").invoke(device) as? Boolean ?: false
        } catch (e: Exception) {
            Log.w(TAG, "isConnected() reflection failed for ${device.address}: ${e.message}")
            false
        }
    }

    // Same device-resolution rule as connectGatt: API 34+ resolves by LE random
    // address (the nRF5340 advertises a random static address), older falls back to
    // getRemoteDevice. Keep the two paths identical so a purge targets exactly the
    // device object a subsequent connect will use.
    private fun remoteLeDevice(addr: String): BluetoothDevice? {
        val adapter = bluetoothAdapter ?: return null
        return if (android.os.Build.VERSION.SDK_INT >= 34) {
            adapter.getRemoteLeDevice(addr, BluetoothDevice.ADDRESS_TYPE_RANDOM)
        } else {
            adapter.getRemoteDevice(addr)
        }
    }

    // Targeted ghost-GATT purge for one address — an in-app analog of toggling phone
    // Bluetooth. If the system still reports this device connected (GATT-profile list,
    // or a bare ACL link via isConnected()) while WE hold no handle for it, a stale
    // OS/OEM link is occupying the peripheral's single connection slot and blocking our
    // reconnect (the "toggle BT to reconnect" wedge). Drop it via a dummy connect-close
    // so the next connectGatt can get in. Returns true only if a purge was performed.
    // Conditional by design: no dummy GATT is created when there is no evidence of a
    // system-held connection, so it is a no-op on a healthy disconnect — unless [force]
    // is set, for callers that have independent evidence of the wedge (a run of connect
    // attempts timing out with no GATT callback at all): some OEM stacks hold the link
    // where neither query can see it, and the dummy connect-close against a genuinely
    // absent device is harmless (the client is unregistered immediately).
    /**
     * Drop a stale system-held link to [address] so it stops occupying the firmware's
     * single connection slot.
     *
     * Only ever runs when a link genuinely exists — either the GATT profile reports one
     * or the device has a live ACL. There is deliberately no "force" mode: a purge with
     * nothing to purge issues a dummy connectGatt + cancelOpen for no benefit, adding
     * initiator and accept-list churn to a connect that is already failing. The wedge it
     * used to chase was measured (2026-07-08) to be a `0x3e` establishment failure with
     * the peripheral holding *zero* connections — there was never a ghost. See NOTES.md
     * "BLE: advertising but won't connect".
     */
    fun purgeGhostGattForAddress(address: String): Boolean {
        val addr = address.uppercase()
        // Never touch a connection we actually hold.
        if (connectedGatts.containsKey(addr)) return false
        return try {
            val fromGattList = bluetoothManager.getConnectedDevices(BluetoothProfile.GATT)
                .firstOrNull { it.address.uppercase() == addr }
            val device = fromGattList
                ?: remoteLeDevice(addr)?.takeIf { isAclConnected(it) }
                ?: return false
            val why = if (fromGattList != null) "gatt-profile link" else "acl link"
            Log.w(TAG, "Purging ghost GATT for $addr via dummy connect-close ($why)")
            val dummyGatt = device.connectGatt(application, false, object : BluetoothGattCallback() {}, BluetoothDevice.TRANSPORT_LE)
            // Immediately disconnect and close to flush the OS daemon state
            dummyGatt?.disconnect()
            dummyGatt?.close()
            true
        } catch (e: Exception) {
            Log.w(TAG, "purgeGhostGattForAddress failed for $addr: ${e.message}")
            false
        }
    }

    private fun completeBond(success: Boolean) {
        bondTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        bondTimeoutRunnable = null
        bondCompletionCallback?.invoke(success)
        bondCompletionCallback = null
        bondingAddress = null
    }

    fun startScan(timeout: Int, serviceUuids: List<String>) {
        val adapter = bluetoothAdapter ?: return
        if (!adapter.isEnabled) return

        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(application, android.Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED) {
            return
        }

        stopScan()
        val scanner = adapter.bluetoothLeScanner ?: return
        val filters = if (serviceUuids.isNotEmpty()) {
            serviceUuids.map { ScanFilter.Builder().setServiceUuid(ParcelUuid(UUID.fromString(it))).build() }
        } else null

        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val device = result.device
                val peripheral = BlePeripheral(
                    uuid = device.address.uppercase(),
                    name = device.name ?: "",
                    rssi = result.rssi.toLong(),
                    serviceUuids = result.scanRecord?.serviceUuids?.map { it.uuid.toString() } ?: emptyList()
                )
                mainHandler.post { flutterApi?.onPeripheralDiscovered(peripheral) {} }
            }
        }
        scanCallback = callback
        isScanning = true
        scanner.startScan(filters, settings, callback)

        // Also report already connected devices that might not be advertising
        try {
            val systemConnectedDevices = bluetoothManager.getConnectedDevices(BluetoothProfile.GATT)
            for (device in systemConnectedDevices) {
                val peripheral = BlePeripheral(
                    uuid = device.address.uppercase(),
                    name = device.name ?: "",
                    rssi = -50, // Dummy RSSI for connected device
                    serviceUuids = emptyList()
                )
                mainHandler.post { flutterApi?.onPeripheralDiscovered(peripheral) {} }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to get system connected devices: ${e.message}")
        }

        if (timeout > 0) {
            scanTimeoutRunnable = Runnable { stopScan() }
            mainHandler.postDelayed(scanTimeoutRunnable!!, timeout * 1000L)
        }
    }

    fun stopScan() {
        if (!isScanning) return
        isScanning = false
        scanTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        scanCallback?.let { try { bluetoothAdapter?.bluetoothLeScanner?.stopScan(it) } catch (_: Exception) {} }
        scanCallback = null
    }

    fun connectGatt(address: String, autoConnect: Boolean): BluetoothGatt? {
        val addr = address.uppercase()
        val device = remoteLeDevice(addr) ?: return null

        // If we have an existing GATT for this address, close it first to ensure a fresh start
        connectedGatts[addr]?.let {
            Log.i(TAG, "Closing existing GATT for $addr before reconnecting")
            // disconnect() before close(): if the OS still considers this link alive,
            // close() alone releases our client handle but leaves the radio link up with
            // no listener — a ghost occupying the device's single connection slot.
            it.disconnect()
            it.close()
            connectedGatts.remove(addr)
            // Run the same teardown a disconnect would. close() suppresses the
            // STATE_DISCONNECTED callback, so this is the one path where it doesn't happen
            // by itself — and skipping it leaves servicesDiscoveredFor holding the address,
            // which makes onServicesDiscovered early-return for the NEW gatt as "already
            // discovered". The ready event that carries the service table up to Dart then
            // never fires again for this link.
            //
            // Reusing the disconnect hook rather than a bespoke subset: this IS a link
            // teardown, and every piece of it applies (the stale completions, the download
            // streaming over a dead link, the command queue whose in-flight slot belongs to
            // a callback close() just ate). The keep-alives it stops are single-slot and
            // restart on the new link's onGattConnected moments later.
            cleanupPeripheral(addr)
        }

        // Check if device is already connected to the system by another app or previous session
        val systemConnectedDevices = bluetoothManager.getConnectedDevices(BluetoothProfile.GATT)
        val isSystemConnected = systemConnectedDevices.any { it.address.uppercase() == addr }
        
        // If already connected to system, autoConnect=false is much more likely to succeed quickly
        val effectiveAutoConnect = if (isSystemConnected) false else autoConnect
        if (isSystemConnected) {
            Log.i(TAG, "Device $addr is already connected to system, using autoConnect=false")
        }

        val gatt = device.connectGatt(application, effectiveAutoConnect, createGattCallback(), BluetoothDevice.TRANSPORT_LE)
        if (gatt != null) connectedGatts[addr] = gatt
        return gatt
    }

    fun disconnectGatt(address: String) {
        connectedGatts[address.uppercase()]?.disconnect()
    }

    fun closeGatt(address: String) {
        val addr = address.uppercase()
        cleanupPeripheral(addr)
        val gatt = connectedGatts[addr]
        if (gatt != null) {
            // Clear cached state + lingering autoConnect handle before close().
            // OnePlus/Xiaomi stacks otherwise keep a passive reconnect alive
            // after gatt.close(), making the LE link come back on its own and
            // defeating maximize-battery disconnect.
            try {
                val refresh = gatt.javaClass.getMethod("refresh")
                refresh.invoke(gatt)
            } catch (e: Exception) {
                Log.w(TAG, "gatt.refresh() reflection failed for $addr: ${e.message}")
            }
            gatt.close()
        }
        connectedGatts.remove(addr)
    }

    /**
     * True once onServicesDiscovered has landed for the CURRENT gatt on [address].
     *
     * Distinct from [isPeripheralConnected], which reports only the ACL/GATT link state and
     * so goes true a discovery round-trip early. Anything that hands a service table to Dart
     * must gate on this one — the link being up says nothing about gatt.services being filled.
     *
     * Checks the table itself as well as the flag, so the predicate validates what callers
     * actually consume rather than a flag that is merely supposed to imply it. The flag alone
     * is accurate today (both paths that retire a gatt clear it), but that is bookkeeping a
     * future edit could break silently, and the table is the ground truth either way.
     */
    fun hasDiscoveredServices(address: String): Boolean {
        val addr = address.uppercase()
        return servicesDiscoveredFor.contains(addr) && connectedGatts[addr]?.services?.isNotEmpty() == true
    }

    fun isPeripheralConnected(address: String): Boolean {
        val addr = address.uppercase()
        val gatt = connectedGatts[addr] ?: return false
        return bluetoothManager.getConnectionState(gatt.device, BluetoothProfile.GATT) == BluetoothProfile.STATE_CONNECTED
    }

    fun getConnectedDevices(): List<String> {
        return bluetoothManager.getConnectedDevices(BluetoothProfile.GATT).map { it.address.uppercase() }
    }

    /** Every LE link the system holds, with names — for diagnostics that report contention. */
    fun connectedLeLinks(): List<BluetoothDevice> = bluetoothManager.getConnectedDevices(BluetoothProfile.GATT)

    /**
     * Match the central's connection priority to what the link is actually doing:
     * HIGH while a file transfer is in flight, LOW_POWER otherwise.
     *
     * This used to be an unconditional HIGH at service discovery, which pinned the link
     * at ~11.25 ms with no slave latency for its entire life — waking the peripheral's
     * radio ~89 times a second on a 150 mAh cell whether or not a byte was moving. Most
     * of a connection is not transfer: discovery, capability reads, a file listing, then
     * long stretches of nothing while the app is foregrounded.
     *
     * The central has the final say on connection parameters, so this has to agree with
     * the peripheral's own request or the two fight — the firmware asks for 100-200 ms
     * when idle and 7.5-22.5 ms during a transfer (transport.c CONN_PARAM_IDLE_* /
     * CONN_PARAM_XFER_*). Keep the pairing intact when changing either side.
     *
     * Driven by [activeDownloads] rather than by transition callbacks: it is the same
     * state the firmware keys off (storage_transfer_active) and it cannot drift, since
     * every caller removes its session before completing it.
     */
    private fun applyConnectionPriority(address: String) {
        val addr = address.uppercase()
        val gatt = connectedGatts[addr] ?: return
        val transferring = activeDownloads.containsKey(addr)
        val priority = if (transferring) {
            BluetoothGatt.CONNECTION_PRIORITY_HIGH
        } else {
            BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER
        }
        try {
            gatt.requestConnectionPriority(priority)
            Log.i(TAG, "Connection priority for $addr -> ${if (transferring) "HIGH (transfer)" else "LOW_POWER (idle)"}")
        } catch (e: Exception) {
            Log.w(TAG, "requestConnectionPriority failed for $addr: ${e.message}")
        }
    }

    /**
     * Whether the system holds a bare ACL link to [address] that the GATT profile list
     * does not show. Distinguishes "a stale link is holding the peripheral's slot" from
     * "nothing is connected and the link keeps dying at establishment".
     */
    fun isAclConnectedTo(address: String): Boolean {
        val device = remoteLeDevice(address.uppercase()) ?: return false
        return isAclConnected(device)
    }

    fun requestBond(address: String, completion: (Result<Boolean>) -> Unit) {
        val addr = address.uppercase()
        val device = connectedGatts[addr]?.device
        if (device == null) {
            completion(Result.failure(Exception("Not connected")))
            return
        }
        if (device.bondState == BluetoothDevice.BOND_BONDED) {
            completion(Result.success(true))
            return
        }
        if (device.bondState == BluetoothDevice.BOND_BONDING) {
            // Bonding already in progress (e.g. reconnect during first pairing attempt).
            // Register callback to ride the existing bond completion — don't call createBond() again,
            // which would show a second system pairing dialog.
            bondingAddress = addr
            bondCompletionCallback = { bonded -> completion(Result.success(bonded)) }
            return
        }
        bondingAddress = addr
        bondCompletionCallback = { bonded -> completion(Result.success(bonded)) }
        device.createBond()
        val timeout = Runnable {
            bondingAddress = null
            bondCompletionCallback?.invoke(false)
            bondCompletionCallback = null
        }
        bondTimeoutRunnable = timeout
        mainHandler.postDelayed(timeout, BOND_TIMEOUT_MS)
    }

    fun readCharacteristic(address: String, serviceUuid: String, charUuid: String, completion: (Result<ByteArray>) -> Unit) {
        val addr = address.uppercase()
        val gatt = connectedGatts[addr]
        val characteristic = findCharacteristic(gatt, serviceUuid, charUuid)
        if (gatt == null || characteristic == null) {
            completion(Result.failure(Exception("Not found")))
            return
        }
        val key = "$addr:$serviceUuid:$charUuid".lowercase()
        readCompletions[key] = completion
        // Label mirrors NativeBleTransport's own timeout line (`read <service>:<char>`) so a
        // Dart give-up and the native truth about the same operation grep together.
        enqueueCommand("read $serviceUuid:$charUuid") {
            if (gatt.readCharacteristic(characteristic) == false) {
                readCompletions.remove(key)?.invoke(Result.failure(Exception("Rejected")))
                completeCommand()
            }
        }
    }

    fun writeCharacteristic(address: String, serviceUuid: String, charUuid: String, data: ByteArray, completion: (Result<Unit>) -> Unit) {
        val addr = address.uppercase()
        val gatt = connectedGatts[addr]
        val characteristic = findCharacteristic(gatt, serviceUuid, charUuid)
        if (gatt == null || characteristic == null) {
            completion(Result.failure(Exception("Not found")))
            return
        }
        val writeType = if (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) {
            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        } else BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT

        val key = "$addr:$serviceUuid:$charUuid".lowercase()
        if (writeType == BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) writeCompletions[key] = completion

        enqueueCommand("write $serviceUuid:$charUuid") {
            val result = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                val r = gatt.writeCharacteristic(characteristic, data, writeType)
                if (r != BluetoothStatusCodes.SUCCESS) Log.e(TAG, "writeCharacteristic returned $r for $key")
                r
            } else {
                @Suppress("DEPRECATION")
                characteristic.value = data
                characteristic.writeType = writeType
                if (gatt.writeCharacteristic(characteristic)) BluetoothStatusCodes.SUCCESS else BluetoothStatusCodes.ERROR_UNKNOWN
            }
            if (result != BluetoothStatusCodes.SUCCESS) {
                writeCompletions.remove(key)?.invoke(Result.failure(Exception("Rejected: $result")))
                completeCommand()
            } else if (writeType == BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) {
                completeCommand()
            }
        }
        if (writeType == BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) completion(Result.success(Unit))
    }

    fun subscribeCharacteristic(address: String, serviceUuid: String, charUuid: String) {
        val addr = address.uppercase()
        val gatt = connectedGatts[addr] ?: return
        val characteristic = findCharacteristic(gatt, serviceUuid, charUuid) ?: return
        val descriptor = characteristic.getDescriptor(CCCD_UUID)
        enqueueCommand("subscribe $serviceUuid:$charUuid") {
            gatt.setCharacteristicNotification(characteristic, true)
            if (descriptor != null) {
                writeDescriptorCompat(gatt, descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            } else completeCommand()
        }
    }

    fun unsubscribeCharacteristic(address: String, serviceUuid: String, charUuid: String) {
        val addr = address.uppercase()
        val gatt = connectedGatts[addr] ?: return
        val characteristic = findCharacteristic(gatt, serviceUuid, charUuid) ?: return
        val descriptor = characteristic.getDescriptor(CCCD_UUID)
        enqueueCommand("unsubscribe $serviceUuid:$charUuid") {
            gatt.setCharacteristicNotification(characteristic, false)
            if (descriptor != null) {
                writeDescriptorCompat(gatt, descriptor, BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)
            } else completeCommand()
        }
    }

    fun startRssiKeepAlive(address: String) {
        stopRssiKeepAlive()
        val addr = address.uppercase()
        val runnable = object : Runnable {
            override fun run() {
                connectedGatts[addr]?.readRemoteRssi()
                mainHandler.postDelayed(this, rssiKeepAliveInterval)
            }
        }
        rssiKeepAliveRunnable = runnable
        mainHandler.postDelayed(runnable, rssiKeepAliveInterval)
    }

    fun stopRssiKeepAlive() {
        rssiKeepAliveRunnable?.let { mainHandler.removeCallbacks(it) }
        rssiKeepAliveRunnable = null
    }

    // Sends 0x32 (KEEP_ALIVE) to the storage characteristic on [storageKeepAliveInterval]
    // (10 s) using WRITE_NO_RESPONSE so it bypasses the GATT command queue. Resets the
    // firmware's idle-disconnect timer (transport.c IDLE_DISCONNECT_TIMEOUT_MS, 60 s)
    // across an idle connection; it is skipped while a transfer is active, since the
    // firmware exempts those from the idle check anyway (see the runnable below). Bypassing
    // the queue is what lets it beat during other GATT work — and the reason it must stand
    // down for a transfer, whose stream shares this characteristic. See the interval's own
    // comment for why all three constants move together.
    fun startStorageKeepAlive(address: String) {
        stopStorageKeepAlive()
        val addr = address.uppercase()
        val runnable = object : Runnable {
            override fun run() {
                // Skipped while a file transfer is in flight — the same guard Dart's
                // keep-alive has always had (DeviceConnection.sendKeepAlive's isStorageBusy
                // check) and which this backstop, added later for background throttling,
                // never inherited. Safe because the firmware exempts an active transfer from
                // its idle-disconnect entirely (transport.c storage_transfer_active()), so
                // nothing needs to beat here; the transfer's own traffic is the liveness.
                // Two reasons it must not: this write bypasses gattQueue, so it races the
                // read stream it shares a characteristic with; and the firmware ACKs it on
                // that same characteristic, which is what used to keep StorageDownload-
                // Session's inactivity watchdog permanently re-armed. Keep reposting so the
                // beat resumes the moment the transfer ends.
                if (!activeDownloads.containsKey(addr)) sendStorageKeepAliveNoResponse(addr)
                mainHandler.postDelayed(this, storageKeepAliveInterval)
            }
        }
        storageKeepAliveRunnable = runnable
        mainHandler.postDelayed(runnable, storageKeepAliveInterval)
    }

    fun stopStorageKeepAlive() {
        storageKeepAliveRunnable?.let { mainHandler.removeCallbacks(it) }
        storageKeepAliveRunnable = null
    }

    private fun sendStorageKeepAliveNoResponse(address: String) {
        val addr = address.uppercase()
        val gatt = connectedGatts[addr] ?: return
        val characteristic = gatt.getService(STORAGE_SERVICE_UUID)?.getCharacteristic(STORAGE_CHAR_UUID) ?: return
        val data = ByteArray(1) { 0x32 }
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(characteristic, data, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE)
            } else {
                @Suppress("DEPRECATION")
                characteristic.value = data
                characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                gatt.writeCharacteristic(characteristic)
            }
        } catch (e: Exception) {
            Log.w(TAG, "sendStorageKeepAliveNoResponse failed for $addr: ${e.message}")
        }
    }

    fun getBluetoothState(): String {
        val adapter = bluetoothAdapter ?: return "unsupported"
        return when (adapter.state) {
            BluetoothAdapter.STATE_ON -> "on"
            BluetoothAdapter.STATE_OFF -> "off"
            else -> "resetting"
        }
    }

    /**
     * A queued GATT operation and the label it reports itself under in the debug log.
     * [label] is required rather than defaulted: an unlabelled command is invisible in
     * exactly the situation this instrumentation exists for.
     */
    private class GattCommand(val label: String, val run: Runnable)

    // ── Command-pipeline stall instrumentation (log-only) ──
    //
    // The pipeline is single-in-flight: processNextCommand posts one command and nothing
    // else moves until completeCommand() runs, which only a GATT callback (or
    // cleanupPeripheral, on teardown) triggers. So an operation whose callback never
    // arrives silently parks every later command — a subscribe, a CMD_READ_FILE — for the
    // life of the connection, while the link still reports connected.
    //
    // Dart cannot see this. Its 10 s _gattOpTimeout abandons the Dart future only; native
    // is never told, so "timed out" there covers both a genuinely wedged pipeline and one
    // that was merely slow and recovered a second later. Those want opposite fixes.
    //
    // Written through WedgeDiagnostics so the lines land in the app's own debug log rather
    // than logcat — a wedge usually happens with the app backgrounded, where reaching for
    // adb after the fact is exactly what does not work.
    private var inFlightLabel: String? = null
    private var inFlightSinceMs = 0L
    private var inFlightWarnCount = 0
    // First warning at Dart's give-up point so the two lines bracket each other in the log;
    // then a slower repeat, which is enough to show it is still stuck without flooding.
    private val commandStallWarnMs = 10_000L
    private val commandStallRepeatMs = 30_000L
    private val commandStallWatchdog = Runnable { reportCommandStall() }

    /**
     * True wall clock (elapsedRealtime), so a reported age is never quietly short by the
     * time the SoC spent asleep. The watchdog's own scheduling is uptime-based, as all
     * Handler posts are, so it simply does not fire across a suspend — the age it prints on
     * the other side is still correct.
     */
    private fun commandAgeMs(): Long = android.os.SystemClock.elapsedRealtime() - inFlightSinceMs

    @Synchronized private fun reportCommandStall() {
        val label = inFlightLabel ?: return
        inFlightWarnCount++
        val age = commandAgeMs()
        val behind = (gattQueue.size - 1).coerceAtLeast(0)
        Log.w(TAG, "GATT command '$label' outstanding ${age}ms, $behind queued behind — " +
            "its callback has not arrived; nothing else in the pipeline can be sent until it does")
        WedgeDiagnostics.captureGattCommand(application, "stalled", label, age, behind)
        mainHandler.postDelayed(commandStallWatchdog, commandStallRepeatMs)
    }

    /** Arms the stall watchdog for the command just posted. Caller holds the monitor. */
    private fun beginCommandTiming(label: String) {
        inFlightLabel = label
        inFlightSinceMs = android.os.SystemClock.elapsedRealtime()
        inFlightWarnCount = 0
        mainHandler.removeCallbacks(commandStallWatchdog)
        mainHandler.postDelayed(commandStallWatchdog, commandStallWarnMs)
    }

    /**
     * Closes out the in-flight command's timing. [outcome] is "recovered" when a callback
     * finally arrived and "abandoned" when the peripheral was torn down with it still
     * outstanding. Only reports when the command had already been warned about, so a
     * healthy pipeline writes nothing at all. Caller holds the monitor (see
     * [resetCommandPipeline] for the teardown path, which takes it itself).
     */
    private fun endCommandTiming(outcome: String) {
        val label = inFlightLabel ?: return
        val age = commandAgeMs()
        val warned = inFlightWarnCount > 0
        mainHandler.removeCallbacks(commandStallWatchdog)
        inFlightLabel = null
        inFlightWarnCount = 0
        if (!warned) return
        val behind = (gattQueue.size - 1).coerceAtLeast(0)
        Log.w(TAG, "GATT command '$label' $outcome after ${age}ms ($behind queued behind)")
        WedgeDiagnostics.captureGattCommand(application, outcome, label, age, behind)
    }

    /**
     * Drop the in-flight command and everything queued behind it, as one indivisible step.
     *
     * [cleanupPeripheral] used to do this as three loose statements with only the first
     * holding the monitor, which left two ways for a dead connection to corrupt the *next*
     * one's pipeline:
     *
     * - An `enqueueCommand` landing between them was either wiped by the `clear()` or left
     *   in the queue unprocessed — its [processNextCommand] had already seen
     *   [isProcessingCommand] still `true`, and nothing re-runs it until some later enqueue
     *   happens along. The queue is `ConcurrentLinkedQueue`, so each statement is
     *   individually safe; it is the sequence that was not.
     * - [processNextCommand] posts the head to `mainHandler`, and clearing the queue does
     *   not unpost it. It then ran against the closed gatt and, on the failure paths that
     *   call [completeCommand] (`writeDescriptorCompat`, the write/read helpers), polled the
     *   queue — popping whatever the new connection had since enqueued, and dropping
     *   [isProcessingCommand] while that command was genuinely in flight.
     *
     * Deliberately its own method rather than `@Synchronized` on [cleanupPeripheral]: that
     * one also invokes the Dart read/write completions, which can re-enter this class.
     */
    @Synchronized private fun resetCommandPipeline() {
        // Report first: this is the only place that learns a stalled command never came
        // back, and the queue length behind it is gone a line later.
        endCommandTiming("abandoned")
        // Only unposts a head that has not started; a runnable already executing runs to
        // completion. That residue is deliberately left alone, and reviewers have now asked
        // three times, so the trace is here rather than in a PR thread.
        //
        // For an already-started A to hurt, its completion must retire a command belonging to
        // the *live* link — so something must have enqueued one, and every enqueue site is
        // either on the main thread (Dart's read/write/subscribe/CMD_READ_FILE via Pigeon,
        // which has no TaskQueue, plus requestMtu's postDelayed) or is
        // onConnectionStateChange(CONNECTED)'s discoverServices on a binder thread:
        //
        // - Main-thread enqueues cannot run while A occupies the main thread, so they land
        //   only after A's body has returned. Before a reconnect, connectedGatts still holds
        //   the dead gatt, so what they enqueue is a command on a dead link — retiring it
        //   early costs nothing and leaves the pipeline consistent (empty queue, flag down).
        // - For an enqueue to belong to the NEW link, connectedGatts must already hold the
        //   new instance, and every assignment to it is preceded by close() on the old one
        //   (connectGatt disconnects+closes+removes first, and refuses outright while an
        //   entry exists). close() unregisters the client, so the old gatt delivers nothing
        //   after that point — A's completion cannot arrive to retire the new command.
        //
        // A per-gatt identity parameter on [completeCommand] was tried and reverted: it
        // guarded that unreachable case at the cost of a required argument in 16 places, and
        // was itself incomplete — doing it properly needs readCompletions, writeCompletions
        // and servicesDiscoveredFor scoped per gatt too.
        gattQueue.peek()?.let { mainHandler.removeCallbacks(it.run) }
        gattQueue.clear()
        isProcessingCommand = false
    }

    @Synchronized fun enqueueCommand(label: String, command: Runnable) {
        gattQueue.add(GattCommand(label, command))
        processNextCommand()
    }
    @Synchronized private fun processNextCommand() {
        if (isProcessingCommand) return
        val cmd = gattQueue.peek() ?: return
        isProcessingCommand = true
        beginCommandTiming(cmd.label)
        mainHandler.post(cmd.run)
    }
    @Synchronized fun completeCommand() {
        // Cheap invariant assertion, and deliberately no more than that: nothing legitimate
        // reaches here with the flag down, because [processNextCommand] only posts a command
        // once it has raised it — so a queue head seen while this is `false` has not been
        // sent, and polling it would discard an unsent command rather than retire a finished
        // one.
        //
        // It is NOT what protects the next connection's command from a stale callback. Once
        // that connection has posted something the flag is true again, raised by *its*
        // command, so this test cannot tell the two apart. What keeps a stale runnable from
        // reaching here at all is the removeCallbacks in [resetCommandPipeline].
        if (!isProcessingCommand) return
        endCommandTiming("recovered")
        gattQueue.poll()
        isProcessingCommand = false
        processNextCommand()
    }

    private fun findCharacteristic(gatt: BluetoothGatt?, serviceUuid: String, characteristicUuid: String): BluetoothGattCharacteristic? =
        gatt?.getService(UUID.fromString(serviceUuid))?.getCharacteristic(UUID.fromString(characteristicUuid))

    @Suppress("DEPRECATION")
    private fun writeDescriptorCompat(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, value: ByteArray) {
        val success = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(descriptor, value) == BluetoothStatusCodes.SUCCESS
        } else {
            descriptor.value = value
            gatt.writeDescriptor(descriptor)
        }
        if (!success) {
            Log.e(TAG, "writeDescriptor failed for ${descriptor.uuid}")
            completeCommand()
        }
    }

    fun cleanupPeripheral(address: String) {
        val addr = address.uppercase()
        servicesDiscoveredFor.remove(addr)
        discoveryTimeouts.remove(addr)?.let { mainHandler.removeCallbacks(it) }
        stopRssiKeepAlive()
        stopStorageKeepAlive()
        val prefix = addr.lowercase()
        readCompletions.keys().toList().filter { it.startsWith(prefix) }.forEach { readCompletions.remove(it)?.invoke(Result.failure(Exception("Disconnected"))) }
        writeCompletions.keys().toList().filter { it.startsWith(prefix) }.forEach { writeCompletions.remove(it)?.invoke(Result.failure(Exception("Disconnected"))) }
        // Drop any queued (and the in-flight) GATT command. A with-response write
        // on a wedged link never gets onCharacteristicWrite, so completeCommand()
        // never runs and the in-flight command stays at the head of gattQueue with
        // isProcessingCommand stuck true. Resetting only the flag would leave that
        // stale command (referencing the now-dead gatt) to be re-posted on the next
        // enqueue after reconnect. Clear the queue so the next connection starts
        // with a clean command pipeline. One call, because the three steps it used to
        // take were separable and a racing enqueue could land between them — see
        // [resetCommandPipeline].
        resetCommandPipeline()
        activeDownloads.remove(addr)?.complete(Result.failure(Exception("Stream closed without EOT")))
    }

    private fun createGattCallback() = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val address = gatt.device.address.uppercase()
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                connectedGatts[address] = gatt

                // Add timeout for discovery
                val discoveryTimeout = Runnable {
                    if (!servicesDiscoveredFor.contains(address)) {
                        Log.e(TAG, "Service discovery timeout for $address")
                        cleanupPeripheral(address)
                        connectionListener?.onGattDisconnected(address, gatt.hashCode(), -1)
                        gatt.disconnect()
                        gatt.close()
                    }
                }
                discoveryTimeouts[address] = discoveryTimeout
                mainHandler.postDelayed(discoveryTimeout, DISCOVERY_TIMEOUT_MS)

                enqueueCommand("discoverServices $address") {
                    if (!gatt.discoverServices()) {
                        mainHandler.removeCallbacks(discoveryTimeout)
                        discoveryTimeouts.remove(address)
                        completeCommand()
                    }
                }
                connectionListener?.onGattConnected(address, gatt)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                cleanupPeripheral(address)
                connectionListener?.onGattDisconnected(address, gatt.hashCode(), status)
            }
        }
        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            completeCommand()
            connectionListener?.onMtuChanged(gatt.device.address.uppercase(), mtu, status)
        }
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val address = gatt.device.address.uppercase()

            discoveryTimeouts.remove(address)?.let { mainHandler.removeCallbacks(it) }

            if (servicesDiscoveredFor.contains(address) || status != BluetoothGatt.GATT_SUCCESS) { completeCommand(); return }
            val bleServices = gatt.services.map { svc ->
                BleService(svc.uuid.toString().lowercase(), svc.characteristics?.map { it.uuid.toString().lowercase() } ?: emptyList())
            }
            servicesDiscoveredFor.add(address)
            applyConnectionPriority(address)
            completeCommand()
            connectionListener?.onGattServicesDiscovered(address, bleServices)
        }
        override fun onCharacteristicChanged(gatt: BluetoothGatt, char: BluetoothGattCharacteristic, value: ByteArray) {
            connectionListener?.onCharacteristicChanged(gatt.device.address.uppercase(), char.service.uuid.toString().lowercase(), char.uuid.toString().lowercase(), value)
        }
        @Suppress("DEPRECATION") override fun onCharacteristicChanged(gatt: BluetoothGatt, char: BluetoothGattCharacteristic) {
            onCharacteristicChanged(gatt, char, char.value ?: return)
        }
        override fun onCharacteristicRead(gatt: BluetoothGatt, char: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            val key = "${gatt.device.address.uppercase()}:${char.service.uuid}:${char.uuid}".lowercase()
            val res = if (status == BluetoothGatt.GATT_SUCCESS) Result.success(value) else Result.failure(Exception("Error $status"))
            readCompletions.remove(key)?.invoke(res)
            completeCommand()
        }
        @Suppress("DEPRECATION") override fun onCharacteristicRead(gatt: BluetoothGatt, char: BluetoothGattCharacteristic, status: Int) {
            onCharacteristicRead(gatt, char, char.value ?: ByteArray(0), status)
        }
        override fun onCharacteristicWrite(gatt: BluetoothGatt, char: BluetoothGattCharacteristic, status: Int) {
            val key = "${gatt.device.address.uppercase()}:${char.service.uuid}:${char.uuid}".lowercase()
            val res = if (status == BluetoothGatt.GATT_SUCCESS) Result.success(Unit) else Result.failure(Exception("Error $status"))
            writeCompletions.remove(key)?.invoke(res)
            completeCommand()
        }
        override fun onDescriptorWrite(gatt: BluetoothGatt, desc: BluetoothGattDescriptor, status: Int) { completeCommand() }
    }

    // ── Native storage file download ──
    //
    // Receives BLE notifications directly on the binder thread, bypassing the
    // mainHandler.post → platform channel path that throttles in Android background.

    fun downloadStorageFile(
        address: String,
        fileIndex: Int,
        offset: Long,
        timerStart: Long,
        outputPath: String,
        callback: (Result<Unit>) -> Unit
    ) {
        val addr = address.uppercase()
        val gatt = connectedGatts[addr]
        if (gatt == null) {
            callback(Result.failure(Exception("Not connected")))
            return
        }
        val characteristic = gatt.getService(STORAGE_SERVICE_UUID)?.getCharacteristic(STORAGE_CHAR_UUID)
        if (characteristic == null) {
            callback(Result.failure(Exception("Storage characteristic not found")))
            return
        }

        // Subscribe to notifications so the binder-thread callback fires.
        // Goes through the GATT queue so it completes before CMD_READ_FILE.
        subscribeCharacteristic(addr, STORAGE_SERVICE_UUID.toString(), STORAGE_CHAR_UUID.toString())

        // Register session BEFORE enqueuing CMD_READ_FILE so the start-ACK (0x03 0x00)
        // is never missed if the write callback and the notification race.
        val session = StorageDownloadSession(addr, offset, outputPath, callback)
        activeDownloads[addr] = session
        // Registered, so applyConnectionPriority now reads "transferring". Raised before
        // CMD_READ_FILE is enqueued rather than on the first packet: the whole point is
        // for the fast interval to be in force by the time data starts arriving.
        applyConnectionPriority(addr)

        // Build CMD_READ_FILE: [0x11, fileIndex, offset 4B LE, timerStart 4B LE]
        val cmd = ByteArray(10)
        cmd[0] = 0x11.toByte()
        cmd[1] = fileIndex.toByte()
        cmd[2] = (offset and 0xFF).toByte()
        cmd[3] = ((offset shr 8) and 0xFF).toByte()
        cmd[4] = ((offset shr 16) and 0xFF).toByte()
        cmd[5] = ((offset shr 24) and 0xFF).toByte()
        cmd[6] = (timerStart and 0xFF).toByte()
        cmd[7] = ((timerStart shr 8) and 0xFF).toByte()
        cmd[8] = ((timerStart shr 16) and 0xFF).toByte()
        cmd[9] = ((timerStart shr 24) and 0xFF).toByte()

        val writeType = if (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0)
            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        else
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT

        enqueueCommand("CMD_READ_FILE idx=$fileIndex off=$offset ts=$timerStart") {
            val success = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(characteristic, cmd, writeType) == android.bluetooth.BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                characteristic.value = cmd
                @Suppress("DEPRECATION")
                characteristic.writeType = writeType
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(characteristic)
            }
            if (!success) {
                activeDownloads.remove(addr)
                session.complete(Result.failure(Exception("Could not start SD card read")))
            }
            if (writeType == BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) completeCommand()
        }
    }

    inner class StorageDownloadSession(
        private val address: String,
        startOffset: Long,
        outputPath: String,
        private val callback: (Result<Unit>) -> Unit
    ) {
        private var expectedOffset = startOffset
        private val fos: java.io.FileOutputStream
        private val completed = java.util.concurrent.atomic.AtomicBoolean(false)
        private var hasReceivedStartAck = false
        // Selects which inactivity window applies (see [timeoutMs]). Distinct from
        // hasReceivedStartAck, which the keep-alive's ACK can also set — that flag says
        // "the stream is open", this one says "the device is actually delivering".
        // Volatile: written on the binder thread (onPacket), read on main when the
        // timeout fires. The functional read — picking the delay — happens on the binder
        // thread, so only the message text depends on the cross-thread one, but there is
        // no reason to leave that unsynchronised.
        @Volatile private var hasReceivedData = false

        // Inactivity timeout: armed at init, re-armed only by DATA — see [rearmTimeout].
        // Keep the "Transfer stalled" prefix: syncAll's retry loop matches on it
        // (sdcard_wal_sync.dart) to retry the file in place rather than fail the sync.
        private val timeoutRunnable = Runnable {
            activeDownloads.remove(address)
            complete(Result.failure(Exception("Transfer stalled: ${timeoutMs() / 1000}s inactivity timeout")))
        }

        /**
         * Only *payload* traffic counts as liveness. ACKs must never re-arm this.
         *
         * The keep-alive (0x32, [storageKeepAliveInterval]) is answered by the firmware
         * with a PACKET_ACK notification on this same characteristic (storage.c
         * storage_write_handler → STORAGE_NOTIFY), which lands here as a 0x03 packet.
         * Re-arming on every packet meant a 10 s ACK cadence perpetually reset a 15 s
         * watchdog: a transfer that died mid-file could never time out, downloadStorage-
         * File never completed, and since Dart awaits it with no timeout of its own the
         * sync hung until the 60 s pipeline watchdog force-recovered — by recycling the
         * GATT, which turned a stalled file into a dropped connection and a partial sync.
         *
         * Two windows, because the two phases have different expectations:
         *  - START (30 s): CMD_READ_FILE sent, no payload yet. The firmware still has to
         *    open + seek the file, and an SD op can block for ~10 s under write pressure
         *    (storage.c's own CMD_LIST_FILES guard waits that long), so this is
         *    deliberately looser than the stream window. Never re-armed — one window for
         *    the whole setup phase — which keeps the worst case at 30 s, comfortably
         *    inside the 60 s Dart watchdog so native still owns this failure.
         *  - STREAM (15 s): unchanged from before, re-armed per DATA packet.
         */
        private fun timeoutMs(): Long = if (hasReceivedData) 15_000L else 30_000L

        private fun rearmTimeout() {
            mainHandler.removeCallbacks(timeoutRunnable)
            mainHandler.postDelayed(timeoutRunnable, timeoutMs())
        }

        init {
            val file = java.io.File(outputPath)
            file.parentFile?.mkdirs()
            fos = java.io.FileOutputStream(file, startOffset > 0)
            rearmTimeout()
        }

        fun onPacket(value: ByteArray) {
            if (completed.get() || value.isEmpty()) return

            when (value[0].toInt() and 0xFF) {
                0x03 -> { // ACK
                    if (value.size >= 2) {
                        val code = value[1].toInt() and 0xFF
                        if (code == 0) hasReceivedStartAck = true
                        else {
                            activeDownloads.remove(address)
                            complete(Result.failure(Exception("Error ACK: $code")))
                        }
                    }
                }
                0x01 -> { // DATA
                    if (!hasReceivedStartAck || value.size < 5) return
                    // Payload in hand: this is the only thing that counts as liveness, and
                    // it also narrows the window from the START grace to the STREAM one.
                    hasReceivedData = true
                    rearmTimeout()
                    val incoming = (value[1].toLong() and 0xFF) or
                        ((value[2].toLong() and 0xFF) shl 8) or
                        ((value[3].toLong() and 0xFF) shl 16) or
                        ((value[4].toLong() and 0xFF) shl 24)
                    val payload = value.copyOfRange(5, value.size)
                    when {
                        incoming > expectedOffset -> {
                            val gapLong = incoming - expectedOffset
                            if (gapLong > MAX_PROTOCOL_GAP_BYTES) {
                                // Implausible gap — treat as a desynced/corrupt offset and fail
                                // rather than allocating up to ~4 GB of zeros. Resume re-fetches.
                                activeDownloads.remove(address)
                                complete(Result.failure(Exception("Protocol gap too large: incoming=$incoming expected=$expectedOffset gap=$gapLong")))
                                return
                            }
                            val gap = gapLong.toInt()
                            Log.w(TAG, "Protocol gap: incoming=$incoming expected=$expectedOffset. Padding with $gap zeros.")
                            val zeros = ByteArray(gap)
                            try { fos.write(zeros) } catch (e: Exception) { activeDownloads.remove(address); complete(Result.failure(e)); return }
                            expectedOffset += gap

                            try { fos.write(payload) } catch (e: Exception) { activeDownloads.remove(address); complete(Result.failure(e)) }
                            expectedOffset += payload.size
                        }
                        incoming < expectedOffset -> {
                            val skip = (expectedOffset - incoming).toInt()
                            if (skip < payload.size) {
                                val tail = payload.copyOfRange(skip, payload.size)
                                try { fos.write(tail) } catch (e: Exception) { activeDownloads.remove(address); complete(Result.failure(e)) }
                                expectedOffset += tail.size
                            }
                        }
                        else -> {
                            try { fos.write(payload) } catch (e: Exception) { activeDownloads.remove(address); complete(Result.failure(e)) }
                            expectedOffset += payload.size
                        }
                    }
                }
                0x02 -> { // EOT — transfer complete
                    activeDownloads.remove(address)
                    // Flush, then finish through complete() like every other exit. This
                    // branch used to inline its own teardown — same CAS, same callback —
                    // which made complete() the funnel for FAILURES only, and left the
                    // successful transfer (the common case) skipping whatever complete()
                    // does. That was harmless while it only closed a stream; it stopped
                    // being harmless when priority restoration moved there, since the link
                    // would then stay at CONNECTION_PRIORITY_HIGH after every successful
                    // download and never return to the idle interval.
                    try { fos.flush() } catch (_: Exception) {}
                    complete(Result.success(Unit))
                }
            }
        }

        fun complete(result: Result<Unit>) {
            if (!completed.compareAndSet(false, true)) return
            mainHandler.removeCallbacks(timeoutRunnable)
            try { fos.close() } catch (_: Exception) {}
            // The single funnel every session ends through, success or failure, guarded by
            // the CAS above so it runs exactly once. Callers remove themselves from
            // activeDownloads before completing, so this re-read sees the transfer gone and
            // drops back to LOW_POWER. Deliberately not removing the entry here: a later
            // session for the same address may already have replaced it, and evicting that
            // would strand a live transfer at idle parameters.
            applyConnectionPriority(address)
            mainHandler.post { callback(result) }
        }
    }
}
