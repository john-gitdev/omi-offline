import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/marker_recording_extractor.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockPathProvider extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  String? tempPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempPath;
}

// ─── Segment file helpers ───────────────────────────────────────────────────────

/// Writes [count] length-prefixed frames of [frameSize] bytes to a .bin file.
/// Sets the file's last-modified time to [modTime].
File _buildSegmentFile(Directory dir, String name, int count, int frameSize, DateTime modTime) {
  assert(frameSize != 255, 'Frame size 255 is reserved for metadata packets');
  final file = File('${dir.path}/$name');
  final builder = BytesBuilder();
  
  // Fill payload with oscillating values to ensure high energy for VAD
  // Each Opus frame will be decoded by the mock decoder during tests.
  // Wait, MarkerRecordingExtractor actually uses its own internal VAD logic!
  // It calls `_vadStep` which computes RMS of the decoded PCM.
  // In our tests, we are mocking the Opus decoder to return non-zero PCM.
  // So the bytes in the .bin file don't strictly matter as long as they are valid Opus lengths.
  
  final payload = Uint8List(frameSize);
  for (var i = 0; i < count; i++) {
    final prefix = Uint8List(4);
    ByteData.sublistView(prefix).setUint32(0, frameSize, Endian.little);
    builder.add(prefix);
    builder.add(payload);
  }
  file.writeAsBytesSync(builder.toBytes());
  file.setLastModifiedSync(modTime);
  return file;
}

// ─── Test setUp helpers ───────────────────────────────────────────────────────

Future<void> _initPrefs() async {
  SharedPreferences.setMockInitialValues({
    'offlineSnrMarginDb': 10.0,
    'offlineHangoverSeconds': 0.0, // disabled for determinism
    'offlineSplitSeconds': 2, // 100 frames
    'offlineMinSpeechSeconds': 0,
    'offlinePreSpeechSeconds': 1.0,
    'offlineGapSeconds': 10,
  });
  await SharedPreferencesUtil.init();
}

class MockDecoder extends Fake implements SimpleOpusDecoder {
  Int16List pcmToReturn = Int16List(320);
  @override
  Int16List decode({Uint8List? input, bool fec = false, int? loss}) => pcmToReturn;
  @override
  void destroy() {}
}

