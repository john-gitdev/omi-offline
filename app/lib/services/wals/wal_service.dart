import 'package:omi/services/wals/wal.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
import 'package:omi/services/wals/sdcard_wal_sync.dart';

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
    _subscriptions.remove(context.hashCode);
    _subscriptions.putIfAbsent(context.hashCode, () => subscription);

    subscription.onStatusChanged(_status);
  }

  @override
  void unsubscribe(Object context) {
    _subscriptions.remove(context.hashCode);
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
    for (var s in _subscriptions.values) {
      s.onStatusChanged(status);
    }
  }

  @override
  SDCardWalSync getSyncs() {
    return _sdSync;
  }

  @override
  void onWalUpdated() {
    for (var s in _subscriptions.values) {
      s.onWalUpdated();
    }
  }

  @override
  void onWalSynced(Wal wal) {
    for (var s in _subscriptions.values) {
      s.onWalSynced(wal);
    }
  }
}
