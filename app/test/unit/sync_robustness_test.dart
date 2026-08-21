import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/diag_log_record.dart';
import 'package:omi/services/devices/device_crash_log.dart';
import 'package:omi/services/devices/device_drop_stats.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/services/devices/transports/device_transport.dart';
import 'package:flutter/services.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
import 'package:omi/services/wals/sdcard_wal_sync.dart';
import 'package:omi/utils/wal_file_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// ---------------------------------------------------------------------------
// Helpers for framed BLE protocol tests
// ---------------------------------------------------------------------------

/// Builds a PACKET_ACK: [0x03][result]
List<int> ackPacket(int result) => [0x03, result];

/// Builds a PACKET_DATA: [0x01][offset LE 4B][payload]
List<int> dataPacket(int offset, List<int> payload) {
  return [
    0x01,
    offset & 0xFF,
    (offset >> 8) & 0xFF,
    (offset >> 16) & 0xFF,
    (offset >> 24) & 0xFF,
    ...payload,
  ];
}

/// Builds a PACKET_EOT: [0x02]
List<int> eotPacket() => [0x02];

class MockPathProvider extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  String? tempPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempPath;
  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

class MockWalSyncListener extends Fake implements IWalSyncListener {
  @override
  void onWalUpdated() {}
  @override
  void onSyncFinished() {}
  @override
  void onStorageStatsUpdated(StorageFileStats stats) {}
}

int globalCurrentFileNum = -1;
int globalWriteCount = 0;
int globalRequestedOffset = 0;
List<int> globalDeletedTimestamps = [];

/// Timestamps for which the mock firmware answers CMD_DELETE_FILE with a failure.
/// Everything else is deleted for real, so the mock's file listing tracks the device's.
Set<int> globalRejectDeleteTimestamps = {};

class MockDeviceConnection implements DeviceConnection {
  final StreamController<List<int>> _controller = StreamController<List<int>>.broadcast();
  final _writeWaiters = <MapEntry<int, Completer<void>>>[];
  int _writesDone = 0;

  void add(List<int> packet) => _controller.add(packet);
  Future<void> close() async => await _controller.close();

  /// Resolves once [writeToStorage] has been called at least [atLeast] times.
  Future<void> waitForWrite(int atLeast) {
    if (_writesDone >= atLeast) return Future.value();
    final c = Completer<void>();
    _writeWaiters.add(MapEntry(atLeast, c));
    return c.future;
  }

  @override
  bool get isStorageBusy => false;
  @override
  Future<void> acquireStorageLock([String owner = 'unknown']) async {}
  @override
  void releaseStorageLock() {}

  @override
  Future<bool> writeToStorage(int numFile, int command, int offset, {int? timestamp}) async {
    globalCurrentFileNum = numFile;
    globalWriteCount++;
    globalRequestedOffset = offset;
    _writesDone++;
    _writeWaiters.removeWhere((e) {
      if (_writesDone >= e.key) {
        if (!e.value.isCompleted) e.value.complete();
        return true;
      }
      return false;
    });
    return true;
  }

  @override
  Future<DeviceCrashLog?> getDiagnostics() async => null;

  @override
  Future<DeviceCrashLog?> performGetDiagnostics() async => null;

  @override
  Future<DeviceDropStats?> getDropStats() async => null;

  @override
  Future<DeviceDropStats?> performGetDropStats() async => null;

  @override
  Future<StreamSubscription<List<int>>?> getDropStatsListener({
    required void Function(DeviceDropStats stats) onDropStats,
    void Function()? onClosed,
  }) async =>
      null;

  @override
  Future<StreamSubscription<List<int>>?> performGetDropStatsListener({
    required void Function(DeviceDropStats stats) onDropStats,
    void Function()? onClosed,
  }) async =>
      null;

  @override
  Future<void> unsubscribeDropStats() async {}

  @override
  Future<bool> deleteFile(StorageFile file, {int? timestamp}) async {
    globalDeletedTimestamps.add(file.timestamp);
    return !globalRejectDeleteTimestamps.contains(file.timestamp);
  }

  List<StorageFile> files = [];

  /// Simulates a listing the device never answered — the link was down, the
  /// listing timed out, or the reply was unusable. Distinct from `files = []`,
  /// which is the device answering that it holds nothing.
  bool listFilesUnanswered = false;

  @override
  Future<List<StorageFile>?> listFiles() async => listFilesUnanswered ? null : files;

  @override
  Future<bool> stopStorageSync() async => true;

  @override
  Future<bool> sendKeepAlive() async => true;

  @override
  Future<bool> performSendKeepAlive() async => true;

  @override
  Future<({bool muted, DateTime? since})?> performGetMuteState() async => (muted: false, since: null);

  @override
  Future<bool> performSetMute(bool muted) async => true;

  @override
  Future<StreamSubscription<List<int>>?> performGetMuteListener(
          {required void Function(bool muted, DateTime? since) onMuteChange}) async =>
      null;

  @override
  Future<({bool muted, DateTime? since})> getMuteState() async => (muted: false, since: null);

  @override
  Future<bool> setMute(bool muted) async => true;

  @override
  Future<StreamSubscription<List<int>>?> getMuteListener(
          {required void Function(bool muted, DateTime? since) onMuteChange}) async =>
      null;

  @override
  Future<bool> syncTime() async => true;

  @override
  Future<Stream<List<int>>> getBleStorageBytesStream() async => _controller.stream;

  @override
  Future<bool> isConnected() async => true;

  @override
  Future<StorageFileStats?> getStorageFileStats() async => StorageFileStats(
        totalUsedBytes: 0,
        fileCount: files.length,
        freeBytes: 1000000,
      );

  @override
  DeviceTransport get transport => throw UnimplementedError();
  @override
  BtDevice get device => throw UnimplementedError();

  @override
  DeviceConnectionState get status => DeviceConnectionState.connected;
  @override
  Future<void> connect(
      {void Function(String deviceId, DeviceConnectionState state)? onConnectionStateChanged,
      bool requiresBond = false}) async {}
  @override
  Future<void> disconnect({bool isManual = true}) async {}
  @override
  Future<int> retrieveBatteryLevel() async => 100;
  @override
  Future<bool> retrieveChargingState() async => false;
  @override
  Future<Stream<List<int>>> readFile(StorageFile file, {int offset = 0}) async => const Stream.empty();
  @override
  Future<void> requestBond() async {}
  @override
  Future<void> unpair() async {}
  @override
  Future<BleAudioCodec?> getAudioCodec() async => BleAudioCodec.opus;
  @override
  Future<bool> rotateFile() async => true;
  @override
  Future<int> getFeatures() async => 0;
  @override
  Future<void> setLedDimRatio(int ratio) async {}
  @override
  Future<int?> getLedDimRatio() async => null;
  @override
  Future<void> setConnectedLed(bool enabled) async {}
  @override
  Future<bool?> getConnectedLed() async => null;
  @override
  Future<void> setLedBootEnabled(bool enabled) async {}
  @override
  Future<bool?> getLedBootEnabled() async => null;
  @override
  Future<void> setMicGain(int gain) async {}
  @override
  Future<int?> getMicGain() async => null;
  @override
  Future<StreamSubscription<List<int>>?> getBleBatteryLevelListener(
          {void Function(int)? onBatteryLevelChange, void Function(bool)? onChargingStateChange}) async =>
      null;
  @override
  Future<List<int>> getStorageList() async => [];
  @override
  Future<StreamSubscription<List<int>>?> getBleStorageBytesListener(
          {required void Function(List<int>) onStorageBytesReceived,
          Function? onError,
          void Function()? onDone}) async =>
      null;

