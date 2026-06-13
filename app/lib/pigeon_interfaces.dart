import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/gen/pigeon_communicator.g.dart',
  dartOptions: DartOptions(),
  swiftOut: 'ios/Runner/PigeonCommunicator.g.swift',
  swiftOptions: SwiftOptions(),
  kotlinOut: 'android/app/src/main/kotlin/com/omi/offline/PigeonCommunicator.g.kt',
  kotlinOptions: KotlinOptions(package: 'com.omi.offline'),
  dartPackageName: 'omi_pigeon',
))

// =============================================================================
// Watch Recorder APIs
// =============================================================================

@HostApi()
abstract class WatchRecorderHostAPI {
  @SwiftFunction('startRecording()')
  void startRecording();
  @SwiftFunction('stopRecording()')
  void stopRecording();
  @SwiftFunction('sendAudioData(audioData:)')
  void sendAudioData(Uint8List audioData);
  @SwiftFunction('sendAudioChunk(audioChunk:chunkIndex:isLast:sampleRate:)')
  void sendAudioChunk(Uint8List audioChunk, int chunkIndex, bool isLast, double sampleRate);
  @SwiftFunction('isWatchPaired()')
  bool isWatchPaired();
  @SwiftFunction('isWatchReachable()')
  bool isWatchReachable();
  @SwiftFunction('isWatchSessionSupported()')
  bool isWatchSessionSupported();
  @SwiftFunction('isWatchAppInstalled()')
  bool isWatchAppInstalled();
  @SwiftFunction('requestWatchMicrophonePermission()')
  void requestWatchMicrophonePermission();
  @SwiftFunction('requestMainAppMicrophonePermission()')
  void requestMainAppMicrophonePermission();
  @SwiftFunction('checkMainAppMicrophonePermission()')
  bool checkMainAppMicrophonePermission();
  @SwiftFunction('getWatchBatteryLevel()')
  double getWatchBatteryLevel();
  @SwiftFunction('getWatchBatteryState()')
  int getWatchBatteryState();
  @SwiftFunction('requestWatchBatteryUpdate()')
  void requestWatchBatteryUpdate();
  @SwiftFunction('getWatchInfo()')
  Map<String, String> getWatchInfo();
}

@FlutterApi()
abstract class WatchRecorderFlutterAPI {
  void onRecordingStarted();
  void onRecordingStopped();
  void onAudioData(Uint8List audioData);
  void onAudioChunk(Uint8List audioChunk, int chunkIndex, bool isLast, double sampleRate);
  void onRecordingError(String error);
  void onMicrophonePermissionResult(bool granted);
  void onMainAppMicrophonePermissionResult(bool granted);
  void onWatchBatteryUpdate(double batteryLevel, int batteryState);
}

// =============================================================================
// BLE APIs
// =============================================================================

/// Discovered BLE peripheral info passed from native to Dart.
class BlePeripheral {
  final String uuid;
  final String name;
  final int rssi;
  final List<String> serviceUuids;

  BlePeripheral({
    required this.uuid,
    required this.name,
    required this.rssi,
    required this.serviceUuids,
  });
}

/// Discovered BLE service with its characteristic UUIDs.
class BleService {
  final String uuid;
  final List<String> characteristicUuids;

  BleService({required this.uuid, required this.characteristicUuids});
}

/// Dart → Native: commands sent from Flutter to the native BLE module.
@HostApi()
abstract class BleHostApi {
  @SwiftFunction('startScan(timeout:serviceUuids:)')
  void startScan(int timeoutSeconds, List<String> serviceUuids);

  @SwiftFunction('stopScan()')
  void stopScan();

  @SwiftFunction('manageDevice(uuid:requiresBond:)')
  void manageDevice(String uuid, bool requiresBond);

  @SwiftFunction('unmanageDevice(uuid:)')
  void unmanageDevice(String uuid);

  @SwiftFunction('removeBond(uuid:)')
  void removeBond(String uuid);

  @SwiftFunction('disconnectPeripheral(uuid:)')
  void disconnectPeripheral(String uuid);

  /// (Android only) Reschedule the WorkManager periodic background sync with
  /// the given interval. Pass 0 or negative to cancel. iOS no-op.
  @SwiftFunction('rescheduleBackgroundSync(intervalMinutes:)')
  void rescheduleBackgroundSync(int intervalMinutes);

  @async
  @SwiftFunction('requestBond(uuid:)')
  bool requestBond(String uuid);

  // Characteristic operations
  @async
  @SwiftFunction('readCharacteristic(peripheralUuid:serviceUuid:characteristicUuid:)')
  Uint8List readCharacteristic(String peripheralUuid, String serviceUuid, String characteristicUuid);

