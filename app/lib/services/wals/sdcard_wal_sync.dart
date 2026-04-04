import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:omi/utils/logger.dart';

import 'package:path_provider/path_provider.dart';

import 'package:disk_space_2/disk_space_2.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/services/wals/wal_interfaces.dart';

/// Thrown when the framed BLE protocol detects a gap in the offset sequence.
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
    if (_isSyncing) {
      return _wals.where((w) => w.isSyncing || (w.status == WalStatus.miss && w.storage == WalStorage.sdcard)).length;
    }
    final pending = _wals.where((w) => w.status == WalStatus.miss && w.storage == WalStorage.sdcard).toList();
    return pending.length;
  }

  SDCardWalSyncImpl(this.listener, {Future<DeviceConnection?> Function(String deviceId)? connectionProvider})
      : _connectionProvider = connectionProvider;

  @override
  void cancelSync() {
    if (_isSyncing) {
      _cancelCompleter ??= Completer<void>();
      _cancelPending = true;
      Logger.debug("SDCardWalSync: Cancel requested — will stop at next segment boundary");

      final dev = _device;
      if (dev != null) {
        final connFuture = _connectionProvider != null
            ? _connectionProvider!(dev.id)
            : ServiceManager.instance().device.ensureConnection(dev.id);
        connFuture.then((conn) => conn?.stopStorageSync() ?? Future.value(false)).catchError((_) => false);
      }

      final int generation = ++_cancelGeneration;
      final cancelCompleterAtRequest = _cancelCompleter;
      Future.delayed(const Duration(seconds: 10), () {
        if (_cancelPending && !_isCancelled && _cancelGeneration == generation && _cancelCompleter == cancelCompleterAtRequest) {
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
      connFuture.then((conn) => conn?.stopStorageSync() ?? Future.value(false)).catchError((_) => false);
    }
    await _storageStream?.cancel();
    _storageStream = null;
    _resetSyncState();
  }

  @override
  Future<void> setDevice(BtDevice? device, {List<StorageFile>? prefetchedFiles}) async {
    _device = device;
    if (_device != null) {
      _wals = await _buildWalsFromFiles(_device!.id, ignoreThreshold: true, prefetchedFiles: prefetchedFiles);
      listener.onWalUpdated();
    }
  }

  @override
  Future<List<Wal>> getMissingWals() async {
    final dev = _device;
    if (dev == null) return [];
    // ignoreThreshold: true to ensure all files (even short tests) show up
    final wals = await _buildWalsFromFiles(dev.id, ignoreThreshold: true);
    Logger.debug('SDCardWalSync: getMissingWals returned ${wals.length} WALs');
    return wals;
  }

  @override
  Future<bool> hasFilesToSync() async {
    if (_device == null) return false;
    if (_wals.isNotEmpty) return true;
    final files = await _listFiles(_device!.id);
    return files.isNotEmpty;
  }

  Future<List<Wal>> _buildWalsFromFiles(String deviceId,
      {required bool ignoreThreshold, List<StorageFile>? prefetchedFiles}) async {
    final files = prefetchedFiles ?? await _listFiles(deviceId);
    if (files.isEmpty) return [];

    final codec = await _getAudioCodec(deviceId);
    final threshold = codec.getStorageBytesPerMinute();
    final wals = <Wal>[];

    const int kMaxStorageBytes = 0x1E000000;

    for (final file in files) {
      if (file.size == 0) continue;
      if (file.size > kMaxStorageBytes) {
        Logger.error('SDCardWalSync: file[${file.index}] has impossible size ${file.size} (> 480 MB)');
        continue;
      }

      final existing = _wals.firstWhereOrNull(
          (w) => w.device == deviceId && w.fileNum == file.index && w.storage == WalStorage.sdcard);
      final walOffset =
          (existing != null && existing.walOffset > 0 && existing.walOffset <= file.size) ? existing.walOffset : 0;

      final newBytes = file.size - walOffset;
      if (!ignoreThreshold && walOffset == 0 && newBytes < threshold) {
        continue;
      }

      final seconds = (newBytes / (codec.getStorageBytesPerMinute() / 60.0)).truncate();
      const kMinValidEpoch = 946684800;
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
        estimatedSegments: (seconds / 60).ceil().clamp(1, 999),
      );
      if (existing != null && existing.isSyncing) {
        wal.isSyncing = true;
        wal.syncStartedAt = existing.syncStartedAt;
      }
      wals.add(wal);
    }
    return wals;
  }

  Future<BleAudioCodec> _getAudioCodec(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return BleAudioCodec.pcm8;
    return await connection.getAudioCodec() ?? BleAudioCodec.pcm8;
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
    final connection = _connectionProvider != null
        ? await _connectionProvider!(dev.id)
        : await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection != null) {
      await connection.deleteFile(StorageFile(index: wal.fileNum, timestamp: 0, size: 0));
    }
    _wals.removeWhere((w) => w.id == wal.id);
    listener.onWalUpdated();
  }

  Future<(File, int)> _flushToDisk(Wal wal, List<int> rawData, int timerStart,
      {String? subFolder, int? deviceSessionId, int? segmentIndex, bool append = false}) async {
    final directory = await getApplicationDocumentsDirectory();
    final folderPath = deviceSessionId != null
        ? '${directory.path}/raw_segments/$deviceSessionId'
        : '${directory.path}/raw_segments/$subFolder';

    final folder = Directory(folderPath);
    if (!await folder.exists()) await folder.create(recursive: true);

    String fileName = (deviceSessionId != null && segmentIndex != null)
        ? '${deviceSessionId}_$segmentIndex.bin'
        : wal.getSegmentFileNameByTimestamp(timerStart);

    String filePath = '${folder.path}/$fileName';
    final file = File(filePath);
    await file.writeAsBytes(rawData, mode: append ? FileMode.append : FileMode.write);
    return (file, rawData.length);
  }

  Future<void> _saveMarker(int deviceSessionId, int utcTime) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final folderPath = '${directory.path}/raw_segments/$deviceSessionId';
      final folder = Directory(folderPath);
      if (!await folder.exists()) await folder.create(recursive: true);
      final markerFile = File('${folder.path}/markers.txt');
      await markerFile.writeAsString('$utcTime\n', mode: FileMode.append);
    } catch (_) {}
  }

  Future _readStorageBytesToFile(Wal wal, Function(File f, int offset, int timerStart, {String? subFolder}) callback,
      {Function(int offset)? onProgress}) async {
    var deviceId = wal.device;
    int fileNum = wal.fileNum;
    int offset = wal.walOffset;
    int timerStart = wal.timerStart;

    var connection = _connectionProvider != null
        ? await _connectionProvider!(deviceId)
        : await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) throw Exception('Device connection lost');

    final completer = Completer<void>();
    _activeTransferCompleter = completer;
    bool hasError = false;
    bool isProcessing = false;
    bool eotReceived = false;

    int? lastDeviceSessionId = wal.timerStart > 0 ? wal.timerStart : null;
    int? lastSegmentIndex = 0;
    final Queue<Uint8List> chunkQueue = Queue<Uint8List>();
    final BytesBuilder batchBuilder = BytesBuilder(copy: false);
    final Set<String> flushedSegmentsThisTransfer = {};
    int writtenOffset = offset;

    if (offset > 0 && lastDeviceSessionId != null) {
      final directory = await getApplicationDocumentsDirectory();
      final existingFile = File('${directory.path}/raw_segments/$lastDeviceSessionId/${lastDeviceSessionId}_0.bin');
      if (await existingFile.exists()) flushedSegmentsThisTransfer.add('${lastDeviceSessionId}_0');
    }

    Future<void> flushRawBuffer(List<int> rawData) async {
      if (rawData.isEmpty) return;
      String subFolder = lastDeviceSessionId?.toString() ?? 'unsynced';
      final segmentKey = '${lastDeviceSessionId}_$lastSegmentIndex';
      final appendMode = flushedSegmentsThisTransfer.contains(segmentKey);
      if (!appendMode) flushedSegmentsThisTransfer.add(segmentKey);

      var (file, bytesWritten) = await _flushToDisk(wal, rawData, timerStart,
          subFolder: subFolder, deviceSessionId: lastDeviceSessionId, segmentIndex: lastSegmentIndex, append: appendMode);
      writtenOffset += bytesWritten;
      _lastSegmentBoundaryOffset = writtenOffset;
      try {
        await callback(file, writtenOffset, timerStart, subFolder: subFolder);
      } catch (_) {}
    }

    _storageStream?.cancel();
    int expectedOffset = offset;
    _lastSegmentBoundaryOffset = offset;
    bool hasReceivedStartAck = false;
    bool isStreamLocked = false;
    int packetsReceived = 0;

    _storageStream = (await connection.getBleStorageBytesStream()).listen(
      (List<int> value) async {
        if (_isCancelled || hasError || isStreamLocked) return;
        packetsReceived++;
        if (packetsReceived % 500 == 0) {
          Logger.debug('SDCardWalSync: [PROGRESS] received $packetsReceived packets, offset=$expectedOffset bytes');
        }
        if (value.isEmpty) return;

        int packetType = value[0];
        switch (packetType) {
          case 0x01:
            if (!hasReceivedStartAck || value.length < 5) return;
            int incomingOffset = value[1] | (value[2] << 8) | (value[3] << 16) | (value[4] << 24);
            List<int> payload = value.sublist(5);

            if (incomingOffset < expectedOffset) {
              final packetEnd = incomingOffset + payload.length;
              if (packetEnd <= expectedOffset) return;
              payload = payload.sublist(expectedOffset - incomingOffset);
            } else if (incomingOffset > expectedOffset) {
              isStreamLocked = true;
              hasError = true;
              if (!completer.isCompleted) completer.completeError(_ProtocolGapException(incomingOffset, expectedOffset));
              return;
            }

            chunkQueue.add(Uint8List.fromList(payload));
            expectedOffset += payload.length;
            if (onProgress != null) onProgress(expectedOffset);
            break;

          case 0x02:
            isStreamLocked = true;
            eotReceived = true;
            if (!isProcessing) {
              if (chunkQueue.isNotEmpty) {
                batchBuilder.clear();
                while (chunkQueue.isNotEmpty) {
                  batchBuilder.add(chunkQueue.removeFirst());
                }
                await flushRawBuffer(batchBuilder.toBytes());
              }
              _lastSegmentBoundaryOffset = writtenOffset;
              if (!completer.isCompleted) completer.complete();
            }
            return;

          case 0x03:
            if (value.length < 2) return;
            if (value[1] == 0x00) {
              hasReceivedStartAck = true;
            } else {
              isStreamLocked = true;
              hasError = true;
              if (!completer.isCompleted) completer.completeError(Exception("Error ACK: ${value[1]}"));
              return;
            }
            break;
        }

        if (isProcessing) return;
        isProcessing = true;
        try {
          const int BATCH_SIZE = 4096;

          while (chunkQueue.isNotEmpty) {
            batchBuilder.clear();
            int batchSize = 0;

            // Build batch WITHOUT await
            while (chunkQueue.isNotEmpty && batchSize < BATCH_SIZE) {
              final chunk = chunkQueue.removeFirst();
              batchBuilder.add(chunk);
              batchSize += chunk.length;
            }

            final Uint8List batch = batchBuilder.toBytes();

            // 2. Scan for Markers (0xFE) without stripping/modifying any bytes (READ-ONLY)
            int scanOff = 0;
            while (scanOff + 4 <= batch.length) {
              final bd = ByteData.sublistView(batch, scanOff, scanOff + 4);
              int packageSize = bd.getUint32(0, Endian.little);

              if (packageSize == 0xFFFFFFFE) {
                if (scanOff + 20 <= batch.length) {
                  final metaBd = ByteData.sublistView(batch, scanOff + 4, scanOff + 20);
                  if (lastDeviceSessionId != null) {
                    await _saveMarker(lastDeviceSessionId, metaBd.getUint32(0, Endian.little));
                  }
                  scanOff += 20;
                  continue;
                } else {
                  break;
                }
              }

              if (packageSize == 0 || packageSize == 0xFFFFFFFF) {
                scanOff += 4;
              } else if (packageSize > 400) {
                scanOff += 1;
              } else {
                int padded = (packageSize + 3) & ~3;
                scanOff += (4 + padded);
              }
            }

            // ---- SAFE FLUSH ----
            await flushRawBuffer(batch);
          }
        } finally {
          isProcessing = false;
          if (eotReceived && !completer.isCompleted) {
            completer.complete();
          }
        }
      },
      onError: (e) {
        hasError = true;
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) {
          if (eotReceived) {
            completer.complete();
          } else {
            completer.completeError(Exception('Stream closed without EOT'));
          }
        }
      },
    );

    try {
      final readStarted = await _writeToStorage(deviceId, fileNum, 0x11, offset);
      if (!readStarted) throw Exception('Could not start SD card read');
      await completer.future;
    } finally {
      // Cancel the stream subscription so it doesn't receive the next operation's
      // ACK packets (e.g. DELETE ACK) and misinterpret them as a new read start-ACK.
      // Also covers the case where _writeToStorage fails before completer is awaited.
      await _storageStream?.cancel();
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
    _cancelCompleter = null;
    _activeTransferCompleter = null;
  }

  Future<void> _checkDiskSpaceBeforeSync(int totalBytesToDownload) async {
    try {
      final double? freeSpaceMb = await DiskSpace.getFreeDiskSpace;
      if (freeSpaceMb != null) {
        final double requiredMb = (totalBytesToDownload * 1.1) / (1024 * 1024);
        if (freeSpaceMb < requiredMb) throw Exception("Phone Storage Full");
      }
    } catch (_) { rethrow; }
  }

  void _updateSpeed(int bytesDownloaded) {
    _totalBytesDownloaded += bytesDownloaded;
    if (_downloadStartTime != null) {
      final elapsed = DateTime.now().difference(_downloadStartTime!).inMilliseconds / 1000.0;
      if (elapsed > 0) _currentSpeedKBps = (_totalBytesDownloaded / 1024) / elapsed;
    }
  }

  @override
  Future<SyncLocalFilesResponse?> syncAll({IWalSyncProgressListener? progress}) async {
    if (_isSyncing || _device == null) return null;

    _resetSyncState();
    _isSyncing = true;
    
    // Refresh and update atomically before UI sees anything
    final refreshed = await getMissingWals();
    _wals = refreshed;
    listener.onWalUpdated();

    final wals = _wals.where((w) => w.status == WalStatus.miss && w.storage == WalStorage.sdcard).toList();
    if (wals.isEmpty) {
      _isSyncing = false;
      return null;
    }
    final dev = _device!;
    final connection = await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) throw Exception('No connection');

    bool anyPartial = false;
    _downloadStartTime = DateTime.now();
    await connection.acquireStorageLock();
    try {
      for (int i = 0; i < wals.length; i++) {
        final wal = wals[i];
        if (_isCancelled) break;
        wal.isSyncing = true;
        wal.syncStartedAt = DateTime.now();
        listener.onWalUpdated();

        final initialOffset = wal.walOffset;
        int lastOffset = initialOffset;
        await _checkDiskSpaceBeforeSync(wal.storageTotalBytes - initialOffset);

        // Single try-catch covers both transfer (with gap retries) and delete.
        // This ensures wal.isSyncing is always cleared and anyPartial is set
        // whether the failure is a gap retry limit, a transfer error, or a
        // delete error.
        try {
          const int maxGapRetries = 3;
          int gapRetries = 0;
          bool transferred = false;
          while (!transferred) {
            try {
              Logger.debug('SDCardWalSync: Starting transfer for file[${wal.fileNum}] (attempt ${gapRetries + 1})');
              await _readStorageBytesToFile(wal, (File file, int offset, int timerStart, {String? subFolder}) async {
                if (_isCancelled) throw Exception("Cancelled");
                _updateSpeed(offset - lastOffset);
                lastOffset = offset;
                listener.onWalUpdated();
              }, onProgress: (offset) {
                wal.walOffset = offset;
                final double withinWal = (wal.storageTotalBytes > initialOffset) ? (offset - initialOffset) / (wal.storageTotalBytes - initialOffset) : 1.0;
                final double clamped = ((i + (withinWal.clamp(0.0, 1.0) * 0.9)) / wals.length).clamp(0.0, 1.0);
                progress?.onWalSyncedProgress(clamped, speedKBps: _currentSpeedKBps);
                _globalProgressListener?.onWalSyncedProgress(clamped, speedKBps: _currentSpeedKBps);
              });
              transferred = true;
            } on _ProtocolGapException catch (e) {
              gapRetries++;
              if (gapRetries > maxGapRetries) {
                Logger.error('SDCardWalSync: Gap retry limit exceeded for file[${wal.fileNum}]: $e');
                rethrow; // caught by outer catch below — sets anyPartial
              }
              Logger.debug('SDCardWalSync: Gap detected (retry $gapRetries/$maxGapRetries) — rewinding to ${e.incoming}');
              wal.walOffset = e.incoming;
              lastOffset = e.incoming;
              _lastSegmentBoundaryOffset = e.incoming;
              final conn = await ServiceManager.instance().device.ensureConnection(dev.id);
              await conn?.stopStorageSync();
              await Future.delayed(const Duration(milliseconds: 200));
            }
          }

          Logger.debug('SDCardWalSync: Transfer complete for file[${wal.fileNum}], deleting...');
          await Future.delayed(const Duration(milliseconds: 500));
          await deleteWal(wal);
          wal.status = WalStatus.synced;
          final double fileDone = ((i + 1.0) / wals.length).clamp(0.0, 1.0);
          progress?.onWalSyncedProgress(fileDone, speedKBps: _currentSpeedKBps);
          _globalProgressListener?.onWalSyncedProgress(fileDone, speedKBps: _currentSpeedKBps);
          Logger.debug('SDCardWalSync: Successfully synced and deleted file[${wal.fileNum}]');
          listener.onWalUpdated();
        } catch (e) {
          Logger.error('SDCardWalSync: Failed to sync file[${wal.fileNum}]: $e');
          wal.walOffset = _lastSegmentBoundaryOffset;
          wal.isSyncing = false;
          listener.onWalUpdated();
          if (_isCancelled) rethrow; // cancellation aborts remaining files
          anyPartial = true; // all other errors: mark partial and continue
        }
      }
    } finally {
      connection.releaseStorageLock();
      _isSyncing = false;
      _completeCancelIfPending();
    }
    return SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: [], isPartial: anyPartial);
  }

  @override
  Future<SyncLocalFilesResponse?> syncWal({required Wal wal, IWalSyncProgressListener? progress}) async {
    if (_isSyncing) return null;
    _resetSyncState();
    _isSyncing = true;
    wal.isSyncing = true;
    wal.syncStartedAt = DateTime.now();
    listener.onWalUpdated();

    final dev = _device!;
    final connection = await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) throw Exception('No connection');

    final initialOffset = wal.walOffset;
    int lastOffset = initialOffset;
    await _checkDiskSpaceBeforeSync(wal.storageTotalBytes - initialOffset);
    _downloadStartTime = DateTime.now();

    await connection.acquireStorageLock();
    try {
      await _readStorageBytesToFile(wal, (File file, int offset, int timerStart, {String? subFolder}) async {
        if (_isCancelled) throw Exception("Cancelled");
        _updateSpeed(offset - lastOffset);
        lastOffset = offset;
        listener.onWalUpdated();
      }, onProgress: (offset) {
        wal.walOffset = offset;
        final double progressPercent = (wal.storageTotalBytes > initialOffset) ? (offset - initialOffset) / (wal.storageTotalBytes - initialOffset) : 1.0;
        final double clamped = progressPercent.clamp(0.0, 1.0);
        progress?.onWalSyncedProgress(clamped, speedKBps: _currentSpeedKBps);
        _globalProgressListener?.onWalSyncedProgress(clamped, speedKBps: _currentSpeedKBps);
      });

      await Future.delayed(const Duration(milliseconds: 500));
      if (wal.walOffset >= wal.storageTotalBytes) {
        await deleteWal(wal);
      } else {
        wal.walOffset = _lastSegmentBoundaryOffset;
      }
      wal.status = WalStatus.synced;
      _wals.removeWhere((w) => w.id == wal.id);
      listener.onWalUpdated();
    } catch (e) {
      wal.walOffset = _lastSegmentBoundaryOffset;
      wal.isSyncing = false;
      listener.onWalUpdated();
      rethrow;
    } finally {
      connection.releaseStorageLock();
      _isSyncing = false;
      _completeCancelIfPending();
    }
    return SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);
  }

  @override
  Future<SyncLocalFilesResponse?> rotateAndSync({IWalSyncProgressListener? progress}) async {
    if (_isSyncing) return null;
    final dev = _device!;
    final connection = await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) throw Exception('No connection');

    final rotated = await connection.rotateFile();
    if (!rotated) throw Exception('Rotation failed');
    _wals = await _buildWalsFromFiles(dev.id, ignoreThreshold: true);
    return await syncAll(progress: progress);
  }

  @override
  Future<void> deleteAllSyncedWals() async {
    final synced = _wals.where((w) => w.status == WalStatus.synced).toList();
    for (final wal in synced) {
      await deleteWal(wal);
    }
  }

  @override
  Future<void> deleteAllPendingWals() async {
    if (_device == null) return;
    final connection = await ServiceManager.instance().device.ensureConnection(_device!.id);
    if (connection == null) return;

    Logger.debug('SDCardWalSync: deleteAllPendingWals — Sending CMD_CLEAR_STORAGE (0x14)');
    final success = await connection.performClearStorage();
    if (success) {
      _wals = [];
      listener.onWalUpdated();
    } else {
      Logger.error('SDCardWalSync: CMD_CLEAR_STORAGE failed, falling back to per-file deletion');
      final files = await _listFiles(_device!.id);
      for (final file in files) {
        await connection.deleteFile(file);
      }
      _wals = [];
      listener.onWalUpdated();
    }
  }
}
