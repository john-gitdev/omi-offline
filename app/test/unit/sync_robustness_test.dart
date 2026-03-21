import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/devices/device_connection.dart';
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
}

class MockDeviceConnection extends Fake implements DeviceConnection {
  final StreamController<List<int>> _controller = StreamController<List<int>>.broadcast();

  /// Push a packet into the BLE stream.
  void add(List<int> packet) => _controller.add(packet);

  /// Close the stream (simulates BLE disconnect).
  Future<void> close() => _controller.close();

  @override
  Future<StreamSubscription<List<int>>?> getBleStorageBytesListener({
    required void Function(List<int>) onStorageBytesReceived,
    Function? onError,
    void Function()? onDone,
  }) async {
    return _controller.stream.listen((data) {
      onStorageBytesReceived(data);
    }, onError: onError, onDone: onDone);
  }

  @override
  Future<bool> isConnected() async => true;

  @override
  Future<bool> performWriteToStorage(int fileNum, int type, int offset) async => true;

  @override
  Future<List<int>> performGetStorageList() async => [0, 0];
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
    tempDir = Directory.systemTemp.createTempSync('sync_test');
    mockPathProvider = MockPathProvider()..tempPath = tempDir.path;
    PathProviderPlatform.instance = mockPathProvider;

    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('SDCardWalSync Protocol Logic', () {
    test('Little-Endian offset parsing is correct', () {
      // Packet: [TYPE=0x01][Offset=0xDEADBEEF][Payload...]
      final bytes = [0x01, 0xEF, 0xBE, 0xAD, 0xDE, 0xAA, 0xBB];
      final offset = bytes[1] | (bytes[2] << 8) | (bytes[3] << 16) | (bytes[4] << 24);
      expect(offset, equals(0xDEADBEEF));
    });

    test('Payload extraction excludes 5-byte header', () {
      final bytes = [0x01, 0x00, 0x00, 0x00, 0x00, 0xDE, 0xAD, 0xBE, 0xEF];
      final payload = bytes.sublist(5);
      expect(payload, equals([0xDE, 0xAD, 0xBE, 0xEF]));
    });
  });

