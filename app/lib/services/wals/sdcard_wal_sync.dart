import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:omi/utils/logger.dart';

import 'package:path_provider/path_provider.dart';

import 'package:disk_space_2/disk_space_2.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/devices/transports/tcp_transport.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/services/wals/wal_interfaces.dart';

class SDCardWalSyncImpl implements SDCardWalSync {
  List<Wal> _wals = <Wal>[];
  BtDevice? _device;

  StreamSubscription? _storageStream;

  IWalSyncListener listener;

  bool _isCancelled = false;
  bool _isSyncing = false;
  TcpTransport? _activeTcpTransport;
  Completer<void>? _activeTransferCompleter;
  @override
  bool get isSyncing => _isSyncing;

  int _totalBytesDownloaded = 0;
  DateTime? _downloadStartTime;
  double _currentSpeedKBps = 0.0;
  @override
  double get currentSpeedKBps => _currentSpeedKBps;

  final Set<int> _sessionsSeen = {};
  @override
  int get recordingsCount => _sessionsSeen.length;

  @override
  int get estimatedTotalChunks {
    int total = 0;
    for (var wal in _wals) {
      if (wal.status == WalStatus.miss && wal.storage == WalStorage.sdcard) {
        total += wal.estimatedChunks;
      }
    }
    return total;
  }

