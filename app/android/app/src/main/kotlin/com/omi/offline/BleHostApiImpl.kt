package com.omi.offline

import android.app.Activity
import android.util.Log

/**
 * Implements the Pigeon BleHostApi interface, delegating all calls to OmiBleManager or FgService.
 */
class BleHostApiImpl(private val getActivity: () -> Activity?, private val flutterApi: BleFlutterApi?) : BleHostApi {

    companion object {
        private const val TAG = "OmiBle.HostApi"
    }

    private val bleManager get() = OmiBleManager.instance

    private var companionManager: OmiCompanionManager? = null
    private var companionAssociationCallback: ((Result<String>) -> Unit)? = null

    fun initCompanionManager(activity: Activity) {
        companionManager = OmiCompanionManager(activity, getActivity)
    }

    override fun startScan(timeoutSeconds: Long, serviceUuids: List<String>) {
        bleManager.startScan(timeoutSeconds.toInt(), serviceUuids)
    }

    override fun stopScan() {
        bleManager.stopScan()
    }

    override fun manageDevice(uuid: String, requiresBond: Boolean) {
        val activity = getActivity() ?: return
        OmiBleForegroundService.startService(activity, uuid, requiresBond = requiresBond, caller = "BleHostApi.manageDevice")
    }

    override fun unmanageDevice(uuid: String) {
        val activity = getActivity() ?: return
        val inst = OmiBleForegroundService.instance
        if (inst != null) {
            inst.unmanageDevice(uuid)
        } else {
            // Fallback if service not running
            bleManager.closeGatt(uuid)
        }
    }

    override fun disconnectPeripheral(uuid: String) {
        bleManager.disconnectGatt(uuid)
    }

    override fun requestBond(uuid: String, callback: (Result<Boolean>) -> Unit) {
        bleManager.requestBond(uuid, callback)
    }

    override fun readCharacteristic(
        peripheralUuid: String,
        serviceUuid: String,
        characteristicUuid: String,
        callback: (Result<ByteArray>) -> Unit
    ) {
        bleManager.readCharacteristic(peripheralUuid, serviceUuid, characteristicUuid, callback)
    }

    override fun writeCharacteristic(
        peripheralUuid: String,
        serviceUuid: String,
        characteristicUuid: String,
        data: ByteArray,
        callback: (Result<Unit>) -> Unit
    ) {
        bleManager.writeCharacteristic(peripheralUuid, serviceUuid, characteristicUuid, data, callback)
    }

    override fun subscribeCharacteristic(peripheralUuid: String, serviceUuid: String, characteristicUuid: String) {
        bleManager.subscribeCharacteristic(peripheralUuid, serviceUuid, characteristicUuid)
    }

    override fun unsubscribeCharacteristic(peripheralUuid: String, serviceUuid: String, characteristicUuid: String) {
        bleManager.unsubscribeCharacteristic(peripheralUuid, serviceUuid, characteristicUuid)
    }

    override fun getBluetoothState(): String {
        return bleManager.getBluetoothState()
    }

    override fun isPeripheralConnected(uuid: String): Boolean {
        return bleManager.isPeripheralConnected(uuid)
    }

    override fun hasCompanionDeviceAssociation(): Boolean {
        val cm = companionManager ?: return false
        return cm.getMacAddresses().isNotEmpty()
    }

    override fun requestCompanionDeviceAssociation(deviceAddress: String, callback: (Result<String>) -> Unit) {
        Log.i(TAG, "requestCompanionDeviceAssociation: $deviceAddress")

        val cm = companionManager ?: run {
            val activity = getActivity()
            if (activity != null) {
                OmiCompanionManager(activity, getActivity).also { companionManager = it }
            } else {
                Log.w(TAG, "Cannot associate: no activity")
                callback(Result.success(""))
                return
            }
        }

        companionAssociationCallback = callback
        cm.associate(deviceAddress = deviceAddress)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?): String? {
        val address = companionManager?.onActivityResult(requestCode, resultCode, data)
        val cb = companionAssociationCallback
        companionAssociationCallback = null
        if (address != null) {
            cb?.invoke(Result.success(address))
        } else {
            cb?.invoke(Result.success(""))
        }
        return address
    }
}
