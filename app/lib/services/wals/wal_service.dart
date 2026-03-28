import 'package:omi/services/wals/wal.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
import 'package:omi/services/wals/sdcard_wal_sync.dart';
import 'package:omi/utils/notifications.dart';

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

    subscription.onStatusChanged(_status);
  }

  @override
  void unsubscribe(Object context) {
    _subscriptions.remove(identityHashCode(context));
  }

  @override
  void start() {
    _sdSync.start();
    _status = WalServiceStatus.ready;
  }

  @override
  Future stop() async {
    await _sdSync.stop();

    _status = WalServiceStatus.stop;
    _onStatusChanged(_status);
    _subscriptions.clear();
  }

  void _onStatusChanged(WalServiceStatus status) {
    for (var s in List.from(_subscriptions.values)) {
      s.onStatusChanged(status);
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
  void onDeviceRecordingFailed() {
    NotificationsService.showDeviceRecordingFailed();
    for (var s in List.from(_subscriptions.values)) {
      s.onDeviceRecordingFailed();
    }
  }
}
