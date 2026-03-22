import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:omi/utils/logger.dart';

import 'package:path_provider/path_provider.dart';

import 'package:disk_space_2/disk_space_2.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/transports/tcp_transport.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/services/wals/wal_interfaces.dart';

/// Thrown when the framed BLE protocol detects a gap in the offset sequence.
/// Caught by [SDCardWalSyncImpl.syncWal] for inline retry before surfacing
/// as a hard failure.
class _ProtocolGapException implements Exception {
  final int incoming;
  final int expected;
  const _ProtocolGapException(this.incoming, this.expected);
  @override
  String toString() => 'Protocol gap: incoming=$incoming expected=$expected';
}

class SDCardWalSyncImpl implements SDCardWalSync {
  List<Wal> _wals = <Wal>[];
  BtDevice? _device;

  /// Optional override for obtaining a [DeviceConnection] in tests.
  /// When null, falls back to [ServiceManager.instance().device.ensureConnection].
  final Future<DeviceConnection?> Function(String deviceId)? _connectionProvider;

  StreamSubscription? _storageStream;

  IWalSyncListener listener;

  bool _isCancelled = false;
  bool _cancelPending = false;
  bool _isSyncing = false;
  int _cancelGeneration = 0;
  bool _isDeviceRecordingFailed = false;
  bool _intentionalWipe = false;
  int _lastSegmentBoundaryOffset = 0;
  TcpTransport? _activeTcpTransport;
  Completer<void>? _activeTransferCompleter;
  Completer<void>? _cancelCompleter;
  IWalSyncProgressListener? _globalProgressListener;
  @override
  bool get isSyncing => _isSyncing;
  @override
  Future<void>? get cancelFuture => _cancelCompleter?.future;
  @override
  void setGlobalProgressListener(IWalSyncProgressListener? listener) {
    _globalProgressListener = listener;
  }

  @override
  bool get isDeviceRecordingFailed => _isDeviceRecordingFailed;

  int _totalBytesDownloaded = 0;
  DateTime? _downloadStartTime;
  double _currentSpeedKBps = 0.0;
  @override
  double get currentSpeedKBps => _currentSpeedKBps;

  final Set<int> _sessionsSeen = {};
  @override
  int get recordingsCount => _sessionsSeen.length;

  @override
  int get estimatedTotalSegments {
    int total = 0;
    final pending = <String>[];
    for (var wal in _wals) {
      if (wal.status == WalStatus.miss && wal.storage == WalStorage.sdcard) {
        total += wal.estimatedSegments;
        pending.add('  wal[${wal.id}] estimatedSegments=${wal.estimatedSegments} '
            'totalBytes=${wal.storageTotalBytes} walOffset=${wal.walOffset}');
      }
    }
    Logger.debug(
        'SDCardWalSync: estimatedTotalSegments=$total from ${pending.length} pending WALs:\n${pending.join('\n')}');
    return total;
  }

  SDCardWalSyncImpl(this.listener, {Future<DeviceConnection?> Function(String deviceId)? connectionProvider})
      : _connectionProvider = connectionProvider;
  @override
  void cancelSync() {
    if (_isSyncing) {
      _cancelCompleter ??= Completer<void>();
      _cancelPending = true;
      Logger.debug("SDCardWalSync: Cancel requested — will stop at next segment boundary");

      // TCP has no segment granularity — disconnect immediately.
      final tcpTransport = _activeTcpTransport;
      if (tcpTransport != null) {
        _isCancelled = true;
        tcpTransport.disconnect();
        final transferCompleter = _activeTransferCompleter;
        if (transferCompleter != null && !transferCompleter.isCompleted) {
          transferCompleter.completeError(Exception('Sync cancelled by user'));
        }
      }

      // Hard-cancel fallback: if no segment boundary arrives within 10 seconds
      // (e.g. connection dropped while waiting), abort immediately.
      // Capture the generation so a stale timer from a previous cancel cannot
      // fire against a new sync's completer.
      final int generation = ++_cancelGeneration;
      Future.delayed(const Duration(seconds: 10), () {
        if (_cancelPending && !_isCancelled && _cancelGeneration == generation) {
          Logger.debug("SDCardWalSync: Hard cancel — no segment boundary in 10s");
          _isCancelled = true;
          final transferCompleter = _activeTransferCompleter;
          if (transferCompleter != null && !transferCompleter.isCompleted) {
            transferCompleter.completeError(Exception('Sync cancelled by user'));
          }
        }
      });
    }
  }

  @override
  void start() {
    getMissingWals().then((wals) {
      if (!_isSyncing) {
        _wals = wals;
        listener.onWalUpdated();
      } else {
        Logger.debug(
            "SDCardWalSync: start() finished while syncing, ignoring overwrite of _wals to avoid race condition.");
      }
    });
  }

  @override
  Future stop() async {
    _wals = [];
    await _storageStream?.cancel();
  }

  @override
  Future<void> setDevice(BtDevice? device) async {
    _device = device;
    if (_device != null) {
      _wals = await getMissingWals();
      listener.onWalUpdated();
    }
  }