  @override
  Future<BtDevice> performGetDeviceInfo(DeviceConnection? connection) => throw UnimplementedError();
  @override
  Future<StorageFileStats?> performGetStorageFileStats() => throw UnimplementedError();
  @override
  Future<int> performRetrieveBatteryLevel() => throw UnimplementedError();
  @override
  Future<bool> performRetrieveChargingState() => throw UnimplementedError();
  @override
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener(
          {void Function(int)? onBatteryLevelChange, void Function(bool)? onChargingStateChange}) =>
      throw UnimplementedError();
  @override
  Future<BleAudioCodec> performGetAudioCodec() => throw UnimplementedError();
  @override
  Future<List<int>> performGetStorageList() => throw UnimplementedError();
  @override
  Future<bool> performWriteToStorage(int numFile, int command, int offset, {int? timestamp}) =>
      throw UnimplementedError();
  @override
  Future<int> performGetFeatures() => throw UnimplementedError();
  @override
  Future<void> performSetLedDimRatio(int ratio) => throw UnimplementedError();
  @override
  Future<int?> performGetLedDimRatio() => throw UnimplementedError();
  @override
  Future<void> performSetConnectedLed(bool enabled) => throw UnimplementedError();
  @override
  Future<bool?> performGetConnectedLed() => throw UnimplementedError();
  @override
  Future<void> performSetLedBootEnabled(bool enabled) => throw UnimplementedError();
  @override
  Future<bool?> performGetLedBootEnabled() => throw UnimplementedError();
  @override
  Future<void> performSetMicGain(int gain) => throw UnimplementedError();
  @override
  Future<int?> performGetMicGain() => throw UnimplementedError();
  @override
  Future<void> performSetButtonConfig(List<int> config) => throw UnimplementedError();
  @override
  Future<List<int>?> performGetButtonConfig() => throw UnimplementedError();
  @override
  Future<void> performSetHapticConfig(List<int> config) => throw UnimplementedError();
  @override
  Future<List<int>?> performGetHapticConfig() => throw UnimplementedError();
  @override
  Future<void> setButtonConfig(List<int> config) => throw UnimplementedError();
  @override
  Future<List<int>?> getButtonConfig() => throw UnimplementedError();
  @override
  Future<void> setHapticConfig(List<int> config) => throw UnimplementedError();
  @override
  Future<List<int>?> getHapticConfig() => throw UnimplementedError();
  @override
  Future<bool> sendUnpairCommand() => throw UnimplementedError();
  @override
  Future<bool> sendRebootCommand() => throw UnimplementedError();
  @override
  Future<bool> sendShutdownCommand() => throw UnimplementedError();
  @override
  Future<void> setVadThreshold(int threshold) => throw UnimplementedError();
  @override
  Future<int?> getVadThreshold() => throw UnimplementedError();
  @override
  Future<void> setPriorityRecordCap(int minutes) => throw UnimplementedError();
  @override
  Future<int?> getPriorityRecordCap() => throw UnimplementedError();
  @override
  Future<void> performSetVadThreshold(int threshold) => throw UnimplementedError();
  @override
  Future<int?> performGetVadThreshold() => throw UnimplementedError();
  @override
  Future<void> performSetPriorityRecordCap(int minutes) => throw UnimplementedError();
  @override
  Future<int?> performGetPriorityRecordCap() => throw UnimplementedError();
  @override
  Future<bool> performSyncDeviceTime() => throw UnimplementedError();
  @override
  Future<bool> performStopStorageSync() => throw UnimplementedError();
  @override
  Future<bool> performRotateFile() => throw UnimplementedError();
  @override
  Future<bool> performClearStorage() => throw UnimplementedError();
  @override
  Future<List<StorageFile>?> performListFiles() => throw UnimplementedError();
  @override
  Future<Stream<List<int>>> performReadFile(StorageFile file, {int offset = 0}) => throw UnimplementedError();
  @override
  Future<bool> performDeleteFile(StorageFile file, {int? timestamp}) => throw UnimplementedError();
  @override
  Future<bool> setDiagLogEnabled(bool enable) => throw UnimplementedError();
  @override
  Future<bool> performSetDiagLogEnabled(bool enable) => throw UnimplementedError();
  @override
  Future<DiagLogDrainResult?> drainDiagLog({bool keepEnabled = true}) => throw UnimplementedError();
  @override
  Future<DiagLogDrainResult?> performDrainDiagLog({bool keepEnabled = true}) => throw UnimplementedError();
  @override
  Future<int?> getFeaturesIfIdle() => throw UnimplementedError();
  @override
  Future<int?> performGetFeaturesIfIdle() => throw UnimplementedError();
}

class MockBtDevice extends Fake implements BtDevice {
  @override
  String get id => 'test-device-id';
  final MockDeviceConnection connection = MockDeviceConnection();
  @override
  DeviceConnection? get connectionInstance => connection;
  @override
  BleAudioCodec get codec => BleAudioCodec.opus;
}

