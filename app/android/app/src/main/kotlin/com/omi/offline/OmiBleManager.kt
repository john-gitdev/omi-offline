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
                        _instance = OmiBleManager(application)
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
    private val rssiKeepAliveInterval = 500L

    private var bondCompletionCallback: ((Boolean) -> Unit)? = null
    private var bondTimeoutRunnable: Runnable? = null
    private var bondingAddress: String? = null

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
        val adapter = bluetoothAdapter ?: return null
        val device = if (android.os.Build.VERSION.SDK_INT >= 34) {
            adapter.getRemoteLeDevice(addr, BluetoothDevice.ADDRESS_TYPE_RANDOM)
        } else {
            adapter.getRemoteDevice(addr)
        }
        val gatt = device.connectGatt(application, autoConnect, createGattCallback(), BluetoothDevice.TRANSPORT_LE)
        if (gatt != null) connectedGatts[addr] = gatt
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
    @Synchronized fun completeCommand() { gattQueue.poll(); isProcessingCommand = false; processNextCommand() }

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
        stopRssiKeepAlive()
        val prefix = addr.lowercase()
        readCompletions.keys().toList().filter { it.startsWith(prefix) }.forEach { readCompletions.remove(it)?.invoke(Result.failure(Exception("Disconnected"))) }
        writeCompletions.keys().toList().filter { it.startsWith(prefix) }.forEach { writeCompletions.remove(it)?.invoke(Result.failure(Exception("Disconnected"))) }
        isProcessingCommand = false
    }

    private fun createGattCallback() = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val address = gatt.device.address.uppercase()
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                connectedGatts[address] = gatt
                enqueueCommand { if (!gatt.discoverServices()) completeCommand() }
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
}
