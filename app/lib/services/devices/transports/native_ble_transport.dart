import 'dart:async';
import 'dart:typed_data';

import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/utils/logger.dart';
import 'device_transport.dart';

/// BLE transport backed by native platform APIs via Pigeon.
/// Uses the intent-based manageDevice/unmanageDevice API.
/// Native owns the connection lifecycle (retry, reconnect, bonding).
/// This transport is long-lived
class NativeBleTransport extends DeviceTransport {
  final String _peripheralUuid;
  final bool requiresBond;
  final BleHostApi _hostApi = BleHostApi();

  // Bounds a single native GATT read/write. A with-response write on a half-dead
  // link (firmware app wedged, but the BLE link is still up so Android never
  // fires a disconnect) never gets its onCharacteristicWrite/Read callback, so
  // the Pigeon future would otherwise park forever — wedging the WAL sync's read
  // `finally` (stopStorageSync), which strands the whole sync and freezes the
  // "Syncing recordings…" foreground notification. Healthy ops finish sub-second;
  // this only trips on a dead peer, surfacing it as a thrown error so the sync
  // unwinds into processing instead of hanging.
  static const Duration _gattOpTimeout = Duration(seconds: 10);

  /// Backstop for a connect request, NOT the expected failure path.
  ///
  /// Native owns connect and retry. A failed attempt reaches us as
  /// `onPeripheralDisconnected`, which errors the ready completer directly — so in the
  /// normal case this timer never fires and we learn the real GATT status instead of
  /// synthesising a timeout. It exists only for the case where native reports nothing
  /// at all.
  ///
  /// It MUST stay above native's own attempt backstops
  /// (`OmiBleForegroundService.DIRECT_CONNECT_TIMEOUT_MS` 40 s /
  /// `AUTO_CONNECT_TIMEOUT_MS` 45 s). It used to be 30 s, with a comment claiming it
  /// matched them; daa55517 raised native to 40 s and left the claim behind. Being the
  /// *shorter* of the two inverted the whole contract: Dart declared a connect failed
  /// while native was still mid-attempt, so a link that came up afterwards arrived as an
  /// unsolicited connection rather than as the answer to the request that asked for it.
  /// Observed 2026-08-09T14:48:40Z — native reported `connect failed` at 22 s, Dart logged
  /// `device ready after 24139ms`, and the connection was discarded two seconds later.
  static const Duration _kConnectBackstop = Duration(seconds: 55);
  final StreamController<DeviceTransportState> _connectionStateController =
      StreamController<DeviceTransportState>.broadcast();

  /// Characteristic notification streams, keyed by "serviceUuid:charUuid" (lowercased).
  final Map<String, StreamController<List<int>>> _streamControllers = {};

  /// Discovered services from native.
  List<BleService> _services = [];

  Completer<List<BleService>>? _deviceReadyCompleter;

  DeviceTransportState _state = DeviceTransportState.disconnected;
  DateTime? _lastConnectedAt;

  NativeBleTransport(this._peripheralUuid, {this.requiresBond = false}) {
    BleBridge.instance.registerPeripheral(
      peripheralUuid: _peripheralUuid,
      onConnectionState: _handleConnectionState,
      onDeviceReady: _handleDeviceReady,
      onCharacteristicValue: _handleCharacteristicValue,
    );
  }

  @override
  String get deviceId => _peripheralUuid;

  @override
  Stream<DeviceTransportState> get connectionStateStream => _connectionStateController.stream;

  // MARK: - Connection

