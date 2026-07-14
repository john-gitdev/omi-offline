import 'dart:async';

import 'package:collection/collection.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/discovery/device_discoverer.dart';
import 'package:omi/services/devices/discovery/native_bluetooth_discoverer.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/mutex.dart';

abstract class IDeviceService {
  void start();
  void stop();
  Future<List<BtDevice>> discover({String? desirableDeviceId, int timeout = 5});

  DeviceServiceStatus get status;

  /// Devices found by the most recent discovery (including background scans).
  List<BtDevice> get devices;

  Future<DeviceConnection?> ensureConnection(String deviceId, {bool force = false, bool requiresBond = false});

  void subscribe(IDeviceServiceSubscription subscription, Object context);
  void unsubscribe(Object context);

  DateTime? getFirstConnectedAt();

  Future<void> disconnectDevice({bool isManual = true});

  /// Recover a wedged (connected-but-dead) GATT on the CURRENT connection by
  /// dropping just that GATT and reconnecting fresh — the automatic equivalent of
  /// toggling Bluetooth. Keeps the device managed (unlike [disconnectDevice], which
  /// unmanages, signalling user-intent-off and cancelling native recovery). No-op if
  /// nothing is connected.
  Future<void> recycleConnection();

  /// Fully tear down connection + transport for a device being forgotten/unpaired.
  Future<void> forgetDevice(String deviceId);

  Future<bool> hasCompanionDeviceAssociation();
  Future<String> requestCompanionDeviceAssociation(String deviceId);
}

enum DeviceServiceStatus { init, ready, scanning, stop }

enum DeviceConnectionState { connected, connecting, disconnected }

/// Feature flags for Omi device capabilities
/// Must match the firmware definitions in features.h
class OmiFeatures {
  static const int speaker = 1 << 0;
  static const int accelerometer = 1 << 1;
  static const int button = 1 << 2;
  static const int battery = 1 << 3;
  static const int usb = 1 << 4;
  static const int haptic = 1 << 5;
  static const int offlineStorage = 1 << 6;
  static const int ledDimming = 1 << 7;
  static const int micGain = 1 << 8;
  static const int vadThreshold = 1 << 9;
  static const int priorityRecordCap = 1 << 10;
  static const int recordToggle = 1 << 11;
}

abstract class IDeviceServiceSubscription {
  void onDevices(List<BtDevice> devices);
  void onStatusChanged(DeviceServiceStatus status);
  void onDeviceConnectionStateChanged(String deviceId, DeviceConnectionState state, {bool isManual = false});
}

class DeviceService implements IDeviceService {
  DeviceServiceStatus _status = DeviceServiceStatus.init;
  List<BtDevice> _devices = [];

  final List<DeviceDiscoverer> _discoverers = [
    NativeBluetoothDiscoverer(),
  ];

  final Map<Object, IDeviceServiceSubscription> _subscriptions = {};

  DeviceConnection? _connection;
  // Guards against concurrent recycleConnection() calls (the stall watchdog, the WAL
  // sync catch, and the keep-alive can all trip on the same wedge at once).
  bool _recycling = false;
  @override
  List<BtDevice> get devices => _devices;

  @override
  DeviceServiceStatus get status => _status;

  DateTime? _firstConnectedAt;

  @override
  Future<List<BtDevice>> discover({String? desirableDeviceId, int timeout = 5}) async {
    Logger.debug("Device discovering...");
    if (_status == DeviceServiceStatus.scanning) {
      Logger.warning("DeviceService: Discovery requested while already scanning. Ignoring redundant request.");
      return [];
    }

    if (_status != DeviceServiceStatus.ready) {
      logCommonErrorMessage("Device service is not ready (status: ${_status.name}).");
      return [];
    }

    _status = DeviceServiceStatus.scanning;
    onStatusChanged(_status);

    try {
      final discoveredDevices = <BtDevice>[];

      final supportedDiscoverers = _discoverers.where((d) => d.isSupported).toList();
      final discoveryFutures = supportedDiscoverers.map((d) async {
        try {
          final result = await d.discover(timeout: timeout);
          return result.devices;
        } catch (e, st) {
          Logger.debug('Discovery failed for ${d.name}: $e');
          Logger.debug('$st');
          return <BtDevice>[];
        }
      });

      // Wait for all discoveries to complete
      final results = await Future.wait(discoveryFutures);

      // Combine all discovered devices
      for (final devices in results) {
        discoveredDevices.addAll(devices);
      }

      _devices = discoveredDevices;
      onDevices(devices);

      _status = DeviceServiceStatus.ready;
      if (desirableDeviceId != null && desirableDeviceId.isNotEmpty) {
        await ensureConnection(desirableDeviceId, force: true);
      }
      return _devices;
    } finally {
      _status = DeviceServiceStatus.ready;
      onStatusChanged(_status);
    }
  }

