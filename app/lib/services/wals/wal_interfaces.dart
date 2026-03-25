import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/services/wals/wal.dart';

class SyncLocalFilesResponse {
  final List<String> newConversationIds;
  final List<String> updatedConversationIds;
  final bool isPartial;

  SyncLocalFilesResponse({
    required this.newConversationIds,
    required this.updatedConversationIds,
    this.isPartial = false,
  });
}

enum SyncPhase {
  downloading,
  synced,
}

abstract class IWalSyncProgressListener {
  void onWalSyncedProgress(double percentage, {double? speedKBps, SyncPhase? phase});
}

abstract class IWalServiceListener extends IWalSyncListener {
  void onStatusChanged(WalServiceStatus status);
}

abstract class IWalSyncListener {
  void onWalUpdated();
  void onWalSynced(Wal wal);
  void onDeviceRecordingFailed() {}
}

abstract class IWalSync {
  Future<List<Wal>> getMissingWals();
  Future deleteWal(Wal wal);
  Future<SyncLocalFilesResponse?> syncAll({
    IWalSyncProgressListener? progress,
  });
  Future<SyncLocalFilesResponse?> syncWal({
    required Wal wal,
    IWalSyncProgressListener? progress,
  });
  void cancelSync();

  void start();
  Future stop();
}

abstract class IWalService {
  void start();
  Future stop();

  void subscribe(IWalServiceListener subscription, Object context);
  void unsubscribe(Object context);

  /// Returns the SDCardWalSync instance for managing sync operations.
  SDCardWalSync getSyncs();
}

enum WalServiceStatus {
  init,
  ready,
  stop,
}

abstract class SDCardWalSync implements IWalSync {
  /// [prefetchedFiles] — if provided, skips the CMD_LIST_FILES BLE round-trip
  /// and uses the supplied list directly (avoids a redundant call when the
  /// caller already has a fresh file listing, e.g. from [_onDeviceConnected]).
  Future<void> setDevice(BtDevice? device, {List<StorageFile>? prefetchedFiles});
  Future<void> deleteAllSyncedWals();
  Future<void> deleteAllPendingWals();
  bool get isSyncing;
  Future<void>? get cancelFuture;
  void setGlobalProgressListener(IWalSyncProgressListener? listener);
  bool get isDeviceRecordingFailed;
  double get currentSpeedKBps;
  int get recordingsCount;
  int get estimatedTotalSegments;

  /// Lightweight check — returns true if the device has at least one file
  /// exceeding the sync threshold. Avoids building full WAL objects.
  /// Fast path: uses in-memory WAL list if already populated by [setDevice].
  Future<bool> hasFilesToSync();

  /// Send CMD_ROTATE_FILE, wait for ACK (current file sealed, new file open),
  /// then run a normal sync including short segments below the usual threshold.
  Future<SyncLocalFilesResponse?> rotateAndSync({IWalSyncProgressListener? progress});
}
