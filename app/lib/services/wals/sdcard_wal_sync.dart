import 'dart:async';
import 'dart:io';
import 'dart:isolate';
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

class _SyncIsolateParams {
  final SendPort replyPort;
  final String documentsPath;
  final int fileNum;
  final int initialOffset;
  final int? lastDeviceSessionId;
  final int timerStart;

  _SyncIsolateParams({
    required this.replyPort,
    required this.documentsPath,
    required this.fileNum,
    required this.initialOffset,
    this.lastDeviceSessionId,
    required this.timerStart,
  });
}

class _SyncMessage {
  final String type;
  final dynamic payload;

  _SyncMessage(this.type, [this.payload]);
}

class SDCardWalSyncImpl implements SDCardWalSync {
  List<Wal> _wals = <Wal>[];
  BtDevice? _device;

  final Future<DeviceConnection?> Function(String deviceId)?
  _connectionProvider;

  StreamSubscription? _storageStream;

  IWalSyncListener listener;

  bool _isCancelled = false;
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
      return _wals
          .where(
            (w) =>
                w.isSyncing ||
                (w.status == WalStatus.miss && w.storage == WalStorage.sdcard),
          )
          .length;
    }
    final pending = _wals
        .where(
          (w) => w.status == WalStatus.miss && w.storage == WalStorage.sdcard,
        )
        .toList();
    return pending.length;
  }

  SDCardWalSyncImpl(
    this.listener, {
    Future<DeviceConnection?> Function(String deviceId)? connectionProvider,
  }) : _connectionProvider = connectionProvider;

  @override
  void cancelSync() {
    if (_isSyncing) {
      _cancelCompleter ??= Completer<void>();
      _isCancelled = true;
      Logger.debug("SDCardWalSync: Cancel requested — stopping immediately");

      // Tell firmware to stop sending (best-effort, fire-and-forget)
      final dev = _device;
      if (dev != null) {
        final connFuture = _connectionProvider != null
            ? _connectionProvider!(dev.id)
            : ServiceManager.instance().device.ensureConnection(dev.id);
        connFuture
            .then((conn) => conn?.stopStorageSync() ?? Future.value(false))
            .catchError((_) => false);
      }

      // Cancel the BLE stream so the app doesn't hang waiting for an EOT that won't come
      _storageStream?.cancel();
      _storageStream = null;

      // Error the in-flight transfer completer so _readStorageBytesToFile returns immediately
      final transferCompleter = _activeTransferCompleter;
      if (transferCompleter != null && !transferCompleter.isCompleted) {
        transferCompleter.completeError(Exception('Sync cancelled by user'));
      }
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
      connFuture
          .then((conn) => conn?.stopStorageSync() ?? Future.value(false))
          .catchError((_) => false);
    }
    await _storageStream?.cancel();
    _storageStream = null;
    _resetSyncState();
  }

  @override
  Future<void> setDevice(
    BtDevice? device, {
    List<StorageFile>? prefetchedFiles,
  }) async {
    _device = device;
    if (_device != null) {
      final connection = _connectionProvider != null
          ? await _connectionProvider!(_device!.id)
          : await ServiceManager.instance().device.ensureConnection(_device!.id);
      if (connection != null) {
        await connection.acquireStorageLock('setDevice');
        try {
          _wals = await _buildWalsFromFilesLocked(
            connection,
            _device!.id,
            ignoreThreshold: true,
            prefetchedFiles: prefetchedFiles,
          );
        } finally {
          connection.releaseStorageLock();
        }
      }
      listener.onWalUpdated();
    }
  }

  @override
  Future<List<Wal>> getMissingWals() async {
    final dev = _device;
    if (dev == null) return [];

    final connection = _connectionProvider != null
        ? await _connectionProvider!(dev.id)
        : await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) return [];

    await connection.acquireStorageLock('getMissingWals');
    try {
      return await _getMissingWalsLocked(connection, dev.id);
    } finally {
      connection.releaseStorageLock();
    }
  }

  Future<List<Wal>> _getMissingWalsLocked(DeviceConnection connection, String deviceId) async {
    final wals = await _buildWalsFromFilesLocked(connection, deviceId, ignoreThreshold: true);
    Logger.debug('SDCardWalSync: getMissingWals returned ${wals.length} WALs');
    return wals;
  }

  @override
  Future<bool> hasFilesToSync() async {
    if (_device == null) return false;
    if (_wals.isNotEmpty) return true;
    
    final connection = _connectionProvider != null
        ? await _connectionProvider!(_device!.id)
        : await ServiceManager.instance().device.ensureConnection(_device!.id);
    if (connection == null) return false;

    await connection.acquireStorageLock('hasFilesToSync');
    try {
      final files = await connection.listFiles();
      return files.isNotEmpty;
    } finally {
      connection.releaseStorageLock();
    }
  }

  Future<List<Wal>> _buildWalsFromFilesLocked(
    DeviceConnection connection,
    String deviceId, {
    required bool ignoreThreshold,
    List<StorageFile>? prefetchedFiles,
  }) async {
    final files = prefetchedFiles ?? await connection.listFiles();
    if (files.isEmpty) return [];

    final codec = await connection.getAudioCodec() ?? BleAudioCodec.pcm8;
    final threshold = codec.getStorageBytesPerMinute();
    final wals = <Wal>[];

    const int kMaxStorageBytes = 0x1E000000;

    for (final file in files) {
      if (file.size == 0) continue;
      if (file.size > kMaxStorageBytes) {
        Logger.error(
          'SDCardWalSync: file[${file.index}] has impossible size ${file.size} (> 480 MB)',
        );
        continue;
      }

      // Match by timerStart (the file's Unix timestamp) rather than fileNum so that
      // partial-resume bookmarks survive array-index shifts caused by earlier files
      // being deleted between a disconnect and the next reconnect.  fileNum is updated
      // to the current index below when the wal is (re-)created.
      // Guard: only match on timerStart when it is a valid epoch; synthetic timestamps
      // (generated when firmware reports timestamp == 0) cannot be matched reliably.
      const int kMinValidEpochForMatch = 946684800;
      final existing = (file.timestamp > kMinValidEpochForMatch)
          ? _wals.firstWhereOrNull(
              (w) =>
                  w.device == deviceId &&
                  w.timerStart == file.timestamp &&
                  w.storage == WalStorage.sdcard,
            )
          : null;
      final walOffset =
          (existing != null &&
              existing.walOffset > 0 &&
              existing.walOffset <= file.size)
          ? existing.walOffset
          : 0;

      final newBytes = file.size - walOffset;
      if (!ignoreThreshold && walOffset == 0 && newBytes < threshold) {
        continue;
      }

      final ms = (newBytes / (codec.getStorageBytesPerMinute() / 60000.0)).truncate();
      // Skip files with less than 500ms of audio that haven't been started —
      // these are post-rotation stub files the firmware just opened on BLE connect.
      if (ms < 500 && walOffset == 0) {
        Logger.debug('SDCardWalSync: Skipping file[${file.index}] — less than 500ms of audio ($ms ms)');
        continue;
      }
      final seconds = (ms / 1000).truncate();
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

  @override
  Future deleteWal(Wal wal) async {
    final dev = _device;
    if (dev == null) return;
    final connection = _connectionProvider != null
        ? await _connectionProvider!(dev.id)
        : await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) return;

    await connection.acquireStorageLock('deleteWal');
    try {
      await _deleteWalLocked(connection, wal);
    } finally {
      connection.releaseStorageLock();
    }
  }

  Future _deleteWalLocked(DeviceConnection connection, Wal wal) async {
    await connection.deleteFile(
      StorageFile(index: wal.fileNum, timestamp: 0, size: 0),
    );
    _wals.removeWhere((w) => w.id == wal.id);
    listener.onWalUpdated();
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

  Future _readStorageBytesToFileLocked(
    DeviceConnection connection,
    Wal wal,
    Function(File f, int offset, int timerStart, {String? subFolder})
    callback, {
    Function(int offset)? onProgress,
  }) async {
    int fileNum = wal.fileNum;
    int offset = wal.walOffset;
    int timerStart = wal.timerStart;
    int? lastDeviceSessionId = wal.timerStart > 0 ? wal.timerStart : null;

    if (_isCancelled) throw Exception("Cancelled");

    final completer = Completer<void>();
    _activeTransferCompleter = completer;
    bool isCompleted = false;
    bool isShuttingDown = false;
    int writtenOffset = offset;

    final dir = await getApplicationDocumentsDirectory();
    final mainReceivePort = ReceivePort();
    SendPort? isolateSendPort;
    Isolate? isolate;

    List<List<Uint8List>> pendingBatches = [];
    List<Uint8List> batchBuffer = [];
    DateTime lastFlush = DateTime.now();
    int inFlightBatches = 0;
    int totalPackets = 0;

    Timer? inactivityTimer;
    void resetInactivityTimer() {
      inactivityTimer?.cancel();
      inactivityTimer = Timer(const Duration(seconds: 15), () {
        if (!isCompleted) {
          isCompleted = true;
          if (!completer.isCompleted) {
            completer.completeError(Exception("Transfer stalled: 15s inactivity timeout"));
          }
        }
      });
    }

    Future<void> cleanup() async {
      if (isShuttingDown) return;
      isShuttingDown = true;
      inactivityTimer?.cancel();
      if (isolateSendPort != null) {
        try {
          isolateSendPort!.send(_SyncMessage('shutdown'));
        } catch (_) {}
      }
      await Future.delayed(const Duration(milliseconds: 20));
      isolate?.kill(priority: Isolate.immediate);
      mainReceivePort.close();
      await _storageStream?.cancel();
      _storageStream = null;
    }

    mainReceivePort.listen((msg) {
      if (isCompleted || isShuttingDown) return;
      if (msg is SendPort) {
        isolateSendPort = msg;
        for (final b in pendingBatches) {
          isolateSendPort!.send(_SyncMessage('dataBatch', b));
          inFlightBatches++;
        }
        pendingBatches.clear();
        return;
      }
      if (msg is! _SyncMessage) return;

      switch (msg.type) {
        case 'progress':
          inFlightBatches = (inFlightBatches - 1).clamp(0, 9999);
          final bytesWritten = msg.payload as int;
          final delta = bytesWritten - writtenOffset;
          writtenOffset = bytesWritten;
          _lastSegmentBoundaryOffset = bytesWritten;

          Logger.debug(
            'SDCardWalSync: [PROGRESS] received $totalPackets packets, offset=$bytesWritten bytes',
          );

          if (onProgress != null) onProgress(bytesWritten);
          _updateSpeed(delta);
          listener.onWalUpdated();
          resetInactivityTimer();
          break;
        case 'marker':
          unawaited(_saveMarker(lastDeviceSessionId ?? 0, msg.payload as int));
          break;
        case 'done':
          isCompleted = true;
          if (!completer.isCompleted) completer.complete();
          break;
        case 'error':
          isCompleted = true;
          if (!completer.isCompleted) completer.completeError(Exception(msg.payload.toString()));
          break;
      }
    });

    isolate = await Isolate.spawn(
      _syncIsolateEntry,
      _SyncIsolateParams(
        replyPort: mainReceivePort.sendPort,
        documentsPath: dir.path,
        fileNum: fileNum,
        initialOffset: offset,
        lastDeviceSessionId: lastDeviceSessionId,
        timerStart: timerStart,
      ),
    );

    resetInactivityTimer();

    _storageStream = (await connection.getBleStorageBytesStream()).listen(
      (List<int> value) async {
        if (isCompleted || isShuttingDown) return;
        resetInactivityTimer();
        if (value.isEmpty) return;

        totalPackets++;
        batchBuffer.add(Uint8List.fromList(value));

        final now = DateTime.now();
        if (batchBuffer.length >= 20 || now.difference(lastFlush) >= const Duration(milliseconds: 20)) {
          final toSend = List<Uint8List>.from(batchBuffer);
          batchBuffer.clear();
          lastFlush = now;

          if (isolateSendPort == null) {
            pendingBatches.add(toSend);
            if (pendingBatches.length > 200) {
              await Future.delayed(const Duration(milliseconds: 2));
            }
          } else {
            while (inFlightBatches > 10 && !isCompleted && !isShuttingDown) {
              await Future.delayed(const Duration(milliseconds: 10));
            }
            if (!isCompleted && !isShuttingDown) {
              try {
                isolateSendPort!.send(_SyncMessage('dataBatch', toSend));
                inFlightBatches++;
              } catch (e) {
                isCompleted = true;
                if (!completer.isCompleted) completer.completeError(Exception("Isolate send failed: $e"));
              }
            }
          }
        }
      },
      onError: (e) {
        if (!isCompleted) {
          isCompleted = true;
          if (!completer.isCompleted) completer.completeError(e);
        }
      },
      onDone: () {
        if (isCompleted || isShuttingDown) return;
        if (batchBuffer.isNotEmpty && isolateSendPort != null) {
          try {
            isolateSendPort!.send(_SyncMessage('dataBatch', List<Uint8List>.from(batchBuffer)));
            inFlightBatches++;
          } catch (_) {}
          batchBuffer.clear();
        }
      },
    );

    try {
      final readStarted = await connection.writeToStorage(fileNum, 0x11, offset);
      if (!readStarted) throw Exception('Could not start SD card read');
      await completer.future;
    } finally {
      await cleanup();
    }
  }

  void _completeCancelIfPending() {
    final c = _cancelCompleter;
    if (c != null && !c.isCompleted) c.complete();
    _cancelCompleter = null;
  }

  void _resetSyncState() {
    _isCancelled = false;
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
    } catch (_) {
      rethrow;
    }
  }

  void _updateSpeed(int bytesDownloaded) {
    _totalBytesDownloaded += bytesDownloaded;
    if (_downloadStartTime != null) {
      final elapsed =
          DateTime.now().difference(_downloadStartTime!).inMilliseconds /
          1000.0;
      if (elapsed > 0) {
        _currentSpeedKBps = (_totalBytesDownloaded / 1024) / elapsed;
      }
    }
  }

  @override
  Future<SyncLocalFilesResponse?> syncAll({
    IWalSyncProgressListener? progress,
  }) async {
    if (_isSyncing || _device == null) return null;

    final dev = _device!;
    final connection = _connectionProvider != null
        ? await _connectionProvider!(dev.id)
        : await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) throw Exception('No connection');

    if (connection.isStorageBusy) {
      Logger.debug('Storage busy, skipping: syncAll');
      return null;
    }

    _resetSyncState();
    _isSyncing = true;

    await connection.acquireStorageLock('syncAll');
    try {
      return await _syncAllLocked(connection, dev.id, progress: progress);
    } finally {
      _isSyncing = false;
      _completeCancelIfPending();
      connection.releaseStorageLock();
    }
  }

  Future<SyncLocalFilesResponse?> _syncAllLocked(
    DeviceConnection connection,
    String deviceId, {
    IWalSyncProgressListener? progress,
  }) async {
    final refreshed = await _getMissingWalsLocked(connection, deviceId);
    _wals = refreshed;
    listener.onWalUpdated();

    if (_isCancelled) return null;

    final wals = _wals
        .where((w) => w.status == WalStatus.miss && w.storage == WalStorage.sdcard)
        .toList();
    if (wals.isEmpty) return null;

    bool anyPartial = false;
    _downloadStartTime = DateTime.now();

    for (int i = 0; i < wals.length; i++) {
      final wal = wals[i];
      if (_isCancelled) break;
      wal.isSyncing = true;
      wal.syncStartedAt = DateTime.now();
      listener.onWalUpdated();

      final initialOffset = wal.walOffset;
      int lastOffset = initialOffset;
      await _checkDiskSpaceBeforeSync(wal.storageTotalBytes - initialOffset);

      try {
        const int maxGapRetries = 3;
        int gapRetries = 0;
        bool transferred = false;
        while (!transferred) {
          if (_isCancelled) throw Exception("Cancelled");
          try {
            await _readStorageBytesToFileLocked(
              connection,
              wal,
              (File file, int offset, int timerStart, {String? subFolder}) async {
                if (_isCancelled) throw Exception("Cancelled");
                _updateSpeed(offset - lastOffset);
                lastOffset = offset;
                listener.onWalUpdated();
              },
              onProgress: (offset) {
                wal.walOffset = offset;
                final double withinWal =
                    (wal.storageTotalBytes > initialOffset)
                    ? (offset - initialOffset) /
                          (wal.storageTotalBytes - initialOffset)
                    : 1.0;
                final double clamped =
                    ((i + (withinWal.clamp(0.0, 1.0) * 0.9)) / wals.length)
                        .clamp(0.0, 1.0);
                progress?.onWalSyncedProgress(
                  clamped,
                  speedKBps: _currentSpeedKBps,
                );
                _globalProgressListener?.onWalSyncedProgress(
                  clamped,
                  speedKBps: _currentSpeedKBps,
                );
              },
            );
            transferred = true;
          } on _ProtocolGapException catch (e) {
            gapRetries++;
            if (gapRetries > maxGapRetries) {
              rethrow;
            }
            wal.walOffset = e.incoming;
            lastOffset = e.incoming;
            _lastSegmentBoundaryOffset = e.incoming;
            await connection.stopStorageSync();
            await Future.delayed(const Duration(milliseconds: 200));
          }
        }

        if (_isCancelled) throw Exception("Cancelled");

        await Future.delayed(const Duration(milliseconds: 500));
        await _deleteWalLocked(connection, wal);
        wal.status = WalStatus.synced;
        final double fileDone = ((i + 1.0) / wals.length).clamp(0.0, 1.0);
        progress?.onWalSyncedProgress(fileDone, speedKBps: _currentSpeedKBps);
        _globalProgressListener?.onWalSyncedProgress(
          fileDone,
          speedKBps: _currentSpeedKBps,
        );
        listener.onWalUpdated();
      } catch (e) {
        wal.walOffset = _lastSegmentBoundaryOffset;
        wal.status = WalStatus.miss;
        wal.isSyncing = false;
        listener.onWalUpdated();
        anyPartial = true;
        if (_isCancelled) break;
      }
    }

    return SyncLocalFilesResponse(
      newConversationIds: [],
      updatedConversationIds: [],
      isPartial: anyPartial,
    );
  }

  @override
  Future<SyncLocalFilesResponse?> syncWal({
    required Wal wal,
    IWalSyncProgressListener? progress,
  }) async {
    if (_isSyncing) return null;

    final connection = _device != null
        ? (_connectionProvider != null
              ? await _connectionProvider!(_device!.id)
              : await ServiceManager.instance().device.ensureConnection(_device!.id))
        : null;
    if (connection == null) throw Exception('No connection');

    if (connection.isStorageBusy) {
      Logger.debug('Storage busy, skipping: syncWal');
      return null;
    }

    _resetSyncState();
    _isSyncing = true;

    await connection.acquireStorageLock('syncWal');
    try {
      return await _syncWalLocked(connection, wal, progress: progress);
    } finally {
      _isSyncing = false;
      _completeCancelIfPending();
      connection.releaseStorageLock();
    }
  }

  Future<SyncLocalFilesResponse?> _syncWalLocked(
    DeviceConnection connection,
    Wal wal, {
    IWalSyncProgressListener? progress,
  }) async {
    wal.isSyncing = true;
    wal.syncStartedAt = DateTime.now();
    listener.onWalUpdated();

    final initialOffset = wal.walOffset;
    int lastOffset = initialOffset;
    await _checkDiskSpaceBeforeSync(wal.storageTotalBytes - initialOffset);
    _downloadStartTime = DateTime.now();

    try {
      const int maxGapRetries = 3;
      int gapRetries = 0;
      bool transferred = false;
      while (!transferred) {
        if (_isCancelled) throw Exception("Cancelled");
        try {
          await _readStorageBytesToFileLocked(
            connection,
            wal,
            (File file, int offset, int timerStart, {String? subFolder}) async {
              if (_isCancelled) throw Exception("Cancelled");
              _updateSpeed(offset - lastOffset);
              lastOffset = offset;
              listener.onWalUpdated();
            },
            onProgress: (offset) {
              wal.walOffset = offset;
              final double progressPercent =
                  (wal.storageTotalBytes > initialOffset)
                  ? (offset - initialOffset) /
                        (wal.storageTotalBytes - initialOffset)
                  : 1.0;
              final double clamped = progressPercent.clamp(0.0, 1.0);
              progress?.onWalSyncedProgress(
                clamped,
                speedKBps: _currentSpeedKBps,
              );
              _globalProgressListener?.onWalSyncedProgress(
                clamped,
                speedKBps: _currentSpeedKBps,
              );
            },
          );
          transferred = true;
        } on _ProtocolGapException catch (e) {
          gapRetries++;
          if (gapRetries > maxGapRetries) rethrow;
          
          wal.walOffset = e.incoming;
          lastOffset = e.incoming;
          _lastSegmentBoundaryOffset = e.incoming;
          await connection.stopStorageSync();
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }

      if (_isCancelled) throw Exception("Cancelled");

      await Future.delayed(const Duration(milliseconds: 500));
      if (wal.walOffset >= wal.storageTotalBytes) {
        await _deleteWalLocked(connection, wal);
      } else {
        wal.walOffset = _lastSegmentBoundaryOffset;
      }
      wal.status = WalStatus.synced;
      listener.onWalUpdated();
    } catch (e) {
      wal.walOffset = _lastSegmentBoundaryOffset;
      wal.isSyncing = false;
      wal.status = WalStatus.miss;
      listener.onWalUpdated();
      rethrow;
    }

    return SyncLocalFilesResponse(
      newConversationIds: [],
      updatedConversationIds: [],
    );
  }

  @override
  Future<SyncLocalFilesResponse?> rotateAndSync({
    IWalSyncProgressListener? progress,
  }) async {
    if (_isSyncing || _device == null) return null;
    
    final dev = _device!;
    final connection = await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) throw Exception('No connection');

    if (connection.isStorageBusy) {
      Logger.debug('Storage busy, skipping: rotateAndSync');
      return null;
    }

    _resetSyncState();
    _isSyncing = true;

    await connection.acquireStorageLock('rotateAndSync');
    try {
      if (_isCancelled) return null;

      final rotated = await connection.rotateFile();
      if (!rotated) throw Exception('Rotation failed');
      _wals = await _buildWalsFromFilesLocked(connection, dev.id, ignoreThreshold: true);

      if (_isCancelled) return null;

      return await _syncAllLocked(connection, dev.id, progress: progress);
    } finally {
      _isSyncing = false;
      _completeCancelIfPending();
      connection.releaseStorageLock();
    }
  }

  @override
  Future<void> deleteAllPendingWals() async {
    if (_device == null) return;
    final connection = await ServiceManager.instance().device.ensureConnection(
      _device!.id,
    );
    if (connection == null) return;

    if (connection.isStorageBusy) {
      Logger.debug('Storage busy, skipping: deleteAllPendingWals');
      return;
    }

    await connection.acquireStorageLock('deleteAllPendingWals');
    try {
      Logger.debug('SDCardWalSync: deleteAllPendingWals — Sending CMD_CLEAR_STORAGE (0x14)');
      final success = await connection.performClearStorage();
      if (success) {
        _wals = [];
        listener.onWalUpdated();
      } else {
        Logger.error('SDCardWalSync: CMD_CLEAR_STORAGE failed, falling back to per-file deletion');
        final files = await connection.listFiles();
        for (final file in files) {
          if (_isCancelled) break;
          await Future.delayed(const Duration(milliseconds: 5)); // Prevent UI starvation
          await connection.deleteFile(file);
          _wals.removeWhere(
            (w) => w.fileNum == file.index && w.storage == WalStorage.sdcard,
          );
        }
        listener.onWalUpdated();
      }
    } finally {
      connection.releaseStorageLock();
    }
  }
}
void _syncIsolateEntry(_SyncIsolateParams params) {
  final isolateReceivePort = ReceivePort();
  params.replyPort.send(isolateReceivePort.sendPort);

  int expectedOffset = params.initialOffset;
  final writeBuffer = BytesBuilder(copy: false);
  Uint8List tailBuffer = Uint8List(0);

  final subFolder = params.lastDeviceSessionId?.toString() ?? 'unsynced';
  final folderPath = '${params.documentsPath}/raw_segments/$subFolder';
  final folder = Directory(folderPath);
  if (!folder.existsSync()) folder.createSync(recursive: true);

  String fileName = (params.lastDeviceSessionId != null)
      ? '${params.lastDeviceSessionId}_0.bin'
      : 'recording_${params.timerStart}.bin';

  final outputFile = File('${folder.path}/$fileName');

  DateTime lastProgressSentAt = DateTime.now();
  bool hasReceivedStartAck = false;
  bool isCompleted = false;

  void flush() {
    if (writeBuffer.isEmpty) return;
    try {
      outputFile.writeAsBytesSync(writeBuffer.takeBytes(), mode: FileMode.append);
    } catch (e) {
      params.replyPort.send(_SyncMessage('error', 'Write failed: $e'));
    }
  }

  isolateReceivePort.listen((message) async {
    if (isCompleted || message is! _SyncMessage) return;

    if (message.type == 'shutdown') {
      flush();
      isCompleted = true;
      isolateReceivePort.close();
      return;
    }

    if (message.type == 'dataBatch') {
      try {
        final List<Uint8List> batch = message.payload;
        for (final value in batch) {
          if (value.isEmpty) continue;

          int packetType = value[0];
          switch (packetType) {
            case 0x01:
              if (!hasReceivedStartAck || value.length < 5) continue;
              int incomingOffset =
                  value[1] |
                  (value[2] << 8) |
                  (value[3] << 16) |
                  (value[4] << 24);
              Uint8List payload = value.sublist(5);

              if (incomingOffset < expectedOffset) {
                final packetEnd = incomingOffset + payload.length;
                if (packetEnd <= expectedOffset) continue;
                payload = payload.sublist(expectedOffset - incomingOffset);
              } else if (incomingOffset > expectedOffset) {
                params.replyPort.send(_SyncMessage('error',
                    'Protocol gap: incoming=$incomingOffset expected=$expectedOffset'));
                isCompleted = true;
                isolateReceivePort.close();
                return;
              }

              writeBuffer.add(payload);
              expectedOffset += payload.length;

              final combined = Uint8List(tailBuffer.length + payload.length);
              combined.setAll(0, tailBuffer);
              combined.setAll(tailBuffer.length, payload);

              final bd = ByteData.sublistView(combined);
              int scanOff = 0;
              while (scanOff + 4 <= combined.length) {
                int packageSize = bd.getUint32(scanOff, Endian.little);
                if (packageSize == 0xFFFFFFFE) {
                  if (scanOff + 20 <= combined.length) {
                    final markerTs = bd.getUint32(scanOff + 4, Endian.little);
                    params.replyPort.send(_SyncMessage('marker', markerTs));
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
              if (combined.length >= 3) {
                tailBuffer = combined.sublist(combined.length - 3);
              } else {
                tailBuffer = combined;
              }
              break;

            case 0x02:
              flush();
              try {
                if (outputFile.lengthSync() != expectedOffset) {
                  params.replyPort.send(_SyncMessage('error', 'Final file size mismatch: expected=$expectedOffset actual=${outputFile.lengthSync()}'));
                } else {
                  params.replyPort.send(_SyncMessage('done'));
                }
              } catch (e) {
                params.replyPort.send(_SyncMessage('error', 'Final validation failed: $e'));
              }
              isCompleted = true;
              isolateReceivePort.close();
              return;

            case 0x03:
              if (value.length >= 2) {
                if (value[1] == 0x00) {
                  hasReceivedStartAck = true;
                } else {
                  params.replyPort.send(_SyncMessage('error', 'Error ACK: \${value[1]}'));
                  isCompleted = true;
                  isolateReceivePort.close();
                  return;
                }
              }
              break;
          }
        }

        if (writeBuffer.length >= 32768 || writeBuffer.length > 524288) {
          flush();
        }

        final now = DateTime.now();
        if (now.difference(lastProgressSentAt) >= const Duration(milliseconds: 500)) {
          params.replyPort.send(_SyncMessage('progress', expectedOffset));
          lastProgressSentAt = now;
        }

        await Future(() {}); // Yield
      } catch (e) {
        flush();
        params.replyPort.send(_SyncMessage('error', e.toString()));
        isCompleted = true;
        isolateReceivePort.close();
      }
    }
  });
}
