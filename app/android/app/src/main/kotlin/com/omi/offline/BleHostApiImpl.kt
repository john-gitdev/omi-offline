package com.omi.offline

import android.app.Activity
import android.content.Context
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log

/**
 * Implements the Pigeon BleHostApi interface, delegating all calls to OmiBleManager or FgService.
 */
class BleHostApiImpl(private val getActivity: () -> Activity?, private val flutterApi: BleFlutterApi?) : BleHostApi {

    companion object {
        private const val TAG = "OmiBle.HostApi"

        // Backstop timeout on the partial wake-lock, re-armed every RENEW_MS while an
        // owner still holds it (see scheduleWakeLockRenewal). Renewal at half the
        // timeout means one missed tick can't leave a gap.
        private const val WAKE_LOCK_TIMEOUT_MS = 10 * 60 * 1000L
        private const val WAKE_LOCK_RENEW_MS = 5 * 60 * 1000L

        // Absolute ceiling on one continuous hold. Renewal would otherwise re-arm the
        // per-acquire timeout forever, so a refcount that never returns to zero (a Dart
        // path that skips its release, an isolate that dies mid-run) would pin the CPU
        // until the process died — strictly worse than the one-shot expiry this replaced.
        // Past this, stop renewing and let the lock lapse: a sync+process cycle running
        // this long is already pathological, and a flat battery is the worse failure.
        private const val WAKE_LOCK_MAX_HOLD_MS = 2 * 60 * 60 * 1000L
    }

    private val bleManager get() = OmiBleManager.instance

    init {
        bleManager.flutterApi = flutterApi
    }

    private var companionManager: OmiCompanionManager? = null
    private var companionAssociationCallback: ((Result<String>) -> Unit)? = null
    private var processingWakeLock: PowerManager.WakeLock? = null
    // Reference count so independent owners (VAD processing, DFU, and the
    // background-connect settle window) can each acquire/release the single
    // partial wake-lock without one owner's release pulling it out from under
    // another's still-running work. Held while > 0.
    private var wakeLockRefCount = 0
    private val wakeLockHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var wakeLockRenewRunnable: Runnable? = null
    private var wakeLockHeldSinceMs = 0L

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

