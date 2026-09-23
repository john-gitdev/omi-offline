@file:Suppress("UNUSED_PARAMETER", "UNUSED_VARIABLE")
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue

object android {
    object os {
        object Build {
            object VERSION { var SDK_INT = 33 }
            object VERSION_CODES { const val TIRAMISU = 33 }
        }
    }
}
object BluetoothStatusCodes { const val SUCCESS = 0 }
class FlutterError(val code: String, override val message: String?, val details: Any?) : Throwable()
object Log {
    fun i(tag: String, message: String) {}
    fun e(tag: String, message: String) {}
    fun w(tag: String, message: String) {}
}
object BluetoothDevice {
    const val BOND_NONE = 10
    const val BOND_BONDING = 11
    const val BOND_BONDED = 12
}
class Device(val address: String) { var bondState = BluetoothDevice.BOND_NONE }
class Service(val uuid: UUID)
class BluetoothGattCharacteristic(val service: Service, val uuid: UUID) {
    companion object { const val WRITE_TYPE_NO_RESPONSE = 1 }
    var descriptor: BluetoothGattDescriptor? = BluetoothGattDescriptor(this)
    var value: ByteArray = byteArrayOf()
    var writeType = 0
    fun getDescriptor(uuid: UUID) = descriptor?.takeIf { it.uuid == uuid }
}
class ServiceView(val gatt: BluetoothGatt) {
    fun getCharacteristic(uuid: UUID) = gatt.characteristic.takeIf { it.uuid == uuid }
}
class BluetoothGattDescriptor(val characteristic: BluetoothGattCharacteristic) {
    val uuid: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    var value: ByteArray = byteArrayOf()
    companion object {
        val ENABLE_NOTIFICATION_VALUE = byteArrayOf(1, 0)
        val DISABLE_NOTIFICATION_VALUE = byteArrayOf(0, 0)
    }
}
class BluetoothGatt(val device: Device) {
    companion object { const val GATT_SUCCESS = 0 }
    val characteristic = BluetoothGattCharacteristic(
        Service(UUID.fromString("30295780-4301-eabd-2904-2849adfeae43")),
        UUID.fromString("30295781-4301-eabd-2904-2849adfeae43"))
    var localAccepted = true
    var descriptorAccepted = true
    var throwRegistration = false
    var writes = 0
    val writtenValues = mutableListOf<List<Byte>>()
    var closed = false
    fun disconnect() {}
    fun close() { closed = true }
    fun setCharacteristicNotification(characteristic: BluetoothGattCharacteristic, enabled: Boolean): Boolean {
        if (throwRegistration) throw IllegalStateException("registration failed")
        return localAccepted
    }
    fun writeDescriptor(descriptor: BluetoothGattDescriptor, value: ByteArray): Int {
        writes++
        writtenValues.add(value.toList())
        return if (descriptorAccepted) 0 else 1
    }
    fun writeDescriptor(descriptor: BluetoothGattDescriptor): Boolean = writeDescriptor(descriptor, descriptor.value) == 0
    var characteristicWriteResult = 0
    val characteristicWrites = mutableListOf<List<Byte>>()
    fun writeCharacteristic(characteristic: BluetoothGattCharacteristic, value: ByteArray, writeType: Int): Int {
        characteristicWrites.add(value.toList())
        return characteristicWriteResult
    }
    fun writeCharacteristic(characteristic: BluetoothGattCharacteristic): Boolean =
        writeCharacteristic(characteristic, characteristic.value, characteristic.writeType) == 0
    fun getService(uuid: UUID): ServiceView? = if (characteristic.service.uuid == uuid) ServiceView(this) else null
}
class TestHandler {
    val posted = mutableListOf<Runnable>()
    val delayed = mutableListOf<Runnable>()
    fun post(task: Runnable) { posted.add(task) }
    fun postDelayed(task: Runnable, delay: Long) { delayed.add(task) }
    fun removeCallbacks(task: Runnable) { posted.remove(task); delayed.remove(task) }
    fun issue() { check(posted.isNotEmpty()) { "No command ready; queue still blocked" }; posted.removeAt(0).run() }
    fun expire() { delayed.toList().forEach { if (delayed.remove(it)) it.run() } }
}
class ConnectionListener {
    var disconnects = 0
    fun onGattDisconnected(address: String, hash: Int, status: Int) { disconnects++ }
}
class Download { fun complete(result: Result<Unit>) {} }
class OmiBleManager {
    companion object {
        private const val TAG = "test"
        private val CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private val STORAGE_SERVICE_UUID = UUID.fromString("30295780-4301-eabd-2904-2849adfeae43")
        private val STORAGE_CHAR_UUID = UUID.fromString("30295781-4301-eabd-2904-2849adfeae43")
        private const val LINK_CLOSED_BY_NATIVE = "link-closed"
    }
    var storageKeepAliveRunnable: Runnable? = null
    private val storageKeepAliveInterval = 10_000L
    val connectedGatts = ConcurrentHashMap<String, BluetoothGatt>()
    private class GattCommand(val label: String, val run: Runnable)
    private val gattQueue = ConcurrentLinkedQueue<GattCommand>()
    private var isProcessingCommand = false
    val mainHandler = TestHandler()
    val connectionListener: ConnectionListener? = ConnectionListener()
    val servicesDiscoveredFor = mutableSetOf<String>()
    val discoveryTimeouts = mutableMapOf<String, Runnable>()
    val readCompletions = ConcurrentHashMap<String, (Result<Unit>) -> Unit>()
    val writeCompletions = ConcurrentHashMap<String, (Result<Unit>) -> Unit>()
    val activeDownloads = ConcurrentHashMap<String, Download>()
    var completedCommands = 0
    private fun beginCommandTiming(label: String) {}
    private fun endCommandTiming(outcome: String) { if (outcome == "recovered") completedCommands++ }
    private fun stopRssiKeepAlive() {}
    private fun findCharacteristic(gatt: BluetoothGatt?, service: String, char: String) =
        gatt?.characteristic?.takeIf { it.service.uuid == UUID.fromString(service) && it.uuid == UUID.fromString(char) }
    fun issue() = mainHandler.issue()
    fun disconnect(address: String) {
        cleanupPeripheral(address)
        connectedGatts.remove(address.uppercase())
    }
    fun closeGatt(address: String) {
        val gatt = connectedGatts.remove(address.uppercase())
        cleanupPeripheral(address)
        gatt?.close()
    }
    // PRODUCTION_QUEUE
    // PRODUCTION_SUBSCRIPTIONS
    // PRODUCTION_WRITE_HELPER
    // PRODUCTION_CLEANUP
    // PRODUCTION_KEEPALIVE
    // PRODUCTION_DESCRIPTOR
    // PRODUCTION_CHAR_WRITE
}
