import 'dart:async';
import 'dart:typed_data';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/device_crash_log.dart';
import 'package:omi/services/devices/device_drop_stats.dart';
import 'package:omi/services/devices/diag_log_record.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/utils/byte_utils.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/mutex.dart';

class OmiDeviceConnection extends DeviceConnection {
  static const String batteryServiceUuid = '0000180f-0000-1000-8000-00805f9b34fb';
  static const String batteryLevelCharacteristicUuid = '00002a19-0000-1000-8000-00805f9b34fb';

  // 1-byte battery detail: [charging:1]
  static const String batteryDetailServiceUuid = '19b10050-e8f2-537e-4f6c-d104768a1214';
  static const String batteryDetailCharacteristicUuid = '19b10051-e8f2-537e-4f6c-d104768a1214';

  // The firmware registers a button trigger service (23ba7924/…7925) but never
  // notifies on it — taps are handled on-device and recorded as inline markers in
  // the audio stream, which suits a recorder built to run disconnected. The app
  // therefore doesn't subscribe to it. The service stays on the device because
  // removing it would shift every later service's handles and force a re-pair.

  // Button + haptic config were consolidated into the Settings service: button
  // config = 19b10015, haptic = 19b10016. The old 23ba7926 service was retired;
  // both are read/written via settingsServiceUuid (byte layouts unchanged).
  static const String buttonConfigCharacteristicUuid = '19b10015-e8f2-537e-4f6c-d104768a1214';
  static const String hapticConfigCharacteristicUuid = '19b10016-e8f2-537e-4f6c-d104768a1214';

  static const String featuresServiceUuid = '19b10020-e8f2-537e-4f6c-d104768a1214';
  static const String featuresCharacteristicUuid = '19b10021-e8f2-537e-4f6c-d104768a1214';
  // Codec ID read (opus=20 / opusFS320=21); lives under the Features service.
  static const String featuresCodecCharacteristicUuid = '19b10022-e8f2-537e-4f6c-d104768a1214';

  static const String storageDataStreamServiceUuid = '30295780-4301-eabd-2904-2849adfeae43';
  static const String storageDataStreamCharacteristicUuid = '30295781-4301-eabd-2904-2849adfeae43';
  static const String storageReadControlCharacteristicUuid = '30295782-4301-eabd-2904-2849adfeae43';

  static const String timeSyncServiceUuid = '19b10030-e8f2-537e-4f6c-d104768a1214';
  static const String timeSyncWriteCharacteristicUuid = '19b10031-e8f2-537e-4f6c-d104768a1214';

  static const String disServiceUuid = '0000180a-0000-1000-8000-00805f9b34fb';
  static const String disModelNumberCharacteristicUuid = '00002a24-0000-1000-8000-00805f9b34fb';
  static const String disFirmwareRevisionCharacteristicUuid = '00002a26-0000-1000-8000-00805f9b34fb';
  static const String disHardwareRevisionCharacteristicUuid = '00002a27-0000-1000-8000-00805f9b34fb';
  static const String disManufacturerNameCharacteristicUuid = '00002a29-0000-1000-8000-00805f9b34fb';
  static const String disSerialNumberCharacteristicUuid = '00002a25-0000-1000-8000-00805f9b34fb';

  static const String settingsServiceUuid = '19b10010-e8f2-537e-4f6c-d104768a1214';
  static const String settingsDimRatioCharacteristicUuid = '19b10011-e8f2-537e-4f6c-d104768a1214';
  static const String settingsMicGainCharacteristicUuid = '19b10012-e8f2-537e-4f6c-d104768a1214';
  static const String settingsVadThresholdCharacteristicUuid = '19b10013-e8f2-537e-4f6c-d104768a1214';
  // Auto-mode Priority Recording safety cap, u16 LE minutes (0 = no cap).
  static const String settingsPriorityRecordCapCharacteristicUuid = '19b10014-e8f2-537e-4f6c-d104768a1214';
  // 19b10015 = button config, 19b10016 = haptic config (declared near the button section above).

  // LED service. Its own service rather than a Settings characteristic: Settings
  // is registered first on the device, so growing it renumbers every service
  // after it and forces bonded phones to re-pair.
  static const String ledServiceUuid = '19b10080-e8f2-537e-4f6c-d104768a1214';
  // Connected (solid blue) LED indicator, 1 byte: 0 = off, 1 = on.
  static const String ledConnectedCharacteristicUuid = '19b10081-e8f2-537e-4f6c-d104768a1214';
  // Boot value of the LED master gate, 1 byte: 0 = LEDs start off each boot, 1 = on.
  // A write also applies live; a read returns the stored default, not the live gate
  // (a button gesture toggles the session without changing the default).
  static const String ledBootCharacteristicUuid = '19b10082-e8f2-537e-4f6c-d104768a1214';

  // 8-byte diagnostics: [uint32 reset_cause LE] [uint32 uptime_seconds LE]
  static const String diagnosticsServiceUuid = '19b10060-e8f2-537e-4f6c-d104768a1214';
  static const String diagnosticsCharacteristicUuid = '19b10061-e8f2-537e-4f6c-d104768a1214';
  // 20-byte drop counters: [blockDrops u32][lastDropUptimeMs u32]
  //                        [sdStreamDrops u32][sdBootDrops u32][nowUptimeMs u32]
  static const String diagnosticsDropsCharacteristicUuid = '19b10062-e8f2-537e-4f6c-d104768a1214';
  // On-device diagnostic event log (dev builds, OMI_FEATURE_DIAG_LOG). 0x0063 =
  // drain read (snapshot header + 16-byte records); 0x0064 = control write
  // [enable u8][ack_seq u32 LE]. See diag_log_record.dart / firmware diag_log.h.
  static const String diagLogReadCharacteristicUuid = '19b10063-e8f2-537e-4f6c-d104768a1214';
  static const String diagLogControlCharacteristicUuid = '19b10064-e8f2-537e-4f6c-d104768a1214';

