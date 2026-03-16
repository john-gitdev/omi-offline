import 'package:omi/backend/schema/bt_device/bt_device.dart';
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

/// Listener for WiFi connection progress
abstract class IWifiConnectionListener {
  void onEnablingDeviceWifi();
  void onConnectingToDevice();
  void onConnected();
  void onConnectionFailed(String error);
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
    IWifiConnectionListener? connectionListener,
    bool force = false,
  });
  Future<SyncLocalFilesResponse?> syncWal({
    required Wal wal,
    IWalSyncProgressListener? progress,
    IWifiConnectionListener? connectionListener,
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
  void setDevice(BtDevice? device);
  Future<void> deleteAllSyncedWals();
  Future<void> deleteAllPendingWals();
  bool get isSyncing;
  bool get isDeviceRecordingFailed;
  double get currentSpeedKBps;
  int get recordingsCount;
  int get estimatedTotalChunks;

  Future<bool> isWifiSyncSupported();
  Future<bool> setWifiCredentials(String ssid, String password);
  Future<void> clearWifiCredentials();
  Future<void> loadWifiCredentials();
  Map<String, String?>? getWifiCredentials();
  Future<SyncLocalFilesResponse?> syncWithWifi({
    IWalSyncProgressListener? progress,
    IWifiConnectionListener? connectionListener,
  });
}