    override fun removeBond(uuid: String) {
        val inst = OmiBleForegroundService.instance
        if (inst != null) {
            inst.removeBond(uuid)
        } else {
            // Service not running, but we can still remove the bond via an ephemeral intent
            // or we can just try directly via adapter. But we'd need to put it in a static method.
            // Since foreground service might not be running, we can just do it inline here.
            try {
                val adapter = android.bluetooth.BluetoothAdapter.getDefaultAdapter()
                if (adapter != null) {
                    val device = adapter.getRemoteDevice(uuid)
                    if (device.bondState != android.bluetooth.BluetoothDevice.BOND_NONE) {
                        val method = device.javaClass.getMethod("removeBond")
                        method.invoke(device)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to remove bond manually: ${e.message}")
            }
        }
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

    /**
     * The bonded set straight from the OS — no GATT, no radio traffic — so Find Devices
     * can mark the paired Omi without touching the link a sync may be using.
     *
     * Enumerated rather than looked up per address on purpose. getRemoteDevice() rejects
     * a lowercase MAC outright (checkBluetoothAddress wants uppercase hex) and assumes a
     * PUBLIC address type, which is not what this device advertises — see
     * OmiBleManager.remoteLeDevice, which reaches for ADDRESS_TYPE_RANDOM on API 34+.
     * bondedDevices sidesteps both: it is the authoritative list, and matching it the way
     * the rest of this module matches addresses (uppercased) needs no assumption about
     * the address type at all.
     *
     * Only BOND_BONDED is reported. BOND_BONDING is a key that is not usable yet, and the
     * caller is an indicator, so claiming a pairing that may still fail is the worse
     * error. Anything that throws (BLUETOOTH_CONNECT denied, Bluetooth off) answers empty
     * for the same reason.
     */
    override fun getBondedDeviceIds(): List<String> {
        return try {
            val adapter = android.bluetooth.BluetoothAdapter.getDefaultAdapter() ?: return emptyList()
            adapter.bondedDevices
                ?.filter { it.bondState == android.bluetooth.BluetoothDevice.BOND_BONDED }
                ?.map { it.address.uppercase() }
                ?: emptyList()
        } catch (e: Exception) {
            Log.w(TAG, "getBondedDeviceIds failed: ${e.message}")
            emptyList()
        }
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
        wakeLockRefCount++
        if (processingWakeLock?.isHeld == true) return
        val ctx = getActivity()?.applicationContext ?: return
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        processingWakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "omi:VadProcessing").also {
            // NOT reference-counted: renewal below re-acquires the same lock, and a
            // ref-counted lock would need one release() per acquire() — so a renewed
            // lock could never be released and would pin the CPU until process death.
            it.setReferenceCounted(false)
            it.acquire(WAKE_LOCK_TIMEOUT_MS)
        }
        wakeLockHeldSinceMs = SystemClock.elapsedRealtime()
        scheduleWakeLockRenewal()
    }

    /**
     * Re-arm the wake-lock timeout while an owner still holds a reference.
     *
     * The timeout exists so a leaked reference can't pin the CPU forever, but it is a
     * BACKSTOP, not a budget: a background sync+process cycle over a large backlog
     * (BLE drain plus VAD decode) routinely runs longer than it. When the timeout
     * fired mid-run the OS released the lock silently, the SoC was free to suspend,
     * and both keep-alives — the native storage 0x32 tick and Dart's timer, each a
     * Handler/Timer post on uptimeMillis, which does not advance across suspend —
     * stopped firing. The firmware's 15 s idle-disconnect then dropped the link and
     * the sync came back partial.
     *
     * SCOPE, so this isn't over-credited: this only explains runs that OUTLIVE the
     * expiry. It says nothing about a partial 10 minutes into a background sync — the
     * lock is still held there. The other half of "backgrounded = more partials" was
     * RecordingsController's pipeline holding only WakelockPlus (a SCREEN flag, which
     * lapses the moment the app is backgrounded, leaving nothing holding the CPU);
     * that is fixed separately in _acquireWake.
     */
    private fun scheduleWakeLockRenewal() {
        cancelWakeLockRenewal()
        val runnable = object : Runnable {
            override fun run() {
                // Owners all released, or the lock went away — stop renewing.
                val wl = processingWakeLock
                if (wakeLockRefCount <= 0 || wl == null) {
                    wakeLockRenewRunnable = null
                    return
                }
                // elapsedRealtime, not uptimeMillis: the ceiling must count suspended
                // time too, or a lock leaked across a long idle would never reach it.
                if (SystemClock.elapsedRealtime() - wakeLockHeldSinceMs >= WAKE_LOCK_MAX_HOLD_MS) {
                    Log.w(TAG, "wake-lock held $WAKE_LOCK_MAX_HOLD_MS ms with refCount=$wakeLockRefCount; " +
                        "letting it lapse (suspected leaked reference)")
                    wakeLockRenewRunnable = null
                    return
                }
                try {
                    wl.acquire(WAKE_LOCK_TIMEOUT_MS)
                } catch (e: Exception) {
                    Log.w(TAG, "wake-lock renewal failed: ${e.message}")
                }
                wakeLockHandler.postDelayed(this, WAKE_LOCK_RENEW_MS)
            }
        }
        wakeLockRenewRunnable = runnable
        wakeLockHandler.postDelayed(runnable, WAKE_LOCK_RENEW_MS)
    }

    private fun cancelWakeLockRenewal() {
        wakeLockRenewRunnable?.let { wakeLockHandler.removeCallbacks(it) }
        wakeLockRenewRunnable = null
    }

    override fun releaseProcessingWakeLock() {
        if (wakeLockRefCount > 0) wakeLockRefCount--
        if (wakeLockRefCount > 0) return
        cancelWakeLockRenewal()
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