  Future<void> _connectToDevice(String id, {bool requiresBond = true}) async {
    var device = _devices.firstWhereOrNull((f) => f.id == id);
    Logger.debug('[DeviceService] device lookup result: ${device?.name ?? "NULL"} (locator: ${device?.locator?.kind})');

    // If device not in discovered list, try to get it from SharedPreferences
    // This allows background reconnection without scanning
    if (device == null) {
      Logger.debug('[DeviceService] Device not in discovered list, checking stored device');
      device = _getStoredDevice(id);
      if (device != null) {
        Logger.debug('[DeviceService] Using stored device: ${device.name}');
        if (!_devices.any((d) => d.id == device!.id)) {
          _devices.add(device);
        }
      } else {
        Logger.debug('[DeviceService] No stored device available for $id, returning');
        return;
      }
    }

    // Clean up existing connection ONLY if it's a different device
    if (_connection != null && _connection!.device.id != id) {
      if (_connection!.status == DeviceConnectionState.connected) {
        await _connection!.disconnect();
      }
      await _connection!.transport.dispose();
      _connection = null;
    }

    _connection ??= DeviceConnectionFactory.create(device, requiresBond: requiresBond);

    if (_connection != null) {
      try {
        await _connection!
            .connect(onConnectionStateChanged: onDeviceConnectionStateChanged, requiresBond: requiresBond);
      } catch (e) {
        Logger.debug('[DeviceService] Connection attempt failed for $id: $e');
        rethrow;
      }
    } else {
      Logger.debug('[DeviceService] Failed to create device connection for ${device.id}');
    }
  }

  @override
  void subscribe(IDeviceServiceSubscription subscription, Object context) {
    _subscriptions.remove(context.hashCode);
    _subscriptions.putIfAbsent(context.hashCode, () => subscription);

    // Retains
    subscription.onDevices(_devices);
    subscription.onStatusChanged(_status);
  }

  @override
  void unsubscribe(Object context) {
    _subscriptions.remove(context.hashCode);
  }

  @override
  void start() {
    _status = DeviceServiceStatus.ready;
    // Automatic discovery and re-connection are handled natively by the platform transports
    // (e.g. NativeBleTransport uses CBCentralManager state restoration / Foreground Service auto-connect)
    // and polled dynamically in dart via DeviceProvider.periodicConnect on app launch/resume.
  }

  @override
  void stop() {
    _status = DeviceServiceStatus.stop;
    onStatusChanged(_status);

    // Stop all discoverers to prevent resource leaks and battery drain
    for (final discoverer in _discoverers) {
      discoverer.stop();
    }

    _subscriptions.clear();
    _devices.clear();
  }

  void onStatusChanged(DeviceServiceStatus status) {
    for (var s in _subscriptions.values) {
      s.onStatusChanged(status);
    }
  }

  void onDeviceConnectionStateChanged(String deviceId, DeviceConnectionState state, {bool isManual = false}) {
    Logger.debug("device connection state changed...$deviceId...$state (isManual: $isManual)");
    DebugLogManager.logEvent(
        'device_connection_state', {'device_id': deviceId, 'state': state.name, 'is_manual': isManual});
    for (var s in _subscriptions.values) {
      s.onDeviceConnectionStateChanged(deviceId, state, isManual: isManual);
    }
  }