  // 9-byte mute state (Read / Write / Notify):
  //   [muted:1][since_utc_s:4 LE][since_uptime_ms:4 LE]
  // Write [0] to unmute, [1] to mute (no-op on the device while in manual mode).
  static const String muteServiceUuid = '19b10070-e8f2-537e-4f6c-d104768a1214';
  static const String muteCharacteristicUuid = '19b10071-e8f2-537e-4f6c-d104768a1214';

  // Protects against stale packets from previous calls
  int _listFilesGeneration = 0;

  StreamSubscription? _listFilesSub;
  Timer? _timeoutTimer;
  // Retries CMD_LIST_FILES until the firmware responds
  Timer? _cccdRetryTimer;

  StreamSubscription<List<int>>? _chargingSubscription;
  StreamSubscription<List<int>>? _muteSubscription;
  StreamSubscription<List<int>>? _dropStatsSubscription;

  // Cached audio codec to avoid redundant BLE reads
  BleAudioCodec? _cachedAudioCodec;

  final Mutex _storageMutex = Mutex();
  String? _lockOwner;

  @override
  bool get isStorageBusy => _storageMutex.isLocked;

  // 2s for the initial listFiles subscription (CCCD descriptor write is slow on first subscribe).
  static const _cccdSettleDelay = Duration(milliseconds: 2000);
  // 500ms for subsequent commands (delete, rotate) — enough for CCCD writes on slow BLE
  // stacks without the 2s penalty of the full listFiles settle delay.
  static const _cccdCommandDelay = Duration(milliseconds: 500);

  OmiDeviceConnection(super.device, super.transport);

  @override
  Future<void> acquireStorageLock([String owner = 'unknown']) async {
    try {
      // tryAcquire cleans up its waiter on timeout; `.acquire().timeout()` did
      // not, which left the mutex held by a phantom owner.
      final acquired = await _storageMutex.tryAcquire(timeout: const Duration(seconds: 10));
      if (!acquired) {
        throw TimeoutException('Storage lock not acquired within 10s');
      }
      _lockOwner = owner;

      try {
        // TODO: Implement actual BLE wake command
        // await writeToConfig(...);

        await _waitForStorageReady();
      } catch (e) {
        _lockOwner = null;
        _storageMutex.release();
        rethrow;
      }
    } catch (e) {
      Logger.error('Failed to acquire SD lock for [$owner]. Current owner: $_lockOwner. Error: $e');
      rethrow;
    }
  }

  Future<void> _waitForStorageReady() async {
    const maxAttempts = 3;

    // Best-effort wake nudge. The underlying reads swallow their errors (they
    // return null/[] rather than throwing), so readiness is inferred from the
    // return value, not exceptions. A null stats result is *not* treated as a
    // hard failure: older firmware lacks the stats characteristic and always
    // returns null, and hard-failing here would block storage sync on those
    // devices. The real readiness gate is the subsequent storage command, which
    // carries its own retries/timeouts. We only loop to give a momentarily-busy
    // SD a few hundred ms to start responding; worst case is bounded (~600ms).
    for (int i = 0; i < maxAttempts; i++) {
      final stats = await performGetStorageFileStats();
      // Cache audio codec while awake (idempotent — cached after first read).
      await performGetAudioCodec();
      if (stats != null) return; // SD confirmed responsive
      if (i < maxAttempts - 1) {
        await Future.delayed(Duration(milliseconds: 100 * (i + 1)));
      }
    }
  }

  Future<void> _sleepStorage() async {
    try {
      // TODO: Replace with actual BLE sleep command
      // await writeToConfig(...).timeout(const Duration(seconds: 2));
    } catch (_) {
      // Ignore failures
    }
  }

  @override
  void releaseStorageLock() {
    unawaited(_sleepStorage());

    _lockOwner = null;
    _storageMutex.release();
  }

  @override
  Future<void> connect({
    void Function(String deviceId, DeviceConnectionState state, {bool isManual})? onConnectionStateChanged,
    bool requiresBond = false,
  }) async {
    await super.connect(onConnectionStateChanged: onConnectionStateChanged, requiresBond: requiresBond);
    await performSyncDeviceTime();
  }

  @override
  Future<DeviceCrashLog?> performGetDiagnostics() async {
    try {
      final data = await transport.readCharacteristic(diagnosticsServiceUuid, diagnosticsCharacteristicUuid);
      if (data.length < 8) return null;

      // uptimeSeconds is the PREVIOUS session's runtime before the last reset
      // (transport.c returns app_settings_get_crash_session_uptime), NOT current
      // uptime — it stays constant until the device resets again. Logging is left to
      // the caller (device_provider), which dedupes on (cause, uptime) so this static
      // historical value isn't re-logged on every connect. Live uptime is on 0x0062.
      final log = DeviceCrashLog(
        deviceId: device.id,
        connectedAt: DateTime.now(),
        resetCause: data.getUint32LittleEndian(0),
        uptimeSeconds: data.getUint32LittleEndian(4),
      );
      return log;
    } catch (e) {
      Logger.debug('Device diagnostics not available (older firmware): $e');
      return null;
    }
  }

