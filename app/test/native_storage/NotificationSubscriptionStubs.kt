@file:Suppress("UNUSED_PARAMETER", "UNUSED_VARIABLE")
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

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
object Log { fun i(tag: String, message: String) {} }
class Device(val address: String)
class Service(val uuid: UUID)
class BluetoothGattCharacteristic(val service: Service, val uuid: UUID) {
    var descriptor: BluetoothGattDescriptor? = BluetoothGattDescriptor(this)
    fun getDescriptor(uuid: UUID) = descriptor
}
class BluetoothGattDescriptor(val characteristic: BluetoothGattCharacteristic) {
    val uuid: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    var value: ByteArray = byteArrayOf()
    companion object { val ENABLE_NOTIFICATION_VALUE = byteArrayOf(1, 0) }
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
    fun setCharacteristicNotification(characteristic: BluetoothGattCharacteristic, enabled: Boolean): Boolean {
        if (throwRegistration) throw IllegalStateException("registration failed")
        return localAccepted
    }
    fun writeDescriptor(descriptor: BluetoothGattDescriptor, value: ByteArray): Int {
        writes++
        return if (descriptorAccepted) 0 else 1
    }
    fun writeDescriptor(descriptor: BluetoothGattDescriptor): Boolean = writeDescriptor(descriptor, descriptor.value) == 0
}
class OmiBleManager {
    companion object {
        private const val TAG = "test"
        private val CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
    val connectedGatts = ConcurrentHashMap<String, BluetoothGatt>()
    val queue = mutableListOf<() -> Unit>()
    var completedCommands = 0
    private fun findCharacteristic(gatt: BluetoothGatt?, service: String, char: String) = gatt?.characteristic
    private fun enqueueCommand(label: String, action: () -> Unit) { queue.add(action) }
    private fun completeCommand() { completedCommands++ }
    fun issue() { queue.removeAt(0).invoke() }
    fun disconnect(address: String) {
        failPendingSubscriptions(address)
        connectedGatts.remove(address.uppercase())
    }
    // PRODUCTION_SUBSCRIPTIONS
    // PRODUCTION_CLEANUP
    // PRODUCTION_DESCRIPTOR
}
