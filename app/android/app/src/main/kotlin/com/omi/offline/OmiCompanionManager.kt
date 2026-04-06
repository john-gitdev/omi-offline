package com.omi.offline

import android.app.Activity
import android.bluetooth.le.ScanFilter
import android.companion.*
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Wraps CompanionDeviceManager for BLE device association and presence observation.
 */
class OmiCompanionManager(
    private val context: Context,
    private val getActivity: () -> Activity?
) {
    companion object {
        private const val TAG = "OmiBle.CompanionMgr"
        const val COMPANION_REQUEST_CODE = 42
    }

    private val companionDeviceManager =
        context.getSystemService(Context.COMPANION_DEVICE_SERVICE) as CompanionDeviceManager

    fun associate(deviceAddress: String? = null, serviceUuid: String? = null) {
        disassociateAll()

        val requestBuilder = AssociationRequest.Builder().setSingleDevice(deviceAddress != null)
        val scanFilterBuilder = ScanFilter.Builder()
        if (deviceAddress != null) scanFilterBuilder.setDeviceAddress(deviceAddress)
        if (serviceUuid != null) scanFilterBuilder.setServiceUuid(ParcelUuid.fromString(serviceUuid))

        requestBuilder.addDeviceFilter(
            BluetoothLeDeviceFilter.Builder()
                .setScanFilter(scanFilterBuilder.build())
                .build()
        )

        val request = requestBuilder.build()

        if (Build.VERSION.SDK_INT >= 33) {
            companionDeviceManager.associate(
                request,
                ContextCompat.getMainExecutor(context),
                object : CompanionDeviceManager.Callback() {
                    override fun onDeviceFound(chooserLauncher: android.content.IntentSender) {
                        launchChooser(chooserLauncher)
                    }

                    override fun onFailure(error: CharSequence?) {
                        Log.e(TAG, "associate() failed: $error")
                    }
                }
            )
        } else {
            @Suppress("deprecation")
            companionDeviceManager.associate(
                request,
                object : CompanionDeviceManager.Callback() {
                    override fun onDeviceFound(chooserLauncher: android.content.IntentSender) {
                        launchChooser(chooserLauncher)
                    }

                    override fun onFailure(error: CharSequence?) {
                        Log.e(TAG, "associate() failed: $error")
                    }
                },
                Handler(Looper.getMainLooper())
            )
        }
    }

    private fun launchChooser(chooserLauncher: android.content.IntentSender) {
        val activity = getActivity()
        if (activity == null) {
            Log.e(TAG, "Cannot launch chooser: activity is null")
            return
        }
        try {
            activity.startIntentSenderForResult(chooserLauncher, COMPANION_REQUEST_CODE, null, 0, 0, 0)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start chooser", e)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): String? {
        if (requestCode != COMPANION_REQUEST_CODE || resultCode != Activity.RESULT_OK) return null
        @Suppress("DEPRECATION")
        val scanResult = data?.getParcelableExtra<android.bluetooth.le.ScanResult>(CompanionDeviceManager.EXTRA_DEVICE) ?: return null
        val address = scanResult.device.address
        startObserving()
        return address
    }

    fun getMacAddresses(): List<String> {
        return if (Build.VERSION.SDK_INT >= 33) {
            companionDeviceManager.myAssociations.mapNotNull { it.deviceMacAddress?.toString() }
        } else {
            @Suppress("deprecation")
            companionDeviceManager.associations
        }
    }

    fun disassociateAll() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            companionDeviceManager.myAssociations.forEach {
                companionDeviceManager.disassociate(it.id)
            }
        } else {
            @Suppress("DEPRECATION")
            companionDeviceManager.associations.forEach {
                companionDeviceManager.disassociate(it)
            }
        }
    }

    fun startObserving() {
        if (Build.VERSION.SDK_INT < 33) {
            Log.d(TAG, "startObserving: skipped (API \${Build.VERSION.SDK_INT} < 33)")
            return
        }
        val associations = companionDeviceManager.myAssociations
        if (associations.isEmpty()) return

        val association = associations.last()

        if (Build.VERSION.SDK_INT >= 36) {
            try {
                val request = android.companion.ObservingDevicePresenceRequest.Builder()
                    .setAssociationId(association.id)
                    .build()
                companionDeviceManager.startObservingDevicePresence(request)
                Log.d(TAG, "Observing device presence (API 36+) for association \${association.id}")
            } catch (e: Exception) {
                Log.w(TAG, "startObserving (API 36+) failed: \${e.message}")
            }
        } else {
            val mac = association.deviceMacAddress
            if (mac != null) {
                try {
                    companionDeviceManager.startObservingDevicePresence(mac.toString())
                    Log.d(TAG, "Observing device presence for \$mac")
                } catch (e: Exception) {
                    Log.w(TAG, "startObserving failed: \${e.message}")
                }
            }
        }
    }

    fun stopObserving() {
        if (Build.VERSION.SDK_INT < 33) return
        for (association in companionDeviceManager.myAssociations) {
            try {
                if (Build.VERSION.SDK_INT >= 36) {
                    val request = android.companion.ObservingDevicePresenceRequest.Builder()
                        .setAssociationId(association.id)
                        .build()
                    companionDeviceManager.stopObservingDevicePresence(request)
                } else {
                    val mac = association.deviceMacAddress
                    if (mac != null) {
                        companionDeviceManager.stopObservingDevicePresence(mac.toString())
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "stopObserving failed: \${e.message}")
            }
        }
    }
}
