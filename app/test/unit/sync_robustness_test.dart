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
