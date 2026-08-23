import 'package:omi/services/wals/wal.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
import 'package:omi/services/wals/sdcard_wal_sync.dart';
import 'package:omi/services/devices/storage_file.dart';

class WalService implements IWalService, IWalSyncListener {
  final Map<Object, IWalServiceListener> _subscriptions = {};
  WalServiceStatus _status = WalServiceStatus.init;
  WalServiceStatus get status => _status;

  late SDCardWalSyncImpl _sdSync;

  WalService() {
    _sdSync = SDCardWalSyncImpl(this);
  }

  @override
  void subscribe(IWalServiceListener subscription, Object context) {
    final key = identityHashCode(context);
    _subscriptions.remove(key);
    _subscriptions.putIfAbsent(key, () => subscription);

    subscription.onWalServiceStatusChanged(_status);
  }

  @override
  void unsubscribe(Object context) {
    _subscriptions.remove(identityHashCode(context));
  }

  @override
  void start() {
    // Nothing to start on the sync itself — see IWalSync, which no longer declares
    // start(). Registering the device (setDevice) is what initialises WAL state.
    _status = WalServiceStatus.ready;
  }

  @override
  Future stop() async {
    await _sdSync.stop();

    _status = WalServiceStatus.stop;
    _onWalServiceStatusChanged(_status);
    _subscriptions.clear();
  }

  void _onWalServiceStatusChanged(WalServiceStatus status) {
    for (var s in List.from(_subscriptions.values)) {
      s.onWalServiceStatusChanged(status);
    }
  }

  @override
  SDCardWalSync getSyncs() {
    return _sdSync;
  }

  @override
  void onWalUpdated() {
    for (var s in List.from(_subscriptions.values)) {
      s.onWalUpdated();
    }
  }

  @override
  void onWalSynced(Wal wal) {
    for (var s in List.from(_subscriptions.values)) {
      s.onWalSynced(wal);
    }
  }

  @override
  void onStorageStatsUpdated(StorageFileStats stats) {
    for (var s in List.from(_subscriptions.values)) {
      s.onStorageStatsUpdated(stats);
    }
  }

  @override
  void onSyncFinished() {
    for (var s in List.from(_subscriptions.values)) {
      s.onSyncFinished();
    }
  }

  @override
  void onDeviceRecordingFailed() {
    for (var s in List.from(_subscriptions.values)) {
      s.onDeviceRecordingFailed();
    }
  }
}