  @override
  Future<DeviceDropStats?> performGetDropStats() async {
    // A GATT read racing the storage notify stream drops the link (Error 133 on
    // Android), so serialize against the storage commands via the same mutex. The
    // acquire is non-blocking (tryAcquire, zero timeout): if a transfer holds the
    // lock this returns null instead of blocking or racing. That closes the
    // check-then-read gap a caller's isStorageBusy guard would otherwise leave (a
    // sync can start in the gap) and prevents two concurrent reads from overlapping.
    final acquired = await _storageMutex.tryAcquire(timeout: Duration.zero);
    if (!acquired) return null;
    try {
      final data = await transport.readCharacteristic(diagnosticsServiceUuid, diagnosticsDropsCharacteristicUuid);
      return _parseDropStats(data);
    } catch (e) {
      Logger.debug('Drop stats char not available (older firmware): $e');
      return null;
    } finally {
      _storageMutex.release();
    }
  }

  /// Parse the drop-counter payload (0x0062). Shared by the on-demand read and
  /// the notify listener. Appended fields default to 0/false on shorter payloads
  /// from older firmware (length grew 20→28→32→40→44→60→68→76→84→92 B). Returns null on a
  /// too-short read (tells us nothing) rather than a false all-zero reading.
  static DeviceDropStats? _parseDropStats(List<int> data) {
    if (data.length < 20) return null;
    return DeviceDropStats(
      blockDrops: data.getUint32LittleEndian(0),
      lastBlockDropUptimeMs: data.getUint32LittleEndian(4),
      streamFrameDrops: data.getUint32LittleEndian(8),
      bootFrameDrops: data.getUint32LittleEndian(12),
      currentUptimeMs: data.getUint32LittleEndian(16),
      // Appended fields (28-byte firmware); 0 / false on older 20-byte builds.
      failedConnCount: data.length >= 28 ? data.getUint32LittleEndian(20) : 0,
      lastFailedConnDuringSlowAdv: data.length >= 28 && data.getUint32LittleEndian(24) == 1,
      // codec_drops appended at offset 28 (32-byte firmware); 0 on older builds.
      codecFrameDrops: data.length >= 32 ? data.getUint32LittleEndian(28) : 0,
      // sd_msgq peak depth (32) + write-fairness activations (36), 40-byte firmware; 0 on older.
      msgqPeakDepth: data.length >= 36 ? data.getUint32LittleEndian(32) : 0,
      writeFairActivations: data.length >= 40 ? data.getUint32LittleEndian(36) : 0,
      // establishment failures (0x3e) appended at offset 40 (44-byte firmware); 0 on older.
      estabFailCount: data.length >= 44 ? data.getUint32LittleEndian(40) : 0,
      // Priority Recording lifecycle appended at offsets 44/48/52/56 (60-byte firmware);
      // 0 on older builds that return only the first 44 bytes.
      priorityRecordStarts: data.length >= 48 ? data.getUint32LittleEndian(44) : 0,
      priorityRecordStops: data.length >= 52 ? data.getUint32LittleEndian(48) : 0,
      markerWriteDrops: data.length >= 56 ? data.getUint32LittleEndian(52) : 0,
      emptyBinRotations: data.length >= 60 ? data.getUint32LittleEndian(56) : 0,
      // Session-end emit attempts (60) + pause-gate marker saves (64), 68-byte
      // firmware; 0 on older builds that return only the first 60 bytes.
      sessionEndMarkerEmits: data.length >= 64 ? data.getUint32LittleEndian(60) : 0,
      markerPauseGateSaves: data.length >= 68 ? data.getUint32LittleEndian(64) : 0,
      // Peak thread stack usage (sd_worker @68, codec @72), 76-byte firmware; 0 on
      // older builds that return only the first 68 bytes.
      sdWorkerStackUsed: data.length >= 72 ? data.getUint32LittleEndian(68) : 0,
      codecStackUsed: data.length >= 76 ? data.getUint32LittleEndian(72) : 0,
      // Ring SD-primitive diagnostics (offsets 76/80), 84-byte firmware; 0 on
      // older builds / LittleFS. ringMaxIoRaw packs (tag<<24)|ms.
      ringMaxIoRaw: data.length >= 80 ? data.getUint32LittleEndian(76) : 0,
      ringIoErrors: data.length >= 84 ? data.getUint32LittleEndian(80) : 0,
      // Mic liveness (84) + capture duty (88), 92-byte firmware; 0 on older builds.
      // lastMicFrameUptimeMs against currentUptimeMs says whether the mic is
      // delivering *now* — the question that otherwise has to be inferred from the
      // absence of event-log records, which is wrong whenever the mic is parked.
      lastMicFrameUptimeMs: data.length >= 88 ? data.getUint32LittleEndian(84) : 0,
      voicedMs: data.length >= 92 ? data.getUint32LittleEndian(88) : 0,
      // Derived, not a wire field: the 76-byte payload is only produced by oo-2.6.2,
      // which is the build that raised SD_REQ_QUEUE_MSGS 100→120. A shorter payload is
      // older firmware still at 100. Keeps the peak-depth denominator honest.
      sdQueueMax: data.length >= 76 ? 120 : 100,
      readAt: DateTime.now(),
    );
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetDropStatsListener({
    required void Function(DeviceDropStats stats) onDropStats,
    void Function()? onClosed,
  }) async {
    try {
      final stream =
          await transport.getCharacteristicStream(diagnosticsServiceUuid, diagnosticsDropsCharacteristicUuid);
      await _dropStatsSubscription?.cancel();
      // onDone/onError fire when the transport closes this stream — notably on a
      // BLE disconnect (the transport re-subscribes on reconnect using a *new*
      // controller this subscription isn't attached to). Surface it so the caller
      // can drop the dead subscription and re-establish one.
      _dropStatsSubscription = stream.listen(
        (v) {
          final stats = _parseDropStats(v);
          if (stats != null) onDropStats(stats);
        },
        onError: (_) => onClosed?.call(),
        onDone: () => onClosed?.call(),
      );
      return _dropStatsSubscription;
    } catch (e) {
      // Subscribing writes the CCCD; during an active transfer that GATT write
      // can race the notify stream (Error 133 on Android). Return null so the
      // caller retries — once it lands, notifications flow without any further
      // reads/writes racing the stream.
      Logger.debug('OmiDeviceConnection: Error subscribing to drop stats: $e');
      return null;
    }
  }

  @override
  Future<void> unsubscribeDropStats() async {
    await _dropStatsSubscription?.cancel();
    _dropStatsSubscription = null;
    // Write CCCD=0 so the firmware stops pushing drop-counter notifications for
    // the rest of the connection, and drop the controller so a later re-subscribe
    // re-issues a fresh CCCD write (a failed initial write leaves it silent).
    try {
      await transport.unsubscribeCharacteristic(diagnosticsServiceUuid, diagnosticsDropsCharacteristicUuid);
    } catch (_) {}
  }

  // Write the 5-byte diag-log control payload: [enable u8][ack_seq u32 LE].
  Future<void> _writeDiagLogControl({required bool enable, required int ackSeq}) async {
    final payload = <int>[
      enable ? 1 : 0,
      ackSeq & 0xFF,
      (ackSeq >> 8) & 0xFF,
      (ackSeq >> 16) & 0xFF,
      (ackSeq >> 24) & 0xFF,
    ];
    await transport.writeCharacteristic(diagnosticsServiceUuid, diagLogControlCharacteristicUuid, payload);
  }

  @override
  Future<bool> performSetDiagLogEnabled(bool enable) async {
    // Serialize against storage commands (same as the drop-stats read): a GATT
    // op racing the storage notify stream drops the link on Android. Non-blocking
    // acquire — if a transfer holds the lock, report false so the caller can surface
    // that the gate didn't reach the device (the provider also re-pushes on connect).
    final acquired = await _storageMutex.tryAcquire(timeout: Duration.zero);
    if (!acquired) return false;
    try {
      await _writeDiagLogControl(enable: enable, ackSeq: 0);
      return true;
    } catch (e) {
      Logger.debug('Diag-log enable write failed (older firmware?): $e');
      return false;
    } finally {
      _storageMutex.release();
    }
  }

  @override
  Future<DiagLogDrainResult?> performDrainDiagLog({bool keepEnabled = true}) async {
    final acquired = await _storageMutex.tryAcquire(timeout: Duration.zero);
    if (!acquired) return null;
    try {
      final all = <DiagLogRecord>[];
      int dropped = 0;
      // Bench pulls are small; this bounds a pathological loop (events arriving
      // faster than we drain, or a transport that never empties).
      const maxBatches = 64;
      for (int i = 0; i < maxBatches; i++) {
        final data = await transport.readCharacteristic(diagnosticsServiceUuid, diagLogReadCharacteristicUuid);
        final snap = DiagLogSnapshot.parse(data);
        if (snap == null) {
          // A too-short read on the FIRST batch means the char/feature is absent →
          // report unavailable (null). After records were read it's a transient end.
          if (i == 0) return null;
          break;
        }
        if (snap.recordSize != DiagLogRecord.sizeBytes) {
          Logger.warning('Diag-log record size ${snap.recordSize} != ${DiagLogRecord.sizeBytes}; stopping drain');
          break;
        }
        if (snap.droppedCount > dropped) dropped = snap.droppedCount;
        if (snap.records.isEmpty) {
          // No FULL records fit in this read. recordCount == 0 means the ring is
          // genuinely drained (done). recordCount > 0 means the ATT read was too
          // small to carry even one record past the 12-byte header — re-reading at
          // offset 0 would return the same header, so stop instead of spinning
          // (bounded by maxBatches regardless) rather than silently report success.
          // Draining that (rare) case needs a larger negotiated MTU.
          if (snap.recordCount > 0) {
            Logger.warning('Diag-log drain stalled: ${snap.recordCount} record(s) held but the ATT read '
                '(${data.length} B) is too small to return one — need a larger MTU. Stopping.');
          }
          break;
        }
        all.addAll(snap.records);
        // Ack the highest seq actually received so the device drops this batch, and
        // re-assert the CURRENT gate (keepEnabled) rather than hard-coding enable —
        // a Clear while the log is OFF must not turn on-device capture back on.
        // On a long-read transport (iOS) the whole snapshot arrives in batch 0 and
        // the next read returns zero records; on Android each read is MTU-bounded.
        await _writeDiagLogControl(enable: keepEnabled, ackSeq: snap.lastReceivedSeq);
      }
      return DiagLogDrainResult(records: all, droppedCount: dropped);
    } catch (e) {
      Logger.debug('Diag-log drain failed (older firmware?): $e');
      return null;
    } finally {
      _storageMutex.release();
    }
  }

  Future<void> stop() async {
    _listFilesGeneration++;
    final sub = _listFilesSub;
    _listFilesSub = null;
    await sub?.cancel();
    await performStopStorageSync();
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _cccdRetryTimer?.cancel();
    _cccdRetryTimer = null;
    _cachedAudioCodec = null;
  }

  @override
  Future<StorageFileStats?> performGetStorageFileStats() async {
    try {
      final data =
          await transport.readCharacteristic(storageDataStreamServiceUuid, storageReadControlCharacteristicUuid);
      if (data.length >= 8) {
        return StorageFileStats(
          totalUsedBytes: data.getUint32LittleEndian(0),
          fileCount: data.getUint32LittleEndian(4),
          freeBytes: data.length >= 12 ? data.getUint32LittleEndian(8) : 0,
          // status_flags (bytes 12-15); low byte = active backend (0=LittleFS,
          // 1=ring). null on firmware predating the field (payload < 16 bytes).
          storageBackend: data.length >= 16 ? (data.getUint32LittleEndian(12) & 0xFF) : null,
        );
      }
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error getting storage stats: $e');
    }
    return null;
  }

  @override
  Future<Stream<List<int>>> getBleStorageBytesStream() async {
    return await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
  }

  @override
  Future<int> performRetrieveBatteryLevel() async {
    try {
      final data = await transport.readCharacteristic(batteryServiceUuid, batteryLevelCharacteristicUuid);
      if (data.isNotEmpty) return data[0];
    } catch (_) {}
    return -1;
  }

  @override
  Future<bool> performRetrieveChargingState() async {
    try {
      final data = await transport.readCharacteristic(batteryDetailServiceUuid, batteryDetailCharacteristicUuid);
      if (data.isNotEmpty) return data[0] == 1;
    } catch (_) {}
    return false;
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
    void Function(bool)? onChargingStateChange,
  }) async {
    // BAS level stream
    StreamSubscription<List<int>>? levelSub;
    try {
      final levelStream = await transport.getCharacteristicStream(batteryServiceUuid, batteryLevelCharacteristicUuid);
      levelSub = levelStream.listen((v) {
        if (v.isNotEmpty && onBatteryLevelChange != null) onBatteryLevelChange(v[0]);
      });
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error subscribing to battery level: $e');
    }

    // Charging stream from custom service
    try {
      final chargingStream =
          await transport.getCharacteristicStream(batteryDetailServiceUuid, batteryDetailCharacteristicUuid);
      await _chargingSubscription?.cancel();
      _chargingSubscription = chargingStream.listen((v) {
        if (v.isNotEmpty && onChargingStateChange != null) onChargingStateChange(v[0] == 1);
      });
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error subscribing to charging state: $e');
    }

    return levelSub;
  }

