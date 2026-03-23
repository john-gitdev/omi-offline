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
import 'package:omi/services/devices/storage_file.dart';
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
  int _lastSegmentBoundaryOffset = 0;
  Completer<void>? _activeTransferCompleter;
  Completer<void>? _cancelCompleter;
  IWalSyncProgressListener? _globalProgressListener;
  @override
  bool get isSyncing => _isSyncing;
  @override
  bool get isDeviceRecordingFailed => false;
  @override
  Future<void>? get cancelFuture => _cancelCompleter?.future;
  @override
  void setGlobalProgressListener(IWalSyncProgressListener? listener) {
    _globalProgressListener = listener;
  }

  int _totalBytesDownloaded = 0;
  DateTime? _downloadStartTime;
  double _currentSpeedKBps = 0.0;
  @override
  double get currentSpeedKBps => _currentSpeedKBps;

  @override
  int get recordingsCount => _wals.length;

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

      // Tell the firmware to stop streaming immediately so it doesn't keep
      // sending BLE packets after we cancel the Dart listener.
      final dev = _device;
      if (dev != null) {
        final connFuture = _connectionProvider != null
            ? _connectionProvider!(dev.id)
            : ServiceManager.instance().device.ensureConnection(dev.id);
        connFuture.then((conn) => conn?.stopStorageSync()).catchError((_) {});
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
    final dev = _device;
    if (dev != null) {
      final connFuture = _connectionProvider != null
          ? _connectionProvider!(dev.id)
          : ServiceManager.instance().device.ensureConnection(dev.id);
      connFuture.then((conn) => conn?.stopStorageSync()).catchError((_) {});
    }
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
    if (dev == null) return [];
    return _buildWalsFromFiles(dev.id, ignoreThreshold: false);
  }

  @override
  Future<bool> hasFilesToSync() async {
    if (_device == null) return false;
    // Fast path: WAL list already built by setDevice() — no BLE round-trip needed.
    if (_wals.isNotEmpty) return true;
    // Slow path: query device file list and apply threshold filter.
    final files = await _listFiles(_device!.id);
    if (files.isEmpty) return false;
    final codec = await _getAudioCodec(_device!.id);
    final threshold = codec.getStorageBytesPerMinute();
    return files.any((f) => f.size >= threshold);
  }

  /// Same as [getMissingWals] but ignores the 60-second threshold.
  /// Used by [syncAll] with `force: true`.
  Future<List<Wal>> _getMissingWalsIgnoringThreshold() async {
    final dev = _device;
    if (dev == null) return [];
    return _buildWalsFromFiles(dev.id, ignoreThreshold: true);
  }

  /// Calls CMD_LIST_FILES and builds WAL entries from the response.
  /// Files are already sorted oldest-first by the firmware.
  Future<List<Wal>> _buildWalsFromFiles(String deviceId, {required bool ignoreThreshold}) async {
    final files = await _listFiles(deviceId);
    Logger.debug('SDCardWalSync: listFiles returned ${files.length} files');
    if (files.isEmpty) return [];

    final codec = await _getAudioCodec(deviceId);
    final threshold = codec.getStorageBytesPerMinute();
    final wals = <Wal>[];

    for (final file in files) {
      if (file.size == 0) continue;

      // Preserve in-progress walOffset for this file if we have it in memory.
      final existing = _wals.firstWhereOrNull(
          (w) => w.device == deviceId && w.fileNum == file.index && w.storage == WalStorage.sdcard);
      final walOffset =
          (existing != null && existing.walOffset > 0 && existing.walOffset <= file.size) ? existing.walOffset : 0;

      final newBytes = file.size - walOffset;
      if (!ignoreThreshold && newBytes < threshold) {
        Logger.debug('SDCardWalSync: file[${file.index}] skipped (newBytes=$newBytes < threshold=$threshold)');
        continue;
      }

      final seconds = (newBytes / (codec.getStorageBytesPerMinute() / 60.0)).truncate();
      // Use firmware-provided UTC timestamp if valid, otherwise estimate backwards.
      const kMinValidEpoch = 946684800; // Jan 1 2000 — reject pre-sync TMP timestamps
      final timerStart = (existing != null)
          ? existing.timerStart
          : (file.timestamp > kMinValidEpoch
              ? file.timestamp
              : DateTime.now().millisecondsSinceEpoch ~/ 1000 - seconds);

      final wal = Wal(
        codec: codec,
        channel: 1,
        device: deviceId,
        fileNum: file.index,
        walOffset: walOffset,
        storageTotalBytes: file.size,
        timerStart: timerStart,
        storage: WalStorage.sdcard,
        estimatedSegments: (seconds / 60).ceil(),
      );
      if (existing != null && existing.isSyncing) {
        wal.isSyncing = true;
        wal.syncStartedAt = existing.syncStartedAt;
      }

      Logger.debug('SDCardWalSync: file[${file.index}] → WAL '
          'ts=${file.timestamp} size=${file.size} walOffset=$walOffset newBytes=$newBytes');
      wals.add(wal);
    }

    Logger.debug('SDCardWalSync: getMissingWals → ${wals.length} WAL(s)');
    return wals;
  }

  Future<BleAudioCodec> _getAudioCodec(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return BleAudioCodec.pcm8;
    return await connection.getAudioCodec();
  }

  Future<List<StorageFile>> _listFiles(String deviceId) async {
    var connection = _connectionProvider != null
        ? await _connectionProvider!(deviceId)
        : await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return [];
    return await connection.listFiles();
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
    Logger.debug("SDCardWalSync: Sending CMD_DELETE_FILE (0x12) for fileNum ${wal.fileNum} to device ${dev.id}");
    final connection = _connectionProvider != null
        ? await _connectionProvider!(dev.id)
        : await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection != null) {
      await connection.deleteFile(wal.fileNum);
    }
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

    int? lastDeviceSessionId = wal.timerStart > 0 ? wal.timerStart : null;
    int? lastSegmentIndex = 0;
    final List<List<int>> frameBuffer = [];
    final List<int> streamBuffer = [];

    // Track which (deviceSessionId, segmentIndex) files have been created during this transfer.
    // The FIRST write to a file must use FileMode.write (overwrite) to avoid appending to
    // leftover data from a prior sync or force-resync. Subsequent flushes within the same
    // transfer can append.
    final Set<String> flushedSegmentsThisTransfer = {};

    // For partial resume (walOffset > 0), the file we're continuing is always
    // {timerStart}_0.bin.  Mark it as already flushed so subsequent writes append.
    if (offset > 0 && lastDeviceSessionId != null) {
      final directory = await getApplicationDocumentsDirectory();
      final existingFile = File(
          '${directory.path}/raw_segments/$lastDeviceSessionId/${lastDeviceSessionId}_0.bin');
      if (await existingFile.exists()) {
        flushedSegmentsThisTransfer.add('${lastDeviceSessionId}_0');
        Logger.debug('SDCardWalSync: Partial resume — will append to ${lastDeviceSessionId}_0.bin');
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

          // INVARIANT: Opus frames are ≤ 80 bytes (codec 20) or ≤ 40 bytes (codec 21).
          // The firmware's raw SD format uses a 1-byte length prefix per frame.
          // If a future codec produces frames > 253 bytes, this parser MUST be updated
          // to use a multi-byte length prefix (and the firmware format must change too).
          // 254 = marker (16-byte payload). 255 is a valid Opus frame length (not reserved).
          assert(packageSize <= 254 || packageSize == 255,
              'Frame length $packageSize exceeds single-byte protocol limit');

          if (packageSize == 254) {
            // Button-press marker — 16-byte payload: utcTime (4B LE), uptimeMs (4B LE), padding (8B)
            if (1 + 16 <= streamBuffer.length) {
              var metadata = streamBuffer.sublist(1, 1 + 16);
              var byteData = ByteData.sublistView(Uint8List.fromList(metadata));
              var utcTime = byteData.getUint32(0, Endian.little);
              if (lastDeviceSessionId != null) {
                await _saveMarker(lastDeviceSessionId!, utcTime);
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
    final readStarted = await _writeToStorage(deviceId, fileNum, 0x11, offset); // CMD_READ_FILE
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
    _activeTransferCompleter = null;
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

    // Refresh the WAL list before syncing.
    // force=true always rebuilds without the 60-second threshold so short recordings are included.
    if (force) {
      Logger.debug("SDCardWalSync: Force sync — refreshing WAL list without threshold...");
      _wals = await _getMissingWalsIgnoringThreshold();
    } else if (_wals.isEmpty) {
      Logger.debug("SDCardWalSync: File list empty, refreshing before sync...");
      _wals = await getMissingWals();
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
    Logger.debug('SDCardWalSync: deleteAllPendingWals — listing all files on ${dev.id}');
    final files = await _listFiles(dev.id);
    if (files.isEmpty) {
      Logger.debug('SDCardWalSync: deleteAllPendingWals — no files found');
      _wals = [];
      listener.onWalUpdated();
      return;
    }
    final connection = _connectionProvider != null
        ? await _connectionProvider!(dev.id)
        : await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) {
      Logger.debug('SDCardWalSync: deleteAllPendingWals — no connection');
      return;
    }
    for (final file in files) {
      Logger.debug('SDCardWalSync: deleteAllPendingWals — CMD_DELETE_FILE index=${file.index}');
      await connection.deleteFile(file.index);
    }
    _wals = [];
    listener.onWalUpdated();
  }

}
