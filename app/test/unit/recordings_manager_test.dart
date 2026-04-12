import "dart:convert";
import "dart:typed_data";
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class MockPathProvider extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  String? tempPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempPath;
  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

void main() {
  late Directory tempDir;
  late MockPathProvider mockPathProvider;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    tempDir = Directory.systemTemp.createTempSync('recordings_test');
    mockPathProvider = MockPathProvider()..tempPath = tempDir.path;
    PathProviderPlatform.instance = mockPathProvider;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('getBatches identifies and groups segments correctly', () async {
    // Create mock structure:
    // raw_segments/100/100_0.bin (modified 2026-03-11)
    // raw_segments/100/100_1.bin (modified 2026-03-11)
    // raw_segments/101/101_0.bin (modified 2026-03-12)

    final rawDir = Directory(p.join(tempDir.path, 'raw_segments'));
    final deviceSession100Dir = Directory(p.join(rawDir.path, '100'))..createSync(recursive: true);
    final deviceSession101Dir = Directory(p.join(rawDir.path, '101'))..createSync(recursive: true);

    final file1 = File(p.join(deviceSession100Dir.path, '100_0.bin'))..writeAsBytesSync([0]);
    final file2 = File(p.join(deviceSession100Dir.path, '100_1.bin'))..writeAsBytesSync([0]);
    final file3 = File(p.join(deviceSession101Dir.path, '101_0.bin'))..writeAsBytesSync([0]);

    // Set modification times
    file1.setLastModifiedSync(DateTime(2026, 3, 11, 10));
    file2.setLastModifiedSync(DateTime(2026, 3, 11, 11));
    file3.setLastModifiedSync(DateTime(2026, 3, 12, 10));

    final manager = RecordingsManager();
    final batches = await manager.getBatches();

    expect(batches.length, 2);
    expect(batches[0].dateString, '2026-03-12');
    expect(batches[0].rawSegments.length, 1);
    expect(batches[1].dateString, '2026-03-11');
    expect(batches[1].rawSegments.length, 2);
  });

  test('getBatches sorts segments by filename within a day', () async {
    final rawDir = Directory(p.join(tempDir.path, 'raw_segments'));
    final deviceSession100Dir = Directory(p.join(rawDir.path, '100'))..createSync(recursive: true);

    // Create files in reverse order
    final file2 = File(p.join(deviceSession100Dir.path, '100_1.bin'))..writeAsBytesSync([0]);
    final file1 = File(p.join(deviceSession100Dir.path, '100_0.bin'))..writeAsBytesSync([0]);

    file1.setLastModifiedSync(DateTime(2026, 3, 11, 10));
    file2.setLastModifiedSync(DateTime(2026, 3, 11, 10));

    final manager = RecordingsManager();
    final batches = await manager.getBatches();

    expect(batches[0].rawSegments[0].path.endsWith('100_0.bin'), true);
    expect(batches[0].rawSegments[1].path.endsWith('100_1.bin'), true);
  });

  group('Conversation.fromFile tests', () {
    test('parses from real file with metadata correctly', () async {
      final recordingsDir = Directory(p.join(tempDir.path, 'recordings', '2026-03-11'))..createSync(recursive: true);
      final wavFile = File(p.join(recordingsDir.path, 'recording_1741687200000.wav'));

      // 1741687200000 = 2026-03-11 10:00:00 UTC
      final startTime = DateTime.fromMillisecondsSinceEpoch(1741687200000);

      // Mock WAV file with 44 byte header + 3200 bytes of data (100ms at 32000Hz mono)
      final data = Uint8List(44 + 3200);
      wavFile.writeAsBytesSync(data);

      final conversation = await Conversation.fromFile(wavFile);

      expect(conversation.startTime, startTime);
      expect(conversation.fileSizeBytes, 3244);
      expect(conversation.duration.inMilliseconds, 100);
    });

    test('prefers metadata sidecar if present', () async {
      final recordingsDir = Directory(p.join(tempDir.path, 'recordings', '2026-03-11'))..createSync(recursive: true);
      final m4aFile = File(p.join(recordingsDir.path, 'recording_1741687200000.m4a'))..writeAsBytesSync([0]);
      final metaFile = File(p.join(recordingsDir.path, 'recording_1741687200000.meta'));

      // .meta structure: 4 bytes version + 4 bytes durationMs (LE) + ... + byte 408 keyLen + N bytes key
      final metaData = ByteData(409 + 5);
      metaData.setUint32(4, 5000, Endian.little); // 5s duration
      metaData.setUint8(408, 5); // key length
      final metaBytes = metaData.buffer.asUint8List();
      metaBytes.setRange(409, 414, utf8.encode('mykey'));
      metaFile.writeAsBytesSync(metaBytes);

      final conversation = await Conversation.fromFile(m4aFile);

      expect(conversation.duration.inSeconds, 5);
      expect(conversation.uploadKey, 'mykey');
      expect(conversation.fileSizeBytes, 1);
    });

    test('falls back to last modified for start time if filename invalid', () async {
      final recordingsDir = Directory(p.join(tempDir.path, 'recordings', '2026-03-11'))..createSync(recursive: true);
      final wavFile = File(p.join(recordingsDir.path, 'invalid_name.wav'))..writeAsBytesSync(Uint8List(44));

      final now = DateTime.now();
      wavFile.setLastModifiedSync(now);

      final conversation = await Conversation.fromFile(wavFile);

      // Allow for some small difference in time due to filesystem resolution
      expect(conversation.startTime.difference(now).inSeconds.abs() <= 1, true);
    });
  });
}