  /// Parse the 9-byte mute payload: [muted:1][since_utc_s:4 LE][since_uptime_ms:4 LE].
  /// `since` is derived from the RTC seconds when valid (post-time-sync); pre-time-sync
  /// it stays null and the UI falls back to a timeless "muted" label. The uptime field
  /// is reserved for a future precise fallback.
  static ({bool muted, DateTime? since}) _parseMuteState(List<int> data) {
    if (data.length < 9) return (muted: false, since: null);
    final muted = data[0] == 1;
    final sinceUtcS = data.getUint32LittleEndian(1);
    DateTime? since;
    if (muted && sinceUtcS > 946684800) {
      since = DateTime.fromMillisecondsSinceEpoch(sinceUtcS * 1000, isUtc: true);
    }
    return (muted: muted, since: since);
  }

  @override
  Future<({bool muted, DateTime? since})?> performGetMuteState() async {
    try {
      final data = await transport.readCharacteristic(muteServiceUuid, muteCharacteristicUuid);
      // A successful-but-short read tells us nothing about mute state; surface it
      // as a failed read (null) rather than a false authoritative "unmuted".
      if (data.length < 9) return null;
      return _parseMuteState(data);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> performSetMute(bool muted) async {
    try {
      await transport.writeCharacteristic(muteServiceUuid, muteCharacteristicUuid, [muted ? 1 : 0]);
      return true;
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error writing mute: $e');
      return false;
    }
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetMuteListener({
    required void Function(bool muted, DateTime? since) onMuteChange,
  }) async {
    try {
      final stream = await transport.getCharacteristicStream(muteServiceUuid, muteCharacteristicUuid);
      await _muteSubscription?.cancel();
      _muteSubscription = stream.listen((v) {
        final s = _parseMuteState(v);
        onMuteChange(s.muted, s.since);
      });
      return _muteSubscription;
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error subscribing to mute state: $e');
      return null;
    }
  }

  @override
  Future<void> disconnect({bool isManual = true}) async {
    await _chargingSubscription?.cancel();
    _chargingSubscription = null;
    await _muteSubscription?.cancel();
    _muteSubscription = null;
    // Do NOT cancel the drop-stats sub here: cancelling suppresses onDone, which is
    // how the diagnostics page learns the stream closed and re-subscribes. Just drop
    // our reference — super.disconnect() closes the stream, firing onDone/onClosed.
    _dropStatsSubscription = null;
    await stop();
    await super.disconnect(isManual: isManual);
  }

  @override
  Future<BleAudioCodec> performGetAudioCodec() async {
    if (_cachedAudioCodec != null) return _cachedAudioCodec!;
    try {
      final data = await transport.readCharacteristic(featuresServiceUuid, featuresCodecCharacteristicUuid);
      if (data.isNotEmpty) {
        if (data[0] == 20) return _cachedAudioCodec = BleAudioCodec.opus;
        if (data[0] == 21) return _cachedAudioCodec = BleAudioCodec.opusFS320;
      }
    } catch (_) {}
    return _cachedAudioCodec = BleAudioCodec.pcm8;
  }

  @override
  Future<List<int>> performGetStorageList() async {
    try {
      final data =
          await transport.readCharacteristic(storageDataStreamServiceUuid, storageReadControlCharacteristicUuid);
      List<int> result = [];
      for (int i = 0; i < (data.length ~/ 4); i++) {
        result.add(data.getUint32LittleEndian(i * 4));
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<bool> performWriteToStorage(int numFile, int command, int offset, {int? timestamp}) async {
    try {
      final List<int> cmd = [
        command & 0xFF,
        numFile & 0xFF,
        offset & 0xFF,
        (offset >> 8) & 0xFF,
        (offset >> 16) & 0xFF,
        (offset >> 24) & 0xFF,
      ];
      if (command == 0x11 && timestamp != null) {
        // Extended CMD_READ_FILE: [0x11][index][offset:4LE][timestamp:4LE]
        cmd.addAll([
          timestamp & 0xFF,
          (timestamp >> 8) & 0xFF,
          (timestamp >> 16) & 0xFF,
          (timestamp >> 24) & 0xFF,
        ]);
      }
      await transport.writeCharacteristic(
          storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, Uint8List.fromList(cmd));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<int> performGetFeatures() async {
    try {
      final data = await transport.readCharacteristic(featuresServiceUuid, featuresCharacteristicUuid);
      if (data.length >= 4) return data.getUint32LittleEndian(0);
    } catch (_) {}
    return 0;
  }

  @override
  Future<int?> performGetFeaturesIfIdle() async {
    // Same guard as getDropStats: a plain GATT read racing the storage notify stream
    // drops the link on Android (Error 133). Non-blocking acquire — return null (not
    // 0, which would read as "no features") when a transfer holds the lock, so the
    // caller can leave capability state unchanged and retry on the next idle connect.
    final acquired = await _storageMutex.tryAcquire(timeout: Duration.zero);
    if (!acquired) return null;
    try {
      final data = await transport.readCharacteristic(featuresServiceUuid, featuresCharacteristicUuid);
      if (data.length >= 4) return data.getUint32LittleEndian(0);
      return null;
    } catch (_) {
      return null;
    } finally {
      _storageMutex.release();
    }
  }

  @override
  Future<void> performSetLedDimRatio(int ratio) async {
    try {
      await transport.writeCharacteristic(settingsServiceUuid, settingsDimRatioCharacteristicUuid, [ratio]);
    } catch (_) {}
  }

  @override
  Future<int?> performGetLedDimRatio() async {
    try {
      final data = await transport.readCharacteristic(settingsServiceUuid, settingsDimRatioCharacteristicUuid);
      if (data.isNotEmpty) return data[0];
    } catch (_) {}
    return null;
  }

  @override
  Future<void> performSetConnectedLed(bool enabled) async {
    try {
      await transport.writeCharacteristic(ledServiceUuid, ledConnectedCharacteristicUuid, [enabled ? 1 : 0]);
    } catch (_) {}
  }

  @override
  Future<bool?> performGetConnectedLed() async {
    try {
      final data = await transport.readCharacteristic(ledServiceUuid, ledConnectedCharacteristicUuid);
      if (data.isNotEmpty) return data[0] != 0;
    } catch (_) {}
    return null;
  }

  @override
  Future<void> performSetLedBootEnabled(bool enabled) async {
    try {
      await transport.writeCharacteristic(ledServiceUuid, ledBootCharacteristicUuid, [enabled ? 1 : 0]);
    } catch (_) {}
  }

  @override
  Future<bool?> performGetLedBootEnabled() async {
    try {
      final data = await transport.readCharacteristic(ledServiceUuid, ledBootCharacteristicUuid);
      if (data.isNotEmpty) return data[0] != 0;
    } catch (_) {}
    return null;
  }

  @override
  Future<void> performSetMicGain(int gain) async {
    try {
      await transport.writeCharacteristic(settingsServiceUuid, settingsMicGainCharacteristicUuid, [gain]);
    } catch (_) {}
  }

  @override
  Future<int?> performGetMicGain() async {
    try {
      final data = await transport.readCharacteristic(settingsServiceUuid, settingsMicGainCharacteristicUuid);
      if (data.isNotEmpty) return data[0];
    } catch (_) {}
    return null;
  }

  @override
  Future<List<int>?> performGetButtonConfig() async {
    try {
      final data = await transport.readCharacteristic(settingsServiceUuid, buttonConfigCharacteristicUuid);
      if (data.length == 6) return data;
    } catch (_) {}
    return null;
  }

  @override
  Future<void> performSetButtonConfig(List<int> config) async {
    try {
      await transport.writeCharacteristic(settingsServiceUuid, buttonConfigCharacteristicUuid, config);
    } catch (_) {}
  }

  @override
  Future<List<int>?> performGetHapticConfig() async {
    try {
      final data = await transport.readCharacteristic(settingsServiceUuid, hapticConfigCharacteristicUuid);
      if (data.length == 6) return data;
    } catch (_) {}
    return null;
  }

  @override
  Future<void> performSetHapticConfig(List<int> config) async {
    try {
      await transport.writeCharacteristic(settingsServiceUuid, hapticConfigCharacteristicUuid, config);
    } catch (_) {}
  }

  @override
  Future<void> performSetVadThreshold(int threshold) async {
    try {
      // 16-bit threshold LE
      final data = [threshold & 0xFF, (threshold >> 8) & 0xFF];
      await transport.writeCharacteristic(settingsServiceUuid, settingsVadThresholdCharacteristicUuid, data);
    } catch (_) {}
  }

  @override
  Future<int?> performGetVadThreshold() async {
    try {
      final data = await transport.readCharacteristic(settingsServiceUuid, settingsVadThresholdCharacteristicUuid);
      if (data.length >= 2) {
        return data[0] + (data[1] << 8);
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> performSetPriorityRecordCap(int minutes) async {
    try {
      // u16 minutes LE (0 = no cap)
      final data = [minutes & 0xFF, (minutes >> 8) & 0xFF];
      await transport.writeCharacteristic(settingsServiceUuid, settingsPriorityRecordCapCharacteristicUuid, data);
    } catch (_) {}
  }

  @override
  Future<int?> performGetPriorityRecordCap() async {
    try {
      final data = await transport.readCharacteristic(settingsServiceUuid, settingsPriorityRecordCapCharacteristicUuid);
      if (data.length >= 2) {
        return data[0] + (data[1] << 8);
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<BtDevice> performGetDeviceInfo(DeviceConnection? connection) async {
    try {
      String? model, fw, hw, manuf, sn;
      try {
        model =
            String.fromCharCodes(await transport.readCharacteristic(disServiceUuid, disModelNumberCharacteristicUuid));
      } catch (_) {}
      try {
        fw = String.fromCharCodes(
            await transport.readCharacteristic(disServiceUuid, disFirmwareRevisionCharacteristicUuid));
      } catch (_) {}
      try {
        hw = String.fromCharCodes(
            await transport.readCharacteristic(disServiceUuid, disHardwareRevisionCharacteristicUuid));
      } catch (_) {}
      try {
        manuf = String.fromCharCodes(
            await transport.readCharacteristic(disServiceUuid, disManufacturerNameCharacteristicUuid));
      } catch (_) {}
      try {
        sn =
            String.fromCharCodes(await transport.readCharacteristic(disServiceUuid, disSerialNumberCharacteristicUuid));
      } catch (_) {}
      return device.copyWith(
          modelNumber: model, firmwareRevision: fw, hardwareRevision: hw, manufacturerName: manuf, serialNumber: sn);
    } catch (_) {
      return device;
    }
  }

  @override
  Future<List<StorageFile>> performListFiles() async {
    return await _performListFilesLocked();
  }

  Future<List<StorageFile>> _performListFilesLocked() async {
    await _listFilesSub?.cancel();
    _listFilesSub = null;
    final int gen = ++_listFilesGeneration;
    final currentCompleter = Completer<List<StorageFile>>();
    final buffer = <int>[];
    bool isStale() => gen != _listFilesGeneration;

    void fail(String reason) {
      if (!currentCompleter.isCompleted) currentCompleter.completeError(TimeoutException(reason));
      unawaited(stop());
    }

    void success(List<StorageFile> files) {
      _cccdRetryTimer?.cancel();
      _timeoutTimer?.cancel();
      _listFilesGeneration++;
      final sub = _listFilesSub;
      _listFilesSub = null;
      unawaited(sub?.cancel());
      if (!currentCompleter.isCompleted) currentCompleter.complete(files);
    }

    try {
      final stream =
          await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
      int? expectedTotalBytes;

      _listFilesSub = stream.listen((blePacket) {
        if (isStale() || blePacket.isEmpty) return;

        // PACKET_ACK (0x03) is just an acknowledgement that the command was received.
        // The actual data follows in PACKET_DATA (0x01) packets.
        if (blePacket[0] == 0x03) {
          if (blePacket.length >= 2 && blePacket[1] == 9) {
            Logger.warning('OmiDeviceConnection: CMD_LIST_FILES returned STORAGE_NOT_READY');
            fail('STORAGE_NOT_READY');
          } else {
            Logger.debug('OmiDeviceConnection: CMD_LIST_FILES ACK received');
          }
          return;
        }

        // PACKET_EOT (0x02) marks the end of the file list transfer.
        if (blePacket[0] == 0x02) {
          Logger.debug('OmiDeviceConnection: CMD_LIST_FILES EOT received');
          if (expectedTotalBytes == null || buffer.length < expectedTotalBytes!) {
            // If we got EOT but haven't received all expected bytes (or any bytes),
            // complete with what we have if it's a valid list.
            if (buffer.length >= 4) {
              // We have at least the count, so we can try parsing.
              _parseAndSuccess(buffer, success);
            } else {
              success([]); // Empty list or malformed
            }
          }
          return;
        }

        // For every packet, we expect the PACKET_DATA (0x01) header
        if (blePacket[0] != 0x01) {
          fail("Unexpected packet type: 0x${blePacket[0].toRadixString(16)}");
          return;
        }

        // Add the payload (skipping 0x01 header) to our accumulation buffer
        buffer.addAll(blePacket.sublist(1));

        // Once we have the first 4 bytes of data, we know the total count
        if (expectedTotalBytes == null && buffer.length >= 4) {
          final count = buffer.getUint32LittleEndian(0);
          if (count == 0) {
            // Firmware sends [0x01][0,0,0,0] followed by [0x02] for empty list.
            expectedTotalBytes = 4;
          } else if (count > 2000) {
            fail("Invalid file count: $count");
            return;
          } else {
            // Entry format: [index:4][timestamp:4][size:4][sessionId:4] = 16 bytes
            expectedTotalBytes = 4 + (count * 16);
            Logger.debug('OmiDeviceConnection: Expecting $count files ($expectedTotalBytes bytes total)');
          }
        }

        // Keep accumulating until we reach the expected size
        if (expectedTotalBytes != null && buffer.length >= expectedTotalBytes!) {
          _parseAndSuccess(buffer, success);
        }
      });

      await Future.delayed(_cccdSettleDelay);
      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x10]);
      // 20s, not 120s: listFiles runs while holding the shared _storageMutex, so a
      // non-responsive listing pins the lock — starving syncAll (which skips when the
      // lock is busy) and refreshStorageStats (10s acquire timeout) for the whole
      // window. A healthy listing answers in seconds; 20s stays well clear of a slow
      // stack while capping the starvation, and sits under the 60s pipeline watchdog.
      _timeoutTimer = Timer(const Duration(seconds: 20), () => fail("Timeout"));
      _cccdRetryTimer = Timer(const Duration(seconds: 10), () async {
        if (isStale() || currentCompleter.isCompleted) return;
        try {
          await transport
              .writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x10]);
        } catch (_) {}
      });
      return await currentCompleter.future;
    } catch (e) {
      return [];
    }
  }

  @override
  Future<bool> performDeleteFile(StorageFile file, {int? timestamp}) async {
    try {
      final completer = Completer<bool>();
      final stream =
          await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
      final sub = stream.listen((data) {
        if (completer.isCompleted) return;
        if (data.isNotEmpty && data[0] == 0x03) completer.complete(data.length < 2 || data[1] == 0);
      });
      await Future.delayed(_cccdCommandDelay);

      final List<int> cmd = [0x12, file.index & 0xFF];
      if (timestamp != null) {
        cmd.addAll([
          timestamp & 0xFF,
          (timestamp >> 8) & 0xFF,
          (timestamp >> 16) & 0xFF,
          (timestamp >> 24) & 0xFF,
        ]);
      }

      await transport.writeCharacteristic(
          storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, Uint8List.fromList(cmd));
      try {
        return await completer.future.timeout(const Duration(seconds: 35));
      } finally {
        await sub.cancel();
      }
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> performSendKeepAlive() async {
    try {
      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x32]);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> sendUnpairCommand() async {
    try {
      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x15]);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> sendRebootCommand() async {
    try {
      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x16]);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> sendShutdownCommand() async {
    try {
      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x17]);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> performStopStorageSync() async {
    try {
      final completer = Completer<bool>();
      final stream =
          await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
      final sub = stream.listen((data) {
        if (!completer.isCompleted && data.isNotEmpty && data[0] == 0x03) {
          completer.complete(data.length < 2 || data[1] == 0);
        }
      });

      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x03]);
      try {
        return await completer.future.timeout(const Duration(seconds: 5));
      } finally {
        await sub.cancel();
      }
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> performRotateFile() async {
    try {
      final completer = Completer<bool>();
      final stream =
          await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
      final sub = stream.listen((data) {
        if (!completer.isCompleted && data.length >= 2 && data[0] == 0x03) completer.complete(data[1] == 0);
      });
      await Future.delayed(_cccdCommandDelay);
      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x13]);
      try {
        return await completer.future.timeout(const Duration(seconds: 25));
      } finally {
        await sub.cancel();
      }
    } catch (e, stack) {
      Logger.error('performRotateFile error: $e\n$stack');
      return false;
    }
  }

  @override
  Future<bool> performClearStorage() async {
    try {
      final completer = Completer<bool>();
      final stream =
          await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
      final sub = stream.listen((data) {
        if (!completer.isCompleted && data.isNotEmpty && data[0] == 0x03) {
          completer.complete(data.length < 2 || data[1] == 0);
        }
      });
      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x14]);
      try {
        return await completer.future.timeout(const Duration(seconds: 65));
      } finally {
        await sub.cancel();
      }
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> performSyncDeviceTime() async {
    for (int i = 0; i < 3; i++) {
      try {
        int epoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final data = ByteData(4)..setUint32(0, epoch, Endian.little);
        await transport.writeCharacteristic(
            timeSyncServiceUuid, timeSyncWriteCharacteristicUuid, data.buffer.asUint8List());
        return true;
      } catch (_) {
        await Future.delayed(Duration(milliseconds: 100 * (i + 1)));
      }
    }
    return false;
  }

  void _parseAndSuccess(List<int> buffer, void Function(List<StorageFile>) success) {
    final count = buffer.getUint32LittleEndian(0);
    final files = <StorageFile>[];
    final totalExpected = 4 + (count * 16);

    // Guard against partial data if called from EOT branch
    final actualBuffer = buffer.length > totalExpected ? buffer.sublist(0, totalExpected) : buffer;

    for (int i = 0; i < count && (4 + (i + 1) * 16) <= actualBuffer.length; i++) {
      files.add(StorageFile(
        index: actualBuffer.getUint32LittleEndian(4 + i * 16),
        timestamp: actualBuffer.getUint32LittleEndian(8 + i * 16),
        size: actualBuffer.getUint32LittleEndian(12 + i * 16),
        sessionId: actualBuffer.getUint32LittleEndian(16 + i * 16),
      ));
    }

    for (int i = 0; i < files.length; i++) {
      Logger.debug(
          'OmiDeviceConnection: file[$i] index=${files[i].index} ts=${files[i].timestamp} size=${files[i].size} sid=${files[i].sessionId}');
    }
    Logger.debug('OmiDeviceConnection: Successfully parsed ${files.length} files (count field said $count)');
    success(files);
  }
}