  @async
  @SwiftFunction('writeCharacteristic(peripheralUuid:serviceUuid:characteristicUuid:data:)')
  void writeCharacteristic(String peripheralUuid, String serviceUuid, String characteristicUuid, Uint8List data);

  @SwiftFunction('subscribeCharacteristic(peripheralUuid:serviceUuid:characteristicUuid:)')
  void subscribeCharacteristic(String peripheralUuid, String serviceUuid, String characteristicUuid);

  @SwiftFunction('unsubscribeCharacteristic(peripheralUuid:serviceUuid:characteristicUuid:)')
  void unsubscribeCharacteristic(String peripheralUuid, String serviceUuid, String characteristicUuid);

  // State
  @SwiftFunction('getBluetoothState()')
  String getBluetoothState();

  @SwiftFunction('isPeripheralConnected(uuid:)')
  bool isPeripheralConnected(String uuid);

  /// (Android only) Check if any CompanionDeviceManager association exists.
  @SwiftFunction('hasCompanionDeviceAssociation()')
  bool hasCompanionDeviceAssociation();

  /// (Android only) Initiate CompanionDeviceManager association for a device.
  @async
  @SwiftFunction('requestCompanionDeviceAssociation(deviceAddress:)')
  String requestCompanionDeviceAssociation(String deviceAddress);

  /// (Android only) Download a storage file natively, bypassing the per-packet
  /// platform-channel dispatch that throttles in background. Accumulates BLE
  /// notifications on the binder thread and writes directly to [outputPath].
  /// iOS throws 'unimplemented' — callers must check Platform.isAndroid.
  @async
  @SwiftFunction('downloadStorageFile(peripheralUuid:fileIndex:offset:timerStart:outputPath:)')
  void downloadStorageFile(
    String peripheralUuid,
    int fileIndex,
    int offset,
    int timerStart,
    String outputPath,
  );

  /// (Android only) Acquire a CPU partial wake-lock so the OS does not throttle
  /// the processing isolate during VAD inference. Call before processAll; release
  /// in finally. iOS no-op.
  @SwiftFunction('acquireProcessingWakeLock()')
  void acquireProcessingWakeLock();

  /// (Android only) Release the CPU partial wake-lock acquired by
  /// [acquireProcessingWakeLock]. iOS no-op.
  @SwiftFunction('releaseProcessingWakeLock()')
  void releaseProcessingWakeLock();

  /// (Android only) Push the next-sync epoch-ms to OmiBleForegroundService so it
  /// can display a native Chronometer countdown without Dart involvement.
  /// Pass 0 to clear (e.g. Manual Only mode). iOS no-op.
  @SwiftFunction('setNextSyncTime(timestampMs:)')
  void setNextSyncTime(int timestampMs);

  /// (Android only) Push the device battery level and the epoch-ms when it was
  /// read to OmiBleForegroundService so ID 2001 shows "78% · 3:45 PM".
  /// Call whenever a battery reading is obtained. iOS no-op.
  @SwiftFunction('setDeviceBattery(level:timestampMs:)')
  void setDeviceBattery(int level, int timestampMs);

  /// (Android only) Set the single foreground-service notification's title and
  /// text directly. Used by the Dart sync state machine to drive the one
  /// persistent notification (idle / connecting / syncing / processing / …).
  /// While a status is set, native suppresses its own connection-state text so
  /// the two don't fight. iOS no-op.
  @SwiftFunction('setSyncStatus(title:text:)')
  void setSyncStatus(String title, String text);

  /// (Android only) Keep the foreground service alive with no device connected
  /// so the idle "Next sync / Last Sync" notification persists across BLE
  /// disconnect and app background. true while auto-sync is on and a device is
  /// bound; false in Manual Only / unbound (reverts to connection-only service
  /// lifetime). iOS no-op.
  @SwiftFunction('setPersistentNotification(enabled:)')
  void setPersistentNotification(bool enabled);

  /// (Android only) Clear any Dart-pushed status text and let native resume
  /// owning the notification (connection state / idle). iOS no-op.
  @SwiftFunction('clearSyncStatus()')
  void clearSyncStatus();
}

@FlutterApi()
abstract class BleFlutterApi {
  void onBluetoothStateChanged(String state);

  void onPeripheralDiscovered(BlePeripheral peripheral);

  void onDeviceReady(String peripheralUuid, List<BleService> services);

  void onPeripheralDisconnected(String peripheralUuid, String? error);

  void onCharacteristicValueUpdated(
    String peripheralUuid,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value,
  );

  void onStateRestored(List<String> peripheralUuids);

  /// Called by native (iOS BGProcessingTask / Android WorkManager) when a
  /// background sync should be triggered. Equivalent to a timer-fired sync tick
  /// but sourced from the OS scheduler instead of the Dart timer.
  void onBackgroundSyncRequested();
}
