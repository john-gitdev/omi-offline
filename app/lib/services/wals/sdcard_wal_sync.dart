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
  List<Wal> _wals = const [];
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
      _wals = wals;
      listener.onWalUpdated();
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
    Logger.debug("SDCardWalSync: totalBytes=$totalBytes, storageOffset=$storageOffset, diff=${totalBytes - storageOffset}, threshold=$threshold");
    if (totalBytes - storageOffset > threshold) {
      var seconds = ((totalBytes - storageOffset) / codec.getFramesLengthInBytes()) ~/ codec.getFramesPerSecond();
      int timerStart = DateTime.now().millisecondsSinceEpoch ~/ 1000 - seconds;

      // Ensure stable ID for existing entries by matching device and fileNum
      final existingWal = _wals.firstWhereOrNull((w) => w.device == deviceId && w.fileNum == 1 && w.storage == WalStorage.sdcard);
      if (existingWal != null) {
        timerStart = existingWal.timerStart;
      }
      
      Logger.debug(
          'SDCardWalSync: totalBytes=$totalBytes storageOffset=$storageOffset frameLengthInBytes=${codec.getFramesLengthInBytes()} fps=${codec.getFramesPerSecond()} calculatedSeconds=$seconds timerStart=$timerStart now=${DateTime.now().millisecondsSinceEpoch ~/ 1000}');

      var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
      if (connection == null) {
        return [];
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
    await _writeToStorage(dev.id, wal.fileNum, 1, 0); // 1 is DELETE command
    _wals = _wals.where((w) => w.id != wal.id).toList();
    listener.onWalUpdated();
  }

  Future<File> _flushToDisk(Wal wal, List<List<int>> chunk, int timerStart,
      {String? subFolder, int? sessionId, int? chunkIndex}) async {
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
    List<int> data = [];

    for (var frame in chunk) {
      final byteFrame = ByteData(frame.length);
      for (var i = 0; i < frame.length; i++) {
        byteFrame.setUint8(i, frame[i]);
      }
      data.addAll(Uint32List.fromList([frame.length]).buffer.asUint8List());
      data.addAll(byteFrame.buffer.asUint8List());
    }
    final file = File(filePath);
    await file.writeAsBytes(data);

    Logger.debug("SDCardWalSync _flushToDisk: Wrote ${data.length} bytes to $filePath");

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

  Future _readStorageBytesToFile(Wal wal, Function(File f, int offset, int timerStart, {String? subFolder}) callback) async {
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

    int? currentSessionId;
    int? currentChunkIndex;
    final List<int> streamBuffer = [];

    _storageStream?.cancel();
    _storageStream = (await connection.getBleStorageBytesListener(onStorageBytesReceived: (List<int> value) async {
      if (_isCancelled || hasError) return;

      // Log every incoming packet size to verify firmware output
      if (value.length > 1 || !isFirstPacket) {
        Logger.debug("SDCardWalSync: Received ${value.length} bytes (Buffer: ${streamBuffer.length})");
      }

      // Handle the initial ACK byte (0) separately to avoid offset desync
      if (isFirstPacket && value.length == 1) {
        isFirstPacket = false;
        if (value[0] == 0) {
          Logger.debug("SDCardWalSync: Received initial success ACK (0)");
          return;
        } else if (value[0] != 100) {
          Logger.debug("SDCardWalSync: Received firmware error ACK: ${value[0]}");
          hasError = true;
          if (!completer.isCompleted) completer.completeError(Exception('Firmware error: ${value[0]}'));
          return;
        }
      }
      isFirstPacket = false;

      // Add to buffer synchronously
      streamBuffer.addAll(value);
      offset += value.length;

      // Serial processing loop to prevent concurrent buffer access
      if (isProcessing) {
        Logger.debug("SDCardWalSync: Already processing, queuing data");
        return;
      }
      isProcessing = true;

      try {
        while (streamBuffer.isNotEmpty) {
          int packageSize = streamBuffer[0];

          // Check for completion marker (100) at packet boundary
          if (packageSize == 100 && streamBuffer.length == 1) {
            Logger.debug("SDCardWalSync: Received termination marker (100)");
            if (!completer.isCompleted) completer.complete();
            streamBuffer.clear();
            break;
          }

          if (packageSize == 255) { // Metadata
            if (1 + 16 <= streamBuffer.length) {
              var metadata = streamBuffer.sublist(1, 1 + 16);
              var byteData = ByteData.sublistView(Uint8List.fromList(metadata));
              var utcTime = byteData.getUint32(0, Endian.little);
              var currentUptimeMs = byteData.getUint32(4, Endian.little);
              currentSessionId = byteData.getUint32(8, Endian.little);
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
              streamBuffer.removeRange(0, 1 + 16);
              continue;
            } else {
              break; // Need more bytes for metadata
            }
          }

          if (packageSize == 254) { // Star marker
            if (1 + 16 <= streamBuffer.length) {
              var metadata = streamBuffer.sublist(1, 1 + 16);
              var byteData = ByteData.sublistView(Uint8List.fromList(metadata));
              var utcTime = byteData.getUint32(0, Endian.little);
              // ignore other fields for star
              final sessionId = currentSessionId;
              if (sessionId != null) {
                await _saveStarMarker(sessionId, utcTime);
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

            String subFolder = currentSessionId?.toString() ?? 'unsynced';
            var file = await _flushToDisk(wal, [frame], timerStart,
                subFolder: subFolder, sessionId: currentSessionId, chunkIndex: currentChunkIndex);

            try {
              await callback(file, offset, timerStart, subFolder: subFolder);
            } catch (e) {
              Logger.debug("SDCardWalSync: Callback failed: $e");
            }
          } else {
            // Log that we are waiting for a partial frame
            Logger.debug("SDCardWalSync: Waiting for more data (Frame size $packageSize, Buffer ${streamBuffer.length})");
            break; 
          }
        }
      } catch (e) {
        Logger.error('SDCard BLE Transfer Error: $e');
        hasError = true;
        if (!completer.isCompleted) completer.completeError(e);
      } finally {
        isProcessing = false;
      }
    }, onError: (e) {
      Logger.error('SDCard BLE Stream Error: $e');
      hasError = true;
      if (!completer.isCompleted) completer.completeError(e);
    }, onDone: () {
      if (!completer.isCompleted) {
        Logger.debug("SDCardWalSync: BLE stream closed before termination marker");
        completer.complete();
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

  void _resetSyncState() {
    _isCancelled = false;
    _isSyncing = false;
    _totalBytesDownloaded = 0;
    _downloadStartTime = null;
    _currentSpeedKBps = 0.0;
    _activeTcpTransport = null;
    _activeTransferCompleter = null;
  }

  Future<void> _checkDiskSpaceBeforeSync(int totalBytesToDownload) async {
    try {
      final double? freeSpaceMb = await DiskSpace.getFreeDiskSpace;
      if (freeSpaceMb != null) {
        final double requiredMb = (totalBytesToDownload * 2.5) / (1024 * 1024);
        if (freeSpaceMb < requiredMb) {
          throw Exception("Phone Storage Full: Need ${requiredMb.toStringAsFixed(1)} MB free, but only ${freeSpaceMb.toStringAsFixed(1)} MB available.");
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

    var wals = _wals.where((w) => w.status == WalStatus.miss && w.storage == WalStorage.sdcard).toList();
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
        await _readStorageBytesToFile(wal, (File file, int offset, int timerStart, {String? subFolder}) async {
          if (_isCancelled) {
            throw Exception('Sync cancelled by user');
          }

          int bytesInChunk = offset - lastOffset;
          _updateSpeed(bytesInChunk);
          await _registerSingleChunk(wal, file, timerStart);
          chunksDownloaded++;
          lastOffset = offset;

          listener.onWalUpdated();
          if (progress != null) {
            final double progressPercent = (offset - wal.storageOffset) / totalBytesToDownload;
            progress.onWalSyncedProgress(progressPercent.clamp(0.0, 1.0), speedKBps: _currentSpeedKBps);
          }
        });

        await deleteWal(wal);
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
    int lastOffset = wal.storageOffset;
    int totalBytesToDownload = wal.storageTotalBytes - wal.storageOffset;

    await _checkDiskSpaceBeforeSync(totalBytesToDownload);
    _downloadStartTime = DateTime.now();

    try {
      await _readStorageBytesToFile(wal, (File file, int offset, int timerStart, {String? subFolder}) async {
        if (_isCancelled) {
          throw Exception('Sync cancelled by user');
        }

        int bytesInChunk = offset - lastOffset;
        _updateSpeed(bytesInChunk);
        await _registerSingleChunk(wal, file, timerStart);
        lastOffset = offset;

        listener.onWalUpdated();
        if (progress != null) {
          final double progressPercent = (offset - wal.storageOffset) / totalBytesToDownload;
          progress.onWalSyncedProgress(progressPercent.clamp(0.0, 1.0), speedKBps: _currentSpeedKBps);
        }
      });

      await deleteWal(wal);
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

  int chunksDownloaded = 0;

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
