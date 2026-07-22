import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/utils/logger.dart';

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
  void onWalServiceStatusChanged(WalServiceStatus status);
}

abstract class IWalSyncListener {
  void onWalUpdated();
  void onWalSynced(Wal wal);
  void onStorageStatsUpdated(StorageFileStats stats) {}
  void onSyncFinished() {}
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
  Future<void> deleteAllPendingWals();
  bool get isSyncing;
  Future<void>? get cancelFuture;
  void setGlobalProgressListener(IWalSyncProgressListener? listener);
  bool get isDeviceRecordingFailed;
  double get currentSpeedKBps;

  /// On-disk size (bytes) of the .bin currently being downloaded, read fresh via
  /// stat; null when no transfer is active. The sync stall-watchdog samples this
  /// so it can observe intra-file byte progress even when the per-packet progress
  /// callback is starved by background timer throttling — otherwise a single large
  /// file over throttled background BLE looks "stalled" for the whole download and
  /// gets force-recovered mid-transfer.
  int? get activeTransferBytesOnDisk;

  int get recordingsCount;
  int get estimatedTotalSegments;

  /// Canonical sync progress for the CURRENT session — the single source both the
  /// recordings card and the foreground-service notification read, so they always
  /// agree. [totalSegments] is the monotonic peak of [estimatedTotalSegments] this
  /// session (the "of N" denominator that never counts down); [syncedSegments] is
  /// that scaled by the last reported download fraction, so it persists across the
  /// native downloader's silent inter-file gaps instead of resetting. Both are 0
  /// when no sync session is active.
  int get totalSegments;
  int get syncedSegments;

  /// Lightweight check — returns true if the device has at least one file
  /// exceeding the sync threshold. Avoids building full WAL objects.
  /// Fast path: uses in-memory WAL list if already populated by [setDevice].
  Future<bool> hasFilesToSync();

  /// Send CMD_ROTATE_FILE, wait for ACK (current file sealed, new file open),
  /// then run a normal sync including short segments below the usual threshold.
  Future<SyncLocalFilesResponse?> rotateAndSync({IWalSyncProgressListener? progress});

  /// Bins (paths relative to `raw_segments/`) whose transfer has NOT delivered
  /// every byte the device advertised — see [Wal.isIncompleteTransfer]. These
  /// are prefixes awaiting a resumed read, so the processing pass must skip
  /// them: it prunes every bin it consumes, and pruning one strands its resume.
  Future<Set<String>> incompleteBinRelPaths();
}

extension SDCardWalSyncCancel on SDCardWalSync {
  /// Stop any in-flight sync and wait (bounded) for the transfer to actually
  /// unwind. [cancelSync] only *requests* cancellation, so a bare call leaves the
  /// transfer stream still draining; callers that then write to the shared
  /// storage characteristic (firmware-update arm, reboot/shutdown, wipe) must
  /// await this first to avoid racing a live transfer. No-op when not syncing.
  Future<void> cancelAndWait({Duration timeout = const Duration(seconds: 2)}) async {
    if (!isSyncing) return;
    cancelSync();
    await cancelFuture?.timeout(timeout, onTimeout: () {
      // Proceed anyway, but log it: a caller writing to the shared storage
      // characteristic right after may now race a transfer that didn't stop.
      Logger.debug('SDCardWalSync.cancelAndWait: sync did not stop within $timeout — proceeding anyway');
    });
  }
}
