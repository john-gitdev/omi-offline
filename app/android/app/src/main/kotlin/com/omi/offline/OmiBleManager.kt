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

/**
 * Pure GATT wrapper — scanning, characteristic ops, and command queue.
 * Connection lifecycle (connect, retry, reconnect) is owned by OmiBleForegroundService.
 * Uses a serialized command queue (Android allows one pending GATT operation at a time).
 * GATT callbacks arrive on binder threads; Pigeon calls are posted to mainHandler.
 */
@SuppressLint("MissingPermission")
class OmiBleManager private constructor(private val application: Application) {

    companion object {
        private const val TAG = "OmiBle"
        private const val BOND_TIMEOUT_MS = 15000L // 15s — bond request timeout

        @Volatile
        private var _instance: OmiBleManager? = null

        val isInitialized: Boolean
            get() = _instance != null

        /** True while the Flutter engine is alive. Set in MainActivity.configureFlutterEngine,
         *  cleared in MainActivity.onDestroy(isFinishing). CompanionService checks this to
         *  avoid starting the foreground service when the app is dead — Omi needs the Flutter
         *  app for WebSocket audio streaming. */
        @Volatile
        var isFlutterAlive: Boolean = false

        fun initialize(application: Application) {
            if (_instance == null) {
                synchronized(this) {
                    if (_instance == null) {
                        _instance = OmiBleManager(application)
                    }
                }
            }
        }

        private val CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    // ── Listener for the foreground service ──

    interface BleConnectionListener {
        fun onGattConnected(address: String, gatt: BluetoothGatt)
        fun onGattDisconnected(address: String, gattHash: Int, status: Int)
        fun onGattServicesDiscovered(address: String, services: List<BleService>)
        fun onMtuChanged(address: String, mtu: Int, status: Int)
    }

    @Volatile
    var connectionListener: BleConnectionListener? = null

    @Volatile
    var flutterApi: BleFlutterApi? = null

    private val bluetoothManager = application.getSystemService(Application.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter
    val mainHandler = Handler(Looper.getMainLooper())

    val connectedGatts = ConcurrentHashMap<String, BluetoothGatt>()
    private val readCompletions = ConcurrentHashMap<String, (Result<ByteArray>) -> Unit>()
    private val writeCompletions = ConcurrentHashMap<String, (Result<Unit>) -> Unit>()

    private val servicesDiscoveredFor = ConcurrentHashMap.newKeySet<String>()

    private var isScanning = false
    private var scanCallback: ScanCallback? = null
    private var scanTimeoutRunnable: Runnable? = null

    private val gattQueue: ConcurrentLinkedQueue<Runnable> = ConcurrentLinkedQueue()
    @Volatile
    private var isProcessingCommand = false

    private var rssiKeepAliveRunnable: Runnable? = null
    private val rssiKeepAliveInterval = 500L // ms

    private var bondCompletionCallback: ((Boolean) -> Unit)? = null
    private var bondTimeoutRunnable: Runnable? = null
    private var bondingAddress: String? = null

    private val bondStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == BluetoothDevice.ACTION_BOND_STATE_CHANGED) {
                val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE) ?: return
                val bondState = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)
                val address = device.address.uppercase()

