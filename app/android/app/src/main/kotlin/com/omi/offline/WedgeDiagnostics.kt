package com.omi.offline

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
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
 * Records are encoded here and **handed to Dart to write** (`BleFlutterApi.onNativeLogRecords`
 * → `DebugLogManager.appendNativeRecords`), in the same one-JSON-object-per-line shape
 * `DebugLogManager.logEvent` produces. Dart owns the file; nothing here touches it.
 *
 * This class used to append to the file directly, on the reasoning that an outage happens
 * while the app is backgrounded, where the Flutter isolate might be frozen and unable to
 * service a platform channel, whereas the foreground service is still running. That
 * reasoning no longer holds, and following it was costing more than it saved:
 *  - The strong form of it — Dart *gone*, not merely slow — was the Activity-owned engine
 *    being reclaimed. The engine is owned by the `Application` since 0.36.0, so Dart now
 *    outlives the Activity (see NOTES.md, "The Flutter engine outlives the Activity").
 *  - Doze does not freeze this process anyway: it runs a `connectedDevice` foreground
 *    service, so it is never a cached app.
 *  - And the direct write was silently destroying these records. Dart's `FileMode.append`
 *    resolves its offset when the file is opened, not when the bytes go out, while
 *    `FileOutputStream(append = true)` is a real `O_APPEND` — so Dart wrote on top of
 *    whatever landed here in between, one-directionally, leaving no torn line to notice.
 *    A 4.4 h capture on 2026-08-31 kept one record out of eight.
 *
 * The honest trade: a record now waits for Dart instead of being written immediately. If
 * Dart is unreachable the records queue (bounded, [MAX_PENDING_RECORDS]) and overflow is
 * reported as a `native_log_records_dropped` record rather than vanishing. Bounded and
 * counted beats immediate and destroyed.
 *
 * Whether anything is kept is Dart's decision — `DebugLogManager` drops records when
 * developer file logging is off. This no longer infers that from the file's existence.
 *
 * The advertising probe, however, always runs. It is not only diagnostic: its verdict
 * decides whether the caller shows the user the "toggle Bluetooth" alert, which is bad
 * advice for an Omi that is merely out of range. So the scan's cost is paid regardless
 * of the logging setting, and only the log lines are conditional.
 */
@SuppressLint("MissingPermission")
object WedgeDiagnostics {

    /**
     * What the advertising probe learned. A boolean cannot carry this: "the Omi is not there"
     * and "I was unable to look" are opposite instructions to the caller, and collapsing them
     * either alerts with no evidence or withholds the alert forever.
     */
    enum class ProbeVerdict {
        /** Advertisements heard. The Omi is present and we still cannot reach it — a wedge. */
        ADVERTISING,

        /** The scan ran its full window and heard nothing. The Omi is absent, or its radio is. */
        SILENT,

        /**
         * The scan could not run this time — rejected by the framework, or another probe held
         * the scanner. Says nothing about the peripheral. The caller should look again soon.
         */
        INCONCLUSIVE,

        /**
         * The scan cannot run at all: no adapter, adapter off, BLUETOOTH_SCAN not granted, or —
         * below Android 12, where a scan is a location operation — no location grant and no
         * location toggle. Looking again would not help, so the caller falls back to its
         * pre-probe behaviour of alerting on the failure streak alone.
         */
        UNAVAILABLE,
    }

    /** The verdict as it appears in the debug log. One name per case, one place to change it. */
    private fun ProbeVerdict.logName(): String = when (this) {
        ProbeVerdict.ADVERTISING -> "peripheral_advertising"
        ProbeVerdict.SILENT -> "no_advertisements_heard"
        ProbeVerdict.INCONCLUSIVE -> "scan_failed"
        ProbeVerdict.UNAVAILABLE -> "probe_unavailable"
    }

    private const val TAG = "OmiBle.WedgeDiag"

    /** How long to listen for the peripheral's advertisements once wedged. */
    private const val PROBE_DURATION_MS = 8_000L

    /**
     * Classic profiles worth reporting in an outage snapshot, with the name each gets in the log.
     * Audio only: A2DP and HFP/HSP are the profiles whose scheduling actually competes with an LE
     * connect initiator. `HID_HOST` would round out the picture but its constant is hidden
     * (`@SystemApi`), and there is no supported way to read that profile's state from an app.
     */
    private val CLASSIC_PROFILES: List<Pair<Int, String>> = listOf(
        BluetoothProfile.A2DP to "a2dp",
        BluetoothProfile.HEADSET to "headset",
    )

