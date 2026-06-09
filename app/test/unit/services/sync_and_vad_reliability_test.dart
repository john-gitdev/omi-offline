import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/vad_audio_processor.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/frame_ref.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/backend/preferences.dart';
import 'package:path/path.dart' as p;

class MockPathProviderPlatform extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  late String tempPath;
  MockPathProviderPlatform(this.tempPath);
  @override
  Future<String?> getApplicationDocumentsDirectoryPath() async => tempPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempPath;
  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

void main() {
  late Directory tempDir;
  late MockPathProviderPlatform mockPathProvider;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('new_features_test');
    mockPathProvider = MockPathProviderPlatform(tempDir.path);
    PathProviderPlatform.instance = mockPathProvider;
    TestWidgetsFlutterBinding.ensureInitialized();

    // Mock FlutterSecureStorage platform channel
    const MethodChannel secureStorageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(secureStorageChannel, (call) async {
      if (call.method == 'read') return null;
      if (call.method == 'write') return null;
      if (call.method == 'delete') return null;
      if (call.method == 'containsKey') return false;
      if (call.method == 'readAll') return <String, String>{};
      if (call.method == 'deleteAll') return null;
      return null;
    });

    // Mock other channels
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter_onnxruntime'),
      (call) async => null,
    );

    // Mock SharedPreferences
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('RecordingsManager.coveredBinPaths', () {
    test('identifies fully covered bin files', () async {
      final dateStr = '2026-06-02';
      final recordingsDir = Directory(p.join(tempDir.path, 'recordings', dateStr))..createSync(recursive: true);
      final rawDir = Directory(p.join(tempDir.path, 'raw_segments', '1780358400'))..createSync(recursive: true);

      // 1. Create a mock recording spanning [00:00:00, 00:10:00] (600s)
      // 1780358400000 = 2026-06-02 00:00:00 UTC
      final startMs = 1780358400000;
      final wavFile = File(p.join(recordingsDir.path, 'recording_$startMs.wav'))..writeAsBytesSync(Uint8List(44));
      
      // Create .meta sidecar with duration
      final metaFile = File(p.join(recordingsDir.path, 'recording_$startMs.meta'));
      final metaData = ByteData(8);
      metaData.setUint32(4, 600000, Endian.little); // 600s duration
      metaFile.writeAsBytesSync(metaData.buffer.asUint8List());

      // 2. Create raw bin files
      // B1: Fully covered (00:01:00 to 00:02:00 UTC)
      final b1Ts = 1780358400 + 60;
      final b1File = File(p.join(rawDir.path, '${b1Ts}_0.bin'))..writeAsBytesSync(Uint8List(36 + (4.05 * 60000).ceil()));

      // B2: Not covered (Starts 11 minutes before)
      final b2Ts = 1780358400 - 660;
      final b2File = File(p.join(rawDir.path, '${b2Ts}_0.bin'))..writeAsBytesSync(Uint8List(36 + (4.05 * 60000).ceil()));

      // B3: Not covered (Ends after recording ends)
      final b3Ts = 1780358400 + 580;
      final b3File = File(p.join(rawDir.path, '${b3Ts}_0.bin'))..writeAsBytesSync(Uint8List(36 + (4.05 * 60000).ceil()));

      final covered = await RecordingsManager.coveredBinPaths([b1File, b2File, b3File]);

      expect(covered.contains(b1File.path), isTrue, reason: 'B1 should be covered');
      expect(covered.contains(b2File.path), isFalse, reason: 'B2 should not be covered (start 11m before)');
      expect(covered.contains(b3File.path), isFalse, reason: 'B3 should not be covered (end after)');
    });
  });

  group('VadAudioProcessor Checkpointing', () {
    test('serialize and restore state captures complex fields', () async {
      final settings = ProcessingSettings(
        vadEnabled: true,
        speechThreshold: 0.5,
        silenceDurationToSplitMs: 120000,
        minDurationMs: 0,
        minSpeechMs: 0,
        maxChunkMs: 3600000,
        deviceId: 'test',
        audioSaveFormat: 'wav',
        omiEnabled: false,
      );
      
      final processor = VadAudioProcessor.fromSettings(settings: settings, outputDir: tempDir.path);
      final binFile = File(p.join(tempDir.path, 'test.bin'))..writeAsBytesSync([0,0,0,0]);
      
      final mockState = {
        'refs': [
          {'t': 'f', 'p': binFile.path, 'o': 10, 'l': 4},
          {'t': 's', 'ms': 500}
        ],
        'sfc': 123,
        'rst': 1780358400000,
        'lse': 1780359000000,
        'idt': true,
        'csi': 456,
        'csu': 789,
        'cfu': 1011,
        'lit': 2022,
        'ccd': 3033,
        'srm': 4044,
        'cmv': 0.95,
        'fbm': true,
        'mpu': 777,
        'sep': true,
        'pm': [{'ms': 888, 'o': 999}],
        'vs': List.filled(256, 0.5),
        'vc': List.filled(64, 0.1),
        'pb': [0.1, 0.2, 0.3],
        'pbl': 3,
      };

      await processor.restoreState(mockState);
      
      final serialized = await processor.serializeState();
      expect(serialized, isNotNull);
      expect(serialized!['sfc'], 123);
      expect(serialized['cmv'], 0.95);
      expect(serialized['pbl'], 3);
      expect(serialized['idt'], true);
      expect(serialized['refs'].length, 2);
      
      final pb = serialized['pb'] as List;
      expect(pb[0], closeTo(0.1, 0.00001));
      expect(pb[1], closeTo(0.2, 0.00001));
      expect(pb[2], closeTo(0.3, 0.00001));
    });
  });

  group('VadAudioProcessor Header Parsing', () {
    test('parses 0xFFFFFFFB header and bridges UTC time', () async {
      final settings = ProcessingSettings(
        vadEnabled: true,
        speechThreshold: 0.5,
        silenceDurationToSplitMs: 120000,
        minDurationMs: 0,
        minSpeechMs: 0,
        maxChunkMs: 3600000,
        deviceId: 'test',
        audioSaveFormat: 'wav',
        omiEnabled: false,
      );
      final processor = VadAudioProcessor.fromSettings(settings: settings, outputDir: tempDir.path);

      // Create a bin file with a valid header
      final utcStartMs = 1780358400000; // 2026-06-02 00:00:00 UTC
      final uptimeStartMs = 100000;
      final imuTicks = 5000;
      final sessionId = 123;

      final binFile = File(p.join(tempDir.path, 'header_test.bin'));
      final builder = BytesBuilder();
      final headerData = ByteData(36);
      headerData.setUint32(0, 0xFFFFFFFB, Endian.little);
      headerData.setUint32(4, 28, Endian.little);
      headerData.setUint64(8, utcStartMs, Endian.little);
      headerData.setUint64(16, uptimeStartMs, Endian.little);
      headerData.setUint32(24, imuTicks, Endian.little);
      headerData.setUint32(28, sessionId, Endian.little);
      headerData.setUint32(32, 1, Endian.little);
      builder.add(headerData.buffer.asUint8List());

      // Add one dummy frame (20ms)
      final frameHeader = ByteData(4)..setUint32(0, 4, Endian.little);
      builder.add(frameHeader.buffer.asUint8List());
      builder.add([0, 1, 2, 3]);

      await binFile.writeAsBytes(builder.toBytes());

      await processor.processSegmentFile(binFile, DateTime.now());
      
      // In private state, _recordingStartTime should match utcStartMs
      // We can verify this via serializeState
      final state = await processor.serializeState();
      expect(state!['rst'], utcStartMs);
      expect(state['csi'], sessionId);
      // lit = currentImuTicks + (frames * 20 / 6.4) = 5000 + (1 * 20 / 6.4) = 5003
      expect(state['lit'], 5003);
    });

    test('handles 0xFFFFFFFD VAD resume marker', () async {
      final settings = ProcessingSettings(
        vadEnabled: false, // AAD mode to treat frames as speech
        speechThreshold: 0.5,
        silenceDurationToSplitMs: 120000,
        minDurationMs: 0,
        minSpeechMs: 0,
        maxChunkMs: 3600000,
        deviceId: 'test',
        audioSaveFormat: 'wav',
        omiEnabled: false,
      );
      final processor = VadAudioProcessor.fromSettings(settings: settings, outputDir: tempDir.path);

      final binFile = File(p.join(tempDir.path, 'resume_test.bin'));
      final builder = BytesBuilder();
      
      // 1. Add Header to establish baseline
      final utcStartMs = 1780358400000;
      final headerData = ByteData(36);
      headerData.setUint32(0, 0xFFFFFFFB, Endian.little);
      headerData.setUint32(4, 28, Endian.little);
      headerData.setUint64(8, utcStartMs, Endian.little);
      headerData.setUint64(16, 100000, Endian.little);
      headerData.setUint32(24, 5000, Endian.little);
      headerData.setUint32(28, 123, Endian.little);
      headerData.setUint32(32, 1, Endian.little);
      builder.add(headerData.buffer.asUint8List());

      // 2. Frame 1 (20ms)
      builder.add(Uint8List(4)..buffer.asByteData().setUint32(0, 4, Endian.little));
      builder.add([0, 1, 2, 3]);

      // 3. Resume Marker (10s later)
      // Frame 1 ends at utcStartMs + 20ms. 
      // We want a 10s gap, so resume at utcStartMs + 10020ms.
      final resumeUtc = (utcStartMs ~/ 1000) + 10;
      final resumeUptime = 100000 + 10020;
      final marker = ByteData(20);
      marker.setUint32(0, 0xFFFFFFFD, Endian.little);
      marker.setUint32(4, resumeUtc, Endian.little); // seconds
      marker.setUint32(8, resumeUptime, Endian.little); // ms
      builder.add(marker.buffer.asUint8List());

      // 4. Frame 2
      builder.add(Uint8List(4)..buffer.asByteData().setUint32(0, 4, Endian.little));
      builder.add([4, 5, 6, 7]);

      await binFile.writeAsBytes(builder.toBytes());
      await processor.processSegmentFile(binFile, DateTime.now());
      
      final state = await processor.serializeState();
      final refs = state!['refs'] as List;
      
      // The gap calculation in VadAudioProcessor:
      // lastFrameEndTime = utcStartMs + 20ms
      // newResumeTime = resumeUtc * 1000 = utcStartMs + 10000ms
      // gapMs = 10000 - 20 = 9980ms
      final gap = refs.firstWhere((r) => r['t'] == 's');
      expect(gap['ms'], 9980);
    });
  });
}
