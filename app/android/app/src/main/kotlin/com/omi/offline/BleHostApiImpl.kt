package com.omi.offline

import android.app.Activity
import android.content.Context
import android.os.PowerManager
import android.util.Log

/**
 * Implements the Pigeon BleHostApi interface, delegating all calls to OmiBleManager or FgService.
 */
class BleHostApiImpl(private val getActivity: () -> Activity?, private val flutterApi: BleFlutterApi?) : BleHostApi {

    companion object {
        private const val TAG = "OmiBle.HostApi"
    }

    private val bleManager get() = OmiBleManager.instance

    init {
        bleManager.flutterApi = flutterApi
    }

    private var companionManager: OmiCompanionManager? = null
    private var companionAssociationCallback: ((Result<String>) -> Unit)? = null
    private var processingWakeLock: PowerManager.WakeLock? = null

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
        val actualRequiresBond = requiresBond && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU
        OmiBleForegroundService.startService(activity, uuid, requiresBond = actualRequiresBond, caller = "BleHostApi.manageDevice")
    }

    override fun unmanageDevice(uuid: String) {
        val inst = OmiBleForegroundService.instance
        if (inst != null) {
            inst.unmanageDevice(uuid)
        } else {
            // Fallback if service not running — still must stop OS-level presence
            // observation so the LE link doesn't get held warm by the OS.
            val activity = getActivity()
            if (activity != null) {
                OmiCompanionManager.stopObservingForAddress(activity.applicationContext, uuid)
            }
            bleManager.closeGatt(uuid)
        }
    }

    override fun disconnectPeripheral(uuid: String) {
        bleManager.disconnectGatt(uuid)
    }

    override fun rescheduleBackgroundSync(intervalMinutes: Long) {
        val ctx = getActivity()?.applicationContext ?: return
        BackgroundSyncWorker.schedule(ctx, intervalMinutes.toInt())
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

    override fun downloadStorageFile(
        peripheralUuid: String,
        fileIndex: Long,
        offset: Long,
        timerStart: Long,
        outputPath: String,
        callback: (Result<Unit>) -> Unit
    ) {
        bleManager.downloadStorageFile(peripheralUuid, fileIndex.toInt(), offset, timerStart, outputPath, callback)
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
        // associate() can throw synchronously (e.g. CompanionDeviceManager rejects
        // the request). Report it back through the callback so Dart sees the real
        // error instead of an opaque pigeon "channel-error" from a thrown handler.
        try {
            cm.associate(deviceAddress = deviceAddress)
        } catch (e: Throwable) {
            Log.e(TAG, "associate() threw synchronously", e)
            companionAssociationCallback = null
            callback(Result.failure(e))
        }
    }

    override fun acquireProcessingWakeLock() {
        if (processingWakeLock?.isHeld == true) return
        val ctx = getActivity()?.applicationContext ?: return
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        processingWakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "omi:VadProcessing")
            .also { it.acquire(30 * 60 * 1000L) }
    }

    override fun releaseProcessingWakeLock() {
        processingWakeLock?.let { if (it.isHeld) it.release() }
        processingWakeLock = null
    }

    override fun setNextSyncTime(timestampMs: Long) {
        OmiBleForegroundService.instance?.setNextSyncTime(timestampMs)
    }

    override fun setDeviceBattery(level: Long, timestampMs: Long) {
        OmiBleForegroundService.instance?.setDeviceBattery(level.toInt(), timestampMs)
    }

    override fun setSyncStatus(title: String, text: String) {
        OmiBleForegroundService.instance?.setSyncStatus(title, text)
    }

    override fun setPersistentNotification(enabled: Boolean) {
        val inst = OmiBleForegroundService.instance
        if (inst != null) {
            inst.setPersistent(enabled)
        } else if (enabled) {
            // No service yet (e.g. Manual Only → auto-sync just enabled): start it
            // pinned so the idle notification appears without waiting for a connect.
            OmiBleForegroundService.startServicePersistent(bleManager.app)
        }
    }

    override fun clearSyncStatus() {
        OmiBleForegroundService.instance?.clearSyncStatus()
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