  void onDevices(List<BtDevice> devices) {
    for (var s in _subscriptions.values) {
      s.onDevices(devices);
    }
  }

  void logCommonErrorMessage(String message) {
    Logger.error('DeviceService Error: $message');
  }

  final Mutex _mutex = Mutex();
  @override
  Future<DeviceConnection?> ensureConnection(String deviceId, {bool force = false, bool requiresBond = false}) async {
    await _mutex.acquire();
    try {
      final currentId = _connection?.device.id;
      final currentStatus = _connection?.status;

      // Connected to this device — return it
      if (currentId == deviceId && currentStatus == DeviceConnectionState.connected) {
        return _connection;
      }

      Logger.debug(
        "[DeviceService] ensureConnection: request=$deviceId (current: $currentId, status: $currentStatus, force: $force)",
      );

      // Transport exists for this device but disconnected — native handles reconnection.
      // Don't dispose and recreate the transport; that would cancel native's auto-reconnect.
      // But if force=true (user-initiated), reconnect explicitly.
      if (!force && _connection?.device.id == deviceId) {
        return null;
      }

      // No connection or different device — only connect on force (user-initiated)
      if (!force) return null;

      try {
        await _connectToDevice(deviceId, requiresBond: requiresBond);
      } catch (e) {
        Logger.debug('[DeviceService] Connection failed for $deviceId: $e');
        return null;
      }

      _firstConnectedAt ??= DateTime.now();
      return _connection;
    } finally {
      _mutex.release();
    }
  }

  @override
  DateTime? getFirstConnectedAt() {
    return _firstConnectedAt;
  }

  // Helper method to get stored device from SharedPreferences
  BtDevice? _getStoredDevice(String id) {
    try {
      final storedDevice = SharedPreferencesUtil().btDevice;
      if (storedDevice.id == id && storedDevice.id.isNotEmpty) {
        return storedDevice;
      }
    } catch (e) {
      Logger.debug('Error getting stored device: $e');
    }
    return null;
  }

  @override
  Future<void> disconnectDevice({bool isManual = true}) async {
    await _mutex.acquire();
    try {
      await _disconnectLocked(isManual: isManual);
    } finally {
      _mutex.release();
    }
  }

  // Assumes [_mutex] is held. Teardown runs under the same lock ensureConnection and the
  // recycle reconnect use, so "is _connection still ours?" checks are atomic w.r.t. a
  // racing disconnect/forget (a teardown either lands fully before a reconnect's guard —
  // which then bails — or fully after it, re-tearing down; it can't interleave).
  Future<void> _disconnectLocked({bool isManual = true}) async {
    if (_connection != null) {
      Logger.debug("DeviceService: Disconnecting device (isManual: $isManual)...");
      await _connection?.disconnect(isManual: isManual);
      _connection = null;
    }
  }

