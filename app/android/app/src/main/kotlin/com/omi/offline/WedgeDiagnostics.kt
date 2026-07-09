package com.omi.offline

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Captures the state of a BLE outage into the app's debug log, from native, at the
 * moment it is detected — so the evidence survives without the user noticing the
 * outage, reaching for a cable and running adb before it clears.
 *
 * What this can and cannot see:
 *
 *  - It CANNOT read the Bluetooth stack's HCI logs or `dumpsys bluetooth_manager`.
 *    Those need READ_LOGS / DUMP, which are signature|privileged — an ordinary app
 *    cannot hold them. So the phone-side `0x3e` count stays adb-only.
 *  - It CAN answer the one question those logs were being read for: during the
 *    outage, is this phone still hearing the peripheral's advertisements? A short
 *    address-filtered scan settles it. Advertisements heard while every connect
 *    dies at establishment means the phone's receiver is fine and the peripheral is
 *    transmitting — the link dies in between. Silence means the phone's radio is
 *    not listening (starved by another scanner) or the peripheral has stopped
 *    advertising altogether.
 *  - The peripheral's own `estab_fail_count` is unreadable during the outage, by
 *    definition. Dart logs it on the next successful connect (`_finishDeviceSetup`),
 *    which is why the two halves of the picture land in the same file.
 *
 * Written from native rather than through Dart because an outage typically happens
 * while the app is backgrounded, where the Flutter isolate may be frozen by Doze and
 * unable to service a platform channel. The foreground service is still running.
 *
 * Lines are appended to the newest `omi_debug_*.log` in the Flutter documents dir, in
 * the same one-JSON-object-per-line shape `DebugLogManager.logEvent` writes. If no
 * such file exists, developer file logging is off (`setEnabled(false)` deletes them)
 * and nothing is written — this never creates the log file.
 *
 * The advertising probe, however, always runs. It is not only diagnostic: its verdict
 * decides whether the caller shows the user the "toggle Bluetooth" alert, which is bad
 * advice for an Omi that is merely out of range. So the scan's cost is paid regardless
 * of the logging setting, and only the log lines are conditional.
 */
@SuppressLint("MissingPermission")
object WedgeDiagnostics {

    private const val TAG = "OmiBle.WedgeDiag"

    /** How long to listen for the peripheral's advertisements once wedged. */
    private const val PROBE_DURATION_MS = 8_000L

    private val probeInFlight = AtomicBoolean(false)
    private val handler = Handler(Looper.getMainLooper())