                if (address == bondingAddress) {
                    when (bondState) {
                        BluetoothDevice.BOND_BONDED -> {
                            Log.i(TAG, "Bond successful for $address")
                            completeBond(true)
                        }
                        BluetoothDevice.BOND_NONE -> {
                            Log.w(TAG, "Bond failed for $address")
                            completeBond(false)
                        }
                    }
                }
            }
        }
    }

    init {
        application.registerReceiver(bondStateReceiver, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED))
    }

    // ── Scanning ──

    fun startScan(timeout: Int, serviceUuids: List<String>) {
        val state = getBluetoothState()
        Log.i(TAG, "startScan called, state=$state, timeout=$timeout, serviceUuids=$serviceUuids")
        val adapter = bluetoothAdapter ?: return
        if (!adapter.isEnabled) {
            Log.w(TAG, "Bluetooth is disabled, cannot scan")
            return
        }

        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(application, android.Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "BLUETOOTH_SCAN permission not granted, cannot scan")
            return
        }

        stopScan()

        val scanner = adapter.bluetoothLeScanner ?: return
        val filters = if (serviceUuids.isNotEmpty()) {
            serviceUuids.map { ScanFilter.Builder().setServiceUuid(ParcelUuid.fromString(it)).build() }
        } else null

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val device = result.device
                val peripheral = BlePeripheral(
                    uuid = device.address.uppercase(),
                    name = result.scanRecord?.deviceName ?: try { device.name } catch (e: SecurityException) { null } ?: "",
                    rssi = result.rssi.toLong(),
                    serviceUuids = result.scanRecord?.serviceUuids?.map { it.uuid.toString() } ?: emptyList()
                )
                mainHandler.post {
                    flutterApi?.onPeripheralDiscovered(peripheral) {}
                }
            }

            override fun onScanFailed(errorCode: Int) {
                Log.e(TAG, "Scan failed with error code: $errorCode")
            }
        }

        scanCallback = callback
        isScanning = true
        scanner.startScan(filters, settings, callback)

        if (timeout > 0) {
            scanTimeoutRunnable = Runnable { stopScan() }
            mainHandler.postDelayed(scanTimeoutRunnable!!, timeout * 1000L)
        }
    }

    fun stopScan() {
        if (!isScanning) return
        isScanning = false
        scanTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        scanCallback?.let {
            bluetoothAdapter?.bluetoothLeScanner?.stopScan(it)
        }
        scanCallback = null
    }

    // ── GATT connection methods ──

    fun connectGatt(address: String, autoConnect: Boolean): BluetoothGatt? {
        val addr = address.uppercase()
        val adapter = bluetoothAdapter ?: return null
        // Use getRemoteLeDevice with ADDRESS_TYPE_RANDOM to specify the correct address type.
        val device = if (android.os.Build.VERSION.SDK_INT >= 34) {
            adapter.getRemoteLeDevice(addr, BluetoothDevice.ADDRESS_TYPE_RANDOM)
        } else {
            adapter.getRemoteDevice(addr)
        }
        val callback = createGattCallback()
        val gatt = device.connectGatt(application, autoConnect, callback, BluetoothDevice.TRANSPORT_LE)
        if (gatt != null) {
            connectedGatts[addr] = gatt
        } else {
            Log.e(TAG, "connectGatt returned null for $addr")
        }
        return gatt
    }

    fun disconnectGatt(address: String) {
        connectedGatts[address.uppercase()]?.disconnect()
    }

    fun closeGatt(address: String) {
        val addr = address.uppercase()
        cleanupPeripheral(addr)
        connectedGatts[addr]?.close()
        connectedGatts.remove(addr)
    }

    fun isPeripheralConnected(address: String): Boolean {
        val addr = address.uppercase()
        val gatt = connectedGatts[addr] ?: return false
        return bluetoothManager.getConnectionState(gatt.device, BluetoothProfile.GATT) == BluetoothProfile.STATE_CONNECTED
    }

    // ── Bonding ──

    fun requestBond(address: String, completion: (Result<Boolean>) -> Unit) {
        val addr = address.uppercase()
        val device = connectedGatts[addr]?.device
        if (device == null) {
            completion(Result.failure(Exception("Device not connected")))
            return
        }

        if (device.bondState == BluetoothDevice.BOND_BONDED) {
            completion(Result.success(true))
            return
        }

        Log.i(TAG, "Initiating bond for $addr")
        bondingAddress = addr
        bondCompletionCallback = { result -> completion(Result.success(result)) }

        if (!device.createBond()) {
            Log.e(TAG, "createBond() returned false")
            completeBond(false)
            return
        }

        bondTimeoutRunnable = Runnable {
            Log.w(TAG, "Bond request timed out for $addr")
            completeBond(false)
        }
        mainHandler.postDelayed(bondTimeoutRunnable!!, BOND_TIMEOUT_MS)
    }

    private fun completeBond(success: Boolean) {
        bondTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        bondTimeoutRunnable = null
        bondCompletionCallback?.invoke(success)
        bondCompletionCallback = null
        bondingAddress = null
    }

    // ── Characteristic operations ──

    fun readCharacteristic(
        address: String,
        serviceUuid: String,
        characteristicUuid: String,
        completion: (Result<ByteArray>) -> Unit
    ) {
        val addr = address.uppercase()
        val gatt = connectedGatts[addr]
        val characteristic = findCharacteristic(gatt, serviceUuid, characteristicUuid)

        if (gatt == null || characteristic == null) {
            completion(Result.failure(Exception("Characteristic not found")))
            return
        }

        val key = "$addr:$serviceUuid:$characteristicUuid".lowercase()
        readCompletions[key] = completion

        enqueueCommand {
            if (!gatt.readCharacteristic(characteristic)) {
                readCompletions.remove(key)?.invoke(Result.failure(Exception("Read request rejected")))
                completeCommand()
            }
        }
    }

    fun writeCharacteristic(
        address: String,
        serviceUuid: String,
        characteristicUuid: String,
        data: ByteArray,
        completion: (Result<Unit>) -> Unit
    ) {
        val addr = address.uppercase()
        val gatt = connectedGatts[addr]
        val characteristic = findCharacteristic(gatt, serviceUuid, characteristicUuid)

        if (gatt == null || characteristic == null) {
            completion(Result.failure(Exception("Characteristic not found")))
            return
        }

        val writeType = if (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) {
            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        } else {
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        }

        val key = "$addr:$serviceUuid:$characteristicUuid".lowercase()
        if (writeType == BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) {
            writeCompletions[key] = completion
        } else {
            // Immediately complete for no-response writes
            completion(Result.success(Unit))
        }

        enqueueCommand {
            val result = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(characteristic, data, writeType)
            } else {
                @Suppress("DEPRECATION")
                characteristic.value = data
                characteristic.writeType = writeType
                if (gatt.writeCharacteristic(characteristic)) BluetoothStatusCodes.SUCCESS else BluetoothStatusCodes.ERROR_UNKNOWN
            }

            if (result != BluetoothStatusCodes.SUCCESS) {
                writeCompletions.remove(key)?.invoke(Result.failure(Exception("Write request rejected: $result")))
                completeCommand()
            } else if (writeType == BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) {
                completeCommand()
            }
        }
    }

    fun subscribeCharacteristic(address: String, serviceUuid: String, characteristicUuid: String) {
        val addr = address.uppercase()
        val gatt = connectedGatts[addr]
        val characteristic = findCharacteristic(gatt, serviceUuid, characteristicUuid) ?: return

        enqueueCommand {
            gatt.setCharacteristicNotification(characteristic, true)
            val descriptor = characteristic.getDescriptor(CCCD_UUID)
            if (descriptor != null) {
                val result = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                } else {
                    @Suppress("DEPRECATION")
                    descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    if (gatt.writeDescriptor(descriptor)) BluetoothStatusCodes.SUCCESS else BluetoothStatusCodes.ERROR_UNKNOWN
                }
                if (result != BluetoothStatusCodes.SUCCESS) {
                    Log.e(TAG, "writeDescriptor failed for subscribe: $result")
                    completeCommand()
                }
            } else {
                completeCommand()
            }
        }
    }

    fun unsubscribeCharacteristic(address: String, serviceUuid: String, characteristicUuid: String) {
        val addr = address.uppercase()
        val gatt = connectedGatts[addr]
        val characteristic = findCharacteristic(gatt, serviceUuid, characteristicUuid) ?: return

        enqueueCommand {
            gatt.setCharacteristicNotification(characteristic, false)
            val descriptor = characteristic.getDescriptor(CCCD_UUID)
            if (descriptor != null) {
                val result = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeDescriptor(descriptor, BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)
                } else {
                    @Suppress("DEPRECATION")
                    descriptor.value = BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                    if (gatt.writeDescriptor(descriptor)) BluetoothStatusCodes.SUCCESS else BluetoothStatusCodes.ERROR_UNKNOWN
                }
                if (result != BluetoothStatusCodes.SUCCESS) {
                    Log.e(TAG, "writeDescriptor failed for unsubscribe: $result")
                    completeCommand()
                }
            } else {
                completeCommand()
            }
        }
    }

    // ── RSSI keep-alive ──

    fun startRssiKeepAlive(address: String) {
        stopRssiKeepAlive()
        val runnable = object : Runnable {
            override fun run() {
                connectedGatts[address]?.readRemoteRssi()
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

    // ── State & utility ──

    fun getBluetoothState(): String {
        val adapter = bluetoothAdapter ?: return "unsupported"
        return when (adapter.state) {
            BluetoothAdapter.STATE_ON -> "on"
            BluetoothAdapter.STATE_OFF -> "off"
            BluetoothAdapter.STATE_TURNING_ON -> "turningOn"
            BluetoothAdapter.STATE_TURNING_OFF -> "turningOff"
            else -> "unknown"
        }
    }

    // ── Command queue ──

    @Synchronized
    fun enqueueCommand(command: Runnable) {
        gattQueue.add(command)
        processNextCommand()
    }

    @Synchronized
    private fun processNextCommand() {
        if (isProcessingCommand) return
        val cmd = gattQueue.peek() ?: return
        isProcessingCommand = true
        try {
            mainHandler.post(cmd)
        } catch (e: Exception) {
            Log.e(TAG, "Error posting command: ${e.message}")
            completeCommand()
        }
    }

    @Synchronized
    fun completeCommand() {
        gattQueue.poll()
        isProcessingCommand = false
        processNextCommand()
    }

    private fun findCharacteristic(gatt: BluetoothGatt?, serviceUuid: String, characteristicUuid: String): BluetoothGattCharacteristic? {
        val service = gatt?.getService(UUID.fromString(serviceUuid)) ?: return null
        return service.getCharacteristic(UUID.fromString(characteristicUuid))
    }

    fun cleanupPeripheral(address: String) {
        val addr = address.uppercase()
        servicesDiscoveredFor.remove(addr)
        stopRssiKeepAlive()

        // Fail pending reads/writes for this device
        val prefix = addr.lowercase()
        val readKeys = readCompletions.keys().asSequence().filter { it.startsWith(prefix) }
        readKeys.forEach { key ->
            readCompletions.remove(key)?.invoke(Result.failure(Exception("Device disconnected")))
        }

        val writeKeys = writeCompletions.keys().asSequence().filter { it.startsWith(prefix) }
        writeKeys.forEach { key ->
            writeCompletions.remove(key)?.invoke(Result.failure(Exception("Device disconnected")))
        }

        // Reset command queue if we were processing a command for this device
        // (Simple approach: reset if we lose connection to avoid getting stuck)
        isProcessingCommand = false
    }

    // ── GATT callback factory ──

    private fun createGattCallback() = object : BluetoothGattCallback() {

        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val address = gatt.device.address.uppercase()
            Log.i(TAG, "onConnectionStateChange: address=$address, status=$status, newState=$newState")

            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.i(TAG, "Connected to $address, discovering services")
                    connectedGatts[address] = gatt

                    // Discover services
                    enqueueCommand {
                        if (!gatt.discoverServices()) {
                            Log.e(TAG, "discoverServices returned false for $address")
                            completeCommand()
                        }
                    }

                    // Notify the connection owner
                    connectionListener?.onGattConnected(address, gatt)
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.i(TAG, "Disconnected from $address (status=$status, gattHash=${gatt.hashCode()})")
                    cleanupPeripheral(address)

                    // Notify the connection owner with GATT hash for stale callback rejection
                    connectionListener?.onGattDisconnected(address, gatt.hashCode(), status)
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            val address = gatt.device.address.uppercase()
            if (status == BluetoothGatt.GATT_SUCCESS) {
                Log.i(TAG, "MTU changed to $mtu for $address")
            }
            completeCommand()

            // Notify connection owner so it can fire onDeviceReady
            connectionListener?.onMtuChanged(address, mtu, status)
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val address = gatt.device.address.uppercase()
            if (servicesDiscoveredFor.contains(address)) {
                completeCommand()
                return
            }
            servicesDiscoveredFor.add(address)

            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "Service discovery failed for $address (status=$status)")
                completeCommand()
                return
            }

            val services = gatt.services ?: run {
                completeCommand()
                return
            }
            val bleServices = services.map { svc ->
                BleService(
                    uuid = svc.uuid.toString().lowercase(),
                    characteristicUuids = svc.characteristics.map { it.uuid.toString().lowercase() }
                )
            }

            if (gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)) {
                Log.i(TAG, "Requested high connection priority for $address")
            } else {
                Log.w(TAG, "Failed to request high connection priority")
            }

            completeCommand()

            connectionListener?.onGattServicesDiscovered(address, bleServices)
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            val address = gatt.device.address.uppercase()
            connectionListener?.onCharacteristicChanged(
                address,
                characteristic.service.uuid.toString().lowercase(),
                characteristic.uuid.toString().lowercase(),
                value
            )
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            onCharacteristicChanged(gatt, characteristic, characteristic.value ?: ByteArray(0))
        }

        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            val address = gatt.device.address.uppercase()
            val key = "$address:${characteristic.service.uuid}:${characteristic.uuid}".lowercase()
            val result = if (status == BluetoothGatt.GATT_SUCCESS) Result.success(value) else Result.failure(Exception("GATT Read Error: $status"))
            readCompletions.remove(key)?.invoke(result)
            completeCommand()
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            onCharacteristicRead(gatt, characteristic, characteristic.value ?: ByteArray(0), status)
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            val address = gatt.device.address.uppercase()
            val key = "$address:${characteristic.service.uuid}:${characteristic.uuid}".lowercase()
            val result = if (status == BluetoothGatt.GATT_SUCCESS) Result.success(Unit) else Result.failure(Exception("GATT Write Error: $status"))
            writeCompletions.remove(key)?.invoke(result)
            completeCommand()
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            val address = gatt.device.address.uppercase()
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "Descriptor write failed for ${address}: $status")
            }
            completeCommand()
        }

        override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.w(TAG, "RSSI read failed: status=$status for ${gatt.device.address}")
            }
        }
    }
}
