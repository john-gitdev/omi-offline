import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:omi/gen/pigeon_communicator.g.dart';

import 'package:collection/collection.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/wal_file_manager.dart';

import 'package:path_provider/path_provider.dart';

import 'package:disk_space_2/disk_space_2.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/errors.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
import 'package:omi/services/wals/wal_sync_exceptions.dart';

class SDCardWalSyncImpl implements SDCardWalSync {
  List<Wal> _wals = <Wal>[];
  BtDevice? _device;

  final Future<DeviceConnection?> Function(String deviceId)? _connectionProvider;

  final Duration _inactivityTimeout;

  StreamSubscription? _storageStream;

  IWalSyncListener listener;

  bool _isCancelled = false;
  bool _isSyncing = false;
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
  DateTime? _lastWalPersistAt;
  static const Duration _walPersistInterval = Duration(seconds: 1);

  // How many consecutive incomplete transfers a single file may accumulate before
  // the completeness guard gives up and deletes it to unblock the (index-0-only)
  // fast path. Each attempt is one sync cycle, so this trades a few retries — which
  // let a transient rotation-adjacent empty read self-heal — against never getting
  // permanently stuck on a genuinely unreadable ("poison") file. Deleting a poison
  // file loses only that one recording; leaving it would stall ALL further sync.
  static const int _maxSyncFailBeforeDrop = 5;
  @override
  double get currentSpeedKBps => _currentSpeedKBps;

  @override
  int get recordingsCount => _wals.length;