  // -------------------------------------------------------------------------
  // Framed BLE Protocol Dispatch Tests
  //
  // These tests drive SDCardWalSyncImpl._readStorageBytesToFile indirectly
  // via syncWal(), injecting packets through a MockDeviceConnection's
  // StreamController to exercise every dispatch branch of the switch.
  // -------------------------------------------------------------------------
  group('Framed BLE Protocol Dispatch', () {
    late MockDeviceConnection mockConn;
    late SDCardWalSyncImpl sync;

    /// Creates a minimal Wal for a fictional SD card file.
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

    setUp(() {
      mockConn = MockDeviceConnection();
      sync = SDCardWalSyncImpl(
        MockWalSyncListener(),
        connectionProvider: (_) async => mockConn,
      );
    });

    tearDown(() async {
      await mockConn.close();
    });

    // Pump [count] microtask/event-loop cycles so async listeners can run.
    Future<void> pump([int count = 5]) async {
      for (int i = 0; i < count; i++) {
        await Future.delayed(Duration.zero);
      }
    }

    test('Error ACK aborts sync with an exception', () async {
      final wal = makeWal();
      final syncFuture = sync.syncWal(wal: wal);

      await pump(); // let subscription register
      mockConn.add(ackPacket(0x01)); // non-zero = firmware error
      await pump();

      await expectLater(syncFuture, throwsA(isA<Exception>()));
    });

    test('EOT after ACK + DATA triggers clean completion', () async {
      final payload = List<int>.filled(10, 0xDD);
      final wal = makeWal(totalBytes: 10);
      final syncFuture = sync.syncWal(wal: wal);

      await pump();
      mockConn.add(ackPacket(0x00));
      await pump();
      mockConn.add(dataPacket(0, payload));
      await pump();
      mockConn.add(eotPacket());

      await expectLater(syncFuture, completes);
    });

    test('DATA packet before ACK is silently ignored (walOffset stays at 0)', () async {
      final payload = List<int>.filled(10, 0xAA);
      final wal = makeWal(totalBytes: 10);
      final syncFuture = sync.syncWal(wal: wal);

      await pump();
      // Push DATA before ACK — should be dropped
      mockConn.add(dataPacket(0, payload));
      await pump();
      expect(wal.walOffset, equals(0)); // no progress yet

      // Now complete the transfer normally
      mockConn.add(ackPacket(0x00));
      await pump();
      mockConn.add(dataPacket(0, payload));
      await pump();
      mockConn.add(eotPacket());

      await expectLater(syncFuture, completes);
      expect(wal.walOffset, equals(10));
    });

    test('Duplicate DATA packet (incoming offset < expected) is discarded', () async {
      final payload = List<int>.filled(10, 0xBB);
      final wal = makeWal(totalBytes: 10);
      final syncFuture = sync.syncWal(wal: wal);

      await pump();
      mockConn.add(ackPacket(0x00));
      await pump();

      // First packet: offset 0, advances expectedOffset to 10
      mockConn.add(dataPacket(0, payload));
      await pump();
      expect(wal.walOffset, equals(10));

      // Duplicate at offset 0: must be discarded (walOffset must stay at 10)
      mockConn.add(dataPacket(0, payload));
      await pump();
      expect(wal.walOffset, equals(10));

      mockConn.add(eotPacket());
      await expectLater(syncFuture, completes);
    });

    test('Gap in DATA sequence aborts the transfer with an exception', () async {
      // totalBytes large enough to trigger gap detection
      final wal = makeWal(totalBytes: 30);
      final syncFuture = sync.syncWal(wal: wal);

      // Drive the same gap pattern on every attempt (initial + 3 retries).
      // After the retry limit the exception propagates.
      for (int attempt = 0; attempt <= 3; attempt++) {
        await pump();
        mockConn.add(ackPacket(0x00));
        await pump();
        // DATA at offset 0 — valid
        mockConn.add(dataPacket(0, List<int>.filled(5, 0xCC)));
        await pump();
        // DATA at offset 20 — gap (expected 5 on first attempt; on retries
        // wal.walOffset=5 so expectedOffset=5, incoming=20 is still a gap)
        mockConn.add(dataPacket(20, List<int>.filled(5, 0xCC)));
        await pump();
        // Allow retry delay (100 ms) to elapse
        await Future.delayed(const Duration(milliseconds: 150));
      }

      await expectLater(syncFuture, throwsA(isA<Exception>()));
    });

    test('Malformed DATA packet (< 5 bytes) is logged and ignored, sync continues', () async {
      final payload = List<int>.filled(5, 0xEE);
      final wal = makeWal(totalBytes: 5);
      final syncFuture = sync.syncWal(wal: wal);

      await pump();
      mockConn.add(ackPacket(0x00));
      await pump();
      // Malformed: only 3 bytes (needs ≥ 5 for a valid DATA header)
      mockConn.add([0x01, 0x00, 0x00]);
      await pump();
      // Valid DATA immediately after — sync should continue from offset 0
      mockConn.add(dataPacket(0, payload));
      await pump();
      mockConn.add(eotPacket());

      await expectLater(syncFuture, completes);
    });
  });

  group('Conversation Metadata Robustness', () {
    test('Conversation.fromFile handles missing uploadKey in meta', () async {
      final audioFile = File('${tempDir.path}/recording_1773961625000.m4a')..createSync(recursive: true);
      final metaFile = File('${tempDir.path}/recording_1773961625000.meta')..createSync(recursive: true);
      
      // Write short meta (only 8 bytes, no upload key)
      final bd = ByteData(8);
      bd.setUint32(0, 1000, Endian.little); // samples
      bd.setUint32(4, 2000, Endian.little); // duration
      metaFile.writeAsBytesSync(bd.buffer.asUint8List());

      final conv = Conversation.fromFile(audioFile);
      expect(conv.duration.inMilliseconds, equals(2000));
      // Fallback key should be the filename
      expect(conv.uploadKey, equals('recording_1773961625000'));
    });

    test('Conversation.fromFile parses long uploadKey correctly', () async {
      final audioFile = File('${tempDir.path}/rec_long.m4a')..createSync(recursive: true);
      final metaFile = File('${tempDir.path}/rec_long.meta')..createSync(recursive: true);
      
      final key = 'ABCDEF_recording_123456789.m4a';
      final keyBytes = key.codeUnits;
      
      final builder = BytesBuilder();
      final bd = ByteData(408);
      bd.setUint32(4, 5000, Endian.little); // 5s duration
      builder.add(bd.buffer.asUint8List());
      builder.addByte(keyBytes.length);
      builder.add(keyBytes);
      
      metaFile.writeAsBytesSync(builder.toBytes());

      final conv = Conversation.fromFile(audioFile);
      expect(conv.duration.inSeconds, equals(5));
      expect(conv.uploadKey, equals(key));
    });
  });
}