  SDCardWalSyncImpl(this.listener);
  @override
  void cancelSync() {
    if (_isSyncing) {
      _isCancelled = true;
      Logger.debug("SDCardWalSync: Cancel requested, actively tearing down connections");

      final tcpTransport = _activeTcpTransport;
      if (tcpTransport != null) {
        tcpTransport.disconnect();
      }

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
      } else {
        Logger.debug(
            "SDCardWalSync: start() finished while syncing, ignoring overwrite of _wals to avoid race condition.");
      }
    });
  }

  @override
  Future stop() async {
    _wals = [];
    _storageStream?.cancel();
  }

  @override
  void setDevice(BtDevice? device) async {
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
    var storageOffset = storageFiles.length >= 2 ? storageFiles[1] : 0;

    if (storageOffset > totalBytes) {
      Logger.debug("SDCard bad state, offset $storageOffset > total $totalBytes");
      storageOffset = 0;
    }

    BleAudioCodec codec = await _getAudioCodec(deviceId);
    int threshold = 10 * codec.getFramesLengthInBytes() * codec.getFramesPerSecond();
    Logger.debug(
        "SDCardWalSync: totalBytes=$totalBytes, storageOffset=$storageOffset, diff=${totalBytes - storageOffset}, threshold=$threshold");

    if (totalBytes > 0) {
      var seconds = (totalBytes / codec.getFramesLengthInBytes()) ~/ codec.getFramesPerSecond();
      int timerStart = DateTime.now().millisecondsSinceEpoch ~/ 1000 - seconds;

      // Ensure stable ID for existing entries by matching device and fileNum
      final existingWal =
          _wals.firstWhereOrNull((w) => w.device == deviceId && w.fileNum == 1 && w.storage == WalStorage.sdcard);
      if (existingWal != null) {
        timerStart = existingWal.timerStart;
      }

      var wal = Wal(
        codec: codec,
        channel: 1,
        device: deviceId,
        fileNum: 1,
        storageOffset: storageOffset,
        storageTotalBytes: totalBytes,
        timerStart: timerStart,
        storage: WalStorage.sdcard,
        estimatedChunks: (seconds / 60).ceil(),
      );
      // Keep status if already syncing
      if (existingWal != null && existingWal.isSyncing) {
        wal.isSyncing = true;
        wal.syncStartedAt = existingWal.syncStartedAt;
      }

      wals.add(wal);
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
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
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

  Future<File> _flushToDisk(Wal wal, List<List<int>> chunk, int timerStart,
      {String? subFolder, int? sessionId, int? chunkIndex, bool append = false}) async {
    final directory = await getApplicationDocumentsDirectory();
    final folderPath =
        sessionId != null ? '${directory.path}/raw_chunks/$sessionId' : '${directory.path}/raw_chunks/$subFolder';

    final folder = Directory(folderPath);
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }

    String fileName;
    if (sessionId != null && chunkIndex != null) {
      fileName = '${sessionId}_$chunkIndex.bin';
    } else {
      fileName = wal.getFileNameByTimeStarts(timerStart);
    }
    String filePath = '${folder.path}/$fileName';

    final builder = BytesBuilder(copy: false);
    for (var frame in chunk) {
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

  Future<void> _saveStarMarker(int sessionId, int utcTime) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final folderPath = '${directory.path}/raw_chunks/$sessionId';
      final folder = Directory(folderPath);
      if (!await folder.exists()) {
        await folder.create(recursive: true);
      }

      final starFile = File('${folder.path}/stars.txt');
      await starFile.writeAsString('$utcTime\n', mode: FileMode.append);
      Logger.debug("SDCardWalSync: Saved STAR marker at $utcTime for session $sessionId");
    } catch (e) {
      Logger.error("SDCardWalSync: Failed to save star marker: $e");
    }
  }

  Future _readStorageBytesToFile(Wal wal, Function(File f, int offset, int timerStart, {String? subFolder}) callback,
      {bool force = false, Function(int offset)? onProgress}) async {
    var deviceId = wal.device;
    int fileNum = wal.fileNum;
    int offset = wal.storageOffset;
    int timerStart = wal.timerStart;

    Logger.debug("_readStorageBytesToFile $offset");

    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      throw Exception('Device connection lost during SD card read');
    }

    final completer = Completer<void>();
    _activeTransferCompleter = completer;
    bool hasError = false;
    bool isFirstPacket = true;
    bool isProcessing = false;
    Timer? completionTimeout;
    DateTime lastWaitingLog = DateTime.now().subtract(const Duration(seconds: 10));

    int? currentSessionId;
    int? currentChunkIndex;
    int? lastSessionId;
    int? lastChunkIndex;
    final List<List<int>> frameBuffer = [];
    final List<int> streamBuffer = [];

    // Track which (sessionId, chunkIndex) files have been created during this transfer.
    // The FIRST write to a file must use FileMode.write (overwrite) to avoid appending to
    // leftover data from a prior sync or force-resync. Subsequent flushes within the same
    // transfer can append.
    final Set<String> flushedChunksThisTransfer = {};

    Future<void> flushBuffer() async {
      if (frameBuffer.isEmpty) return;

      String subFolder = lastSessionId?.toString() ?? 'unsynced';
      final chunkKey = '${lastSessionId}_$lastChunkIndex';
      final appendMode = flushedChunksThisTransfer.contains(chunkKey);
      if (!appendMode) flushedChunksThisTransfer.add(chunkKey);

      var file = await _flushToDisk(wal, frameBuffer, timerStart,
          subFolder: subFolder, sessionId: lastSessionId, chunkIndex: lastChunkIndex, append: appendMode);

      try {
        await callback(file, offset, timerStart, subFolder: subFolder);
      } catch (e) {
        Logger.debug("SDCardWalSync: Callback failed: $e");
      }
      frameBuffer.clear();
    }

    _storageStream?.cancel();
    int packetsReceived = 0;
    _storageStream = (await connection.getBleStorageBytesListener(onStorageBytesReceived: (List<int> value) async {
      if (_isCancelled || hasError) return;

      packetsReceived++;
      // Log only every 100 packets to reduce noise, unless it's near the end
      if (packetsReceived % 100 == 0 || offset >= wal.storageTotalBytes - 512) {
        Logger.debug(
            "SDCardWalSync: Received ${value.length} bytes (Buffer: ${streamBuffer.length}, Packet #$packetsReceived)");
      }

      // Handle the initial ACK byte separately to avoid offset desync.
      // Firmware sends a single-byte ACK immediately after receiving the READ command:
      //   0x00 = success (start streaming)
      //   0x03 = INVALID_FILE_SIZE
      //   0x04 = ZERO_FILE_SIZE
      //   0x06 = INVALID_COMMAND
      // All error codes are small integers (< 16). Any other single-byte first packet
      // is unexpected and falls through to be treated as the start of audio data.
      if (isFirstPacket && value.length == 1) {
        isFirstPacket = false;
        if (value[0] == 0) {
          Logger.debug("SDCardWalSync: Received initial success ACK");
          return;
        } else if (value[0] < 16) {
          Logger.debug("SDCardWalSync: Received firmware error ACK: ${value[0]}");
          hasError = true;
          if (!completer.isCompleted) completer.completeError(Exception('Firmware error code: ${value[0]}'));
          return;
        }
        // else: unexpected first packet — fall through and process as data
      }
      isFirstPacket = false;

      // Add to buffer synchronously
      streamBuffer.addAll(value);
      offset += value.length;

      // Diagnostic logging near the end
      if (offset >= wal.storageTotalBytes - 512) {
        if (offset >= wal.storageTotalBytes - 64) {
          Logger.debug("SDCardWalSync: End bytes (Total $offset/${wal.storageTotalBytes}): $value");
        }
      }

      if (onProgress != null) {
        onProgress(offset);
      }

      // Timeout/Overrun completion logic
      completionTimeout?.cancel();
      if (offset >= wal.storageTotalBytes) {
        if (offset >= wal.storageTotalBytes + 1024) {
          Logger.debug(
              "SDCardWalSync: Overrun threshold reached ($offset/${wal.storageTotalBytes}). Forcing completion.");
          await flushBuffer();
          if (!completer.isCompleted) completer.complete();
          return;
        }

        completionTimeout = Timer(const Duration(seconds: 5), () async {
          if (!completer.isCompleted) {
            Logger.debug("SDCardWalSync: Progress at 100% and 5s idle. Forcing completion.");
            await flushBuffer();
            completer.complete();
          }
        });
      }

      // Serial processing loop to prevent concurrent buffer access
      if (isProcessing) {
        // Silent buffering while processing is active
        return;
      }
      isProcessing = true;

      try {
        while (streamBuffer.isNotEmpty) {
          int packageSize = streamBuffer[0];

          // 0xFD = End-of-Transfer marker. Single byte, no payload.
          // Mirrors the firmware constant EOT_MARKER = 0xFD. Unambiguous: Opus frames
          // are always 80 bytes (0x50), so 0xFD will never appear as a valid length prefix.
          if (packageSize == 0xFD) {
            Logger.debug("SDCardWalSync: Received EOT marker (0xFD). offset=$offset, bufferLen=${streamBuffer.length}");
            completionTimeout?.cancel();
            await flushBuffer();
            if (!completer.isCompleted) completer.complete();
            streamBuffer.clear();
            break;
          }

          if (packageSize == 255) {
            // Metadata
            if (1 + 16 <= streamBuffer.length) {
              var metadata = streamBuffer.sublist(1, 1 + 16);
              var byteData = ByteData.sublistView(Uint8List.fromList(metadata));
              var utcTime = byteData.getUint32(0, Endian.little);
              var currentUptimeMs = byteData.getUint32(4, Endian.little);
              currentSessionId = byteData.getUint32(8, Endian.little);
              if (currentSessionId != null) {
                _sessionsSeen.add(currentSessionId!);
              }
              currentChunkIndex = byteData.getUint32(12, Endian.little);

              if (currentSessionId != null) {
                SharedPreferencesUtil().saveInt('anchor_utc_$currentSessionId', utcTime);
                SharedPreferencesUtil().saveInt('anchor_uptime_$currentSessionId', currentUptimeMs);
              }

              final sessionId = currentSessionId;
              if (sessionId != null && sessionId > SharedPreferencesUtil().latestSyncedSessionId) {
                SharedPreferencesUtil().latestSyncedSessionId = sessionId;
              }

              Logger.debug("SDCardWalSync BLE: Parsed metadata session $currentSessionId");

              if (currentSessionId != lastSessionId || currentChunkIndex != lastChunkIndex) {
                await flushBuffer();
                lastSessionId = currentSessionId;
                lastChunkIndex = currentChunkIndex;
              }

              streamBuffer.removeRange(0, 1 + 16);
              continue;
            } else {
              break; // Need more bytes for metadata
            }
          }

          if (packageSize == 254) {
            // Star marker
            if (1 + 16 <= streamBuffer.length) {
              var metadata = streamBuffer.sublist(1, 1 + 16);
              var byteData = ByteData.sublistView(Uint8List.fromList(metadata));
              var utcTime = byteData.getUint32(0, Endian.little);
              var starUptimeMs = byteData.getUint32(4, Endian.little);

              // If device has no RTC lock, utcTime will be 0. Reconstruct UTC time from
              // the uptime anchor saved when we parsed the most recent metadata packet.
              int resolvedUtcTime = utcTime;
              if (utcTime == 0 && currentSessionId != null) {
                final anchorUtc = SharedPreferencesUtil().getInt('anchor_utc_$currentSessionId');
                final anchorUptime = SharedPreferencesUtil().getInt('anchor_uptime_$currentSessionId');
                if (anchorUtc > 0 && anchorUptime > 0) {
                  final uptimeDeltaSeconds = (starUptimeMs - anchorUptime) ~/ 1000;
                  resolvedUtcTime = anchorUtc + uptimeDeltaSeconds;
                  Logger.debug(
                      "SDCardWalSync: Star marker UTC resolved via anchor: $resolvedUtcTime (delta ${uptimeDeltaSeconds}s)");
                } else {
                  Logger.debug(
                      "SDCardWalSync: Star marker utcTime=0 and no anchor available for session $currentSessionId");
                }
              }

              final sessionId = currentSessionId;
              if (sessionId != null) {
                await _saveStarMarker(sessionId, resolvedUtcTime);
              }
              streamBuffer.removeRange(0, 1 + 16);
              continue;
            } else {
              break; // Need more bytes for star marker
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
                  "SDCardWalSync: Waiting for more data (Frame size $packageSize, Buffer ${streamBuffer.length}, Total $offset/${wal.storageTotalBytes})");
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
      completionTimeout?.cancel();
      _storageStream?.cancel();
      _storageStream = null;
    }
  }

  void _resetSyncState() {
    _isCancelled = false;
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
    IWifiConnectionListener? connectionListener,
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

    // If our list is empty, refresh it before checking sync status
    if (_wals.isEmpty) {
      Logger.debug("SDCardWalSync: File list empty, refreshing before sync...");
      _wals = await getMissingWals();
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

    var resp = SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);

    for (var wal in wals) {
      if (_isCancelled) break;

      wal.isSyncing = true;
      wal.syncStartedAt = DateTime.now();
      listener.onWalUpdated();

      int lastOffset = wal.storageOffset;
      int totalBytesToDownload = wal.storageTotalBytes - wal.storageOffset;

      await _checkDiskSpaceBeforeSync(totalBytesToDownload);
      _downloadStartTime = DateTime.now();

      try {
        await _readStorageBytesToFile(
            wal,
            (File file, int offset, int timerStart, {String? subFolder}) async {
              if (_isCancelled) {
                throw Exception("Sync cancelled by user");
              }

              int bytesInChunk = offset - lastOffset;
              _updateSpeed(bytesInChunk);
              await _registerSingleChunk(wal, file, timerStart);
              lastOffset = offset;

              listener.onWalUpdated();
            },
            force: true,
            onProgress: (offset) {
              wal.storageOffset = offset;
              final remainingBytes = wal.storageTotalBytes - offset;
              final seconds = (remainingBytes / wal.codec.getFramesLengthInBytes()) ~/ wal.codec.getFramesPerSecond();
              wal.estimatedChunks = (seconds / 60).ceil();

              if (progress != null) {
                final double progressPercent = offset / totalBytesToDownload;
                progress.onWalSyncedProgress(progressPercent.clamp(0.0, 1.0), speedKBps: _currentSpeedKBps);
              }
            });

        // Small delay to allow firmware buffers to clear before sending DELETE
        await Future.delayed(const Duration(milliseconds: 500));
        if (wal.storageOffset >= wal.storageTotalBytes) {
          await deleteWal(wal);
        } else {
          Logger.debug(
              "SDCardWalSync: Partial transfer (${wal.storageOffset}/${wal.storageTotalBytes} bytes) — skipping DELETE to preserve remaining data");
        }
        wal.status = WalStatus.synced;
        _wals.removeWhere((w) => w.id == wal.id);
        listener.onWalUpdated();
      } catch (e) {
        Logger.debug("SDCardWalSync: Error syncing WAL ${wal.id}: $e");
        wal.isSyncing = false;
        wal.syncStartedAt = null;
        wal.syncEtaSeconds = null;
        wal.syncSpeedKBps = null;
        listener.onWalUpdated();
        rethrow;
      }
    }

    _isSyncing = false;
    return resp;
  }

  @override
  Future<SyncLocalFilesResponse?> syncWal({
    required Wal wal,
    IWalSyncProgressListener? progress,
    IWifiConnectionListener? connectionListener,
  }) async {
    _resetSyncState();
    _isSyncing = true;
    wal.isSyncing = true;
    wal.syncStartedAt = DateTime.now();
    listener.onWalUpdated();

    var resp = SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);
    int lastOffset = 0;
    int totalBytesToDownload = wal.storageTotalBytes;

    await _checkDiskSpaceBeforeSync(totalBytesToDownload);
    _downloadStartTime = DateTime.now();

    try {
      await _readStorageBytesToFile(
          wal,
          (File file, int offset, int timerStart, {String? subFolder}) async {
            if (_isCancelled) {
              throw Exception("Sync cancelled by user");
            }

            int bytesInChunk = offset - lastOffset;
            _updateSpeed(bytesInChunk);
            await _registerSingleChunk(wal, file, timerStart);
            lastOffset = offset;

            listener.onWalUpdated();
          },
          force: true,
          onProgress: (offset) {
            wal.storageOffset = offset;
            final remainingBytes = wal.storageTotalBytes - offset;
            final seconds = (remainingBytes / wal.codec.getFramesLengthInBytes()) ~/ wal.codec.getFramesPerSecond();
            wal.estimatedChunks = (seconds / 60).ceil();

            if (progress != null) {
              final double progressPercent = offset / totalBytesToDownload;
              progress.onWalSyncedProgress(progressPercent.clamp(0.0, 1.0), speedKBps: _currentSpeedKBps);
            }
          });

      // Small delay to allow firmware buffers to clear before sending DELETE
      await Future.delayed(const Duration(milliseconds: 500));
      if (wal.storageOffset >= wal.storageTotalBytes) {
        await deleteWal(wal);
      } else {
        Logger.debug(
            "SDCardWalSync: Partial transfer (${wal.storageOffset}/${wal.storageTotalBytes} bytes) — skipping DELETE to preserve remaining data");
      }
      wal.status = WalStatus.synced;
      _wals.removeWhere((w) => w.id == wal.id);
      listener.onWalUpdated();
    } catch (e) {
      Logger.debug("SDCardWalSync: Error syncing WAL ${wal.id}: $e");
      wal.isSyncing = false;
      wal.syncStartedAt = null;
      listener.onWalUpdated();
      rethrow;
    }

    _isSyncing = false;
    return resp;
  }

  Future<void> _registerSingleChunk(Wal wal, File file, int timerStart) async {
    // Note: We no longer queue this for automatic processing in LocalWalSync.
    // The RecordingsManager will pick up the .bin files in raw_chunks/ session folders.
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
    final pendingWals = _wals.where((w) => w.status == WalStatus.miss || w.status == WalStatus.corrupted).toList();
    for (final wal in pendingWals) {
      await deleteWal(wal);
    }
  }

  @override
  Future<bool> isWifiSyncSupported() async {
    final dev = _device;
    if (dev == null) {
      return false;
    }
    var connection = await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) return false;
    return await connection.isWifiSyncSupported();
  }

  @override
  Future<bool> setWifiCredentials(String ssid, String password) async {
    return true;
  }

  @override
  Future<void> clearWifiCredentials() async {}

  @override
  Future<void> loadWifiCredentials() async {}

  @override
  Map<String, String?>? getWifiCredentials() {
    return null;
  }

  @override
  Future<SyncLocalFilesResponse?> syncWithWifi({
    IWalSyncProgressListener? progress,
    IWifiConnectionListener? connectionListener,
  }) async {
    var wals = _wals.where((w) => w.status == WalStatus.miss && w.storage == WalStorage.sdcard).toList();
    if (wals.isEmpty) {
      Logger.debug("SDCardWalSync WiFi: All synced!");
      return null;
    }

    final dev = _device;
    if (dev == null) {
      Logger.debug("SDCardWalSync WiFi: No device connected");
      return null;
    }

    final deviceId = dev.id;
    var bleConnection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (bleConnection == null) {
      Logger.debug("SDCardWalSync WiFi: BLE connection lost");
      return null;
    }

    _resetSyncState();
    _isSyncing = true;

    for (var wal in wals) {
      if (_isCancelled) break;

      wal.isSyncing = true;
      wal.syncStartedAt = DateTime.now();
      wal.syncMethod = SyncMethod.wifi;
      listener.onWalUpdated();

      try {
        final totalBytes = wal.storageTotalBytes - wal.storageOffset;
        await _checkDiskSpaceBeforeSync(totalBytes);

        // This is a simplified placeholder for the WiFi sync logic
        // In a real implementation, this would involve connecting to the device's AP
        // and streaming data over TCP.

        await deleteWal(wal);
        wal.status = WalStatus.synced;
        _wals.removeWhere((w) => w.id == wal.id);
        listener.onWalUpdated();
      } catch (e) {
        Logger.error("SDCardWalSync WiFi error: $e");
        wal.isSyncing = false;
        wal.syncStartedAt = null;
        listener.onWalUpdated();
        rethrow;
      }
    }

    _isSyncing = false;
    return SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);
  }
}