  @override
  Future<List<Wal>> getMissingWals() async {
    final dev = _device;
    if (dev == null) {
      return [];
    }
    String deviceId = dev.id;
    List<Wal> wals = [];
    var storageFiles = await _getStorageList(deviceId);
    Logger.debug("SDCardWalSync: _getStorageList returned $storageFiles");
    if (storageFiles.isEmpty) {
      return [];
    }
    var totalBytes = storageFiles[0];
    var walOffset = storageFiles.length >= 2 ? storageFiles[1] : 0;

    if (walOffset > totalBytes) {
      Logger.debug("SDCard bad state, walOffset $walOffset > total $totalBytes");
      // totalBytes=0 with a stale offset means the firmware's SD worker failed to
      // reopen the data file after a DELETE — recording has stopped on the device.
      // Suppress the alert if the wipe was intentional (user triggered delete/wipe).
      final failed = totalBytes == 0 && walOffset > 0;
      if (_intentionalWipe) {
        _intentionalWipe = false;
        _isDeviceRecordingFailed = false;
        Logger.debug("SDCard: suppressing recording-failed alert after intentional wipe");
      } else if (failed != _isDeviceRecordingFailed) {
        _isDeviceRecordingFailed = failed;
        if (failed) listener.onDeviceRecordingFailed();
      }
      walOffset = 0;
    } else if (_isDeviceRecordingFailed) {
      _isDeviceRecordingFailed = false;
      _intentionalWipe = false;
    }

    BleAudioCodec codec = await _getAudioCodec(deviceId);
    int threshold = codec.getStorageBytesPerMinute();
    final int newBytes = totalBytes - walOffset;
    Logger.debug(
        "SDCardWalSync: totalBytes=$totalBytes, walOffset=$walOffset, diff=$newBytes, threshold=$threshold");

    if (totalBytes > 0 && newBytes >= threshold) {
      var seconds = (newBytes / (codec.getStorageBytesPerMinute() / 60.0)).truncate();
      int timerStart = DateTime.now().millisecondsSinceEpoch ~/ 1000 - seconds;

      // Ensure stable ID for existing entries by matching device and fileNum
      final existingWal =
          _wals.firstWhereOrNull((w) => w.device == deviceId && w.fileNum == 1 && w.storage == WalStorage.sdcard);
      if (existingWal != null) {
        timerStart = existingWal.timerStart;
      }

      // Preserve in-memory walOffset if it's ahead of the device-committed offset.
      // This happens after a mid-sync cancel: the device hasn't committed the new
      // position yet, but we've already written those bytes and set walOffset further.
      final effectiveWalOffset =
          (existingWal != null && existingWal.walOffset > walOffset && existingWal.walOffset <= totalBytes)
              ? existingWal.walOffset
              : walOffset;

      var wal = Wal(
        codec: codec,
        channel: 1,
        device: deviceId,
        fileNum: 1,
        walOffset: effectiveWalOffset,
        storageTotalBytes: totalBytes,
        timerStart: timerStart,
        storage: WalStorage.sdcard,
        estimatedSegments: (seconds / 60).ceil(),
      );
      // Keep status if already syncing
      if (existingWal != null && existingWal.isSyncing) {
        wal.isSyncing = true;
        wal.syncStartedAt = existingWal.syncStartedAt;
      }

      Logger.debug('SDCardWalSync: getMissingWals → WAL created: '
          'seconds=$seconds estimatedSegments=${wal.estimatedSegments} '
          'totalBytes=$totalBytes walOffset=$walOffset newBytes=$newBytes');
      wals.add(wal);
    } else {
      Logger.debug('SDCardWalSync: getMissingWals → skipped (newBytes=$newBytes < threshold=$threshold '
          'OR totalBytes=0). totalBytes=$totalBytes walOffset=$walOffset');
    }

    Logger.debug('SDCardWalSync: getMissingWals → returning ${wals.length} WAL(s)');
    return wals;
  }

  /// Same as [getMissingWals] but ignores the 60-second threshold.
  /// Used by [syncAll] with `force: true` so an explicit "Sync All" always works
  /// even when the device has less than 60 seconds of audio buffered.
  Future<List<Wal>> _getMissingWalsIgnoringThreshold() async {
    final dev = _device;
    if (dev == null) return [];
    String deviceId = dev.id;
    List<Wal> wals = [];
    var storageFiles = await _getStorageList(deviceId);
    if (storageFiles.isEmpty) return [];
    var totalBytes = storageFiles[0];
    var walOffset = storageFiles.length >= 2 ? storageFiles[1] : 0;
    if (walOffset > totalBytes) walOffset = 0;
    BleAudioCodec codec = await _getAudioCodec(deviceId);
    if (totalBytes > 0) {
      var seconds = ((totalBytes - walOffset) / (codec.getStorageBytesPerMinute() / 60.0)).truncate();
      int timerStart = DateTime.now().millisecondsSinceEpoch ~/ 1000 - seconds;
      final existingWal =
          _wals.firstWhereOrNull((w) => w.device == deviceId && w.fileNum == 1 && w.storage == WalStorage.sdcard);
      if (existingWal != null) timerStart = existingWal.timerStart;
      final effectiveWalOffset =
          (existingWal != null && existingWal.walOffset > walOffset && existingWal.walOffset <= totalBytes)
              ? existingWal.walOffset
              : walOffset;
      wals.add(Wal(
        codec: codec,
        channel: 1,
        device: deviceId,
        fileNum: 1,
        walOffset: effectiveWalOffset,
        storageTotalBytes: totalBytes,
        timerStart: timerStart,
        storage: WalStorage.sdcard,
        estimatedSegments: (seconds / 60).ceil(),
      ));
    }
    return wals;
  }

  Future<BleAudioCodec> _getAudioCodec(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return BleAudioCodec.pcm8;
    return await connection.getAudioCodec();
  }

  Future<List<int>> _getStorageList(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return [];
    return await connection.getStorageList();
  }

  Future<bool> _writeToStorage(String deviceId, int numFile, int command, int offset) async {
    var connection = _connectionProvider != null
        ? await _connectionProvider!(deviceId)
        : await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return false;
    return await connection.writeToStorage(numFile, command, offset);
  }