  @override
  Future<void> recycleConnection() async {
    if (_recycling) {
      Logger.debug('[DeviceService] recycleConnection: already in progress, skipping');
      return;
    }
    final conn = _connection;
    if (conn == null) {
      Logger.debug('[DeviceService] recycleConnection: no active connection, skipping');
      return;
    }
    _recycling = true;
    final deviceId = conn.device.id;
    Logger.warning('[DeviceService] recycleConnection: dropping current GATT for $deviceId '
        'and reconnecting fresh (wedge recovery)');
    try {
      // Soft-disconnect the CURRENT (possibly wedged) GATT without unmanaging the
      // device. Android: it stays managed → native rebuilds a fresh gatt on its own.
      // iOS: marks it manually-disconnected → the ensureConnection below reconnects.
      try {
        await conn.transport.softDisconnect();
      } catch (e) {
        Logger.debug('[DeviceService] recycleConnection: softDisconnect failed: $e');
      }
      // Wait (bounded, OUTSIDE the mutex — we won't hold it for 5s) for the native
      // disconnect callback to flip our status before escalating/reconnecting.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (conn.status == DeviceConnectionState.connected && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 150));
      }
      // Escalate (if the soft-disconnect was swallowed) and reconnect UNDER the mutex, so
      // the "is _connection still ours?" guard is atomic with a racing disconnect/forget
      // (both now take the same lock). Without that, a manual teardown could complete
      // between the guard and the reconnect and be undone.
      await _recycleReconnectLocked(conn, deviceId);
    } finally {
      _recycling = false;
    }
  }

  /// Escalate (if the soft-disconnect left a stale "connected" status) and reconnect
  /// [conn]'s device under [_mutex] — the same lock disconnectDevice/forgetDevice/
  /// ensureConnection hold. Holding it across the guard AND the reconnect makes them
  /// atomic w.r.t. a racing manual teardown: the teardown lands either fully before
  /// (guard bails) or fully after (it re-tears down). Called only from recycleConnection.
  Future<void> _recycleReconnectLocked(DeviceConnection conn, String deviceId) async {
    await _mutex.acquire();
    try {
      // A manual disconnect/forget (or a different device connecting) replaced our
      // captured connection — don't resurrect a device the user just tore down.
      if (!identical(_connection, conn)) {
        Logger.debug('[DeviceService] recycleConnection: connection superseded — not reconnecting');
        return;
      }
      // If the soft-disconnect produced no disconnect callback (deep wedge / OEM stack
      // that swallows gatt.disconnect), status is still "connected". Escalate to a full
      // disconnect: it force-closes the gatt (refresh + close) and flips state to
      // disconnected. Heavier (it unmanages), but only a fallback; the reconnect below
      // re-manages and clears USER_DISCONNECTED.
      if (conn.status == DeviceConnectionState.connected) {
        Logger.warning('[DeviceService] recycleConnection: soft-disconnect left status connected '
            'after 5s — escalating to a full disconnect');
        try {
          await conn.disconnect(isManual: false);
        } catch (e) {
          Logger.debug('[DeviceService] recycleConnection: escalated disconnect failed: $e');
        }
      }
      // Reuses _connection == conn (same device id). Mirrors ensureConnection(force)'s
      // body, but atomically after the guard so a swallowed-disconnect wedge can't leave
      // ensureConnection's connected fast-path handing back the same wedged connection.
      try {
        await _connectToDevice(deviceId);
        _firstConnectedAt ??= DateTime.now();
      } catch (e) {
        Logger.debug('[DeviceService] recycleConnection: reconnect failed (native/schedule retries): $e');
      }
    } finally {
      _mutex.release();
    }
  }

  @override
  Future<void> forgetDevice(String deviceId) async {
    Logger.debug("DeviceService: Forgetting device $deviceId");
    // Under the mutex so a concurrent recycle reconnect can't resurrect the device
    // between this teardown and its guard (uses _disconnectLocked to avoid re-acquiring).
    await _mutex.acquire();
    try {
      if (_connection != null) {
        if (_connection!.status == DeviceConnectionState.connected) {
          try {
            await _connection?.sendUnpairCommand();
            // Give the Omi a moment to process the command before we sever the link
            await Future.delayed(const Duration(milliseconds: 500));
          } catch (e) {
            Logger.debug("DeviceService: Failed to send unpair command to Omi: $e");
          }

          try {
            await _disconnectLocked(isManual: true);
          } catch (e) {
            Logger.debug("DeviceService: disconnect during forget failed: $e");
          }
        }

        try {
          await _connection?.transport.dispose();
        } catch (e) {
          Logger.debug("DeviceService: transport dispose during forget failed: $e");
        }
        _connection = null;
      }

      _devices.removeWhere((d) => d.id == deviceId);
    } finally {
      _mutex.release();
    }

    try {
      await BleHostApi().removeBond(deviceId);
    } catch (e) {
      Logger.debug("DeviceService: Failed to remove bond natively: $e");
    }
  }

  @override
  Future<bool> hasCompanionDeviceAssociation() {
    return BleHostApi().hasCompanionDeviceAssociation();
  }

  @override
  Future<String> requestCompanionDeviceAssociation(String deviceId) {
    return BleHostApi().requestCompanionDeviceAssociation(deviceId);
  }
}