    private val probeInFlight = AtomicBoolean(false)
    private val handler = Handler(Looper.getMainLooper())

    private fun timestamp(): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        fmt.timeZone = TimeZone.getTimeZone("UTC")
        return fmt.format(Date())
    }

    /**
     * Records waiting to reach Dart, which is the debug log's only writer.
     *
     * **Native must never append to that file.** It did until 2026-08-31, and the writes
     * were being destroyed: `DebugLogManager._append` uses Dart's `FileMode.append`, which
     * is *not* `O_APPEND` — it resolves the write offset when the file is opened, not when
     * the bytes go out — while `FileOutputStream(append = true)` here is. So a record
     * appended between Dart's open and Dart's write was overwritten by it. One-directional
     * (nothing here ever clobbered a Dart line), and concentrated exactly where it did the
     * most damage: these records are emitted on disconnect, the same instant Dart emits its
     * own burst about that disconnect. A 4.4 h capture kept **one** of eight expected
     * `ble_link_drop` records, and the survivor was a deliberate disconnect rather than one
     * of the supervision timeouts the record exists to classify — a biased sample is worse
     * than none, because it looks like data.
     *
     * Dart already serializes every writer inside its own isolate with a mutex; handing
     * these to it puts them under the same lock instead of racing it across a language
     * boundary.
     *
     * Bounded, and **overflow is counted, never silent** — silence is the property that let
     * the original fault run undetected for as long as it did. [droppedRecords] rides out on
     * the next successful drain.
     */
    private val pendingRecords = ArrayDeque<String>()
    private const val MAX_PENDING_RECORDS = 256
    private var droppedRecords = 0

    /**
     * Encodes one event line in `DebugLogManager.logEvent`'s schema and queues it for Dart.
     *
     * Encoding happens on the caller's thread so the timestamp inside the line is the
     * instant the event happened, not the instant Dart drained it. A batch delivered late is
     * therefore still dated correctly, though it lands in the file after lines logged while
     * it was in flight — read the log by timestamp, not by position.
     *
     * `context` is unused now that nothing here touches the disk. It stays on the signature
     * because every caller has one and threading it back through if this ever needs an
     * application context again is churn for no gain.
     */
    @Suppress("UNUSED_PARAMETER")
    private fun logEvent(context: Context, type: String, fields: Map<String, Any?>) {
        val line = try {
            val payload = JSONObject()
            payload.put("timestamp", timestamp())
            payload.put("level", "EVENT")
            payload.put("type", type)
            for ((k, v) in fields) payload.put(k, v ?: JSONObject.NULL)
            payload.toString()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to encode $type: ${e.message}")
            return
        }
        synchronized(pendingRecords) {
            // Drop the OLDEST on overflow. A backlog this deep means Dart has been gone a
            // long time, and in that situation the newest records describe what is wrong
            // now; the oldest describe a state several failures ago.
            while (pendingRecords.size >= MAX_PENDING_RECORDS) {
                pendingRecords.removeFirst()
                droppedRecords++
            }
            pendingRecords.addLast(line)
        }
        drainToDart()
    }

    /**
     * Public entry point for the drain, called when Dart declares itself ready.
     *
     * [drainToDart] is otherwise only reached by a new record arriving, so records captured
     * before Dart came up — the boot-time ones, which have no successor to push them out —
     * would wait for an unrelated BLE event.
     */
    fun flushPendingRecords() = drainToDart()

    /**
     * Hands every queued record to Dart, oldest first.
     *
     * Gated on `isFlutterAlive` rather than a null check alone: after an OS-reclaim Activity
     * destroy `flutterApi` can dangle at a dead messenger, where a send silently no-ops —
     * which would put us straight back to losing records without knowing. Anything not sent
     * stays queued for the next call.
     *
     * Pigeon's generated sender must run on the main looper. Records are already timestamped
     * by then, so the hop costs nothing but ordering, which the timestamps carry anyway.
     *
     * The reply confirms **delivery, not durability**: the Dart handler is a `void` Pigeon
     * method, so it answers as soon as it has the batch, and the append it starts swallows
     * its own IO errors the way every other Dart log write does. So a failed *send* is
     * retried here, and a failed *write* is not. That is deliberate — it makes these records
     * exactly as reliable as the Dart lines they sit beside, and no more. Do not read this
     * path as loss-proof; read it as no longer losing records to a race.
     */
    private fun drainToDart() {
        val api = if (OmiBleManager.isFlutterAlive) OmiBleManager.instance.flutterApi else null
        if (api == null) return
        handler.post {
            val batch: List<String>
            val dropped: Int
            synchronized(pendingRecords) {
                if (pendingRecords.isEmpty() && droppedRecords == 0) return@post
                batch = pendingRecords.toList()
                dropped = droppedRecords
                pendingRecords.clear()
                droppedRecords = 0
            }
            val lines = if (dropped > 0) {
                // Report the loss in the log itself, in the same schema, so it is visible to
                // whoever reads the capture rather than only to logcat.
                val notice = JSONObject()
                    .put("timestamp", timestamp())
                    .put("level", "EVENT")
                    .put("type", "native_log_records_dropped")
                    .put("count", dropped)
                    .toString()
                listOf(notice) + batch
            } else {
                batch
            }
            api.onNativeLogRecords(lines) { result ->
                if (result.isFailure) {
                    // Put them back rather than lose them; the next event drains again.
                    synchronized(pendingRecords) {
                        for (l in batch.asReversed()) {
                            if (pendingRecords.size < MAX_PENDING_RECORDS) pendingRecords.addFirst(l)
                            else droppedRecords++
                        }
                        droppedRecords += dropped
                    }
                    Log.w(TAG, "Failed to hand ${batch.size} records to Dart: ${result.exceptionOrNull()?.message}")
                }
            }
        }
    }

    /**
     * One line about the single-in-flight GATT command pipeline, for the case Dart cannot
     * see: `NativeBleTransport` abandons a read/write after 10 s, but that timeout is
     * Dart-local. It cannot tell an operation that was merely slow — and later completed,
     * freeing the pipeline — from one whose callback never arrived, which parks every
     * command queued behind it until the link drops. The two need opposite fixes, and the
     * only place that distinction exists is here.
     *
     * Read the outcomes as a sequence for one command:
     *  - `stalled` alone, then nothing: the callback never came. Anything enqueued after it
     *    was never sent, however healthy the link looked.
     *  - `stalled` then `recovered`: slow, not wedged. Dart gave up early; the pipeline was
     *    fine. Whatever else went wrong, it was not this.
     *  - `stalled` then `abandoned`: it stayed stuck until the peripheral was torn down.
     *
     * Log-only, deliberately. Nothing here completes, cancels or re-posts a command:
     * force-completing races the late callback this is trying to detect, and a double
     * completeCommand() would pop an unrelated command off the queue.
     */
    fun captureGattCommand(
        context: Context,
        outcome: String,
        label: String,
        outstandingMs: Long,
        queuedBehind: Int,
    ) {
        logEvent(
            context,
            "ble_gatt_command",
            mapOf(
                "outcome" to outcome,
                "command" to label,
                "outstanding_ms" to outstandingMs,
                "queued_behind" to queuedBehind,
            ),
        )
    }

    private fun adapterStateName(state: Int): String = when (state) {
        BluetoothAdapter.STATE_OFF -> "off"
        BluetoothAdapter.STATE_TURNING_ON -> "turning_on"
        BluetoothAdapter.STATE_ON -> "on"
        BluetoothAdapter.STATE_TURNING_OFF -> "turning_off"
        else -> "unknown_$state"
    }

    /**
     * Below Android 12 an LE scan is a location operation: it needs a location grant, and it
     * needs the system location toggle on. Without the toggle the scan starts, runs, and
     * silently delivers nothing — indistinguishable from a peripheral that isn't there, which
     * is precisely the verdict the probe must not fabricate.
     *
     * Unreadable state answers `true`: let the scan itself speak rather than invent a verdict.
     */
    private fun locationServicesEnabled(context: Context): Boolean = try {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        when {
            lm == null -> true
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.P -> lm.isLocationEnabled
            else -> lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }
    } catch (e: Exception) {
        Log.w(TAG, "Cannot read location services state: ${e.message}")
        true
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
     * Emits `ble_wedge` immediately (so the state survives even if the process dies mid-probe)
     * and exactly one `ble_wedge_scan_probe` once the probe resolves — **at least**
     * [PROBE_DURATION_MS] later if it scanned, right away if it could not. Every outage record
     * therefore carries its own verdict, and a missing one means the process died rather than
     * that the probe stayed silent.
     *
     * "At least" is not pedantry: the window is closed by a main-looper post, which in a
     * backgrounded app runs late, so the probe's `probe_ms` reports what it measured and
     * `probe_requested_ms` what it asked for. Never assume the two agree.
     *
     * [onProbeComplete] receives a [ProbeVerdict] for [address], on the main thread, once the
     * probe window closes. This is the caller's cue to decide whether the outage is a wedge
     * (device present, unreachable) or simply an absent device — so the probe runs even when
     * file logging is off, and is not merely diagnostic. It is invoked exactly once.
     *
     * The caller re-probes a long outage every few failures, so this may run more than once
     * per outage; [probeInFlight] keeps two probes from overlapping.
     */
    /**
     * Link strength at the moment a connection dropped.
     *
     * Nothing recorded RSSI on a live link before this. The app has been calling
     * `readRemoteRssi()` every 3 s since the RSSI keep-alive was added, but there was no
     * `onReadRemoteRssi` override, so every one of those reads was discarded — the value
     * was measured and thrown away. The only RSSI in the logs came from
     * `ble_wedge_scan_probe`, which runs while SCANNING, so a transfer that died
     * mid-file left no record of how strong the link was.
     *
     * That is the question a mid-transfer drop actually raises. A supervision timeout
     * (`gatt_status_8`) at -60 dBm means something on the device stopped answering; the
     * same timeout at -100 dBm means the Omi was simply too far away. Those want opposite
     * investigations, and without this they are indistinguishable after the fact.
     *
     * [rssiAgeMs] matters as much as the value: the keep-alive reads every 3 s, so a
     * reading much older than that means the link had already stopped carrying traffic.
     */
    fun captureLinkDrop(context: Context, address: String, status: Int, rssi: Int?, rssiAgeMs: Long?) {
        logEvent(
            context,
            "ble_link_drop",
            mapOf(
                "device" to address,
                "gatt_status" to status,
                "last_rssi" to rssi,
                "rssi_age_ms" to rssiAgeMs,
            ),
        )
    }

    fun captureWedge(
        context: Context,
        bleManager: OmiBleManager,
        address: String,
        consecutiveFailures: Int,
        retryCount: Int,
        lastStatus: Int,
        lastRealStatus: Int?,
        onProbeComplete: (verdict: ProbeVerdict) -> Unit,
    ) {
        val addr = address.uppercase()
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

        val bondState = try {
            adapter?.bondedDevices?.firstOrNull { it.address.uppercase() == addr }
                ?.let { bondStateName(it.bondState) } ?: "not_bonded"
        } catch (e: Exception) {
            "unreadable"
        }

        // Wedge-specific fields first, then the shared environment snapshot — the same fields
        // captureRecovery records, so the two can be diffed to explain how the outage resolved.
        val fields = linkedMapOf<String, Any?>(
            "device" to addr,
            "consecutive_failures" to consecutiveFailures,
            "retry_count" to retryCount,
            // -1 is our own connect backstop firing, i.e. Android never reported a
            // status. Any other value is the framework's, and is the useful one.
            "last_gatt_status" to lastStatus,
            // The most recent status Android actually delivered this outage (null if it
            // never did — an all-timeout outage where the initiator wedged with zero
            // callbacks). This is what survives the -1 masking: `-1` + `147` means the
            // stack was rejecting, `-1` + null means it went completely silent.
            "last_real_gatt_status" to lastRealStatus,
            "bond_state" to bondState,
            "uptime_ms" to SystemClock.elapsedRealtime(),
        )
        fields.putAll(environmentSnapshot(context, bleManager, addr))
        logEvent(context, "ble_wedge", fields)

        probeAdvertising(context, adapter, addr, onProbeComplete)
    }

    /**
     * The phone-side environment both ends of an outage record share: adapter state, every
     * contending LE link, and the screen/Doze state that governs how much radio time the stack
     * gives us. Captured at *both* wedge-detection and recovery on purpose — a wedge that clears
     * on its own leaves no trace of *why* unless these same fields, taken at both moments, can be
     * diffed. A contention count that fell, a screen that woke, or Doze that exited between the two
     * is the most likely cause of a spontaneous recovery, and the only one these logs can name.
     *
     * Every read is defensive: a throw in any one field must not cost the log line it is part of.
     */
    private fun environmentSnapshot(
        context: Context,
        bleManager: OmiBleManager,
        addr: String,
    ): Map<String, Any?> {
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager

        // Every LE link the system holds right now, ours included. Contention alone was measured
        // not to cause the failure, but a count that *moved* across the outage is the first thing
        // to check when a wedge clears with nothing else having changed.
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

        // Guarded at the call site like connectedLeLinks() above: isAclConnectedTo resolves the
        // address via remoteLeDevice(), which throws IllegalArgumentException on a malformed one.
        // This snapshot now runs inside onGattServicesDiscovered (via captureRecovery), which
        // finishes the connection (MTU → device-ready) immediately after — a diagnostic must never
        // be able to abort the recovery it is recording, so it degrades to false rather than throw.
        val aclConnected = try {
            bleManager.isAclConnectedTo(addr)
        } catch (e: Exception) {
            Log.w(TAG, "Cannot read ACL state: ${e.message}")
            false
        }

        val classicProfiles = connectedClassicProfiles(adapter)
        val audioDevices = btAudioDevices(context)

        return linkedMapOf(
            "adapter_state" to (adapter?.let { adapterStateName(it.state) } ?: "no_adapter"),
            // Both false means no stale link is holding the peripheral's single connection slot.
            "omi_in_gatt_list" to omiInGattList,
            "omi_acl_connected" to aclConnected,
            "other_le_links" to otherLinks,
            // Contenders only — excludes the Omi's own link, which is absent at wedge (it is
            // failing to connect) and present at recovery (it just connected). le_link_count folds
            // that +1 into the total, so a lone contender dropping across the two events reads
            // identically (wedge other=1/omi=0 and recovery other=0/omi=1 both total 1). Diff THIS
            // field for the contention signal; le_link_count stays as the raw system-wide total.
            "contending_le_links" to otherLinks.length(),
            "le_link_count" to (otherLinks.length() + if (omiInGattList) 1 else 0),
            // The classic (BR/EDR) half of the contention picture, which every field above is
            // structurally blind to — see connectedClassicProfiles(). Diff both across
            // wedge→recovery: a headset or car kit that connected just before the outage and
            // dropped just before the recovery is the same signal contending_le_links carries
            // for LE, and until these existed it could not be seen at all.
            "classic_profiles" to classicProfiles,
            "bt_audio_devices" to audioDevices,
            // Connected vs actually streaming — see scoActive(). An idle link and a live call are
            // both "connected" but only one seriously competes for the controller's time.
            "sco_active" to scoActive(context),
            "audio_active" to audioActive(context),
            "screen_interactive" to (power?.isInteractive ?: false),
            "doze_mode" to (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) power?.isDeviceIdleMode else null),
        )
    }

    /**
     * Which classic (BR/EDR) profiles currently hold a link. [OmiBleManager.connectedLeLinks]
     * structurally cannot see these: it reads the GATT profile list, and a car kit, a headset or a
     * pair of smart glasses connects over A2DP/HFP, not GATT. The blind spot was load-bearing —
     * wedge records listed one contending LE link (a watch) while the devices actually suspected of
     * causing the outage were classic audio, so the log could neither support nor refute the
     * suspicion.
     *
     * Classic audio is also the harder contender of the two to share a radio with: A2DP, and SCO
     * especially, hold reserved periodic slots the controller schedules around, leaving an LE
     * connect initiator whatever is left. That is the shape that produces `147` — the peer never
     * completed the link — rather than an outright rejection.
     *
     * [BluetoothAdapter.getProfileConnectionState] rather than a profile proxy because it is
     * synchronous: this snapshot runs on a GATT binder thread inside the disconnect path and must
     * not wait on a service binding. The price is that it reports only *whether* a profile has a
     * link, never to which device — [btAudioDevices] names the connected endpoints, and
     * [scoActive] / [audioActive] say whether any of them was actually carrying audio.
     */
    private fun connectedClassicProfiles(adapter: BluetoothAdapter?): JSONArray {
        val out = JSONArray()
        if (adapter == null) return out
        for ((profile, name) in CLASSIC_PROFILES) {
            try {
                if (adapter.getProfileConnectionState(profile) == BluetoothProfile.STATE_CONNECTED) {
                    out.put(name)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Cannot read $name profile state: ${e.message}")
            }
        }
        return out
    }

    /**
     * The Bluetooth audio endpoints the framework has *available*, by name — the only synchronous
     * way to put a *device* behind [connectedClassicProfiles]'s bare profile names.
     *
     * Available, not active: `getDevices` lists every connected endpoint that could be routed to,
     * so a paired-and-connected headset appears here while it sits idle and while audio is coming
     * out of the phone's own speaker. Naming this "routes" would invite exactly the misreading that
     * matters — an idle A2DP link and one actively streaming are very different contenders for the
     * controller's time, and only the second is a strong suspect for a failed connect. [scoActive]
     * and [audioActive] carry that distinction; this field carries identity.
     *
     * Covers LE Audio (`TYPE_BLE_*`) as well: an LE Audio headset is a scheduling contender that
     * may never appear in the GATT list either, so reading only the classic types would reopen the
     * same blind spot one generation of hardware later. Those constants are API 31 but need no
     * version guard — they are compile-time `Int`s, and a pre-31 device simply never reports them.
     */
    private fun btAudioDevices(context: Context): JSONArray {
        val out = JSONArray()
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return out
        try {
            val devices = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS or AudioManager.GET_DEVICES_INPUTS)
            for (device in devices) {
                val kind = when (device.type) {
                    AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "a2dp"
                    AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "sco"
                    AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER -> "le_audio"
                    else -> continue
                }
                out.put("${device.productName} ($kind)")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Cannot enumerate BT audio devices: ${e.message}")
        }
        return out
    }

    /**
     * Whether audio is actually *flowing*, which is what decides how much of the radio a connected
     * audio device is really taking. [btAudioDevices] can only say something is connected.
     *
     * The SCO half is the one worth having: SCO is a reserved periodic slot the controller cannot
     * preempt, so a call in progress over a car kit is the worst case for an LE connect initiator.
     *
     * The name is narrower than the reading, deliberately: an LE Audio headset on a call sets this
     * too (`TYPE_BLE_HEADSET`), and LE Audio claims no classic SCO slot — it reserves scheduled
     * isochronous events instead. Still a contender, but a different mechanism, so a `true` here is
     * "a voice call was routed to Bluetooth", not "the classic-SCO worst case" specifically. Both
     * are included because the diagnostic question is whether a call was occupying the radio.
     *
     * `isMusicActive` is not Bluetooth-specific — it is true for speaker playback too — so it means
     * "A2DP was probably streaming" only when read together with an `a2dp` entry in
     * [btAudioDevices]. Recorded separately rather than folded into one flag for that reason.
     *
     * `getCommunicationDevice()` on API 31+, where `isBluetoothScoOn` is deprecated; the deprecated
     * call still runs below that, since minSdk is 26 and there is no other way to ask there.
     */
    @Suppress("DEPRECATION")
    private fun scoActive(context: Context): Boolean? = try {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        when {
            audio == null -> null
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> audio.communicationDevice?.type.let {
                it == AudioDeviceInfo.TYPE_BLUETOOTH_SCO || it == AudioDeviceInfo.TYPE_BLE_HEADSET
            }
            else -> audio.isBluetoothScoOn
        }
    } catch (e: Exception) {
        Log.w(TAG, "Cannot read SCO state: ${e.message}")
        null
    }

    /** See [scoActive] — only meaningful alongside an `a2dp`/`le_audio` entry in [btAudioDevices]. */
    private fun audioActive(context: Context): Boolean? = try {
        (context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager)?.isMusicActive
    } catch (e: Exception) {
        Log.w(TAG, "Cannot read playback state: ${e.message}")
        null
    }

    /**
     * Listen for [addr]'s advertisements for [PROBE_DURATION_MS] — a floor, not a bound; see
     * `probe_ms` vs `probe_requested_ms` below — log what was heard, and hand the verdict to
     * [onComplete] on the main thread.
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
     * A zero-packet tally only means "silent" if the scan actually listened. The framework can
     * refuse a scan up front, or accept it and reject it asynchronously via `onScanFailed` —
     * SCAN_FAILED_SCANNING_TOO_FREQUENTLY is plausible here, since the app runs its own
     * discovery scans and Android rate-limits scan starts per app. Those report
     * [ProbeVerdict.INCONCLUSIVE], never [ProbeVerdict.SILENT]. Reporting them as advertising
     * instead would post the alert on no evidence and, because the caller latches on the first
     * affirmative verdict, stop it from ever looking again.
     *
     * Early returns post to the main thread rather than calling back inline: [captureWedge]
     * runs on whatever thread the disconnect arrived on — a GATT binder thread, in the common
     * case — and a callback whose thread depends on which branch it took is a trap for the
     * next caller. They also log their verdict before returning: an outage record that holds a
     * `ble_wedge` with no `ble_wedge_scan_probe` after it cannot be told apart from one where
     * the process died mid-probe, and "we never got to look, and here is why" is a finding.
     */
    private fun probeAdvertising(
        context: Context,
        adapter: BluetoothAdapter?,
        addr: String,
        onComplete: (verdict: ProbeVerdict) -> Unit,
    ) {
        // A verdict reached without scanning. Leaves the same one-line record a completed scan
        // leaves, with `reason` naming the door that was shut.
        fun reportUnscanned(verdict: ProbeVerdict, reason: String) {
            Log.i(TAG, "Wedge probe for $addr: not scanned ($reason) → $verdict")
            logEvent(
                context, "ble_wedge_scan_probe", mapOf(
                    "device" to addr,
                    "probe_ms" to 0,
                    "adv_packets" to 0,
                    "verdict" to verdict.logName(),
                    "reason" to reason,
                )
            )
            handler.post { onComplete(verdict) }
        }

        // Nothing a later probe could fix: the caller falls back to its pre-probe behaviour.
        if (adapter == null) { reportUnscanned(ProbeVerdict.UNAVAILABLE, "no_adapter"); return }
        if (!adapter.isEnabled) { reportUnscanned(ProbeVerdict.UNAVAILABLE, "adapter_off"); return }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED) {
                reportUnscanned(ProbeVerdict.UNAVAILABLE, "no_bluetooth_scan_permission"); return
            }
        } else {
            // minSdk is 26, so Android 8–11 reach here, where scanning is gated on location
            // rather than on BLUETOOTH_SCAN. A missing grant makes startScan throw; a disabled
            // location toggle makes it return nothing at all. Catch both before they masquerade
            // as INCONCLUSIVE-forever or as a silent Omi.
            val fine = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)
            val coarse = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION)
            if (fine != PackageManager.PERMISSION_GRANTED && coarse != PackageManager.PERMISSION_GRANTED) {
                reportUnscanned(ProbeVerdict.UNAVAILABLE, "no_location_permission"); return
            }
            if (!locationServicesEnabled(context)) {
                reportUnscanned(ProbeVerdict.UNAVAILABLE, "location_services_off"); return
            }
        }
        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) { reportUnscanned(ProbeVerdict.UNAVAILABLE, "no_scanner"); return }
        // Another device's probe owns the scanner right now. Transient — look again later.
        if (!probeInFlight.compareAndSet(false, true)) {
            reportUnscanned(ProbeVerdict.INCONCLUSIVE, "probe_already_running"); return
        }

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

            /** Non-null once Android rejects the scan; the probe then has no opinion. */
            @Volatile var scanError: Int? = null

            override fun onScanResult(callbackType: Int, result: ScanResult) {
                if (result.device.address.uppercase() != addr) return
                packets++
                if (firstSeenMs < 0) firstSeenMs = SystemClock.elapsedRealtime() - startedAt
                rssiLast = result.rssi
                if (result.rssi < rssiMin) rssiMin = result.rssi
                if (result.rssi > rssiMax) rssiMax = result.rssi
            }

            override fun onScanFailed(errorCode: Int) {
                scanError = errorCode
                Log.w(TAG, "Wedge probe scan failed: $errorCode")
            }
        }

        val filters = listOf(ScanFilter.Builder().setDeviceAddress(addr).build())
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()

        try {
            scanner.startScan(filters, settings, tally)
        } catch (e: SecurityException) {
            // A grant revoked between the check above and here, or one this code does not know
            // to ask for. Retrying cannot earn it back.
            Log.w(TAG, "Wedge probe scan denied: ${e.message}")
            probeInFlight.set(false)
            reportUnscanned(ProbeVerdict.UNAVAILABLE, "scan_denied"); return
        } catch (e: Exception) {
            Log.w(TAG, "Wedge probe scan could not start: ${e.message}")
            probeInFlight.set(false)
            reportUnscanned(ProbeVerdict.INCONCLUSIVE, "scan_start_failed"); return
        }

        handler.postDelayed({
            try {
                scanner.stopScan(tally)
            } catch (e: Exception) {
                Log.w(TAG, "Wedge probe scan could not stop: ${e.message}")
            }
            probeInFlight.set(false)

            // The window the scan ACTUALLY listened for, not the one asked for. The stop
            // below is a main-looper postDelayed, and in a backgrounded, screen-off app —
            // i.e. every real outage — it can fire well late while results keep arriving on
            // the binder thread. Wedge 9 logged `first_seen_ms=14530` against a requested
            // 8000, so the scan ran at least 14.5 s and the packet count was being read as
            // if it covered 8. Reporting the constant made `adv_packets` incomparable
            // between probes, which is the number the wedge-vs-out-of-range call turns on
            // (BLE_Research.md §3). Measured on the same clock as `first_seen_ms`, so the
            // two can be read against each other; the gap to `probe_requested_ms` is itself
            // a signal, since it measures how starved the main thread was.
            val actualMs = SystemClock.elapsedRealtime() - startedAt
            val packets = tally.packets
            val heard = packets > 0
            val scanError = tally.scanError
            // A packet heard is a packet heard, whatever the framework said afterwards. Zero
            // packets from a scan the framework rejected is not silence — it never listened.
            val verdict = when {
                heard -> ProbeVerdict.ADVERTISING
                scanError != null -> ProbeVerdict.INCONCLUSIVE
                else -> ProbeVerdict.SILENT
            }
            Log.i(TAG, "Wedge probe for $addr: $packets adv packets in ${actualMs}ms → $verdict")
            logEvent(
                context, "ble_wedge_scan_probe", mapOf(
                    "device" to addr,
                    "probe_ms" to actualMs,
                    "probe_requested_ms" to PROBE_DURATION_MS,
                    "adv_packets" to packets,
                    "first_seen_ms" to (if (tally.firstSeenMs >= 0) tally.firstSeenMs else null),
                    "rssi_min" to (if (heard) tally.rssiMin else null),
                    "rssi_max" to (if (heard) tally.rssiMax else null),
                    "rssi_last" to (if (heard) tally.rssiLast else null),
                    "scan_error" to scanError,
                    // The whole point of the probe. "advertising" narrows the fault to the
                    // link-establishment handshake with a peripheral we can plainly hear;
                    // "silent" means either its radio stopped or ours never listened.
                    // "scan_failed" means we never got to ask.
                    "verdict" to verdict.logName(),
                )
            )
            onComplete(verdict)
        }, PROBE_DURATION_MS)
    }

    /**
     * Logged when a connect finally lands after [captureWedge] fired, closing the record. Carries
     * the same [environmentSnapshot] the `ble_wedge` line took at detection: diff the two to see
     * what changed as the link came back — a dropped contending link, a woken screen, or Doze
     * exiting is the cause a *self*-recovery (no Bluetooth toggle in the log before it) would
     * otherwise never name. See NOTES.md "advertising but won't connect".
     */
    fun captureRecovery(
        context: Context,
        bleManager: OmiBleManager,
        address: String,
        wedgeStartedAtMs: Long,
        failuresBeforeRecovery: Int,
        restoredAcrossRestart: Boolean = false,
    ) {
        val addr = address.uppercase()
        val fields = linkedMapOf<String, Any?>(
            "device" to addr,
            "wedge_duration_ms" to (if (wedgeStartedAtMs > 0) SystemClock.elapsedRealtime() - wedgeStartedAtMs else null),
            "failures_before_recovery" to failuresBeforeRecovery,
            // The outage outlived a process death, so it was reopened from disk. Two fields
            // read differently when this is true: `wedge_duration_ms` spans the restart (it
            // is rebuilt from a persisted wall clock, so it is good to a second rather than
            // exact), while `failures_before_recovery` counts only the failures since the
            // restart — the streak is deliberately not restored. See newManagedDevice.
            "restored_across_restart" to restoredAcrossRestart,
        )
        fields.putAll(environmentSnapshot(context, bleManager, addr))
        logEvent(context, "ble_wedge_recovered", fields)
    }
}