  @override
  Future deleteWal(Wal wal) async {
    final dev = _device;
    if (dev == null) return;
    Logger.debug("SDCardWalSync: Sending DELETE command (1) for fileNum ${wal.fileNum} to device ${dev.id}");
    await _writeToStorage(dev.id, wal.fileNum, 1, 0); // 1 is DELETE command
    _wals = _wals.where((w) => w.id != wal.id).toList();
    listener.onWalUpdated();
  }

  Future<File> _flushToDisk(Wal wal, List<List<int>> frames, int timerStart,
      {String? subFolder, int? deviceSessionId, int? segmentIndex, bool append = false}) async {
    final directory = await getApplicationDocumentsDirectory();
    final folderPath = deviceSessionId != null
        ? '${directory.path}/raw_segments/$deviceSessionId'
        : '${directory.path}/raw_segments/$subFolder';

    final folder = Directory(folderPath);
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }

    String fileName;
    if (deviceSessionId != null && segmentIndex != null) {
      fileName = '${deviceSessionId}_$segmentIndex.bin';
    } else {
      fileName = wal.getSegmentFileNameByTimestamp(timerStart);
    }
    String filePath = '${folder.path}/$fileName';

    final builder = BytesBuilder(copy: false);
    for (var frame in frames) {
      final len = frame.length;
      builder.addByte(len & 0xFF);
      builder.addByte((len >> 8) & 0xFF);
      builder.addByte((len >> 16) & 0xFF);
      builder.addByte((len >> 24) & 0xFF);
      builder.add(frame);
    }

    final data = builder.takeBytes();
    final file = File(filePath);
    await file.writeAsBytes(data, mode: append ? FileMode.append : FileMode.write);

    Logger.debug("SDCardWalSync _flushToDisk: Wrote ${data.length} bytes to $filePath (append: $append)");