  @override
  Future<void> connect({bool requiresBond = false}) async {
    if (_state == DeviceTransportState.connected) return;
    if (_state == DeviceTransportState.connecting && _deviceReadyCompleter != null) {
      Logger.debug('[NativeBleTransport] $_peripheralUuid: already connecting, joining existing attempt');
      try {
        await _deviceReadyCompleter!.future;
      } catch (_) {}
      return;
    }

    Logger.debug('[NativeBleTransport] $_peripheralUuid: starting fresh connect (requiresBond=$requiresBond)');
    _updateState(DeviceTransportState.connecting);

    _deviceReadyCompleter = Completer<List<BleService>>();
    // Add a catchError to the future to prevent unhandled exceptions if the completer
    // is failed before someone is actively awaiting it (or if multiple people await it).
    _deviceReadyCompleter!.future.catchError((_) => <BleService>[]);

    try {
      await _hostApi.manageDevice(_peripheralUuid, requiresBond);
    } catch (e) {
      Logger.debug('[NativeBleTransport] $_peripheralUuid: manageDevice failed: $e');
      final completer = _deviceReadyCompleter;
      _deviceReadyCompleter = null;
      if (completer != null && !completer.isCompleted) {
        completer.completeError(e);
      }
      _updateState(DeviceTransportState.disconnected);
      if (e.toString().contains('bluetooth_off')) {
        rethrow;
      }
      await Future.delayed(const Duration(seconds: 2));
      rethrow;
    }

    Logger.debug(
      '[NativeBleTransport] $_peripheralUuid: manageDevice sent, waiting for device-ready '
      '(${_kConnectBackstop.inSeconds}s backstop)',
    );
    final t0 = DateTime.now();
    try {
      _services = await _deviceReadyCompleter!.future.timeout(
        _kConnectBackstop,
        onTimeout: () => throw TimeoutException('Device ready timeout after ${_kConnectBackstop.inSeconds}s'),
      );
      _deviceReadyCompleter = null;
      final ms = DateTime.now().difference(t0).inMilliseconds;
      Logger.debug('[NativeBleTransport] $_peripheralUuid: device ready after ${ms}ms (${_services.length} services)');
      _updateState(DeviceTransportState.connected);
    } catch (e) {
      final ms = DateTime.now().difference(t0).inMilliseconds;
      Logger.debug('[NativeBleTransport] $_peripheralUuid: connect failed after ${ms}ms: $e');
      final completer = _deviceReadyCompleter;
      _deviceReadyCompleter = null;
      if (completer != null && !completer.isCompleted) {
        completer.completeError(e);
      }
      _updateState(DeviceTransportState.disconnected);
      if (e.toString().contains('bluetooth_off')) {
        rethrow;
      }
      await Future.delayed(const Duration(seconds: 2));
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    if (_state == DeviceTransportState.disconnected) return;

    _updateState(DeviceTransportState.disconnecting);

    // Unsubscribe all active streams
    for (final key in _streamControllers.keys.toList()) {
      final parts = key.split(':');
      if (parts.length == 2) {
        try {
          _hostApi.unsubscribeCharacteristic(_peripheralUuid, parts[0], parts[1]);
        } catch (_) {}
      }
    }

    _closeAllStreams();
    _services = [];

    // Fail any pending completers
    if (_deviceReadyCompleter != null && !_deviceReadyCompleter!.isCompleted) {
      _deviceReadyCompleter!.completeError(Exception('Disconnected'));
      _deviceReadyCompleter = null;
    }

    try {
      await _hostApi.unmanageDevice(_peripheralUuid);
    } catch (e) {
      Logger.debug('[NativeBleTransport] unmanageDevice failed: $e');
    }

    _updateState(DeviceTransportState.disconnected);
  }

  @override
  Future<void> softDisconnect() async {
    // Drop just the current GATT/link WITHOUT unmanaging the device (unlike
    // disconnect(), which calls unmanageDevice → USER_DISCONNECTED, cancels native
    // recovery, and can stop the foreground service). Android: gatt.disconnect() —
    // the device stays managed, so native tears down the stale gatt (disconnect +
    // refresh + close) and rebuilds a fresh one on its own. iOS: cancelPeripheral-
    // Connection — marks it manually-disconnected, so the caller MUST follow with an
    // explicit reconnect (which clears that flag). The native disconnect callback
    // drives our state to disconnected.
    if (_state == DeviceTransportState.disconnected) return;
    try {
      await _hostApi.disconnectPeripheral(_peripheralUuid);
    } catch (e) {
      Logger.debug('[NativeBleTransport] softDisconnect failed: $e');
    }
  }

  @override
  Future<bool> isConnected() async {
    try {
      final nativeConnected = await _hostApi.isPeripheralConnected(_peripheralUuid);
      final bool isStablyConnected =
          _lastConnectedAt != null && DateTime.now().difference(_lastConnectedAt!).inSeconds > 5;

      if (!nativeConnected && _state == DeviceTransportState.connected && isStablyConnected) {
        Logger.warning(
            '[NativeBleTransport] State mismatch detected! Native OS is disconnected but Dart is connected. Forcing cleanup.');
        // Don't call disconnect() directly as it might interfere with callers waiting on states.
        // Just trigger the same cleanup path a native disconnection would.
        _handleConnectionState(false, 'native_state_mismatch');
        // Also force the native side to drop the stuck GATT object so it can reconnect.
        try {
          await _hostApi.disconnectPeripheral(_peripheralUuid);
        } catch (_) {}
      }
      return nativeConnected;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> ping() async {
    return isConnected();
  }

  @override
  Future<bool> requestBond() async {
    try {
      return await _hostApi.requestBond(_peripheralUuid);
    } catch (e) {
      Logger.debug('[NativeBleTransport] requestBond failed: $e');
      return false;
    }
  }

  // MARK: - Characteristic Streams

  @override
  Future<Stream<List<int>>> getCharacteristicStream(String serviceUuid, String characteristicUuid) async {
    final key = '${serviceUuid.toLowerCase()}:${characteristicUuid.toLowerCase()}';

    if (!_streamControllers.containsKey(key)) {
      _streamControllers[key] = StreamController<List<int>>.broadcast();
      if (_hasCharacteristic(serviceUuid, characteristicUuid)) {
        _subscribeCharacteristic(serviceUuid, characteristicUuid);
      }
    }

    return _streamControllers[key]!.stream;
  }

  void _subscribeCharacteristic(String serviceUuid, String characteristicUuid) {
    try {
      _hostApi.subscribeCharacteristic(_peripheralUuid, serviceUuid, characteristicUuid);
    } catch (e) {
      Logger.debug('[NativeBleTransport] Failed to subscribe $serviceUuid:$characteristicUuid: $e');
    }
  }

  @override
  Future<void> unsubscribeCharacteristic(String serviceUuid, String characteristicUuid) async {
    final key = '${serviceUuid.toLowerCase()}:${characteristicUuid.toLowerCase()}';
    // Drop the controller first so a later getCharacteristicStream re-creates it
    // and re-issues the CCCD write. Closing it fires onDone on any live listener.
    // Also forget the key so an auto-reconnect (_resubscribeAfterReconnect) doesn't
    // resurrect a stream the caller explicitly stopped.
    final controller = _streamControllers.remove(key);
    _activeSubscriptionKeys.remove(key);
    try {
      // Await so a native failure surfaces to the caller instead of becoming an
      // unhandled future error, and so teardown ordering (CCCD=0 before any later
      // re-subscribe) is preserved.
      await _hostApi.unsubscribeCharacteristic(_peripheralUuid, serviceUuid, characteristicUuid);
    } catch (e) {
      Logger.debug('[NativeBleTransport] Failed to unsubscribe $serviceUuid:$characteristicUuid: $e');
    }
    await controller?.close();
  }

  bool _hasCharacteristic(String serviceUuid, String characteristicUuid) {
    final sUuid = serviceUuid.toLowerCase();
    final cUuid = characteristicUuid.toLowerCase();
    for (final service in _services) {
      if (service.uuid.toLowerCase() == sUuid) {
        return service.characteristicUuids.any((c) => c.toLowerCase() == cUuid);
      }
    }
    return false;
  }

  @override
  Future<List<int>> readCharacteristic(String serviceUuid, String characteristicUuid) async {
    if (!_hasCharacteristic(serviceUuid, characteristicUuid)) return [];
    try {
      final data =
          await _hostApi.readCharacteristic(_peripheralUuid, serviceUuid, characteristicUuid).timeout(_gattOpTimeout);
      return data.toList();
    } on TimeoutException catch (_) {
      // A read that never gets its onCharacteristicRead callback is the wedged-GATT
      // signature (link up, GATT ops dead) — NOT an empty characteristic. Surface it
      // distinctly (still returning [] to preserve the callers' empty-on-failure
      // contract) so a wedge isn't silently read as "device returned nothing".
      Logger.warning('[NativeBleTransport] readCharacteristic $serviceUuid:$characteristicUuid TIMED OUT after '
          '${_gattOpTimeout.inSeconds}s — likely a wedged GATT (returning empty)');
      return [];
    } catch (e) {
      Logger.debug('[NativeBleTransport] Failed to read $serviceUuid:$characteristicUuid: $e');
      return [];
    }
  }

  @override
  Future<void> writeCharacteristic(String serviceUuid, String characteristicUuid, List<int> data) async {
    if (!_hasCharacteristic(serviceUuid, characteristicUuid)) {
      throw Exception('Characteristic not available: $characteristicUuid');
    }
    try {
      await _hostApi
          .writeCharacteristic(_peripheralUuid, serviceUuid, characteristicUuid, Uint8List.fromList(data))
          .timeout(_gattOpTimeout);
    } catch (e) {
      Logger.debug('[NativeBleTransport] Failed to write characteristic: $e');
      rethrow;
    }
  }

  // MARK: - Dispose

  @override
  Future<void> dispose() async {
    // Unregister Dart callbacks first so we don't receive stale events.
    BleBridge.instance.unregisterPeripheral(_peripheralUuid);
    // Tell native to release this peripheral so a subsequent manageDevice call
    // starts a fresh connection cycle (without this, native may silently ignore
    // a repeated manageDevice for an already-managed peripheral).
    try {
      await _hostApi.unmanageDevice(_peripheralUuid);
    } catch (_) {}
    _closeAllStreams();
    await _connectionStateController.close();
  }

  // MARK: - Private Helpers

  void _updateState(DeviceTransportState newState) {
    if (_state != newState) {
      _state = newState;
      if (_state == DeviceTransportState.connected) {
        _lastConnectedAt = DateTime.now();
      } else if (_state == DeviceTransportState.disconnected) {
        _lastConnectedAt = null;
      }
      _connectionStateController.add(_state);
    }
  }

  void _closeAllStreams() {
    for (final controller in _streamControllers.values) {
      controller.close();
    }
    _streamControllers.clear();
  }

  void _addToStream(String serviceUuid, String characteristicUuid, List<int> data) {
    final key = '${serviceUuid.toLowerCase()}:${characteristicUuid.toLowerCase()}';
    final controller = _streamControllers[key];
    if (controller != null && !controller.isClosed) {
      controller.add(data);
    }
  }

  // MARK: - Native Callbacks

  /// Track which characteristics were subscribed so we can re-subscribe on reconnect.
  final Set<String> _activeSubscriptionKeys = {};

  void _handleConnectionState(bool connected, String? error) {
    // Native no longer emits a separate "physical connected" event — a successful
    // connection is signalled via _handleDeviceReady. This callback now only
    // carries disconnects; ignore any stray connected==true.
    if (connected) return;

    // Ignore transient GATT status errors during connection phase to allow native retry to work.
    final bool isConnecting = _deviceReadyCompleter != null && !_deviceReadyCompleter!.isCompleted;
    if (isConnecting && error != null && (error.contains('133') || error.contains('-1'))) {
      Logger.debug(
          '[NativeBleTransport] $_peripheralUuid: ignoring transient GATT error during connect (native will retry): $error');
      return;
    }
    Logger.debug(
        '[NativeBleTransport] $_peripheralUuid: disconnected (error=$error isConnecting=$isConnecting state=$_state)');

    // Remember active subscriptions before closing streams
    _activeSubscriptionKeys.clear();
    _activeSubscriptionKeys.addAll(_streamControllers.keys);

    _closeAllStreams();
    _services = [];
    _updateState(DeviceTransportState.disconnected);

    // Fail pending completer
    if (_deviceReadyCompleter != null && !_deviceReadyCompleter!.isCompleted) {
      _deviceReadyCompleter!.completeError(error ?? 'Disconnected before ready');
    }
  }

  void _handleDeviceReady(List<BleService> services) {
    // A ready carrying an empty service table is not a usable link, and must never be
    // latched as connected. readCharacteristic short-circuits to [] whenever
    // _hasCharacteristic misses, so with _services empty the app looks connected while
    // the capability read returns 0 (Device Settings → Customization collapses to its one
    // ungated row) and every storage write throws (nothing ever syncs). Worse, connect()
    // early-returns while _state is connected, so nothing re-drives the link and the
    // session stays stranded until the app is force-closed.
    //
    // Native's manageDevice used to produce exactly this by taking its
    // "Dart restarted, native kept the link" shortcut in the window between
    // STATE_CONNECTED and onServicesDiscovered (fixed there too — it now gates on
    // hasDiscoveredServices). Keep the guard here regardless: an empty table is never
    // worth adopting, and native's own discovery fires a real ready moments later.
    //
    // Drop the event and leave any pending completer alone, rather than failing it. The
    // real ready is what should resolve connect(), and it lands within a second or so;
    // erroring here instead would make connect() throw for something that immediately
    // succeeded, and push the caller through a spurious disconnected → connected
    // transition. Nothing can hang on this: a genuine disconnect fails the pending
    // completer in _handleConnectionState, and connect() times out at _kConnectBackstop
    // regardless —
    // well outside native's 15s discovery timeout, which drops a stuck link into the
    // ordinary retry path long before then.
    if (services.isEmpty) {
      Logger.warning('[NativeBleTransport] $_peripheralUuid: device-ready carried 0 services — ignoring, '
          'waiting for the real discovery');
      return;
    }

    _services = services;
    if (_deviceReadyCompleter != null && !_deviceReadyCompleter!.isCompleted) {
      Logger.debug(
          '[NativeBleTransport] $_peripheralUuid: device ready (initial connect path, ${services.length} services)');
      _deviceReadyCompleter!.complete(services);
    } else {
      Logger.debug(
          '[NativeBleTransport] $_peripheralUuid: device ready (auto-reconnect path, ${services.length} services)');
      _resubscribeAfterReconnect(services);
    }
    _updateState(DeviceTransportState.connected);
  }

  bool _isResubscribing = false;

  void _resubscribeAfterReconnect(List<BleService> services) {
    if (_isResubscribing) return;
    _isResubscribing = true;

    try {
      _services = services;

      // Re-create stream controllers and re-subscribe to previously active characteristics
      for (final key in _activeSubscriptionKeys) {
        final parts = key.split(':');
        if (parts.length == 2) {
          _streamControllers[key] = StreamController<List<int>>.broadcast();
          _subscribeCharacteristic(parts[0], parts[1]);
        }
      }

      _updateState(DeviceTransportState.connected);
    } catch (e) {
      Logger.debug('[NativeBleTransport] Failed to re-subscribe after reconnect: $e');
      _updateState(DeviceTransportState.disconnected);
    } finally {
      _isResubscribing = false;
    }
  }

  void _handleCharacteristicValue(String serviceUuid, String characteristicUuid, Uint8List value) {
    _addToStream(serviceUuid, characteristicUuid, value);
  }
}
