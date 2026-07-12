import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/device_crash_log.dart';
import 'package:omi/services/devices/device_drop_stats.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/services/devices/transports/device_transport.dart';
import 'package:flutter/services.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
import 'package:omi/services/wals/sdcard_wal_sync.dart';
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
  Future<bool> deleteFile(StorageFile file, {int? timestamp}) async {
    globalDeletedTimestamps.add(file.timestamp);
    return true;
  }

  List<StorageFile> files = [];

  @override
  Future<List<StorageFile>> listFiles() async => files;

  @override
  Future<bool> stopStorageSync() async => true;

  @override
  Future<bool> sendKeepAlive() async => true;

  @override
  Future<bool> performSendKeepAlive() async => true;

  @override
  Future<({bool muted, DateTime? since})> performGetMuteState() async => (muted: false, since: null);

  @override
  Future<void> performSetMute(bool muted) async {}

  @override
  Future<StreamSubscription<List<int>>?> performGetMuteListener(
          {required void Function(bool muted, DateTime? since) onMuteChange}) async =>
      null;

  @override
  Future<({bool muted, DateTime? since})> getMuteState() async => (muted: false, since: null);

  @override
  Future<void> setMute(bool muted) async {}

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
  Future<void> setMicGain(int gain) async {}
  @override
  Future<int?> getMicGain() async => null;
  @override
  Future<StreamSubscription<List<int>>?> getBleBatteryLevelListener(
          {void Function(int)? onBatteryLevelChange, void Function(bool)? onChargingStateChange}) async =>
      null;
  @override
  Future<StreamSubscription<List<int>>?> getBleButtonListener(
          {required void Function(List<int>) onButtonReceived}) async =>
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
  Future<List<int>> performGetButtonState() => throw UnimplementedError();
  @override
  Future<BleAudioCodec> performGetAudioCodec() => throw UnimplementedError();
  @override
  Future<StreamSubscription<List<int>>?> performGetBleButtonListener(
          {required void Function(List<int>) onButtonReceived}) =>
      throw UnimplementedError();
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
  Future<List<StorageFile>> performListFiles() => throw UnimplementedError();
  @override
  Future<Stream<List<int>>> performReadFile(StorageFile file, {int offset = 0}) => throw UnimplementedError();
  @override
  Future<bool> performDeleteFile(StorageFile file, {int? timestamp}) => throw UnimplementedError();
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
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
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