    private fun timestamp(): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        fmt.timeZone = TimeZone.getTimeZone("UTC")
        return fmt.format(Date())
    }

    /**
     * Where `DebugLogManager` writes: whatever `path_provider`'s
     * `getApplicationDocumentsDirectory()` resolves to on Android. Today that is
     * `PathUtils.getDataDirectory()`, i.e. `getDir("flutter")` → `.../app_flutter`. That
     * mapping is engine-internal and undocumented, so `filesDir` is searched as a fallback
     * rather than assumed away. Nothing here ever creates a directory or a log file, so an
     * extra candidate is free: whichever one actually holds the log wins.
     */
    private fun candidateLogDirs(context: Context): List<File> = listOf(
        context.getDir("flutter", Context.MODE_PRIVATE),
        context.filesDir,
    )

    /**
     * Newest `omi_debug_*.log`, or null when developer file logging is off — disabling it
     * deletes every log file, so absence is the "off" signal. Never creates one: a log
     * appearing on its own would silently re-enable a feature the user turned off.
     */
    private fun currentLogFile(context: Context): File? = try {
        candidateLogDirs(context)
            .flatMap { dir ->
                dir.listFiles { f -> f.isFile && f.name.startsWith("omi_debug_") && f.name.endsWith(".log") }
                    ?.toList() ?: emptyList()
            }
            .maxByOrNull { it.name }
    } catch (e: Exception) {
        Log.w(TAG, "Cannot resolve debug log file: ${e.message}")
        null
    }

    /**
     * Appends one event line, matching `DebugLogManager.logEvent`'s schema so the in-app
     * log viewer and the "Save Diagnostic Logs to File" export both pick it up unchanged.
     *
     * Runs off the caller's thread. A concurrent Dart append is safe (O_APPEND, and the
     * reader tolerates a torn line); a concurrent Dart *rotation* could drop this line,
     * which is an acceptable trade for not sharing a lock across the language boundary.
     */
    private fun logEvent(context: Context, type: String, fields: Map<String, Any?>) {
        // Timestamp and encode on the caller's thread so the line records when the event
        // happened, not when the writer got scheduled. Everything touching the disk —
        // resolving the file included — happens off it.
        val line = try {
            val payload = JSONObject()
            payload.put("timestamp", timestamp())
            payload.put("level", "EVENT")
            payload.put("type", type)
            for ((k, v) in fields) payload.put(k, v ?: JSONObject.NULL)
            payload.toString() + "\n"
        } catch (e: Exception) {
            Log.w(TAG, "Failed to encode $type: ${e.message}")
            return
        }
        Thread {
            try {
                val file = currentLogFile(context) ?: return@Thread
                FileOutputStream(file, true).use { it.write(line.toByteArray(Charsets.UTF_8)) }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to append $type: ${e.message}")
            }
        }.start()
    }

    private fun adapterStateName(state: Int): String = when (state) {
        BluetoothAdapter.STATE_OFF -> "off"
        BluetoothAdapter.STATE_TURNING_ON -> "turning_on"
        BluetoothAdapter.STATE_ON -> "on"
        BluetoothAdapter.STATE_TURNING_OFF -> "turning_off"
        else -> "unknown_$state"
    }

    private fun bondStateName(state: Int): String = when (state) {
        BluetoothDevice.BOND_NONE -> "none"
        BluetoothDevice.BOND_BONDING -> "bonding"
        BluetoothDevice.BOND_BONDED -> "bonded"
        else -> "unknown_$state"
    }

    /**
     * Snapshot the outage, then probe the air for the peripheral's advertisements.
     *
     * Emits `ble_wedge` immediately (so the state survives even if the process dies
     * mid-probe) and `ble_wedge_scan_probe` [PROBE_DURATION_MS] later.
     *
     * [onProbeComplete] receives whether any advertisement from [address] was heard, on the
     * main thread, once the probe window closes. This is the caller's cue to decide whether
     * the outage is a wedge (device present, unreachable) or simply an absent device — so
     * the probe runs even when file logging is off, and is not merely diagnostic. It is
     * invoked exactly once; when the probe cannot run at all it is invoked immediately with
     * `true`, preserving the pre-probe behaviour of alerting on any six-failure streak.
     *
     * Call once per outage — the caller's `wedgeDetected` latch already ensures that.
     */
    fun captureWedge(
        context: Context,
        bleManager: OmiBleManager,
        address: String,
        consecutiveFailures: Int,
        retryCount: Int,
        lastStatus: Int,
        onProbeComplete: (advertisingHeard: Boolean) -> Unit,
    ) {
        val addr = address.uppercase()
        val btManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = btManager?.adapter
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager

        // Every LE link the system holds right now, ours included. Contention alone was
        // measured not to cause the failure, but the count is the first thing to check
        // against that conclusion when a new outage looks different.
        val otherLinks = JSONArray()
        var omiInGattList = false
        try {
            for (device in bleManager.connectedLeLinks()) {
                if (device.address.uppercase() == addr) {
                    omiInGattList = true
                } else {
                    otherLinks.put("${device.name ?: "unknown"} @ ${device.address}")
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Cannot enumerate LE links: ${e.message}")
        }

        val bondState = try {
            adapter?.bondedDevices?.firstOrNull { it.address.uppercase() == addr }
                ?.let { bondStateName(it.bondState) } ?: "not_bonded"
        } catch (e: Exception) {
            "unreadable"
        }

        logEvent(
            context, "ble_wedge", mapOf(
                "device" to addr,
                "consecutive_failures" to consecutiveFailures,
                "retry_count" to retryCount,
                // -1 is our own connect backstop firing, i.e. Android never reported a
                // status. Any other value is the framework's, and is the useful one.
                "last_gatt_status" to lastStatus,
                "adapter_state" to (adapter?.let { adapterStateName(it.state) } ?: "no_adapter"),
                "bond_state" to bondState,
                // Both false means no stale link is holding the peripheral's single
                // connection slot — the state seen throughout the 2026-07-08 outage.
                "omi_in_gatt_list" to omiInGattList,
                "omi_acl_connected" to bleManager.isAclConnectedTo(addr),
                "other_le_links" to otherLinks,
                "le_link_count" to (otherLinks.length() + if (omiInGattList) 1 else 0),
                "screen_interactive" to (power?.isInteractive ?: false),
                "doze_mode" to (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) power?.isDeviceIdleMode else null),
                "uptime_ms" to SystemClock.elapsedRealtime(),
            )
        )

        probeAdvertising(context, adapter, addr, onProbeComplete)
    }

    /**
     * Listen for [addr]'s advertisements for [PROBE_DURATION_MS], log what was heard, and
     * hand the verdict to [onComplete] on the main thread.
     *
     * Deliberately its own [ScanCallback] and not [OmiBleManager.startScan]: that one owns
     * a single `scanCallback` field used by device discovery, and would be clobbered.
     *
     * SCAN_MODE_LOW_LATENCY is a ~100% radio duty cycle. That is exactly what the app's
     * permanent discovery scan was just changed *away* from, and it is still the right
     * choice here: this runs bounded to 8 s, at most once per outage, in the ~30 s gap
     * between backed-off retries, and a lower duty cycle would let the peripheral's 1 s
     * slow-advertising tier slip between scan windows and produce a false silence — the
     * exact reading this probe exists to make trustworthy.
     *
     * Every early return reports `true` (assume present), which keeps the caller's alert
     * behaviour identical to what it was before the probe existed. Those returns post to the
     * main thread rather than calling back inline: [captureWedge] runs on whatever thread the
     * disconnect arrived on — a GATT binder thread, in the common case — and a callback whose
     * thread depends on which branch it took is a trap for the next caller.
     */
    private fun probeAdvertising(
        context: Context,
        adapter: BluetoothAdapter?,
        addr: String,
        onComplete: (advertisingHeard: Boolean) -> Unit,
    ) {
        fun assumePresent() = handler.post { onComplete(true) }

        if (adapter == null || !adapter.isEnabled) { assumePresent(); return }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED
        ) {
            assumePresent(); return
        }
        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) { assumePresent(); return }
        if (!probeInFlight.compareAndSet(false, true)) { assumePresent(); return }

        val startedAt = SystemClock.elapsedRealtime()

        // Results arrive on a binder thread; the summary is read on the main thread when
        // the probe window closes. @Volatile supplies the visibility that plain captured
        // locals would not, and the single-writer/single-reader-after-stop ordering means
        // no stronger synchronisation is needed.
        val tally = object : ScanCallback() {
            @Volatile var packets = 0
            @Volatile var firstSeenMs = -1L
            @Volatile var rssiMin = Int.MAX_VALUE
            @Volatile var rssiMax = Int.MIN_VALUE
            @Volatile var rssiLast = 0

            override fun onScanResult(callbackType: Int, result: ScanResult) {
                if (result.device.address.uppercase() != addr) return
                packets++
                if (firstSeenMs < 0) firstSeenMs = SystemClock.elapsedRealtime() - startedAt
                rssiLast = result.rssi
                if (result.rssi < rssiMin) rssiMin = result.rssi
                if (result.rssi > rssiMax) rssiMax = result.rssi
            }

            override fun onScanFailed(errorCode: Int) {
                Log.w(TAG, "Wedge probe scan failed: $errorCode")
            }
        }

        val filters = listOf(ScanFilter.Builder().setDeviceAddress(addr).build())
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()

        try {
            scanner.startScan(filters, settings, tally)
        } catch (e: Exception) {
            Log.w(TAG, "Wedge probe scan could not start: ${e.message}")
            probeInFlight.set(false)
            assumePresent(); return
        }

        handler.postDelayed({
            try {
                scanner.stopScan(tally)
            } catch (e: Exception) {
                Log.w(TAG, "Wedge probe scan could not stop: ${e.message}")
            }
            probeInFlight.set(false)

            val packets = tally.packets
            val heard = packets > 0
            Log.i(TAG, "Wedge probe for $addr: $packets adv packets in ${PROBE_DURATION_MS}ms")
            logEvent(
                context, "ble_wedge_scan_probe", mapOf(
                    "device" to addr,
                    "probe_ms" to PROBE_DURATION_MS,
                    "adv_packets" to packets,
                    "first_seen_ms" to (if (tally.firstSeenMs >= 0) tally.firstSeenMs else null),
                    "rssi_min" to (if (heard) tally.rssiMin else null),
                    "rssi_max" to (if (heard) tally.rssiMax else null),
                    "rssi_last" to (if (heard) tally.rssiLast else null),
                    // The whole point of the probe. "advertising" narrows the fault to the
                    // link-establishment handshake with a peripheral we can plainly hear;
                    // "silent" means either its radio stopped or ours never listened.
                    "verdict" to (if (heard) "peripheral_advertising" else "no_advertisements_heard"),
                )
            )
            onComplete(heard)
        }, PROBE_DURATION_MS)
    }

    /** Logged when a connect finally lands after [captureWedge] fired, closing the record. */
    fun captureRecovery(context: Context, address: String, wedgeStartedAtMs: Long, failuresBeforeRecovery: Int) {
        logEvent(
            context, "ble_wedge_recovered", mapOf(
                "device" to address.uppercase(),
                "wedge_duration_ms" to (if (wedgeStartedAtMs > 0) SystemClock.elapsedRealtime() - wedgeStartedAtMs else null),
                "failures_before_recovery" to failuresBeforeRecovery,
            )
        )
    }
}