void main() {
  late Directory tempDir;
  late MockPathProvider mockPathProvider;
  final mockDecoder = MockDecoder();

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    
    // Fill mock decoder with speech by default
    mockDecoder.pcmToReturn = Int16List.fromList(List.filled(320, 5000));

    const aacChannel = MethodChannel('com.omi.offline/aacEncoder');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      aacChannel,
      (call) async {
        if (call.method == 'startEncoder') return 'test-device-session';
        return null;
      },
    );

    tempDir = Directory.systemTemp.createTempSync('extractor_test');
    mockPathProvider = MockPathProvider()..tempPath = tempDir.path;
    PathProviderPlatform.instance = mockPathProvider;

    await _initPrefs();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  // ─── MarkerRecordingExtractor tests ────────────────────────────────────────

  group('MarkerRecordingExtractor', () {
    test('no segments returns empty result', () async {
      final extractor = MarkerRecordingExtractor();

      final batch = Batch(
        dateString: '2026-03-17',
        date: DateTime(2026, 3, 17),
        rawSegments: [],
        finalizedRecordings: [],
        markerTimestamps: [],
      );

      final tempOut = Directory('${tempDir.path}/out')..createSync();
      final result = await extractor.process(batch, tempOut.path);

      expect(result.savedPaths, isEmpty);
      expect(result.lastSafeSegmentIndex, equals(-1));

      extractor.destroy();
    });

    test('fast path — no markers returns empty and correct deletion index (all segments beyond 2hr)', () async {
      final extractor = MarkerRecordingExtractor();

      // Create a deviceSession folder to hold the segments
      final deviceSessionDir = Directory('${tempDir.path}/raw_segments/100')..createSync(recursive: true);
      final tempOut = Directory('${tempDir.path}/out')..createSync();

      // Reference \"now\" is T. Segments are placed from T-3hr to T-30min.
      final now = DateTime(2026, 3, 17, 14, 0, 0);

      final c0 = _buildSegmentFile(deviceSessionDir, '100_0.bin', 300, 10, now.subtract(const Duration(hours: 3)));
      final c1 = _buildSegmentFile(deviceSessionDir, '100_1.bin', 300, 10, now.subtract(const Duration(hours: 2, minutes: 30)));
      final c2 = _buildSegmentFile(deviceSessionDir, '100_2.bin', 300, 10, now.subtract(const Duration(hours: 1)));
      final c3 = _buildSegmentFile(deviceSessionDir, '100_3.bin', 300, 10, now.subtract(const Duration(minutes: 30)));

      final batch = Batch(
        dateString: '2026-03-17',
        date: DateTime(2026, 3, 17),
        rawSegments: [c0, c1, c2, c3],
        finalizedRecordings: [],
        markerTimestamps: [],
      );

      final result = await extractor.process(batch, tempOut.path);

      expect(result.savedPaths, isEmpty);
      expect(result.lastSafeSegmentIndex, equals(-1));

      extractor.destroy();
    });

    test('full path — overlapping markers are merged into one conversation', () async {
      final extractor = MarkerRecordingExtractor(decoder: mockDecoder);
      final deviceSessionDir = Directory('${tempDir.path}/raw_segments/104')..createSync(recursive: true);
      final tempOut = Directory('${tempDir.path}/out')..createSync();

      final now = DateTime(2026, 3, 17, 14, 0, 0);
      final c0 = _buildSegmentFile(deviceSessionDir, '104_0.bin', 2000, 10, now);

      final m1 = now.add(const Duration(seconds: 10));
      final m2 = now.add(const Duration(seconds: 20));

      final batch = Batch(
        dateString: '2026-03-17',
        date: DateTime(2026, 3, 17),
        rawSegments: [c0],
        finalizedRecordings: [],
        markerTimestamps: [m1, m2],
      );

      final result = await extractor.process(batch, tempOut.path);

      // They should be merged into one single recording
      expect(result.savedPaths.length, equals(1));
      
      extractor.destroy();
    });

    test('full path — window truncated at maxWindowFrames cap', () async {
      final extractor = MarkerRecordingExtractor(decoder: mockDecoder);
      final deviceSessionDir = Directory('${tempDir.path}/raw_segments/105')..createSync(recursive: true);
      final tempOut = Directory('${tempDir.path}/out')..createSync();

      final now = DateTime(2026, 3, 17, 14, 0, 0);
      
      // Create a segment longer than 5 minutes (15000 frames)
      // 20000 frames = 400 seconds = 6.6 minutes
      final c0 = _buildSegmentFile(deviceSessionDir, '105_0.bin', 20000, 10, now);

      // Marker in the middle of 6 minutes of speech
      final marker = now.add(const Duration(minutes: 3));

      final batch = Batch(
        dateString: '2026-03-17',
        date: DateTime(2026, 3, 17),
        rawSegments: [c0],
        finalizedRecordings: [],
        markerTimestamps: [marker],
      );

      final result = await extractor.process(batch, tempOut.path);

      expect(result.savedPaths.length, equals(1));
      final conv = Conversation.fromFile(File(result.savedPaths.first));
      
      // Should be exactly 5 minutes (300,000ms)
      expect(conv.duration.inMinutes, equals(5));
      
      extractor.destroy();
    });
  });

  group('RecordingsManager getBatches', () {
    test('loads markers from markers.txt', () async {
      final directory = tempDir;
      mockPathProvider.tempPath = directory.path;

      final deviceSessionDir = Directory('${directory.path}/raw_segments/200')..createSync(recursive: true);
      final markerTime = DateTime.utc(2026, 3, 17, 10, 0, 0);
      final markerEpochSec = markerTime.millisecondsSinceEpoch ~/ 1000;

      final markerFile = File('${deviceSessionDir.path}/markers.txt');
      markerFile.writeAsStringSync('$markerEpochSec\n');

      _buildSegmentFile(deviceSessionDir, '200_0.bin', 10, 10, markerTime);

      final manager = RecordingsManager();
      final batches = await manager.getBatches();

      final dateString = '2026-03-17';
      final batch = batches.where((b) => b.dateString == dateString).firstOrNull;

      expect(batch, isNotNull);
      expect(batch!.markerTimestamps.length, equals(1));
      expect(batch.markerTimestamps.first.millisecondsSinceEpoch, equals(markerEpochSec * 1000));
    });
  });
}