  @override
  int get estimatedTotalSegments {
    if (_isSyncing) {
      return _wals
          .where(
            (w) => w.isSyncing || (w.status == WalStatus.miss && w.storage == WalStorage.sdcard),
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
    Duration inactivityTimeout = const Duration(seconds: 15),
  })  : _connectionProvider = connectionProvider,
        _inactivityTimeout = inactivityTimeout;

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
            .then((conn) async => await conn?.stopStorageSync() ?? Future.value(false))
            .catchError((_) => Future.value(false));
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
          .then((conn) async => await conn?.stopStorageSync() ?? Future.value(false))
          .catchError((_) => Future.value(false));
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
      // Restore persisted WAL offsets so partial downloads resume correctly after
      // an app restart, and so fully-downloaded-but-not-yet-deleted files are not
      // re-downloaded from offset 0 (which would create duplicate recordings).
      if (_wals.isEmpty) {
        try {
          final persisted = await WalFileManager.loadWals();
          _wals = persisted.where((w) => w.device == _device!.id).toList();
          Logger.debug('SDCardWalSync: Loaded ${_wals.length} persisted WALs from disk');
        } catch (e) {
          Logger.debug('SDCardWalSync: Failed to load persisted WALs: $e');
        }
      }

      final connection = _connectionProvider != null
          ? await _connectionProvider!(_device!.id)
          : await ServiceManager.instance().device.ensureConnection(_device!.id);
      if (connection != null) {
        // Skip lock when files are prefetched — _buildWalsFromFilesLocked only
        // needs BLE I/O (listFiles) when prefetchedFiles is null. With files
        // already in hand the only remaining call is getAudioCodec(), which is
        // cached, so acquiring the lock here would deadlock any caller that
        // already holds it (e.g. refreshStorageStats).
        if (prefetchedFiles == null) {
          await connection.acquireStorageLock('setDevice');
        }
        try {
          // Skip rebuild when prefetchedFiles is an empty list — caller wants to
          // register the device without BLE I/O. An empty file list would make
          // _buildWalsFromFilesLocked return [] and erase the persisted WALs we
          // just loaded. The real rebuild happens when refreshStorageStats() calls
          // setDevice() again with the actual file listing.
          if (prefetchedFiles == null || prefetchedFiles.isNotEmpty) {
            _wals = await _buildWalsFromFilesLocked(
              connection,
              _device!.id,
              prefetchedFiles: prefetchedFiles,
            );
          }
        } finally {
          if (prefetchedFiles == null) {
            connection.releaseStorageLock();
          }
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
    final wals = await _buildWalsFromFilesLocked(connection, deviceId);
    Logger.debug('SDCardWalSync: getMissingWals returned ${wals.length} WALs');
    return wals;
  }

  Future<void> _updateStorageStatsLocked(DeviceConnection connection) async {
    try {
      final stats = await connection.getStorageFileStats();
      if (stats != null) {
        listener.onStorageStatsUpdated(stats);
      }
    } catch (e) {
      Logger.debug('SDCardWalSync: Failed to update storage stats: $e');
    }
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
    List<StorageFile>? prefetchedFiles,
  }) async {
    final files = prefetchedFiles ?? await connection.listFiles();
    if (files.isEmpty) return [];

    final codec = await connection.getAudioCodec() ?? BleAudioCodec.pcm8;
    final wals = <Wal>[];

    const int kMaxStorageBytes = 0x1E000000;

    for (final file in files) {
      if (file.size > kMaxStorageBytes) {
        Logger.error(
          'SDCardWalSync: file[${file.index}] has impossible size ${file.size} (> 480 MB)',
        );
        continue;
      }

      // Match by timerStart (the file's Unix timestamp) rather than fileNum so that
      // partial-resume bookmarks survive array-index shifts.
      const int kMinValidEpochForMatch = 946684800;
      final bool hasValidTimestamp = file.timestamp > kMinValidEpochForMatch;

      final existing = hasValidTimestamp
          ? _wals.firstWhereOrNull(
              (w) => w.device == deviceId && w.timerStart == file.timestamp && w.storage == WalStorage.sdcard,
            )
          : _wals.firstWhereOrNull(
              (w) =>
                  w.device == deviceId &&
                  w.sessionId == file.sessionId &&
                  w.timerStart < kMinValidEpochForMatch &&
                  w.storage == WalStorage.sdcard,
            );

      // Verify that if we found a match, the identity is actually the same.
      // If the file on disk has a different timestamp than our saved bookmark,
      // we must discard the bookmark because the SD card has been reset or rearranged.
      bool isMatchValid = existing != null;
      if (existing != null && hasValidTimestamp && existing.timerStart != file.timestamp) {
        Logger.debug(
            'SDCardWalSync: Discarding invalid bookmark for index ${file.index} (TS mismatch: ${existing.timerStart} vs ${file.timestamp})');
        isMatchValid = false;
      }

      final walOffset =
          (isMatchValid && existing!.walOffset > 0 && existing.walOffset <= file.size) ? existing.walOffset : 0;

      final newBytes = file.size - walOffset;
      final ms = (newBytes / (codec.getStorageBytesPerMinute() / 60000.0)).truncate();
      final seconds = (ms / 1000).truncate();

      // Trust the raw firmware timestamp. Never "invent" a UTC time here;
      // pre-sync files stay low (e.g. 1010) so the protocol remains honest.
      final timerStart = file.timestamp;

      final wal = Wal(
        codec: codec,
        channel: 1,
        device: deviceId,
        fileNum: file.index,
        walOffset: walOffset,
        storageTotalBytes: file.size,
        timerStart: timerStart,
        sessionId: file.sessionId,
        storage: WalStorage.sdcard,
        estimatedSegments: (seconds / 60).ceil().clamp(1, 999),
      );
      if (isMatchValid && existing!.isSyncing) {
        wal.isSyncing = true;
        wal.syncStartedAt = existing.syncStartedAt;
      }
      // Carry the incomplete-transfer counter across list refreshes so a file that
      // keeps reading short is eventually recognised as poison (see the completeness
      // guard in _syncAllLocked). Only meaningful when the identity actually matches.
      if (isMatchValid) {
        wal.syncFailCount = existing!.syncFailCount;
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

  Future _deleteWalLocked(DeviceConnection connection, Wal wal, {int? overrideFileNum, bool skipSave = false}) async {
    final targetIdx = overrideFileNum ?? wal.fileNum;
    Logger.debug('SDCardWalSync: deleting synced WAL from SD card: index=$targetIdx ts=${wal.timerStart}');
    final connected = await connection.isConnected();
    if (!connected) throw Exception('Device disconnected before deletion of index=$targetIdx ts=${wal.timerStart}');
    final success = await connection.deleteFile(
      StorageFile(index: targetIdx, timestamp: wal.timerStart, size: 0),
    );
    if (!success) throw Exception('Firmware rejected deletion of index=$targetIdx ts=${wal.timerStart}');
    _wals.removeWhere((w) => w.id == wal.id);
    listener.onWalUpdated();
    // Persist after deletion so the WAL is gone from disk even if the app restarts before
    // the next natural save point. This prevents re-downloading a deleted file.
    if (!skipSave) {
      WalFileManager.saveWals(_wals, deviceId: wal.device).catchError((_) => Future.value(false));
    }
  }

  Future<(File, int)> _flushToDisk(
    Wal wal,
    List<int> rawData,
    int timerStart, {
    required String subFolder,
    bool append = false,
  }) async {
    final directory = await getApplicationDocumentsDirectory();
    final folderPath = '${directory.path}/raw_segments/$subFolder';

    final folder = Directory(folderPath);
    if (!await folder.exists()) await folder.create(recursive: true);

    final fileName = '${timerStart}_${wal.sessionId ?? 0}.bin';

    String filePath = '${folder.path}/$fileName';
    final file = File(filePath);
    await file.writeAsBytes(
      rawData,
      mode: append ? FileMode.append : FileMode.write,
    );

    if (SharedPreferencesUtil().adjustmentMode) {
      try {
        final adjFolder = Directory('${directory.path}/adjustment_mode_segments/$subFolder');
        if (!await adjFolder.exists()) await adjFolder.create(recursive: true);
        await file.copy('${adjFolder.path}/$fileName');
      } catch (e) {
        Logger.error('SDCardWalSync: failed to copy bin to adjustment_mode_segments: $e');
      }
    }

    return (file, rawData.length);
  }

  Future _readStorageBytesToFileLocked(
    DeviceConnection connection,
    Wal wal,
    Function(File f, int offset, int timerStart, {String? subFolder}) callback, {
    Function(int offset)? onProgress,
    int? overrideFileNum,
  }) async {
    // Native whole-file download (writes straight to disk, no per-packet Dart hop).
    // Android and iOS both implement BleHostApi.downloadStorageFile; other platforms
    // fall through to the Dart notification-stream path below.
    if (Platform.isAndroid || Platform.isIOS) {
      return await _readStorageBytesToFileLockedNative(connection, wal, callback,
          onProgress: onProgress, overrideFileNum: overrideFileNum);
    }
    int fileNum = overrideFileNum ?? wal.fileNum;
    int offset = wal.walOffset;
    int timerStart = wal.timerStart;

    if (_isCancelled) throw Exception("Cancelled");

    final completer = Completer<void>();
    _activeTransferCompleter = completer;
    bool hasError = false;
    bool isProcessing = false;
    bool eotReceived = false;

    final Queue<Uint8List> chunkQueue = Queue<Uint8List>();
    final BytesBuilder batchBuilder = BytesBuilder(copy: false);
    final Set<String> flushedSegmentsThisTransfer = {};
    int writtenOffset = offset;

    // Use 'session_$sessionId' prefix for pre-sync timestamps so they land in the 'Unorganized' UI section
    String subFolderPrefix = (timerStart < 946684800) ? 'session_${wal.sessionId}' : timerStart.toString();

    if (offset > 0) {
      final directory = await getApplicationDocumentsDirectory();
      final existingFile = File(
        '${directory.path}/raw_segments/$subFolderPrefix/${timerStart}_${wal.sessionId ?? 0}.bin',
      );
      if (await existingFile.exists()) {
        // Truncate-on-resume: file.length and wal.walOffset can diverge if a
        // prior session was killed between writeAsBytes (which flushed bytes to
        // disk) and the next walOffset persist (every ~2 MB / per-flush). Any
        // bytes on disk beyond walOffset are about to be re-fetched from the
        // device — keeping them would duplicate audio in the middle of the bin
        // and confuse the VAD frame parser. The device's stored file is
        // immutable until we send CMD_DELETE_FILE, so the re-fetch is safe.
        try {
          final actualSize = await existingFile.length();
          if (actualSize > offset) {
            final raf = await existingFile.open(mode: FileMode.append);
            try {
              await raf.truncate(offset);
            } finally {
              await raf.close();
            }
            Logger.debug(
                'SDCardWalSync: Truncated ${existingFile.path} from $actualSize to $offset bytes (resume reconciliation)');
          }
        } catch (e) {
          Logger.error('SDCardWalSync: truncate-on-resume failed for ${existingFile.path}: $e');
        }
        flushedSegmentsThisTransfer.add('${timerStart}_${wal.sessionId ?? 0}');
      }
    }

    Future<void> flushRawBuffer(List<int> rawData) async {
      if (rawData.isEmpty) return;
      final segmentKey = '${timerStart}_${wal.sessionId ?? 0}';
      final appendMode = flushedSegmentsThisTransfer.contains(segmentKey);
      if (!appendMode) flushedSegmentsThisTransfer.add(segmentKey);

      var (file, bytesWritten) = await _flushToDisk(
        wal,
        rawData,
        timerStart,
        subFolder: subFolderPrefix,
        append: appendMode,
      );
      writtenOffset += bytesWritten;
      _lastSegmentBoundaryOffset = writtenOffset;
      try {
        await callback(file, writtenOffset, timerStart, subFolder: subFolderPrefix);
      } catch (_) {}
    }

    _storageStream?.cancel();
    int expectedOffset = offset;
    _lastSegmentBoundaryOffset = offset;
    bool hasReceivedStartAck = false;
    bool isStreamLocked = false;
    int packetsReceived = 0;
    Timer? inactivityTimer;

    void resetInactivityTimer() {
      inactivityTimer?.cancel();
      inactivityTimer = Timer(_inactivityTimeout, () {
        if (!completer.isCompleted) {
          isStreamLocked = true;
          hasError = true;
          completer.completeError(
            Exception("Transfer stalled: ${_inactivityTimeout.inSeconds}s inactivity timeout"),
          );
        }
      });
    }

    resetInactivityTimer();

    _storageStream = (await connection.getBleStorageBytesStream()).listen(
      (List<int> value) async {
        resetInactivityTimer();
        if (_isCancelled || hasError || isStreamLocked) return;
        packetsReceived++;
        if (packetsReceived % 500 == 0) {
          Logger.debug(
            'SDCardWalSync: [PROGRESS] received $packetsReceived packets, offset=$expectedOffset bytes',
          );
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
              if (!completer.isCompleted) {
                completer.completeError(
                  ProtocolGapException(incomingOffset, expectedOffset),
                );
              }
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
                while (chunkQueue.isNotEmpty) {
                  batchBuilder.add(chunkQueue.removeFirst());
                }
                await flushRawBuffer(batchBuilder.takeBytes());
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
              if (!completer.isCompleted) {
                completer.completeError(AckException(value[1]));
              }
              return;
            }
            break;
        }

        if (isProcessing) return;
        isProcessing = true;
        try {
          const int batchSizeLimit = 4096;

          while (chunkQueue.isNotEmpty) {
            int batchSize = 0;

            // Build batch WITHOUT await
            while (chunkQueue.isNotEmpty && batchSize < batchSizeLimit) {
              final chunk = chunkQueue.removeFirst();
              batchBuilder.add(chunk);
              batchSize += chunk.length;
            }

            final Uint8List batch = batchBuilder.takeBytes();

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
      final readStarted = await connection.writeToStorage(
        fileNum,
        0x11,
        offset,
        timestamp: timerStart,
      );
      if (!readStarted) throw Exception('Could not start SD card read');
      await completer.future;
    } finally {
      inactivityTimer?.cancel();
      // Ensure the firmware closes its read handle before we return (and potentially
      // try to delete the file). CMD_STOP_SYNC (0x03) forces this on the firmware.
      await connection.stopStorageSync();

      // Cancel the stream subscription so it doesn't receive the next operation's
      // ACK packets (e.g. DELETE ACK) and misinterpret them as a new read start-ACK.
      await _storageStream?.cancel();
      _storageStream = null;
    }
  }

  // Android-only: receives BLE packets natively (binder thread → file), polls
  // the output file size at 1 Hz for WAL offset tracking, and calls [callback]
  // once on completion. iOS uses the existing stream path above.
  Future _readStorageBytesToFileLockedNative(
    DeviceConnection connection,
    Wal wal,
    Function(File f, int offset, int timerStart, {String? subFolder}) callback, {
    Function(int offset)? onProgress,
    int? overrideFileNum,
  }) async {
    final fileNum = overrideFileNum ?? wal.fileNum;
    final offset = wal.walOffset;
    final timerStart = wal.timerStart;

    if (_isCancelled) throw Exception("Cancelled");

    final String subFolderPrefix = (timerStart < 946684800) ? 'session_${wal.sessionId}' : timerStart.toString();

    final directory = await getApplicationDocumentsDirectory();
    final folderPath = '${directory.path}/raw_segments/$subFolderPrefix';
    await Directory(folderPath).create(recursive: true);
    final outputPath = '$folderPath/${timerStart}_${wal.sessionId ?? 0}.bin';
    final outputFile = File(outputPath);

    // Truncate-on-resume: same guard as the stream path.
    if (offset > 0 && await outputFile.exists()) {
      try {
        final actualSize = await outputFile.length();
        if (actualSize > offset) {
          final raf = await outputFile.open(mode: FileMode.append);
          try {
            await raf.truncate(offset);
          } finally {
            await raf.close();
          }
          Logger.debug(
              'SDCardWalSync: Truncated $outputPath from $actualSize to $offset bytes (resume reconciliation)');
        }
      } catch (e) {
        Logger.error('SDCardWalSync: truncate-on-resume failed for $outputPath: $e');
      }
    }

    // _activeTransferCompleter is not used for the native path; cancellation is
    // handled by _isCancelled + poll timer calling stopStorageSync → firmware
    // stops sending → native inactivity timeout fires → downloadStorageFile throws.
    _activeTransferCompleter = null;

    final hostApi = BleHostApi();
    Timer? pollTimer;
    int lastPolledSize = offset;

    pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isCancelled) {
        pollTimer?.cancel();
        connection.stopStorageSync().catchError((_) => false);
        return;
      }
      try {
        final currentSize = outputFile.existsSync() ? outputFile.lengthSync() : lastPolledSize;
        if (currentSize > lastPolledSize) {
          lastPolledSize = currentSize;
          _lastSegmentBoundaryOffset = currentSize;
          onProgress?.call(currentSize);
        }
      } catch (_) {}
    });

    try {
      await hostApi.downloadStorageFile(
        _device!.id,
        fileNum,
        offset,
        timerStart,
        outputPath,
      );
    } finally {
      pollTimer.cancel();
      await connection.stopStorageSync();
    }

    final finalSize = outputFile.existsSync() ? await outputFile.length() : offset;
    _lastSegmentBoundaryOffset = finalSize;
    onProgress?.call(finalSize);

    if (SharedPreferencesUtil().adjustmentMode && outputFile.existsSync()) {
      try {
        final adjFolder = Directory('${directory.path}/adjustment_mode_segments/$subFolderPrefix');
        if (!await adjFolder.exists()) await adjFolder.create(recursive: true);
        await outputFile.copy('${adjFolder.path}/${timerStart}_${wal.sessionId ?? 0}.bin');
      } catch (e) {
        Logger.error('SDCardWalSync: failed to copy bin to adjustment_mode_segments: $e');
      }
    }

    await callback(outputFile, finalSize, timerStart, subFolder: subFolderPrefix);
  }

  void _completeCancelIfPending() {
    final c = _cancelCompleter;
    if (c != null && !c.isCompleted) c.complete();
    _cancelCompleter = null;
  }

  void _resetSyncState() {
    _isCancelled = false;
    _isSyncing = false;
    _totalBytesDownloaded = 0;
    _downloadStartTime = null;
    _currentSpeedKBps = 0.0;
    _cancelCompleter = null;
    _activeTransferCompleter = null;
  }

  Future<void> _checkDiskSpaceBeforeSync(int totalBytesToDownload) async {
    double? freeSpaceMb;
    try {
      freeSpaceMb = await DiskSpace.getFreeDiskSpace;
    } catch (_) {
      return; // Can't determine free space; proceed with sync.
    }
    if (freeSpaceMb != null) {
      final double requiredMb = (totalBytesToDownload * 1.1) / (1024 * 1024);
      if (freeSpaceMb < requiredMb) throw Exception("Phone Storage Full");
    }
  }

  void _updateSpeed(int bytesDownloaded) {
    _totalBytesDownloaded += bytesDownloaded;
    if (_downloadStartTime != null) {
      final elapsed = DateTime.now().difference(_downloadStartTime!).inMilliseconds / 1000.0;
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
    if (connection == null) throw DeviceConnectionException('No connection');

    // A brief non-sync storage op (e.g. refreshStorageStats when the device
    // settings page opens) can hold the lock for a second or two. Returning null
    // here reads as "no new segments" to the pipeline, which then proceeds to
    // processing as if the sync ran — so a real sync gets silently skipped. Wait a
    // bounded time for a transient holder to clear before giving up; a genuinely
    // stuck holder still skips gracefully (and acquireStorageLock below carries its
    // own 10s timeout as a backstop).
    if (connection.isStorageBusy) {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (connection.isStorageBusy && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 250));
      }
      if (connection.isStorageBusy) {
        Logger.debug('Storage busy, skipping: syncAll (lock held >3s)');
        return null;
      }
    }

    _resetSyncState();
    _isSyncing = true;

    await connection.acquireStorageLock('syncAll');
    try {
      return await _syncAllLocked(connection, dev.id, progress: progress);
    } finally {
      _isSyncing = false;
      listener.onSyncFinished();
      _completeCancelIfPending();
      connection.releaseStorageLock();
    }
  }

  Future<SyncLocalFilesResponse?> _syncAllLocked(
    DeviceConnection connection,
    String deviceId, {
    List<Wal>? prefetchedWals,
    IWalSyncProgressListener? progress,
  }) async {
    _wals = prefetchedWals ?? await _getMissingWalsLocked(connection, deviceId);
    listener.onWalUpdated();

    if (_isCancelled) return null;

    // The firmware sorts files ascending by timestamp: index 0 = oldest completed
    // recording, highest index = newest. The active TMP_ file is excluded from the
    // list entirely by the firmware, so no active-file filtering is needed here.
    final wals = _wals.where((w) {
      return w.status == WalStatus.miss && w.storage == WalStorage.sdcard;
    }).toList();

    if (wals.isEmpty) return null;

    // Ascending = oldest first.
    wals.sort((a, b) => a.fileNum.compareTo(b.fileNum));

    bool anyPartial = false;
    _downloadStartTime = DateTime.now();

    // Protocol settle delay: give firmware storage thread a moment to finish its
    // CMD_LIST_FILES cleanup (folder closing, EOT notify) before starting first read.
    await Future.delayed(const Duration(milliseconds: 200));

    bool anyDeleted = false;
    for (int i = 0; i < wals.length; i++) {
      final wal = wals[i];
      if (_isCancelled) break;

      // Abort if device disconnected between files
      if (!await connection.isConnected()) {
        Logger.debug('SDCardWalSync: Connection lost during syncAll, aborting loop');
        break;
      }

      wal.isSyncing = true;
      wal.syncStartedAt = DateTime.now();
      listener.onWalUpdated();

      final initialOffset = wal.walOffset;
      int lastOffset = initialOffset;
      _lastSegmentBoundaryOffset =
          initialOffset; // reset per-file so a failure on file[i] can't inherit file[i-1]'s offset
      await _checkDiskSpaceBeforeSync(wal.storageTotalBytes - initialOffset);

      try {
        const int maxGapRetries = 3;
        const int maxAckRetries = 3;
        const int maxStallRetries = 2;
        int gapRetries = 0;
        int ackRetries = 0;
        int stallRetries = 0;
        bool transferred = false;
        while (!transferred) {
          if (_isCancelled) throw Exception("Cancelled");
          try {
            await _readStorageBytesToFileLocked(
              connection,
              wal,
              (File file, int offset, int timerStart, {String? subFolder}) async {
                if (_isCancelled) throw Exception("Cancelled");
                listener.onWalUpdated();
              },
              onProgress: (offset) {
                _updateSpeed(offset - lastOffset);
                lastOffset = offset;
                wal.walOffset = offset;
                // Throttle persistence to ~1 Hz. onProgress fires per BLE packet
                // (~50/sec); without throttling this floods disk and logs with
                // identical writes. The truncate-on-resume guard at the start of
                // _readStorageBytesToFileLocked still bounds re-fetch on crash to
                // one persist-window of bytes (tens of KB at BLE rates). End-of-
                // file state transitions (deletion, transfer-failure, end-of-
                // sync) still persist immediately below.
                final now = DateTime.now();
                if (_lastWalPersistAt == null || now.difference(_lastWalPersistAt!) >= _walPersistInterval) {
                  _lastWalPersistAt = now;
                  WalFileManager.saveWals(_wals, deviceId: deviceId).catchError((_) => Future.value(false));
                }
                final double withinWal = (wal.storageTotalBytes > initialOffset)
                    ? (offset - initialOffset) / (wal.storageTotalBytes - initialOffset)
                    : 1.0;
                final double clamped = ((i + (withinWal.clamp(0.0, 1.0) * 0.9)) / wals.length).clamp(0.0, 1.0);
                progress?.onWalSyncedProgress(clamped, speedKBps: _currentSpeedKBps);
                _globalProgressListener?.onWalSyncedProgress(clamped, speedKBps: _currentSpeedKBps);
              },
              overrideFileNum: 0, // Always target oldest file for fast-path
            );
            transferred = true;
          } on ProtocolGapException catch (e) {
            gapRetries++;
            if (gapRetries > maxGapRetries) rethrow;
            wal.walOffset = e.incoming;
            lastOffset = e.incoming;
            _lastSegmentBoundaryOffset = e.incoming;
            await connection.stopStorageSync();
            await Future.delayed(const Duration(milliseconds: 200));
          } on AckException catch (e) {
            // ACK 7 = FILE_NOT_FOUND, often due to SD contention.
            if (e.code == 7 && ackRetries < maxAckRetries) {
              ackRetries++;
              Logger.debug(
                  'SDCardWalSync: Error ACK 7 for fileNum=${wal.fileNum}, retrying ($ackRetries/$maxAckRetries) after 500ms');
              await connection.stopStorageSync();
              await Future.delayed(const Duration(milliseconds: 500));
              continue;
            }
            rethrow;
          } catch (e) {
            if (e.toString().contains('Transfer stalled') && stallRetries < maxStallRetries) {
              stallRetries++;
              Logger.debug(
                  'SDCardWalSync: Transfer stalled for fileNum=${wal.fileNum}, retrying ($stallRetries/$maxStallRetries) after 1s');
              await connection.stopStorageSync();
              await Future.delayed(const Duration(seconds: 1));
              continue;
            }
            rethrow;
          }
        }

        if (_isCancelled) throw Exception("Cancelled");

        // Completeness guard. The firmware advertised wal.storageTotalBytes for this
        // file in CMD_LIST_FILES, but a transfer can "complete" (clean EOT / the
        // native download returns) having delivered FEWER bytes — e.g. the firmware
        // sent an empty EOT for a file whose cached size went stale after a rotation,
        // returned res=0 / 0-bytes when the file rotated under the read handle, or hit
        // a mid-file read error (see storage.c / sd_card.c). wal.walOffset now holds
        // the bytes actually written to the local file (the native path sets it from
        // the on-disk size). Marking such a short read "synced" and deleting the
        // device-side copy turns a transient read glitch into PERMANENT data loss —
        // this is exactly how a Priority Recording vanished (device had 468 KB, the
        // read returned ~0, the file was deleted). Only accept + delete when the whole
        // file arrived; otherwise leave it as `miss` so the next sync retries. The
        // device copy is immutable until we send CMD_DELETE_FILE, so the retry is safe.
        if (wal.storageTotalBytes > 0 && wal.walOffset < wal.storageTotalBytes) {
          // Forward-progress guard on the poison-file drop. A short read that still
          // ADVANCED the byte offset this attempt is a file that IS transferring —
          // just interrupted (background BLE throttling, a mid-transfer link drop like
          // "Stream closed without EOT"). It is NOT a genuinely unreadable file stuck
          // at a byte the firmware can't deliver. The drop below ACCEPTS DATA LOSS to
          // unblock the head of the queue; letting a *progressing* file accrue strikes
          // toward it would delete a large recording mid-transfer and lose it for good,
          // even though the very next sync would finish it (e.g. a 3 MB file that only
          // syncs cleanly in the foreground could hit 5 background-throttled short reads
          // first). So only a read that fails to advance past where it resumed counts
          // as a strike; any forward progress resets the count. initialOffset is this
          // attempt's resume point, captured before the read above.
          final bool madeProgress = wal.walOffset > initialOffset;
          if (madeProgress) {
            wal.syncFailCount = 0;
          } else {
            wal.syncFailCount += 1;
          }
          wal.status = WalStatus.miss;
          wal.isSyncing = false;
          listener.onWalUpdated();
          anyPartial = true;

          if (wal.syncFailCount >= _maxSyncFailBeforeDrop) {
            // Poison file: it has read short on every attempt. The fast path can only
            // read/delete index 0, so a file stuck at the head blocks the whole queue.
            // Delete it to unblock — this ACCEPTS THE LOSS of this one file so newer
            // recordings can keep syncing. Logged loudly so the loss is visible.
            Logger.error('SDCardWalSync: ts=${wal.timerStart} still incomplete '
                '(${wal.walOffset}/${wal.storageTotalBytes} B) after ${wal.syncFailCount} attempts — '
                'deleting to unblock sync (DATA LOST for this file)');
            bool deleted = false;
            try {
              await _deleteWalLocked(connection, wal, overrideFileNum: 0, skipSave: true);
              anyDeleted = true;
              deleted = true;
              await Future.delayed(const Duration(milliseconds: 200));
            } catch (e) {
              Logger.error('SDCardWalSync: poison-file deletion failed for ts=${wal.timerStart}: $e');
            }
            WalFileManager.saveWals(_wals, deviceId: deviceId).catchError((_) => Future.value(false));
            // Only advance the snapshot loop when the head was actually removed. The
            // fast path targets index 0, so continuing while the head is still present
            // would operate on it with the NEXT WAL's identity (timestamp/offset). On a
            // failed delete, break so the next cycle re-enumerates before touching index 0.
            if (deleted) continue;
            break;
          }

          Logger.error('SDCardWalSync: incomplete transfer for ts=${wal.timerStart} '
              '(${wal.walOffset}/${wal.storageTotalBytes} B), '
              '${madeProgress ? 'made progress from $initialOffset — strikes reset' : 'no progress'}, '
              'strike ${wal.syncFailCount}/$_maxSyncFailBeforeDrop — NOT deleting; retrying on the next sync');
          WalFileManager.saveWals(_wals, deviceId: deviceId).catchError((_) => Future.value(false));
          // The fast path only ever reads index 0, so we can't skip past this file
          // without deleting it. Stop here; the next sync cycle re-lists and retries
          // from the head (giving the firmware time to settle after the rotation).
          break;
        }

        // Full file received — clear any prior short-read strikes and finalize.
        wal.syncFailCount = 0;
        wal.status = WalStatus.synced;
        wal.isSyncing = false;
        listener.onWalUpdated();

        // Diagnostic: a bin the DEVICE itself advertised as 0 bytes in CMD_LIST_FILES
        // means the firmware opened+rotated the file but never persisted a single
        // frame into it. That is the signature of a lost Priority Recording — the
        // 0xFFFFFFF8 start marker and its force-captured audio were dropped at the
        // rotation, so an empty bin rotates through here and is deleted as "synced".
        // Surface it loudly so this is traceable from the app log alone, with no
        // RTT/serial capture. storageTotalBytes = device-advertised size; walOffset =
        // bytes actually received (both ~0 here → the loss is on-device, not in transit).
        if (wal.storageTotalBytes == 0) {
          Logger.warning('SDCardWalSync: ts=${wal.timerStart} synced EMPTY — device advertised 0 B '
              '(firmware wrote nothing to this bin; a lost priority marker/recording rotates through here)');
        }

        // Delete immediately so a disconnect won't re-sync this file next session.
        try {
          await _deleteWalLocked(connection, wal, overrideFileNum: 0, skipSave: true);
          anyDeleted = true;
          // Settle delay: give the SD worker time to finish metadata updates before requesting next file
          await Future.delayed(const Duration(milliseconds: 200));
        } catch (e) {
          Logger.error('SDCardWalSync: deletion failed for index=0 after transfer: $e');
          anyPartial = true;
        }

        final double fileDone = ((i + 1.0) / wals.length).clamp(0.0, 1.0);
        progress?.onWalSyncedProgress(fileDone, speedKBps: _currentSpeedKBps);
        _globalProgressListener?.onWalSyncedProgress(fileDone, speedKBps: _currentSpeedKBps);
      } catch (e) {
        Logger.error('SDCardWalSync: transfer failed for fileNum=${wal.fileNum} ts=${wal.timerStart}: $e');
        wal.walOffset = _lastSegmentBoundaryOffset;
        wal.status = WalStatus.miss;
        wal.isSyncing = false;
        listener.onWalUpdated();
        // Persist the partial offset so the next session resumes from where we stopped.
        WalFileManager.saveWals(_wals, deviceId: deviceId).catchError((_) => Future.value(false));
        anyPartial = true;

        if (_isCancelled) break;

        // Give a small window for connection state to update in the provider/service
        await Future.delayed(const Duration(milliseconds: 100));
        if (!await connection.isConnected()) {
          Logger.debug('SDCardWalSync: Connection lost after failure, aborting syncAll');
          break;
        }

        // Re-check cancellation after the awaits above: cancelSync() may have set
        // _isCancelled during the delay / isConnected() window. Bail before the
        // poison-budget logic so an in-flight user cancel neither spends a strike (a
        // cancellation isn't the file's fault) nor deletes a recording.
        if (_isCancelled) break;

        // A DEFINITE transport/GATT error (op timeout, missing characteristic, mid-
        // download drop) is a wedged (connected-but-dead) GATT — the ACL link is up so
        // the isConnected() check above doesn't catch it, but GATT ops are dead. It is
        // NOT this file's fault, so charging the per-file poison budget for it would
        // delete a good recording. Recycle the link so the next cycle rides a FRESH GATT
        // instead of hammering the wedge, and abort the batch WITHOUT a strike (the
        // persisted offset resumes this file next cycle). An ambiguous 15s "Transfer
        // stalled" is intentionally NOT treated here: it may be a single unreadable file
        // (must still drop via the budget below to unblock the head), and a link-wide
        // stall wedge is already recovered by the pipeline stall watchdog, which recycles.
        final errStr = e.toString();
        final bool definiteTransportError = e is TimeoutException ||
            errStr.contains('Future not completed') ||
            errStr.contains('Stream closed without EOT') ||
            errStr.contains('Not found') ||
            errStr.contains('Characteristic not available');
        if (definiteTransportError) {
          // _connectionProvider != null only in tests, which have no real DeviceService.
          if (_connectionProvider == null) {
            Logger.warning('SDCardWalSync: transfer failed with a transport-wedge signal ($e) — '
                'recycling connection, not charging file ts=${wal.timerStart}');
            unawaited(ServiceManager.instance().device.recycleConnection());
          }
          break;
        }

        // Poison budget for THROWN terminal failures (a genuine per-file error, not the
        // cancel/disconnect/transport cases handled above). The clean-but-short guard
        // increments syncFailCount; a file that instead consistently THROWS after
        // exhausting the inner retries (ACK error, protocol gap, stall) would otherwise
        // never reach the drop threshold — and since the fast path can't get past a bad
        // index-0 head (a fatal ACK 7 even breaks the whole batch), it could block every
        // newer recording forever. An attempt that made forward progress is a healthy
        // slow/large transfer resuming (reset strikes); one that made none counts toward
        // the budget, and once exhausted the file is dropped to unblock the queue.
        if (_lastSegmentBoundaryOffset > initialOffset) {
          wal.syncFailCount = 0;
        } else {
          wal.syncFailCount += 1;
        }
        WalFileManager.saveWals(_wals, deviceId: deviceId).catchError((_) => Future.value(false));
        if (wal.syncFailCount >= _maxSyncFailBeforeDrop) {
          Logger.error('SDCardWalSync: ts=${wal.timerStart} unreadable (throwing) after '
              '${wal.syncFailCount} attempts — deleting to unblock sync (DATA LOST for this file)');
          try {
            await _deleteWalLocked(connection, wal, overrideFileNum: 0, skipSave: true);
            anyDeleted = true;
          } catch (delErr) {
            Logger.error('SDCardWalSync: poison-file deletion failed for ts=${wal.timerStart}: $delErr');
          }
          // Re-enumerate next cycle before operating on index 0 again (whether or not
          // the delete succeeded — a failed delete leaves the same head in place).
          break;
        }

        // Fatal errors (ACK 7, "could not start SD card read") stop the batch — continuing
        // after these is unlikely to succeed.
        if (errStr.contains('Error ACK: 7') || errStr.contains('Could not start SD card read')) {
          Logger.debug('SDCardWalSync: Fatal error, stopping batch sync');
          break;
        }

        // After a stall failure (after retries), try the next file if it was just one bad
        // file, but if we've had too many failures, abort the batch. A link-wide stall
        // wedge (rather than one bad file) is caught by the pipeline stall watchdog, which
        // recycles the connection.
        if (errStr.contains('Transfer stalled')) {
          Logger.debug('SDCardWalSync: Transfer stalled after retries, skipping this file.');
        }
      }
    }

    // Persist the trimmed WAL list only when something was actually deleted,
    // but always refresh storage stats so File Count / Free Space stay current
    // even on transfer-only or all-failed cycles.
    if (anyDeleted) {
      await WalFileManager.saveWals(_wals, deviceId: deviceId).catchError((_) => Future.value(false));
    }
    await _updateStorageStatsLocked(connection);

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
    if (connection == null) throw DeviceConnectionException('No connection');

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
      listener.onSyncFinished();
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
    _lastSegmentBoundaryOffset = initialOffset;
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
              listener.onWalUpdated();
            },
            onProgress: (offset) {
              _updateSpeed(offset - lastOffset);
              lastOffset = offset;
              wal.walOffset = offset;
              final double progressPercent = (wal.storageTotalBytes > initialOffset)
                  ? (offset - initialOffset) / (wal.storageTotalBytes - initialOffset)
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
        } on ProtocolGapException catch (e) {
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

      // Completeness guard, mirroring _syncAllLocked: a transfer can "complete"
      // (clean EOT) having delivered fewer bytes than the device advertised in
      // CMD_LIST_FILES — an empty/short read after a rotation, etc. Deleting the
      // device-side file on a short read is permanent data loss, so only delete when
      // the whole file arrived; otherwise leave the WAL `miss` so a later sync retries
      // (the device copy is immutable until CMD_DELETE_FILE, so the retry is safe).
      // Unlike the fast path there is no index-0 queue to unblock here, so no
      // poison-drop — just skip the delete and report the sync as partial.
      if (wal.storageTotalBytes > 0 && wal.walOffset < wal.storageTotalBytes) {
        wal.syncFailCount += 1;
        wal.status = WalStatus.miss;
        wal.isSyncing = false;
        listener.onWalUpdated();
        Logger.error('SDCardWalSync: syncWal incomplete for ts=${wal.timerStart} '
            '(${wal.walOffset}/${wal.storageTotalBytes} B) — NOT deleting; leaving on device to retry');
        // Persist the strike + offset (onWalUpdated is only a notification) so the
        // failure count survives a refresh/restart. Awaited (unlike the batch loop's
        // throttled fire-and-forget saves) because this is a single terminal op that
        // returns right after — the write must land before we hand back. The success
        // path persists via _deleteWalLocked.
        await WalFileManager.saveWals(_wals, deviceId: wal.device).catchError((_) => Future.value(false));
        return SyncLocalFilesResponse(
          newConversationIds: [],
          updatedConversationIds: [],
          isPartial: true,
        );
      }

      wal.syncFailCount = 0;
      await _deleteWalLocked(connection, wal);
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
    if (connection == null) throw DeviceConnectionException('No connection');

    if (connection.isStorageBusy) {
      Logger.debug('Storage busy, skipping: rotateAndSync');
      return null;
    }

    _resetSyncState();
    _isSyncing = true;

    await connection.acquireStorageLock('rotateAndSync');
    try {
      if (_isCancelled) return null;

      bool rotated = false;
      for (int i = 0; i < 3; i++) {
        if (_isCancelled) return null;
        rotated = await connection.rotateFile();
        if (rotated) break;
        Logger.warning('Rotation failed, retrying in 2 seconds...');
        await Future.delayed(const Duration(seconds: 2));
      }
      if (!rotated) throw Exception('Rotation failed');

      final wals = await _buildWalsFromFilesLocked(connection, dev.id);

      if (_isCancelled) return null;

      return await _syncAllLocked(connection, dev.id, prefetchedWals: wals, progress: progress);
    } finally {
      _isSyncing = false;
      listener.onSyncFinished();
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
