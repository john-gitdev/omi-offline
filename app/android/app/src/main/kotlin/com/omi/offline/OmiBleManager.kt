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

    private val gattQueue: ConcurrentLinkedQueue<Runnable> = ConcurrentLinkedQueue()
    @Volatile
    private var isProcessingCommand = false

    // Single field, not keyed by address: the app manages exactly one peripheral at a
    // time (one paired device in prefs, one NativeBleTransport), so there is never a
    // second device whose start could cancel this one's callback.
    private var rssiKeepAliveRunnable: Runnable? = null
    private val rssiKeepAliveInterval = 3000L

    private var storageKeepAliveRunnable: Runnable? = null
    // 5 s, not 15 s: the firmware idle-disconnect is 15 s, so a 15 s cadence left
    // zero margin — one silently-dropped write (Android flow-control backoff) tripped
    // the idle-drop. 5 s fits 2+ attempts inside the 15 s window, so a single missed
    // keepalive can't disconnect us. Matches the Dart foreground keepalive cadence.
    private val storageKeepAliveInterval = 5_000L
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
            // Retire the state that described the object we just discarded. close()
            // suppresses the STATE_DISCONNECTED callback, so cleanupPeripheral() never runs
            // on this path — and without this, servicesDiscoveredFor would keep the address,
            // making onServicesDiscovered early-return for the NEW gatt as "already
            // discovered", so the ready event that carries the service table up to Dart
            // never fires again for this link.
            //
            // Deliberately the per-address half only, not the whole of cleanupPeripheral():
            // its keep-alive stops take no address, and stopping a second managed device's
            // storage keep-alive would let the firmware idle-disconnect it (that keep-alive
            // only restarts on ITS next onGattConnected, possibly hours away).
            failPerAddressIo(addr, "GATT replaced")
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
        enqueueCommand {
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

        enqueueCommand {
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
        enqueueCommand {
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
        enqueueCommand {
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

    // Sends 0x32 (KEEP_ALIVE) to the storage characteristic every 5 s using
    // WRITE_NO_RESPONSE so it bypasses the GATT command queue and never stalls
    // an in-flight file read. Resets the firmware's 15 s idle-disconnect timer
    // (IDLE_DISCONNECT_TIMEOUT_MS) regardless of whether a data stream is active.
    fun startStorageKeepAlive(address: String) {
        stopStorageKeepAlive()
        val addr = address.uppercase()
        val runnable = object : Runnable {
            override fun run() {
                sendStorageKeepAliveNoResponse(addr)
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

    @Synchronized fun enqueueCommand(command: Runnable) { gattQueue.add(command); processNextCommand() }
    @Synchronized private fun processNextCommand() {
        if (isProcessingCommand) return
        val cmd = gattQueue.peek() ?: return
        isProcessingCommand = true
        mainHandler.post(cmd)
    }
    @Synchronized fun completeCommand() {
        // Ignore a completion arriving with nothing in flight. The flag is false only when
        // no command is outstanding, so this can never reject a real completion — it only
        // rejects a zombie: a command whose pipeline was reset out from under it (a gatt
        // replaced, a disconnect) and whose callback landed anyway, or a callback that
        // fired twice. Unguarded, such a call polls whatever is at the head NOW, which is
        // the next connection's command; that entry was already posted so it still runs,
        // but its own callback then polls a third, and the accounting is off by one from
        // there — commands get posted while another is in flight, breaking the
        // one-op-at-a-time serialization this queue exists to enforce.
        //
        // Narrows the zombie window rather than closing it: a completion landing after the
        // next command has been posted still finds the flag set. Closing it fully means
        // telling completeCommand() WHICH command completed (gatt identity, ~17 call sites
        // across both files), which is its own change.
        if (!isProcessingCommand) return
        gattQueue.poll()
        isProcessingCommand = false
        processNextCommand()
    }

    /**
     * Drop every queued command and release the in-flight slot, for use when the gatt they
     * were built against is going away.
     *
     * The queue and [isProcessingCommand] are process-global, not per-device, so a command
     * whose callback never arrives (close() swallows it) leaves the flag set and
     * [processNextCommand] refuses to run anything for ANY device — including the next
     * connection's discoverServices(). Clearing rather than draining is deliberate: the
     * queue holds bare Runnables with no address, and each captures the gatt it was built
     * for, so running the survivors against a closed handle would just stall again.
     *
     * @Synchronized to match [completeCommand]/[enqueueCommand], which lock on the same
     * monitor. Safe to hold: nothing here blocks or invokes a caller-supplied callback.
     */
    @Synchronized fun resetCommandPipeline() {
        // Unpost the in-flight command before dropping the queue. [processNextCommand] PEEKS
        // rather than polls, so the posted runnable is still the head here — which is the
        // only reference to it there is, and the only entry ever posted (one at a time).
        // Left posted, it can run after the reset, fail against the closed gatt, and call
        // completeCommand() on its way out — which polls the NEW gatt's command off the
        // head. That entry was already posted so it still runs, but its own callback then
        // polls a third entry, and from there the accounting is permanently off by one:
        // commands get posted while another is in flight, breaking the one-op-at-a-time
        // serialization this queue exists to enforce (overlapping GATT ops drop the link
        // with Error 133 on Android).
        gattQueue.peek()?.let { mainHandler.removeCallbacks(it) }
        gattQueue.clear()
        isProcessingCommand = false
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
        // Addressless, so this is the disconnect path's alone — see failPerAddressIo.
        stopRssiKeepAlive()
        stopStorageKeepAlive()
        failPerAddressIo(addr, "Disconnected")
    }

    /**
     * Retire everything tracked for [address] because the gatt it described is gone: the
     * discovery flag and its timeout, the in-flight characteristic ops, the streaming
     * download, and the shared command pipeline.
     *
     * Shared by the two paths that retire a gatt — [cleanupPeripheral] on disconnect and
     * [connectGatt] when it replaces one — so a new per-address map, or a change to the
     * "<addr>:<service>:<char>" completion key format, cannot be added to one and silently
     * missed by the other. [reason] is what the failed callbacks report, and is the only
     * thing that differs between the two.
     *
     * [reason] does NOT apply to the download failure, which must always lead with
     * "Stream closed without EOT". That string is a wire contract, not a message: it travels
     * verbatim through Pigeon into SDCardWalSync's `definiteTransportError` check, which is
     * what stops a mid-transfer link failure from being charged against the file's poison
     * budget. Fail a download with anything else and a dropped link reads as an unreadable
     * file — and enough of those delete a perfectly good recording off the device. The
     * reason is appended for the logs; the Dart side matches with contains().
     *
     * Deliberately does NOT stop the RSSI/storage keep-alives: those take no address, so
     * they belong only to the disconnect path, which knows the whole link is going away.
     *
     * The pipeline reset is not optional here. A with-response write on a dying link never
     * gets its onCharacteristicWrite, so completeCommand() never runs and the in-flight
     * command sits at the head of gattQueue with isProcessingCommand stuck true — which
     * blocks the NEXT connection's discoverServices() and leaves it connected-but-
     * undiscovered, the very state this cleanup exists to prevent. The queue is
     * process-global, so a stuck flag wedges every managed device: clearing is the repair,
     * not collateral.
     */
    private fun failPerAddressIo(addr: String, reason: String) {
        servicesDiscoveredFor.remove(addr)
        discoveryTimeouts.remove(addr)?.let { mainHandler.removeCallbacks(it) }
        val prefix = addr.lowercase()
        readCompletions.keys().toList().filter { it.startsWith(prefix) }.forEach { readCompletions.remove(it)?.invoke(Result.failure(Exception(reason))) }
        writeCompletions.keys().toList().filter { it.startsWith(prefix) }.forEach { writeCompletions.remove(it)?.invoke(Result.failure(Exception(reason))) }
        resetCommandPipeline()
        activeDownloads.remove(addr)?.complete(Result.failure(Exception("Stream closed without EOT ($reason)")))
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

                enqueueCommand {
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
            gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
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

        enqueueCommand {
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

        // Inactivity timeout: 15 s reset on each packet
        private val timeoutRunnable = Runnable {
            activeDownloads.remove(address)
            complete(Result.failure(Exception("Transfer stalled: 15s inactivity timeout")))
        }

        init {
            val file = java.io.File(outputPath)
            file.parentFile?.mkdirs()
            fos = java.io.FileOutputStream(file, startOffset > 0)
            mainHandler.postDelayed(timeoutRunnable, 15_000L)
        }

        fun onPacket(value: ByteArray) {
            if (completed.get() || value.isEmpty()) return

            // Reset inactivity watchdog on every received packet
            mainHandler.removeCallbacks(timeoutRunnable)
            mainHandler.postDelayed(timeoutRunnable, 15_000L)

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
                    try { fos.flush(); fos.close() } catch (_: Exception) {}
                    mainHandler.removeCallbacks(timeoutRunnable)
                    if (completed.compareAndSet(false, true)) {
                        mainHandler.post { callback(Result.success(Unit)) }
                    }
                }
            }
        }

        fun complete(result: Result<Unit>) {
            if (!completed.compareAndSet(false, true)) return
            mainHandler.removeCallbacks(timeoutRunnable)
            try { fos.close() } catch (_: Exception) {}
            mainHandler.post { callback(result) }
        }
    }
}