    return file;
  }

  Future<void> _saveMarker(int deviceSessionId, int utcTime) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final folderPath = '${directory.path}/raw_segments/$deviceSessionId';
      final folder = Directory(folderPath);
      if (!await folder.exists()) {
        await folder.create(recursive: true);
      }

      final markerFile = File('${folder.path}/markers.txt');
      await markerFile.writeAsString('$utcTime\n', mode: FileMode.append);
      Logger.debug("SDCardWalSync: Saved marker at $utcTime for session $deviceSessionId");
    } catch (e) {
      Logger.error("SDCardWalSync: Failed to save marker: $e");
    }
  }

  Future _readStorageBytesToFile(Wal wal, Function(File f, int offset, int timerStart, {String? subFolder}) callback,
      {bool force = false, Function(int offset)? onProgress}) async {
    var deviceId = wal.device;
    int fileNum = wal.fileNum;
    int offset = wal.walOffset;
    int timerStart = wal.timerStart;
    // Tracks the current stream position so flushBuffer can pass it to the
    // callback. Updated to match expectedOffset after each packet is processed.
    int currentStreamOffset = offset;

    Logger.debug("_readStorageBytesToFile $offset");

    var connection = _connectionProvider != null
        ? await _connectionProvider!(deviceId)
        : await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      throw Exception('Device connection lost during SD card read');
    }

    final completer = Completer<void>();
    _activeTransferCompleter = completer;
    bool hasError = false;
    bool isProcessing = false;

    DateTime lastWaitingLog = DateTime.now().subtract(const Duration(seconds: 10));

    int? currentDeviceSessionId;
    int? currentSegmentIndex;
    int? lastDeviceSessionId;
    int? lastSegmentIndex;
    final List<List<int>> frameBuffer = [];
    final List<int> streamBuffer = [];

    // Track which (deviceSessionId, segmentIndex) files have been created during this transfer.
    // The FIRST write to a file must use FileMode.write (overwrite) to avoid appending to
    // leftover data from a prior sync or force-resync. Subsequent flushes within the same
    // transfer can append.
    final Set<String> flushedSegmentsThisTransfer = {};

    // Seed the last known session/segment so frames arriving before the first metadata
    // packet go into the correct named folder instead of 'unsynced/'.
    // Only seed if walOffset > 0 (not a fresh start) and we have a stored session.
    final seededDeviceId = SharedPreferencesUtil().latestSyncedDeviceId;
    final seededSessionId = SharedPreferencesUtil().latestSyncedDeviceSessionId;
    final seededSegmentIndex = SharedPreferencesUtil().latestSyncedSegmentIndex;
    if (offset > 0 && seededDeviceId == deviceId && seededSessionId > 0 && seededSegmentIndex >= 0) {
      lastDeviceSessionId = seededSessionId;
      lastSegmentIndex = seededSegmentIndex;
      // If the file from a previous partial sync already exists, mark it as already
      // flushed so the first write uses append mode instead of overwriting it.
      final directory = await getApplicationDocumentsDirectory();
      final existingFile = File(
          '${directory.path}/raw_segments/$seededSessionId/${seededSessionId}_$seededSegmentIndex.bin');
      if (await existingFile.exists()) {
        flushedSegmentsThisTransfer.add('${seededSessionId}_$seededSegmentIndex');
        Logger.debug(
            'SDCardWalSync: Seeded session=$seededSessionId segment=$seededSegmentIndex (append — file exists)');
      } else {
        Logger.debug(
            'SDCardWalSync: Seeded session=$seededSessionId segment=$seededSegmentIndex (write — no existing file)');
      }
    }

    Future<void> flushBuffer() async {
      if (frameBuffer.isEmpty) return;

      String subFolder = lastDeviceSessionId?.toString() ?? 'unsynced';
      final segmentKey = '${lastDeviceSessionId}_$lastSegmentIndex';
      final appendMode = flushedSegmentsThisTransfer.contains(segmentKey);
      if (!appendMode) flushedSegmentsThisTransfer.add(segmentKey);

      var file = await _flushToDisk(wal, frameBuffer, timerStart,
          subFolder: subFolder,
          deviceSessionId: lastDeviceSessionId,
          segmentIndex: lastSegmentIndex,
          append: appendMode);

      try {
        await callback(file, currentStreamOffset, timerStart, subFolder: subFolder);
      } catch (e) {
        Logger.debug("SDCardWalSync: Callback failed: $e");
      }
      frameBuffer.clear();
    }

    _storageStream?.cancel();
    int packetsReceived = 0;
    int expectedOffset = offset;
    _lastSegmentBoundaryOffset = offset;
    bool hasReceivedStartAck = false;
    bool isStreamLocked = false;

    _storageStream = (await connection.getBleStorageBytesListener(onStorageBytesReceived: (List<int> value) async {
      if (_isCancelled || hasError || isStreamLocked) return;

      packetsReceived++;
      // Log only every 100 packets to reduce noise, unless it's near the end
      if (packetsReceived % 100 == 0 || expectedOffset >= wal.storageTotalBytes - 512) {
        Logger.debug(
            "SDCardWalSync: Received ${value.length} bytes (Buffer: ${streamBuffer.length}, Packet #$packetsReceived)");
      }

      if (value.isEmpty) {
        Logger.debug("SDCardWalSync: Received empty BLE packet, ignoring.");
        return;
      }

      int packetType = value[0];

      // 1. Dispatch based on Packet Type
      switch (packetType) {
        case 0x01: // PACKET_DATA: [0x01][Offset(4B)][Payload(NB)]
          if (!hasReceivedStartAck) {
            Logger.debug("SDCardWalSync: Ignoring DATA packet received before ACK.");
            return;
          }
          if (value.length < 5) {
            Logger.error("SDCardWalSync: Malformed DATA packet (length ${value.length})");
            return;
          }

          // Parse Little-Endian Offset: bytes[1] | (bytes[2] << 8) | (bytes[3] << 16) | (bytes[4] << 24)
          int incomingOffset = value[1] | (value[2] << 8) | (value[3] << 16) | (value[4] << 24);
          List<int> payload = value.sublist(5);

          if (incomingOffset < expectedOffset) {
            final packetEnd = incomingOffset + payload.length;
            if (packetEnd <= expectedOffset) {
              // Fully duplicate — all bytes already received, discard.
              Logger.debug(
                  "SDCardWalSync: Discarding fully duplicate packet (incoming $incomingOffset..$packetEnd <= expected $expectedOffset)");
              return;
            }
            // Partial overlap — firmware re-sent bytes we already have due to alignment.
            // Trim the leading duplicate bytes and keep only the new tail.
            final trimBytes = expectedOffset - incomingOffset;
            Logger.debug(
                "SDCardWalSync: Partial overlap — trimming $trimBytes leading bytes (incoming $incomingOffset, expected $expectedOffset)");
            payload = payload.sublist(trimBytes);
            incomingOffset = expectedOffset;
          } else if (incomingOffset > expectedOffset) {
            // Gap detected: Critical Error, Abort
            Logger.error(
                "SDCardWalSync: Gap detected in stream (incoming $incomingOffset > expected $expectedOffset). Aborting.");
            isStreamLocked = true;
            hasError = true;
            if (!completer.isCompleted) {
              completer.completeError(_ProtocolGapException(incomingOffset, expectedOffset));
            }
            return;
          }

          // Exact match: Process payload
          streamBuffer.addAll(payload);
          expectedOffset += payload.length;
          currentStreamOffset = expectedOffset;

          // Report progress based on file offset
          if (onProgress != null) {
            onProgress(expectedOffset);
          }
          break;

        case 0x02: // PACKET_EOT: [0x02]
          Logger.debug("SDCardWalSync: Received EOT marker. offset=$expectedOffset, bufferLen=${streamBuffer.length}");
          isStreamLocked = true;
          await flushBuffer();
          if (!completer.isCompleted) completer.complete();
          streamBuffer.clear();
          return;

        case 0x03: // PACKET_ACK: [0x03][Result(1B)]
          if (value.length < 2) {
            Logger.error("SDCardWalSync: Malformed ACK packet");
            return;
          }
          int result = value[1];
          if (result == 0x00) {
            Logger.debug("SDCardWalSync: Received start ACK(OK). Beginning download.");
            hasReceivedStartAck = true;
          } else {
            Logger.error("SDCardWalSync: Received error ACK ($result). Aborting.");
            isStreamLocked = true;
            hasError = true;
            if (!completer.isCompleted) {
              completer.completeError(Exception("Firmware reported error ACK: $result"));
            }
            return;
          }
          break;

        default:
          Logger.error("SDCardWalSync: Received unknown packet type: $packetType");
          return;
      }

      // 2. Serial processing loop for the streamBuffer (raw WAL data)
      if (isProcessing) {
        return;
      }
      isProcessing = true;

      try {
        while (streamBuffer.isNotEmpty) {
          int packageSize = streamBuffer[0];

          // Legacy markers (0xFD, 0xFF, 0xFE) are now embedded in the WAL payload
          // if they appeared there, but the firmware refactoring ensures
          // they only appear as payloads of PACKET_DATA.

          if (packageSize == 255) {
            // Metadata
            if (1 + 16 <= streamBuffer.length) {
              var metadata = streamBuffer.sublist(1, 1 + 16);
              var byteData = ByteData.sublistView(Uint8List.fromList(metadata));
              var utcTime = byteData.getUint32(0, Endian.little);
              var currentUptimeMs = byteData.getUint32(4, Endian.little);
              currentDeviceSessionId = byteData.getUint32(8, Endian.little);
              if (currentDeviceSessionId != null) {
                _sessionsSeen.add(currentDeviceSessionId!);
              }
              currentSegmentIndex = byteData.getUint32(12, Endian.little);

              if (currentDeviceSessionId != null) {
                // 946684800 = Jan 1 2000 00:00:00 UTC — reject stale/unsynced Omi clocks.
                const kMinValidEpoch = 946684800;
                if (utcTime > kMinValidEpoch) {
                  final existingUtc = SharedPreferencesUtil()
                      .getInt('anchor_utc_device_session_$currentDeviceSessionId', defaultValue: 0);
                  // Only overwrite if new utcTime is significantly more recent (meaning Omi was re-synced).
                  if (utcTime > existingUtc + 60) {
                    SharedPreferencesUtil()
                        .saveInt('anchor_utc_device_session_$currentDeviceSessionId', utcTime);
                    SharedPreferencesUtil()
                        .saveInt('anchor_uptime_device_session_$currentDeviceSessionId', currentUptimeMs);
                  }
                }

                // Per-segment anchors (keep these as precise markers for local calculation).
                // Only store if utcTime is valid — stale per-segment anchors poison back-calculation.
                if (currentSegmentIndex != null && utcTime > 946684800) {
                  SharedPreferencesUtil().saveInt(
                      'anchor_utc_device_session_${currentDeviceSessionId}_$currentSegmentIndex', utcTime);
                  SharedPreferencesUtil().saveInt(
                      'anchor_uptime_device_session_${currentDeviceSessionId}_$currentSegmentIndex', currentUptimeMs);
                }
              }

              final deviceSessionId = currentDeviceSessionId;
              final segmentIndex = currentSegmentIndex;
              if (deviceSessionId != null && segmentIndex != null) {
                final storedDeviceId = SharedPreferencesUtil().latestSyncedDeviceId;
                final storedSessionId = SharedPreferencesUtil().latestSyncedDeviceSessionId;
                final storedSegmentIndex = SharedPreferencesUtil().latestSyncedSegmentIndex;
                if (deviceId != storedDeviceId || deviceSessionId > storedSessionId) {
                  // Different device or new session — update all three.
                  SharedPreferencesUtil().latestSyncedDeviceId = deviceId;
                  SharedPreferencesUtil().latestSyncedDeviceSessionId = deviceSessionId;
                  SharedPreferencesUtil().latestSyncedSegmentIndex = segmentIndex;
                } else if (deviceSessionId == storedSessionId && segmentIndex > storedSegmentIndex) {
                  SharedPreferencesUtil().latestSyncedSegmentIndex = segmentIndex;
                }
              }

              Logger.debug("SDCardWalSync BLE: Parsed metadata session $currentDeviceSessionId");

              if (currentDeviceSessionId != lastDeviceSessionId || currentSegmentIndex != lastSegmentIndex) {
                await flushBuffer();
                lastDeviceSessionId = currentDeviceSessionId;
                lastSegmentIndex = currentSegmentIndex;
                _lastSegmentBoundaryOffset = expectedOffset - streamBuffer.length;

                if (_cancelPending) {
                  // Segment is fully written. Rewind walOffset to the start of this
                  // metadata packet so the next sync resumes at a clean record boundary.
                  wal.walOffset = expectedOffset - streamBuffer.length;
                  Logger.debug(
                      'SDCardWalSync: Cancel — stopped at segment boundary, walOffset → ${wal.walOffset}');
                  isStreamLocked = true;
                  if (!completer.isCompleted) {
                    completer.completeError(Exception('Sync cancelled by user'));
                  }
                  return;
                }
              }

              streamBuffer.removeRange(0, 1 + 16);
              continue;
            } else {
              break; // Need more bytes for metadata
            }
          }

          if (packageSize == 254) {
            // Marker
            if (1 + 16 <= streamBuffer.length) {
              var metadata = streamBuffer.sublist(1, 1 + 16);
              var byteData = ByteData.sublistView(Uint8List.fromList(metadata));
              var utcTime = byteData.getUint32(0, Endian.little);
              var markerUptimeMs = byteData.getUint32(4, Endian.little);

              // If device has no RTC lock, utcTime will be 0. Reconstruct UTC time from
              // the uptime anchor saved when we parsed the most recent metadata packet.
              int resolvedUtcTime = utcTime;
              if (utcTime == 0 && currentDeviceSessionId != null) {
                final anchorUtc =
                    SharedPreferencesUtil().getInt('anchor_utc_device_session_$currentDeviceSessionId');
                final anchorUptime =
                    SharedPreferencesUtil().getInt('anchor_uptime_device_session_$currentDeviceSessionId');
                if (anchorUtc > 0 && anchorUptime > 0) {
                  final uptimeDeltaSeconds = (markerUptimeMs - anchorUptime) ~/ 1000;
                  resolvedUtcTime = anchorUtc + uptimeDeltaSeconds;
                  Logger.debug(
                      "SDCardWalSync: Marker UTC resolved via anchor: $resolvedUtcTime (delta ${uptimeDeltaSeconds}s)");
                } else {
                  Logger.debug(
                      "SDCardWalSync: Marker utcTime=0 and no anchor available for session $currentDeviceSessionId");
                }
              }

              final deviceSessionId = currentDeviceSessionId;
              if (deviceSessionId != null) {
                await _saveMarker(deviceSessionId, resolvedUtcTime);
              }
              streamBuffer.removeRange(0, 1 + 16);
              continue;
            } else {
              break; // Need more bytes for marker
            }
          }

          if (packageSize == 0) {
            streamBuffer.removeAt(0);
            continue;
          }

          // Regular audio data frame
          if (1 + packageSize <= streamBuffer.length) {
            var frame = streamBuffer.sublist(1, 1 + packageSize);
            streamBuffer.removeRange(0, 1 + packageSize);

            frameBuffer.add(frame);
            if (frameBuffer.length >= 100) {
              await flushBuffer();
            }
          } else {
            // Throttled logging for "Waiting for more data"
            final now = DateTime.now();
            if (now.difference(lastWaitingLog).inSeconds >= 5) {
              Logger.debug(
                  "SDCardWalSync: Waiting for more data (Frame size $packageSize, Buffer ${streamBuffer.length}, Total $expectedOffset/${wal.storageTotalBytes})");
              lastWaitingLog = now;
            }
            break;
          }

          // Yield to microtasks to prevent blocking UI/other events during high throughput
          await Future.microtask(() {});
        }
      } catch (e) {
        Logger.error('SDCard BLE Transfer Error: $e');
        hasError = true;
        if (!completer.isCompleted) completer.completeError(e);
      } finally {
        isProcessing = false;
      }
    }, onError: (e) {
      // Do NOT mark this handler async — Stream.listen() ignores the returned Future,
      // meaning any exception thrown inside an async handler is silently dropped.
      // Use .then/.catchError to safely chain the async flush.
      Logger.error('SDCard BLE Stream Error: $e');
      flushBuffer().whenComplete(() {
        hasError = true;
        if (!completer.isCompleted) completer.completeError(e);
      });
    }, onDone: () {
      if (!completer.isCompleted) {
        Logger.debug("SDCardWalSync: BLE stream closed before termination marker");
        flushBuffer().whenComplete(() {
          if (!completer.isCompleted) completer.complete();
        });
      }
    })) as StreamSubscription<List<int>>;
    final readStarted = await _writeToStorage(deviceId, fileNum, 0, offset);
    if (!readStarted) {
      throw Exception('Could not start SD card read command');
    }

    try {
      await completer.future;
    } finally {
      _storageStream?.cancel();
      _storageStream = null;
    }
  }

  void _completeCancelIfPending() {
    final c = _cancelCompleter;
    if (c != null && !c.isCompleted) c.complete();
    _cancelCompleter = null;
  }

  void _resetSyncState() {
    _isCancelled = false;
    _cancelPending = false;
    _cancelGeneration++;
    _isSyncing = false;
    _totalBytesDownloaded = 0;
    _downloadStartTime = null;
    _currentSpeedKBps = 0.0;
    _activeTcpTransport = null;
    _activeTransferCompleter = null;
    _sessionsSeen.clear();
  }

  Future<void> _checkDiskSpaceBeforeSync(int totalBytesToDownload) async {
    try {
      final double? freeSpaceMb = await DiskSpace.getFreeDiskSpace;
      if (freeSpaceMb != null) {
        // 1.1x: raw download bytes + ~5% overhead for the 4-byte length prefix added per
        // Opus frame in _flushToDisk, plus a small safety margin. The old 2.5x multiplier
        // was incorrect — we store the compressed audio, not decoded PCM.
        final double requiredMb = (totalBytesToDownload * 1.1) / (1024 * 1024);
        if (freeSpaceMb < requiredMb) {
          throw Exception(
              "Phone Storage Full: Need ${requiredMb.toStringAsFixed(1)} MB free, but only ${freeSpaceMb.toStringAsFixed(1)} MB available.");
        }
      }
    } catch (e) {
      if (e.toString().contains("Phone Storage Full")) rethrow;
      Logger.debug("SDCardWalSync: Disk space check failed (non-fatal): $e");
    }
  }

  void _updateSpeed(int bytesDownloaded) {
    _totalBytesDownloaded += bytesDownloaded;
    final downloadStartTime = _downloadStartTime;
    if (downloadStartTime != null) {
      final elapsedSeconds = DateTime.now().difference(downloadStartTime).inMilliseconds / 1000.0;
      if (elapsedSeconds > 0) {
        _currentSpeedKBps = (_totalBytesDownloaded / 1024) / elapsedSeconds;
      }
    }
  }

  @override
  Future<SyncLocalFilesResponse?> syncAll({
    IWalSyncProgressListener? progress,
    bool force = false,
  }) async {
    if (_isSyncing) {
      Logger.debug("SDCardWalSync: Sync already in progress, ignoring duplicate request");
      return null;
    }

    if (_device == null) {
      Logger.debug("SDCardWalSync: No device connected, sync aborted");
      return null;
    }

    // If our list is empty, refresh it before checking sync status.
    // force=true bypasses the 60-second threshold so an explicit "Sync All" always works.
    if (_wals.isEmpty) {
      Logger.debug("SDCardWalSync: File list empty, refreshing before sync...");
      _wals = await getMissingWals();
      if (_wals.isEmpty && force) {
        _wals = await _getMissingWalsIgnoringThreshold();
      }
    }

    // Log full WAL state at sync start so we can audit what's being synced and why.
    Logger.debug('SDCardWalSync: syncAll start — _wals total=${_wals.length} force=$force');
    for (final w in _wals) {
      Logger.debug('  WAL[${w.id}] status=${w.status} estimatedSegments=${w.estimatedSegments} '
          'totalBytes=${w.storageTotalBytes} walOffset=${w.walOffset} '
          'isSyncing=${w.isSyncing}');
    }

    // NOTE: `force` controls WAL *selection* only (include already-synced wals vs. only
    // missing ones). The firmware offset is always 0 regardless — we always re-download
    // from the beginning because that's the only safe strategy after an app reinstall or
    // new device pairing. The `force: false` default in _readStorageBytesToFile is dead code.
    var wals = _wals.where((w) => (force || w.status == WalStatus.miss) && w.storage == WalStorage.sdcard).toList();
    if (wals.isEmpty) {
      Logger.debug("SDCardWalSync: All synced!");
      return null;
    }

    _resetSyncState();
    _isSyncing = true;

    bool anyPartial = false;
    var resp = SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);

    try {
      for (var wal in wals) {
        if (_isCancelled) break;

        wal.isSyncing = true;
        wal.syncStartedAt = DateTime.now();
        listener.onWalUpdated();

        final int initialOffset = wal.walOffset;
        int lastOffset = initialOffset;
        int totalBytesToDownload = wal.storageTotalBytes - initialOffset;

        await _checkDiskSpaceBeforeSync(totalBytesToDownload);
        _downloadStartTime = DateTime.now();

        final List<File> syncedFiles = [];
        const int maxGapRetries = 3;
        int gapRetries = 0;
        try {
          while (true) {
            try {
              await _readStorageBytesToFile(
                  wal,
                  (File file, int offset, int timerStart, {String? subFolder}) async {
                    if (_isCancelled) {
                      throw Exception("Sync cancelled by user");
                    }

                    syncedFiles.add(file);
                    int bytesInSegment = offset - lastOffset;
                    _updateSpeed(bytesInSegment);
                    await _registerSingleSegment(wal, file, timerStart);
                    lastOffset = offset;
                    listener.onWalUpdated();
                  },
                  force: true,
                  onProgress: (offset) {
                    wal.walOffset = offset;
                    final remainingBytes = wal.storageTotalBytes - offset;
                    final seconds = (remainingBytes / (wal.codec.getStorageBytesPerMinute() / 60.0)).truncate();
                    wal.estimatedSegments = (seconds / 60).ceil();

                    final double progressPercent =
                        totalBytesToDownload > 0 ? (offset - initialOffset) / totalBytesToDownload : 1.0;
                    final double clamped = progressPercent.clamp(0.0, 1.0);
                    progress?.onWalSyncedProgress(clamped, speedKBps: _currentSpeedKBps);
                    _globalProgressListener?.onWalSyncedProgress(clamped, speedKBps: _currentSpeedKBps);
                  });
              break; // transfer completed successfully
            } on _ProtocolGapException catch (e) {
              gapRetries++;
              if (gapRetries > maxGapRetries) {
                Logger.error('SDCardWalSync: Gap retry limit ($maxGapRetries) exceeded. Aborting. $e');
                rethrow;
              }
              Logger.debug(
                  'SDCardWalSync: Gap detected — retry $gapRetries/$maxGapRetries from offset ${e.incoming}. $e');
              wal.walOffset = e.incoming;
              lastOffset = e.incoming;
              await Future.delayed(const Duration(milliseconds: 100));
            }
          }

          // Update estimatedSegments from exact frame count now that we have the .bin files.
          final uniqueFiles = {for (final f in syncedFiles) f.path: f}.values.toList();
          if (uniqueFiles.isNotEmpty) {
            final totalFrames = uniqueFiles.fold(0, (sum, f) => sum + _countFramesInFile(f));
            final exactSeconds = totalFrames / wal.codec.getFramesPerSecond();
            wal.estimatedSegments = (exactSeconds / 60).ceil();
            Logger.debug('SDCardWalSync: syncAll post-sync frame count: '
                'frames=$totalFrames exactSeconds=$exactSeconds estimatedSegments=${wal.estimatedSegments}');
          }

          // Small delay to allow firmware buffers to clear before sending DELETE
          await Future.delayed(const Duration(milliseconds: 500));
          if (wal.walOffset >= wal.storageTotalBytes) {
            await deleteWal(wal);
          } else {
            wal.walOffset = _lastSegmentBoundaryOffset;
            Logger.debug(
                "SDCardWalSync: Partial transfer — rewound walOffset to last segment boundary $_lastSegmentBoundaryOffset (total ${wal.storageTotalBytes} bytes)");
            anyPartial = true;
          }
          wal.status = WalStatus.synced;
          _wals.removeWhere((w) => w.id == wal.id);
          listener.onWalUpdated();
        } catch (e) {
          wal.walOffset = _lastSegmentBoundaryOffset;
          Logger.debug("SDCardWalSync: Error syncing WAL ${wal.id}: $e — rewound walOffset to $_lastSegmentBoundaryOffset");
          wal.isSyncing = false;
          wal.syncStartedAt = null;
          wal.syncEtaSeconds = null;
          wal.syncSpeedKBps = null;
          listener.onWalUpdated();
          rethrow;
        }
      }
    } finally {
      _isSyncing = false;
      _completeCancelIfPending();
    }

    return SyncLocalFilesResponse(
      newConversationIds: resp.newConversationIds,
      updatedConversationIds: resp.updatedConversationIds,
      isPartial: anyPartial,
    );
  }

  @override
  Future<SyncLocalFilesResponse?> syncWal({
    required Wal wal,
    IWalSyncProgressListener? progress,
  }) async {
    if (_isSyncing) {
      Logger.debug("SDCardWalSync: Sync already in progress, ignoring duplicate syncWal request");
      return null;
    }
    _resetSyncState();
    _isSyncing = true;
    wal.isSyncing = true;
    wal.syncStartedAt = DateTime.now();
    listener.onWalUpdated();

    var resp = SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);
    final int initialOffset = wal.walOffset;
    int lastOffset = initialOffset;
    int totalBytesToDownload = wal.storageTotalBytes - initialOffset;

    await _checkDiskSpaceBeforeSync(totalBytesToDownload);
    _downloadStartTime = DateTime.now();

    final List<File> syncedFiles = [];
    const int maxGapRetries = 3;
    int gapRetries = 0;
    try {
      while (true) {
        try {
          await _readStorageBytesToFile(
              wal,
              (File file, int offset, int timerStart, {String? subFolder}) async {
                if (_isCancelled) {
                  throw Exception("Sync cancelled by user");
                }

                syncedFiles.add(file);
                int bytesInSegment = offset - lastOffset;
                _updateSpeed(bytesInSegment);
                await _registerSingleSegment(wal, file, timerStart);
                lastOffset = offset;

                listener.onWalUpdated();
              },
              force: true,
              onProgress: (offset) {
                wal.walOffset = offset;
                final remainingBytes = wal.storageTotalBytes - offset;
                final seconds = (remainingBytes / (wal.codec.getStorageBytesPerMinute() / 60.0)).truncate();
                wal.estimatedSegments = (seconds / 60).ceil();

                final double progressPercent =
                    totalBytesToDownload > 0 ? (offset - initialOffset) / totalBytesToDownload : 1.0;
                final double clamped = progressPercent.clamp(0.0, 1.0);
                progress?.onWalSyncedProgress(clamped, speedKBps: _currentSpeedKBps);
                _globalProgressListener?.onWalSyncedProgress(clamped, speedKBps: _currentSpeedKBps);
              });
          break; // transfer completed successfully
        } on _ProtocolGapException catch (e) {
          gapRetries++;
          if (gapRetries > maxGapRetries) {
            Logger.error('SDCardWalSync: Gap retry limit ($maxGapRetries) exceeded. Aborting. $e');
            rethrow;
          }
          Logger.debug('SDCardWalSync: Gap detected — retry $gapRetries/$maxGapRetries from offset ${wal.walOffset}. $e');
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }

      // Update estimatedSegments from exact frame count now that we have the .bin files.
      final uniqueFiles = {for (final f in syncedFiles) f.path: f}.values.toList();
      if (uniqueFiles.isNotEmpty) {
        final totalFrames = uniqueFiles.fold(0, (sum, f) => sum + _countFramesInFile(f));
        final exactSeconds = totalFrames / wal.codec.getFramesPerSecond();
        wal.estimatedSegments = (exactSeconds / 60).ceil();
        Logger.debug('SDCardWalSync: syncWal post-sync frame count: '
            'frames=$totalFrames exactSeconds=$exactSeconds estimatedSegments=${wal.estimatedSegments}');
      }

      // Small delay to allow firmware buffers to clear before sending DELETE
      await Future.delayed(const Duration(milliseconds: 500));
      if (wal.walOffset >= wal.storageTotalBytes) {
        await deleteWal(wal);
      } else {
        wal.walOffset = _lastSegmentBoundaryOffset;
        Logger.debug(
            "SDCardWalSync: Partial transfer — rewound walOffset to last segment boundary $_lastSegmentBoundaryOffset (total ${wal.storageTotalBytes} bytes)");
      }
      wal.status = WalStatus.synced;
      _wals.removeWhere((w) => w.id == wal.id);
      listener.onWalUpdated();
    } catch (e) {
      wal.walOffset = _lastSegmentBoundaryOffset;
      Logger.debug("SDCardWalSync: Error syncing WAL ${wal.id}: $e — rewound walOffset to $_lastSegmentBoundaryOffset");
      wal.isSyncing = false;
      wal.syncStartedAt = null;
      listener.onWalUpdated();
      rethrow;
    } finally {
      _isSyncing = false;
      _completeCancelIfPending();
    }

    return resp;
  }

  Future<void> _registerSingleSegment(Wal wal, File file, int timerStart) async {
    // Note: We no longer queue this for automatic processing in LocalWalSync.
    // The RecordingsManager will pick up the .bin files in raw_segments/ device session folders.
  }

  /// Counts Opus frames in a .bin segment file (4-byte LE prefix per frame).
  /// Uses streaming reads to avoid loading the entire file into memory.
  /// Do not special-case len==255 — it is a valid Opus payload length.
  int _countFramesInFile(File file) {
    final raf = file.openSync();
    int frameCount = 0;
    try {
      while (true) {
        final header = raf.readSync(4);
        if (header.length < 4) break;
        final len = ByteData.sublistView(Uint8List.fromList(header)).getUint32(0, Endian.little);
        if (len == 0) continue; // null padding, 0 payload bytes
        raf.setPositionSync(raf.positionSync() + len);
        frameCount++;
      }
    } finally {
      raf.closeSync();
    }
    return frameCount;
  }

  @override
  Future<void> deleteAllSyncedWals() async {
    final syncedWals = _wals.where((w) => w.status == WalStatus.synced).toList();
    for (final wal in syncedWals) {
      await deleteWal(wal);
    }
  }

  @override
  Future<void> deleteAllPendingWals() async {
    final dev = _device;
    if (dev == null) {
      Logger.debug('SDCardWalSync: deleteAllPendingWals — no device connected, skipping');
      return;
    }
    // Always send DELETE directly to fileNum=1 regardless of _wals state.
    // The old loop over _wals was a silent no-op when _wals was empty (e.g.
    // called hours after the last sync when _wals had already been cleared).
    Logger.debug('SDCardWalSync: deleteAllPendingWals — sending DELETE for fileNum=1 to ${dev.id}');
    _intentionalWipe = true;
    await _writeToStorage(dev.id, 1, 1, 0); // cmd=1 DELETE, fileNum=1, offset=0
    _wals = _wals.where((w) => w.fileNum != 1).toList();
    listener.onWalUpdated();
  }

}