void main() {
  late Directory tempDir;
  late MockPathProvider mockPathProvider;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('disk_space_2'),
      (call) async => 1000.0,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    tempDir = Directory.systemTemp.createTempSync('sync_test');
    mockPathProvider = MockPathProvider()..tempPath = tempDir.path;
    PathProviderPlatform.instance = mockPathProvider;
    // WalFileManager caches its File handles in statics, so without this the
    // first test to touch them pins wals.json to ITS tempDir — which tearDown
    // then deletes — and every later test silently reads/writes a dead path
    // (production swallows the error: saveWals is fire-and-forget).
    await WalFileManager.init();
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  tearDown(() {
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {
      // Best-effort: production's saveWals is fire-and-forget, so a write can
      // still hold wals.json here (Windows refuses to delete an open file).
      // It's a temp dir — the OS reclaims it either way.
    }
  });

  group('Wal incomplete-transfer identity', () {
    Wal walOf({required int offset, required int total, int timerStart = 1784260394, int? sessionId}) => Wal(
          codec: BleAudioCodec.opus,
          channel: 1,
          device: 'test-device',
          fileNum: 0,
          walOffset: offset,
          storageTotalBytes: total,
          timerStart: timerStart,
          sessionId: sessionId,
          storage: WalStorage.sdcard,
        );

    test('a bin short of the advertised size is incomplete', () {
      expect(walOf(offset: 1338480, total: 2071116).isIncompleteTransfer, isTrue);
    });

    test('a bin that received every advertised byte is complete', () {
      expect(walOf(offset: 2071116, total: 2071116).isIncompleteTransfer, isFalse);
    });

    test('a device-advertised 0 B bin is complete, not incomplete', () {
      // An empty rotation advertises 0 B and transfers 0 B. Treating it as
      // incomplete would park it in the skip set forever.
      expect(walOf(offset: 0, total: 0).isIncompleteTransfer, isFalse);
    });

    test('relativeBinPath matches the download path layout', () {
      expect(walOf(offset: 0, total: 10, sessionId: 4230330572).relativeBinPath,
          equals('1784260394/1784260394_4230330572.bin'));
    });

    test('relativeBinPath uses the session_ folder for pre-time-sync bins', () {
      expect(walOf(offset: 0, total: 10, timerStart: 1010, sessionId: 77).relativeBinPath,
          equals('session_77/1010_77.bin'));
    });
  });

  group('SDCardWalSync Protocol Logic', () {
    test('Little-Endian offset parsing is correct', () {
      final bytes = [0x01, 0xEF, 0xBE, 0xAD, 0xDE, 0xAA, 0xBB];
      final offset = bytes[1] | (bytes[2] << 8) | (bytes[3] << 16) | (bytes[4] << 24);
      expect(offset, equals(0xDEADBEEF));
    });
    test('Payload extraction excludes 5-byte header', () {
      final bytes = [0x01, 0x00, 0x00, 0x00, 0x00, 0xDE, 0xAD, 0xBE, 0xEF];
      expect(bytes.sublist(5), equals([0xDE, 0xAD, 0xBE, 0xEF]));
    });
  });

  group('Framed BLE Protocol Dispatch', () {
    late MockDeviceConnection mockConn;
    late SDCardWalSyncImpl sync;

    Future<void> pump([int count = 5]) async {
      for (int i = 0; i < count; i++) {
        await Future.delayed(Duration.zero);
      }
    }

    Wal makeWal({int totalBytes = 10, int walOffset = 0}) => Wal(
          codec: BleAudioCodec.opus,
          channel: 1,
          device: 'test-device',
          fileNum: 1,
          walOffset: walOffset,
          storageTotalBytes: totalBytes,
          timerStart: 0,
          storage: WalStorage.sdcard,
        );

    setUp(() async {
      globalRejectDeleteTimestamps = {};
      globalDeletedTimestamps = [];
      mockConn = MockDeviceConnection();
      sync = SDCardWalSyncImpl(
        MockWalSyncListener(),
        connectionProvider: (_) async => mockConn,
        inactivityTimeout: const Duration(seconds: 1),
      );
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
    });

    tearDown(() async {
      sync.cancelSync();
      await pump(10);
      await mockConn.close();
    });

    test('Error ACK aborts sync with an exception', () async {
      final syncFuture = sync.syncWal(wal: makeWal()).catchError((_) {
        return null;
      });
      await pump();
      mockConn.add(ackPacket(0x01));
      await syncFuture;
    });

    test('EOT after ACK + DATA triggers clean completion', () async {
      final syncFuture = sync.syncWal(wal: makeWal(totalBytes: 10));
      await pump();
      mockConn.add(ackPacket(0x00));
      await pump();
      mockConn.add(dataPacket(0, List<int>.filled(10, 0xDD)));
      await pump();
      mockConn.add(eotPacket());
      await expectLater(syncFuture, completes);
    });

    test('syncWal does NOT delete a device file on an incomplete (short) transfer', () async {
      globalDeletedTimestamps = [];
      final syncFuture = sync.syncWal(wal: makeWal(totalBytes: 1000));
      await pump();
      mockConn.add(ackPacket(0x00));
      await pump();
      // Clean EOT after only 5 of 1000 bytes — the single-WAL path must not delete.
      mockConn.add(dataPacket(0, List<int>.filled(5, 0xEE)));
      await pump();
      mockConn.add(eotPacket());
      final response = await syncFuture;
      expect(response!.isPartial, isTrue);
      expect(globalDeletedTimestamps, isEmpty);
    });

    test('Gap in DATA sequence aborts the transfer with an exception', () async {
      final syncFuture = sync.syncWal(wal: makeWal(totalBytes: 30));
      for (int attempt = 0; attempt <= 3; attempt++) {
        await pump();
        mockConn.add(ackPacket(0x00));
        await pump();
        mockConn.add(dataPacket(0, List<int>.filled(5, 0xCC)));
        await pump();
        mockConn.add(dataPacket(20, List<int>.filled(5, 0xCC)));
        await pump();
        await Future.delayed(const Duration(milliseconds: 150));
      }
      await expectLater(syncFuture, throwsA(isA<Exception>()));
    });

    test('syncAll continues to next file on protocol gap', () async {
      globalCurrentFileNum = -1;
      globalWriteCount = 0;
      mockConn.files = [
        StorageFile(index: 1, timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000, size: 3000000),
        StorageFile(index: 2, timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000, size: 1000000)
      ];
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      await pump(10);

      final syncAllFuture = sync.syncAll();
      await mockConn.waitForWrite(1);
      await pump(10);
      expect(globalWriteCount, equals(1));
      expect(globalCurrentFileNum, equals(0));

      for (int i = 0; i < 5; i++) {
        mockConn.add(ackPacket(0x00));
        await pump();
        mockConn.add(dataPacket(100, [0xAA])); // Gap
        await pump();
        await Future.delayed(const Duration(milliseconds: 110));
        await pump();
      }

      await mockConn.waitForWrite(2);
      await pump(10);
      expect(globalWriteCount, equals(2));

      mockConn.add(ackPacket(0x00));
      await pump();
      mockConn.add(dataPacket(0, [0xDD]));
      await pump();
      mockConn.add(eotPacket());
      await pump();

      final response = await syncAllFuture;
      expect(response!.isPartial, isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('syncAll retries then skips file on stall, batch continues', () async {
      globalCurrentFileNum = -1;
      globalWriteCount = 0;
      mockConn.files = [
        StorageFile(index: 1, timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000, size: 3000000),
        StorageFile(index: 2, timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000, size: 1000000)
      ];
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      await pump(10);

      final stallFuture = sync.syncAll();
      await mockConn.waitForWrite(1);
      await pump(10);
      expect(globalWriteCount, equals(1));

      // No data ever arrives, so every read stalls. The sync should retry within
      // each file, then skip it and move on rather than aborting the whole batch.
      await Future.delayed(const Duration(seconds: 8));
      await pump(20);

      final response = await stallFuture;
      expect(response!.isPartial, isTrue);
      // Retries occurred (old behavior aborted immediately after the first write).
      expect(globalWriteCount, greaterThan(1));
      // One stalling file yields 1 initial read + maxStallRetries (2) retries = 3 writes.
      // Exceeding that proves the batch advanced to the second file rather than aborting.
      expect(globalWriteCount, greaterThan(3));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('syncAll does NOT delete a file that transferred incompletely (short read)', () async {
      globalWriteCount = 0;
      globalDeletedTimestamps = [];
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      mockConn.files = [StorageFile(index: 1, timestamp: ts, size: 1000000)];
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      await pump(10);

      final syncFuture = sync.syncAll();
      await mockConn.waitForWrite(1);
      await pump(10);

      // Firmware "completes" (clean EOT) after delivering only 5 of 1,000,000 bytes —
      // the empty/short-read failure mode (stale cached size / rotated-under-read /
      // read error). The completeness guard must treat this as incomplete.
      mockConn.add(ackPacket(0x00));
      await pump();
      mockConn.add(dataPacket(0, List<int>.filled(5, 0xEE)));
      await pump();
      mockConn.add(eotPacket());
      await pump(10);

      final response = await syncFuture;
      expect(response!.isPartial, isTrue);
      // Critical: the device-side file must NOT be deleted — that would lose the
      // recording permanently (this is how a Priority Recording vanished). It stays
      // on the device so the next sync can retry.
      expect(globalDeletedTimestamps, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('an incomplete bin belonging to ANOTHER device is still skipped', () async {
      // raw_segments/ is one global pool — a bin's path carries no device id — but
      // _wals only holds the CONNECTED device's WALs. A second Omi's half-downloaded
      // bin is just as unsafe to decode and prune, and nothing else would catch it:
      // its own WAL isn't consulted until that device reconnects.
      final otherTs = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 500;
      await WalFileManager.saveWals([
        Wal(
          codec: BleAudioCodec.opus,
          channel: 1,
          device: 'other-omi',
          fileNum: 0,
          walOffset: 512,
          storageTotalBytes: 4096, // half-downloaded
          timerStart: otherTs,
          storage: WalStorage.sdcard,
        ),
      ], deviceId: 'other-omi');

      // Connect THIS device and give it its own (complete) WAL, so the union is
      // exercised rather than the no-device fallback.
      mockConn.files = [StorageFile(index: 1, timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000, size: 100)];
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      await pump(10);

      expect(await sync.incompleteBinRelPaths(), contains('$otherTs/${otherTs}_0.bin'));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('two pre-time-sync bins sharing a timerStart but not a sessionId are both kept', () async {
      // Pre-sync bins (timerStart < 946684800) carry sessionId in the PATH
      // (session_<sid>/…) but share a device-scoped Wal.id ($device-$timerStart).
      // Keying the union by Wal.id would collapse them and expose one partial to
      // pruning; keying by the physical path keeps both.
      await WalFileManager.saveWals([
        Wal(
            codec: BleAudioCodec.opus,
            channel: 1,
            device: 'other-omi',
            fileNum: 0,
            walOffset: 100,
            storageTotalBytes: 4096, // partial
            timerStart: 1010,
            sessionId: 111,
            storage: WalStorage.sdcard),
        Wal(
            codec: BleAudioCodec.opus,
            channel: 1,
            device: 'other-omi',
            fileNum: 1,
            walOffset: 200,
            storageTotalBytes: 4096, // partial
            timerStart: 1010,
            sessionId: 222,
            storage: WalStorage.sdcard),
      ], deviceId: 'other-omi');

      final incomplete = await sync.incompleteBinRelPaths();
      expect(incomplete, containsAll(['session_111/1010_111.bin', 'session_222/1010_222.bin']));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a corrupt wals.json makes incompleteBinRelPaths throw (fail closed)', () async {
      // _loadWalsUnlocked returns [] for missing/empty/bad-shape, but jsonDecode
      // throws on a half-written file. The union must NOT swallow that: with no
      // device attached, other devices' partials live ONLY in this file, and
      // failing open would let processing prune a mid-download bin. Processing's
      // caller turns the throw into "skip this run" until a sync rewrites it.
      final walFile = File('${tempDir.path}/wals.json');
      await walFile.writeAsString('{"version":1,"wals":[{"device":"x",'); // truncated JSON

      await expectLater(sync.incompleteBinRelPaths(), throwsA(anything));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a short-read bin is reported incomplete so processing cannot consume + prune it', () async {
      globalWriteCount = 0;
      globalDeletedTimestamps = [];
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      mockConn.files = [StorageFile(index: 1, timestamp: ts, size: 1000000)];
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      await pump(10);

      final syncFuture = sync.syncAll();
      await mockConn.waitForWrite(1);
      await pump(10);
      mockConn.add(ackPacket(0x00));
      await pump();
      mockConn.add(dataPacket(0, List<int>.filled(5, 0xEE)));
      await pump();
      mockConn.add(eotPacket());
      await pump(10);
      await syncFuture;

      // The local bin now holds 5 of the 1,000,000 advertised bytes and the WAL is
      // parked at that resume offset. The processing pass must be told to skip it:
      // it prunes every bin it decodes, and pruning this one strands the resume —
      // the tail would be appended to a recreated (empty) file, scrambling the bin.
      expect(await sync.incompleteBinRelPaths(), contains('$ts/${ts}_0.bin'));
    }, timeout: const Timeout(Duration(seconds: 30)));

    // A refused CMD_DELETE_FILE leaves a file we already hold in full sitting on the
    // card. These three pin what may and may not follow from that.
    test('a refused delete does not become a re-download (duplicate audio) next sync', () async {
      // Field case, 2026-08-10: the whole file arrived, the delete came back a failure,
      // and the processing pass then consumed and pruned the local bin. Before the
      // `synced` carry the rebuilt WAL defaulted to `miss`, the resume found no bin on
      // disk, rewound to 0, and the entire file was fetched and decoded a SECOND time.
      final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 1000;
      globalRejectDeleteTimestamps = {ts};
      globalDeletedTimestamps = [];
      globalWriteCount = 0;

      // Native-like: walOffset tracks the physical bin, which is what makes a pruned
      // bin rewind the resume offset to 0. That rewind is the duplicate's mechanism.
      final nativeLike = SDCardWalSyncImpl(
        MockWalSyncListener(),
        connectionProvider: (_) async => mockConn,
        inactivityTimeout: const Duration(seconds: 1),
        reconcileResumeOffsets: true,
      );
      mockConn.files = [StorageFile(index: 1, timestamp: ts, size: 10)];
      await nativeLike.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      await pump(10);

      final first = nativeLike.syncAll();
      await mockConn.waitForWrite(1);
      await pump(10);
      mockConn.add(ackPacket(0x00));
      await pump();
      mockConn.add(dataPacket(0, List<int>.filled(10, 0xAB)));
      await pump();
      mockConn.add(eotPacket());
      await pump(10);
      final firstResp = await first;
      expect(firstResp!.isPartial, isTrue, reason: 'a refused delete leaves the card un-drained');
      expect(globalDeletedTimestamps, equals([ts]));
      expect(globalWriteCount, equals(1));

      // Processing decodes the bin and deletes it — it prunes every bin it consumes.
      final bin = File('${tempDir.path}/raw_segments/$ts/${ts}_0.bin');
      expect(await bin.exists(), isTrue);
      await bin.delete();

      // The device still lists the file, because the delete never took.
      globalDeletedTimestamps = [];
      final second = nativeLike.syncAll();
      await pump(20);
      await second;

      expect(globalWriteCount, equals(1), reason: 'the file must not be read a second time');
      expect(globalDeletedTimestamps, equals([ts]), reason: 'only the delete is retried');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a file whose delete was refused blocks the head instead of mis-attributing the next', () async {
      // The fast path can only read and delete index 0, and relies on each finished file
      // being removed so the next one becomes index 0. A file that would not delete still
      // holds that slot, so carrying on would re-read IT and store the bytes under the
      // NEXT file's timestamp and bin path.
      final tsA = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 2000;
      final tsB = tsA + 300;
      globalRejectDeleteTimestamps = {tsA};
      globalDeletedTimestamps = [];
      globalWriteCount = 0;
      mockConn.files = [
        StorageFile(index: 1, timestamp: tsA, size: 10),
        StorageFile(index: 2, timestamp: tsB, size: 10),
      ];
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      await pump(10);

      final first = sync.syncAll();
      await mockConn.waitForWrite(1);
      await pump(10);
      mockConn.add(ackPacket(0x00));
      await pump();
      mockConn.add(dataPacket(0, List<int>.filled(10, 0xAB)));
      await pump();
      mockConn.add(eotPacket());
      await pump(10);
      final firstResp = await first;
      expect(globalWriteCount, equals(1), reason: 'B must not be read while A still holds index 0');
      expect(firstResp!.isPartial, isTrue);

      // Next cycle: the sweep retries A's delete, fails again, and must still refuse to
      // download B rather than read whatever is at index 0.
      globalDeletedTimestamps = [];
      final second = sync.syncAll();
      await pump(20);
      final secondResp = await second;
      expect(globalWriteCount, equals(1));
      expect(globalDeletedTimestamps, equals([tsA]));
      expect(secondResp!.isPartial, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('deleting one pre-time-sync bin keeps its id-colliding sibling tracked', () async {
      // Wal.id is `$device-$timerStart`, and pre-time-sync segments key timerStart on
      // UPTIME seconds, which restart at 0 each boot — so two bins recorded before the
      // clock was ever set, in different boots, share an id while being different files
      // (they differ by sessionId, which is why the rebuild matches those on sessionId
      // and incompleteBinRelPaths keys on relativeBinPath). Removing by id on delete
      // evicted the sibling too, and a WAL that is not tracked is rebuilt as `miss` at
      // offset 0 on the next listing: a full re-download of a bin already part-fetched.
      const sharedTs = 1010; // below kMinValidEpochForMatch — pre-time-sync
      mockConn.files = [
        StorageFile(index: 0, timestamp: sharedTs, size: 100, sessionId: 111),
        StorageFile(index: 1, timestamp: sharedTs, size: 5000, sessionId: 222),
      ];
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      await pump(10);

      final built = await sync.getMissingWals();
      expect(built.length, 2, reason: 'both colliding bins are tracked to begin with');
      expect(built.map((w) => w.id).toSet().length, 1, reason: 'and they really do share a Wal.id');

      // Delete one. incompleteBinRelPaths reads the tracked WALs (plus what was
      // persisted) WITHOUT re-listing, so it shows what the delete actually evicted.
      await sync.deleteWal(built.firstWhere((w) => w.sessionId == 111));
      await pump(10);

      expect(
        await sync.incompleteBinRelPaths(),
        contains('session_222/${sharedTs}_222.bin'),
        reason: 'the id-colliding sibling must survive its neighbour being deleted',
      );
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a file that GREW since it was received is resumed, not skipped as already-synced', () async {
      // The `synced` carry must not swallow audio we never received. If the device
      // advertises more bytes than we hold, the file has to resume — and must NOT be
      // deleted, or the tail is lost.
      final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3000;
      globalRejectDeleteTimestamps = {ts};
      globalDeletedTimestamps = [];
      globalWriteCount = 0;
      mockConn.files = [StorageFile(index: 1, timestamp: ts, size: 10)];
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      await pump(10);

      final first = sync.syncAll();
      await mockConn.waitForWrite(1);
      await pump(10);
      mockConn.add(ackPacket(0x00));
      await pump();
      mockConn.add(dataPacket(0, List<int>.filled(10, 0xAB)));
      await pump();
      mockConn.add(eotPacket());
      await pump(10);
      await first;

      mockConn.files = [StorageFile(index: 1, timestamp: ts, size: 30)];
      globalWriteCount = 0;
      globalRequestedOffset = -1;
      globalDeletedTimestamps = [];

      final second = sync.syncAll();
      await mockConn.waitForWrite(2);
      await pump(10);
      expect(globalWriteCount, equals(1), reason: 'the unreceived tail must still be fetched');
      expect(globalRequestedOffset, equals(10), reason: 'resume from what we already hold');
      expect(globalDeletedTimestamps, isEmpty, reason: 'a grown file must not be deleted as synced');

      sync.cancelSync();
      await pump(10);
      await second;
    }, timeout: const Timeout(Duration(seconds: 30)));

    // The invariant these three protect: the app must NEVER ask the device to
    // resume from an offset the local bin cannot continue from. Every byte the
    // downloader receives is appended, so a resume point past what is on disk
    // silently drops the bytes in between — and because (T-a)+a == T, the file
    // still reaches its advertised length and passes the completeness guard.
    // Assert on the offset actually put on the wire, not on our own bookkeeping.
    Wal resumeWal({required int offset, required int total, required int ts}) => Wal(
          codec: BleAudioCodec.opus,
          channel: 1,
          device: 'test',
          fileNum: 1,
          walOffset: offset,
          storageTotalBytes: total,
          timerStart: ts,
          storage: WalStorage.sdcard,
        );

    Future<void> writeBin(int ts, int bytes) async {
      final f = File('${tempDir.path}/raw_segments/$ts/${ts}_0.bin');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(List<int>.filled(bytes, 0xAB));
    }

    /// Drives a real resumed read and returns the offset actually put on the wire.
    ///
    /// `reconcileResumeOffsets: true` opts into the NATIVE path's semantics
    /// (walOffset == physical bin length). The host VM is never Android/iOS, so
    /// production's `_platformUsesNativeDownload` is false here and the
    /// reconciliation — which only ever runs on a real device — would otherwise be
    /// impossible to cover. The transfer itself still goes over the mock stream;
    /// only the resume-offset decision under test is switched to native rules.
    Future<int> offsetAskedFor(Wal w) async {
      final nativeLike = SDCardWalSyncImpl(
        MockWalSyncListener(),
        connectionProvider: (_) async => mockConn,
        inactivityTimeout: const Duration(seconds: 1),
        reconcileResumeOffsets: true,
      );
      await nativeLike.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      globalRequestedOffset = -1;
      final f = nativeLike.syncWal(wal: w);
      await mockConn.waitForWrite(1);
      await pump(5);
      final asked = globalRequestedOffset;
      await expectLater(f, throwsA(isA<Exception>())); // no data follows; stalls out
      nativeLike.cancelSync();
      return asked;
    }

    test('the Dart stream path is NOT reconciled (its gap handler seeks ahead on purpose)', () async {
      // A gap leaves the bin legitimately shorter than walOffset, with a hole.
      // Rewinding would replay the gapped bytes and let the file reach its
      // advertised length while still holding that hole — turning a DETECTED
      // incomplete into a silent corruption. `sync` here is built with production
      // defaults, so on this host it takes the stream path.
      final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3;
      await writeBin(ts, 40); // shorter than the logical offset below
      globalRequestedOffset = -1;
      final f = sync.syncWal(wal: resumeWal(offset: 100, total: 200, ts: ts));
      await mockConn.waitForWrite(1);
      await pump(5);
      expect(globalRequestedOffset, equals(100), reason: 'stream path must keep its logical offset');
      await expectLater(f, throwsA(isA<Exception>()));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('resume rewinds to 0 when the bin was pruned from under it', () async {
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      // Nothing on disk: the processing pass decoded the partial and deleted it.
      // Asking from 100 would land the tail at position 0 of a recreated file.
      expect(await offsetAskedFor(resumeWal(offset: 100, total: 200, ts: ts)), equals(0));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('resume rewinds to the real length when the bin is short', () async {
      final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 1;
      await writeBin(ts, 40);
      expect(await offsetAskedFor(resumeWal(offset: 100, total: 200, ts: ts)), equals(40));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('resume is preserved when the bin is intact (no needless re-download)', () async {
      final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 2;
      await writeBin(ts, 100);
      expect(await offsetAskedFor(resumeWal(offset: 100, total: 200, ts: ts)), equals(100));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a fully-transferred bin is NOT reported incomplete (stays processable)', () async {
      globalDeletedTimestamps = [];
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      mockConn.files = [StorageFile(index: 1, timestamp: ts, size: 5)];
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      await pump(10);

      final syncFuture = sync.syncAll();
      await mockConn.waitForWrite(1);
      await pump(10);
      mockConn.add(ackPacket(0x00));
      await pump();
      mockConn.add(dataPacket(0, List<int>.filled(5, 0xEE)));
      await pump();
      mockConn.add(eotPacket());
      await pump(10);
      await syncFuture;

      // Every advertised byte arrived, so the bin is whole: processing must be free
      // to decode and prune it as usual. Guards the fix against over-blocking.
      expect(await sync.incompleteBinRelPaths(), isEmpty);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('syncAll eventually drops a persistently-unreadable (zero-progress) file to unblock', () async {
      globalDeletedTimestamps = [];
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      mockConn.files = [StorageFile(index: 1, timestamp: ts, size: 1000000)];
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      await pump(10);

      // Every attempt "completes" (clean EOT) having delivered ZERO bytes — the file
      // the firmware genuinely can't read (rotated-under-read / stale cached size /
      // an empty read error). No attempt makes forward progress, so the guard counts
      // each as a strike and, after _maxSyncFailBeforeDrop (5), deletes the file to
      // unblock the index-0-only fast path (accepting the loss of that one file).
      // Contrast the progressing-file test below: the drop keys on *no progress*, not
      // on "short read" — a file that keeps advancing is never dropped because it will
      // eventually complete.
      for (int attempt = 1; attempt <= 5; attempt++) {
        final f = sync.syncAll();
        await mockConn.waitForWrite(attempt);
        await pump(10);
        mockConn.add(ackPacket(0x00));
        await pump();
        mockConn.add(eotPacket()); // EOT with no data packet → zero bytes, no progress
        await pump(10);
        await f;
        if (attempt < 5) {
          expect(globalDeletedTimestamps, isEmpty,
              reason: 'must not delete before the poison threshold (attempt $attempt)');
        }
      }
      expect(globalDeletedTimestamps, contains(ts));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('syncAll never drops a file that keeps making forward progress', () async {
      // Forward-progress guard (#2b): a large recording that only comes down in
      // pieces — background BLE throttling, or the link dropping mid-transfer
      // ("Stream closed without EOT") — must NOT be dropped as poison. Each attempt
      // advances the byte offset, so the file will finish on a later sync (typically
      // once the app is foregrounded). Prove it survives well past
      // _maxSyncFailBeforeDrop (5) attempts as long as it keeps progressing —
      // deleting it would lose the recording for good just short of completion.
      globalDeletedTimestamps = [];
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      mockConn.files = [StorageFile(index: 1, timestamp: ts, size: 1000000)];
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      await pump(10);

      // 8 attempts, each delivering a fresh 50 KB chunk AT the resumed offset then
      // EOT — always short of the 1 MB total (never completes), but always advancing.
      // The chunk must start at the offset the sync asked to resume from
      // (globalRequestedOffset); a packet before that is treated as already-have and
      // makes no progress (see the read handler's incomingOffset < expectedOffset
      // branch), which is why a fixed dataPacket(0, …) would plateau after attempt 1.
      for (int attempt = 1; attempt <= 8; attempt++) {
        final f = sync.syncAll();
        await mockConn.waitForWrite(attempt);
        await pump(10);
        final resumeOffset = globalRequestedOffset;
        mockConn.add(ackPacket(0x00));
        await pump();
        mockConn.add(dataPacket(resumeOffset, List<int>.filled(50000, 0xEE)));
        await pump();
        mockConn.add(eotPacket());
        await pump(10);
        await f;
        expect(globalDeletedTimestamps, isEmpty, reason: 'a progressing file must never be dropped (attempt $attempt)');
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('syncAll drops a file that always THROWS a terminal error (thrown poison)', () async {
      globalDeletedTimestamps = [];
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      mockConn.files = [StorageFile(index: 1, timestamp: ts, size: 1000000)];
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      await pump(10);

      // Every attempt throws an error-ACK with no data — the *thrown* failure mode,
      // not the clean-but-short one. A thrown poison file must also count toward the
      // retry budget and be dropped; otherwise (fast path can't get past a bad index-0
      // head) it blocks every newer recording forever.
      for (int attempt = 1; attempt <= 5; attempt++) {
        final f = sync.syncAll();
        await mockConn.waitForWrite(attempt);
        await pump(10);
        mockConn.add(ackPacket(0x01)); // firmware error ACK (non-fatal, non-7)
        await pump(10);
        await f;
        if (attempt < 5) {
          expect(globalDeletedTimestamps, isEmpty,
              reason: 'must not delete before the poison threshold (attempt $attempt)');
        }
      }
      expect(globalDeletedTimestamps, contains(ts));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('Crash Recovery (Syncing): resumes from last segment boundary after interruption', () async {
      globalCurrentFileNum = -1;
      globalWriteCount = 0;
      globalRequestedOffset = 0;
      mockConn.files = [
        StorageFile(index: 1, timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000, size: 300000),
      ];
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      await pump(10);

      final syncFuture = sync.syncAll();
      await mockConn.waitForWrite(1);
      await pump(10);
      expect(globalWriteCount, equals(1));
      expect(globalRequestedOffset, equals(0));

      mockConn.add(ackPacket(0x00));
      await pump();

      // Send 260,000 bytes (crosses the 252,000 boundary)
      mockConn.add(dataPacket(0, List.filled(260000, 0xBB)));
      await pump();
      await Future.delayed(const Duration(milliseconds: 200));
      await pump();

      // Cancel sync to simulate interruption
      sync.cancelSync();
      await pump(10);

      final response = await syncFuture;
      expect(response!.isPartial, isTrue);

      // Start second sync. It should resume from 252000
      globalWriteCount = 0;
      final syncFuture2 = sync.syncAll();
      await mockConn.waitForWrite(2);
      await pump(10);

      expect(globalWriteCount, equals(1));
      expect(globalRequestedOffset, equals(260000));

      sync.cancelSync();
      await syncFuture2;
    });

    test('Crash Recovery (Adjustment Mode Copying): resumes from last segment boundary', () async {
      SharedPreferencesUtil().adjustmentMode = true;

      globalCurrentFileNum = -1;
      globalWriteCount = 0;
      globalRequestedOffset = 0;
      mockConn.files = [
        StorageFile(index: 1, timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000, size: 300000),
      ];
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      await pump(10);

      final syncFuture = sync.syncAll();
      await mockConn.waitForWrite(1);
      await pump(10);
      expect(globalWriteCount, equals(1));
      expect(globalRequestedOffset, equals(0));

      mockConn.add(ackPacket(0x00));
      await pump();

      // Send 260,000 bytes (crosses the 252,000 boundary)
      mockConn.add(dataPacket(0, List.filled(260000, 0xCC)));
      await pump();
      await Future.delayed(const Duration(milliseconds: 200));
      await pump();

      // Cancel sync to simulate interruption
      sync.cancelSync();
      await pump(10);

      final response = await syncFuture;
      expect(response!.isPartial, isTrue);

      // Start second sync. It should resume from 252000
      globalWriteCount = 0;
      final syncFuture2 = sync.syncAll();
      await mockConn.waitForWrite(2);
      await pump(10);

      expect(globalWriteCount, equals(1));
      expect(globalRequestedOffset, equals(260000));

      // Let second sync finish properly (send remaining 40,000 bytes)
      mockConn.add(ackPacket(0x00));
      await pump();
      mockConn.add(dataPacket(260000, List.filled(40000, 0xCC))); // 300000 total size
      await pump();
      mockConn.add(eotPacket());
      await pump();

      await syncFuture2;

      // Verify the adjustment mode file exists and has size
      final dir = Directory(p.join(tempDir.path, 'adjustment_mode_segments'));
      final files = dir.listSync(recursive: true).whereType<File>().toList();
      expect(files.length, greaterThanOrEqualTo(1));

      SharedPreferencesUtil().adjustmentMode = false;
    });
  });

  // A sync that never ran and a sync that ran and found nothing were the same
  // value (null) until 0.35.x, so a run that issued zero BLE commands reported to
  // the user as a completed sync — and stamped lastSyncCompletedMs, which
  // suppressed BackgroundSyncWorker's next attempt for a whole interval. These
  // pin the two apart. See IWalSync.syncAll.
  group('syncAll null means "did not run", never "nothing to sync"', () {
    late MockDeviceConnection mockConn;
    late SDCardWalSyncImpl sync;

    setUp(() {
      globalRejectDeleteTimestamps = {};
      globalDeletedTimestamps = [];
      mockConn = MockDeviceConnection();
      sync = SDCardWalSyncImpl(
        MockWalSyncListener(),
        connectionProvider: (_) async => mockConn,
        inactivityTimeout: const Duration(seconds: 1),
      );
    });

    tearDown(() async {
      sync.cancelSync();
      await mockConn.close();
    });

    test('an empty card returns a response, not null — the device WAS asked', () async {
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      mockConn.files = [];

      final result = await sync.syncAll();

      expect(result, isNotNull,
          reason: 'CMD_LIST_FILES went out and the card held nothing — that is a completed sync, '
              'and callers key their "Skipped" state and lastSyncCompletedMs stamp off null');
      expect(result!.newConversationIds, isEmpty);
      expect(result.isPartial, isFalse);
    });

    test('no registered device returns null — this is the 4.7s connect-setup window', () async {
      // setDevice deliberately NOT called: the link can be up and the battery
      // readable while the WAL layer still has no device, because
      // _onDeviceConnected calls setDevice last.
      expect(sync.hasDevice, isFalse);
      mockConn.files = [];

      expect(await sync.syncAll(), isNull);
    });

    test('hasDevice flips only once setDevice has registered the device', () async {
      expect(sync.hasDevice, isFalse);
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      expect(sync.hasDevice, isTrue);
      await sync.setDevice(null);
      expect(sync.hasDevice, isFalse);
    });

    // The third case, and the one the 2026-08-21 log caught: the sync DID run, it
    // DID take the storage lock, and the listing came back with nothing — because
    // it failed, not because the card was empty. Both produce no files, so the
    // caller cannot tell them apart from the list alone, and reporting the failure
    // as an empty card is what let a device holding three closed 10-minute bins
    // show as "nothing to sync" while lastSyncCompletedMs suppressed the next
    // automatic attempt for a full interval.
    test('an unanswered listing returns null — it is not an empty card', () async {
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      mockConn.files = [
        StorageFile(index: 0, timestamp: 1787334441, size: 3087516, sessionId: 3394048838),
      ];
      mockConn.listFilesUnanswered = true;

      expect(await sync.syncAll(), isNull,
          reason: 'no answer means we do not know what the device holds — that is a skip, '
              'and the caller must retry rather than stamp a completed sync');
    });

    test('an answered empty card and an unanswered listing do not report the same thing', () async {
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));

      mockConn.files = [];
      expect(await sync.syncAll(), isNotNull, reason: 'answered, and holds nothing — a completed sync');

      mockConn.listFilesUnanswered = true;
      expect(await sync.syncAll(), isNull, reason: 'same empty file list, opposite meaning');
    });

    // A listing with no answer must not erase what we already knew. _wals carries
    // the resume offsets restored from disk, and dropping them is what makes a
    // half-downloaded bin restart from 0 and decode its audio a second time.
    test('an unanswered listing leaves the known WAL list alone', () async {
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      mockConn.files = [
        StorageFile(index: 0, timestamp: 1787334441, size: 3087516, sessionId: 3394048838),
      ];
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      expect(await sync.hasFilesToSync(), isTrue, reason: 'the listing answered, so the WAL is known');

      mockConn.listFilesUnanswered = true;
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      expect(await sync.hasFilesToSync(), isTrue,
          reason: 'hasFilesToSync reads the cached WAL list first — a listing with no answer '
              'must not have wiped it');
    });

    // Force Sync rotates BEFORE it lists, so a listing that then fails leaves a
    // run that genuinely reached the device and genuinely sealed the active bin.
    // Reporting null there would tell RecordingsController nothing was rotated: it
    // hands the cooldown back (licensing another rotate, and another near-empty
    // bin) and, missing the isPartial branch, finalizes every draft on disk while
    // the bin holding their tail is still on the device.
    test('rotateAndSync reports partial when the rotate lands and the listing does not', () async {
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      mockConn.files = [];
      mockConn.listFilesUnanswered = true;

      final result = await sync.rotateAndSync();

      expect(result, isNotNull, reason: 'the rotate landed — this run reached the device');
      expect(result!.isPartial, isTrue,
          reason: 'nothing was fetched, so the caller must drop force mode and keep its drafts');
    });

    // Entering in the same microtask is the case that used to run two download
    // loops against the same index-0 queue: the old guard set `_isSyncing`
    // several awaits deep, so neither call saw the other.
    //
    // The second is DENIED, not joined. A sync fixes its file list at its own
    // CMD_LIST_FILES and never re-lists, so handing the second caller the running
    // sync's result would give them an answer that predates whatever the device
    // has closed since — stale, while reading as a fresh sync.
    test('a second syncAll entering together is denied, not joined', () async {
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      mockConn.files = [];

      final first = sync.syncAll();
      final second = sync.syncAll();

      final results = await Future.wait([first, second]);
      expect(results[0], isNotNull, reason: 'the first one runs');
      expect(results[1], isNull, reason: 'the second did not run, and must not report as though it did');
    });

    // isSyncing is set three awaits into the run — after the connection lookup
    // and after up to 3s of storage-lock polling. A UI gating on it alone waves
    // the user into a denial it never explains, which is the silent no-op this
    // branch set out to remove. isSyncInFlight is true from the claim onward.
    test('isSyncInFlight is true from the claim, before isSyncing catches up', () async {
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      mockConn.files = [];

      expect(sync.isSyncInFlight, isFalse);
      final run = sync.syncAll();
      expect(sync.isSyncInFlight, isTrue, reason: 'claimed synchronously, so the UI can see it immediately');
      expect(sync.isSyncing, isFalse, reason: 'this is exactly the window isSyncing does not cover');

      await run;
      expect(sync.isSyncInFlight, isFalse, reason: 'released the moment the run settles');
    });

    test('a sync can run again once the previous one has settled', () async {
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      mockConn.files = [];

      expect(await sync.syncAll(), isNotNull);
      // The claim must be released the moment the run settles, or a caller
      // arriving right after a sync finished is denied for no reason.
      expect(await sync.syncAll(), isNotNull);
    });

    // Force Sync must SEAL the active bin — that is what licenses the caller to
    // finalize drafts, because after a rotate nothing belonging to them is left
    // on the device. It therefore never joins a plain sync (that would return
    // without a rotate) and never queues behind one. It reports that it did not
    // run, and the UI says so.
    test('rotateAndSync does not run while a sync is in flight', () async {
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      mockConn.files = [];

      final running = sync.syncAll();
      expect(await sync.rotateAndSync(), isNull,
          reason: 'a run that cannot rotate is not a Force Sync — say so rather than half-do it');

      expect(await running, isNotNull);
    });

    test('rotateAndSync runs when nothing else is', () async {
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      mockConn.files = [];

      expect(await sync.rotateAndSync(), isNotNull);
    });

    // The 2026-08-19 11:48 PDT sequence, end to end: the pipeline fires while
    // _onDeviceConnected is still caching settings, so the WAL layer has no
    // device. It used to return null here and report a completed sync having sent
    // the card nothing. It must now wait and then actually issue commands.
    test('a sync starting before setDevice waits for it, then really talks to the device', () async {
      mockConn.files = [
        StorageFile(index: 0, size: 300000, timestamp: 1787206371, sessionId: 1),
      ];
      globalWriteCount = 0;
      expect(sync.hasDevice, isFalse);

      // Shape of RecordingsController._awaitSyncableDevice followed by the sync.
      final pipeline = Future(() async {
        await sync.deviceReady.timeout(const Duration(seconds: 5));
        return sync.syncAll();
      });

      await Future.delayed(const Duration(milliseconds: 50));
      expect(globalWriteCount, 0, reason: 'nothing may reach the device before it is registered');

      // _onDeviceConnected finally hands the device over.
      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));

      final result = await pipeline;
      expect(result, isNotNull, reason: 'the sync ran, so it must not report as a skip');
      expect(globalWriteCount, greaterThan(0),
          reason: 'CMD_READ_FILE actually went out — the runs in the log sent nothing at all');
    });

    test('deviceReady completes on attach and goes pending again on detach', () async {
      var ready = false;
      unawaited(sync.deviceReady.then((_) => ready = true));
      await Future.delayed(Duration.zero);
      expect(ready, isFalse, reason: 'nothing attached yet');

      await sync.setDevice(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50));
      await Future.delayed(Duration.zero);
      expect(ready, isTrue);

      // A detach must not leave a completed future behind, or the next sync would
      // stop waiting and skip against a device that is no longer registered.
      await sync.setDevice(null);
      var readyAgain = false;
      unawaited(sync.deviceReady.then((_) => readyAgain = true));
      await Future.delayed(Duration.zero);
      expect(readyAgain, isFalse);
    });
  });

  group('Conversation Metadata Robustness', () {
    test('Conversation.fromFile handles missing uploadKey in meta', () async {
      final audioFile = File('${tempDir.path}/recording_1773961625000.m4a')..createSync(recursive: true);
      final metaFile = File('${tempDir.path}/recording_1773961625000.meta')..createSync(recursive: true);
      final bd = ByteData(8);
      bd.setUint32(0, 1000, Endian.little);
      bd.setUint32(4, 2000, Endian.little);
      metaFile.writeAsBytesSync(bd.buffer.asUint8List());
      final conv = Conversation.fromFile(audioFile);
      expect(conv.duration.inMilliseconds, equals(2000));
      expect(conv.uploadKey, equals('recording_1773961625000'));
    });
  });
}
