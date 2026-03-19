import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/manual_recording_extractor.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockPathProvider extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  String? tempPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempPath;
}

// ─── Chunk file helpers ───────────────────────────────────────────────────────

/// Writes [count] length-prefixed frames of [frameSize] bytes to a .bin file.
/// Sets the file's last-modified time to [modTime].
File _buildChunkFile(Directory dir, String name, int count, int frameSize, DateTime modTime) {
  assert(frameSize != 255, 'Frame size 255 is reserved for metadata packets');
  final file = File('${dir.path}/$name');
  final builder = BytesBuilder();
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
    'offlineHangoverSeconds': 0.0,
    'offlineSplitSeconds': 2, // 100 frames
    'offlineMinSpeechSeconds': 0,
    'offlinePreSpeechSeconds': 1.0,
    'offlineGapSeconds': 10,
  });
  await SharedPreferencesUtil.init();
}

void main() {
  late Directory tempDir;
  late MockPathProvider mockPathProvider;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    const aacChannel = MethodChannel('com.omi.offline/aacEncoder');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      aacChannel,
      (call) async {
        if (call.method == 'startEncoder') return 'test-session';
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

  // ─── ManualRecordingExtractor tests ────────────────────────────────────────

  group('ManualRecordingExtractor', () {
    test('no chunks returns empty result', () async {
      final extractor = ManualRecordingExtractor();

      final batch = DailyBatch(
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

    test('fast path — no stars returns empty and correct deletion index (all chunks beyond 2hr)', () async {
      final extractor = ManualRecordingExtractor();

      // Create a session folder to hold the chunks
      final sessionDir = Directory('${tempDir.path}/raw_segments/100')..createSync(recursive: true);
      final tempOut = Directory('${tempDir.path}/out')..createSync();

      // Reference "now" is T. Chunks are placed from T-3hr to T-30min.
      // Each chunk has 300 frames = 6000ms = 6s of audio.
      // With such small frame counts endTime ≈ startTime, so the cutoff test
      // depends almost entirely on the chunk lastModified time.
      final now = DateTime(2026, 3, 17, 14, 0, 0);

      // Chunk 0: T-3hr — well outside 2hr window
      final c0 = _buildChunkFile(sessionDir, '100_0.bin', 300, 5, now.subtract(const Duration(hours: 3)));
      // Chunk 1: T-2hr30min — outside 2hr window
      final c1 = _buildChunkFile(sessionDir, '100_1.bin', 300, 5, now.subtract(const Duration(hours: 2, minutes: 30)));
      // Chunk 2: T-1hr — inside 2hr window
      final c2 = _buildChunkFile(sessionDir, '100_2.bin', 300, 5, now.subtract(const Duration(hours: 1)));
      // Chunk 3: T-30min — inside 2hr window (newest)
      final c3 = _buildChunkFile(sessionDir, '100_3.bin', 300, 5, now.subtract(const Duration(minutes: 30)));

      final batch = DailyBatch(
        dateString: '2026-03-17',
        date: DateTime(2026, 3, 17),
        rawSegments: [c0, c1, c2, c3],
        finalizedRecordings: [],
        markerTimestamps: [],
      );

      final result = await extractor.process(batch, tempOut.path);

      expect(result.savedPaths, isEmpty);
      // c0 and c1 are outside 2hr window. lastChunkEndBefore returns index 1.
      // Apply safety margin of 2: max(-1, 1 - 2) = -1.
      expect(result.lastSafeSegmentIndex, equals(-1));

      extractor.destroy();
    });

    test('fast path — no stars, 5 chunks, 3 older than 2hr cutoff', () async {
      final extractor = ManualRecordingExtractor();

      final sessionDir = Directory('${tempDir.path}/raw_segments/101')..createSync(recursive: true);
      final tempOut = Directory('${tempDir.path}/out')..createSync();

      // newest chunk is T. Cutoff = T - 2hr.
      // Place 5 chunks at: T-180min, T-150min, T-90min, T-60min, T=now.
      // Chunks at T-180min and T-150min are outside the 2hr window.
      // Each chunk has 100 frames = 2000ms = 2s, so endTime ≈ startTime for this test.
      final now = DateTime(2026, 3, 17, 14, 0, 0);

      final times = [
        now.subtract(const Duration(minutes: 180)),
        now.subtract(const Duration(minutes: 150)),
        now.subtract(const Duration(minutes: 90)),
        now.subtract(const Duration(minutes: 60)),
        now,
      ];

      final chunks = <File>[];
      for (int i = 0; i < times.length; i++) {
        chunks.add(_buildChunkFile(sessionDir, '101_$i.bin', 100, 5, times[i]));
      }

      final batch = DailyBatch(
        dateString: '2026-03-17',
        date: DateTime(2026, 3, 17),
        rawSegments: chunks,
        finalizedRecordings: [],
        markerTimestamps: [],
      );

      final result = await extractor.process(batch, tempOut.path);

      expect(result.savedPaths, isEmpty);

      // Cutoff = now - 2hr = now - 120min.
      // Chunks at T-180min and T-150min have endTime before cutoff (since frames are few).
      // lastChunkEndBefore returns index 1.
      // After safety margin of 2: max(-1, 1 - 2) = -1.
      expect(result.lastSafeSegmentIndex, equals(-1));

      extractor.destroy();
    });

    test('fast path — all chunks within 2hr window, no stars returns -1', () async {
      final extractor = ManualRecordingExtractor();

      final sessionDir = Directory('${tempDir.path}/raw_segments/102')..createSync(recursive: true);
      final tempOut = Directory('${tempDir.path}/out')..createSync();

      final now = DateTime(2026, 3, 17, 14, 0, 0);

      // All chunks within 2hr — nothing safe to delete
      final c0 = _buildChunkFile(sessionDir, '102_0.bin', 100, 5, now.subtract(const Duration(hours: 1)));
      final c1 = _buildChunkFile(sessionDir, '102_1.bin', 100, 5, now.subtract(const Duration(minutes: 30)));
      final c2 = _buildChunkFile(sessionDir, '102_2.bin', 100, 5, now);

      final batch = DailyBatch(
        dateString: '2026-03-17',
        date: DateTime(2026, 3, 17),
        rawSegments: [c0, c1, c2],
        finalizedRecordings: [],
        markerTimestamps: [],
      );

      final result = await extractor.process(batch, tempOut.path);

      expect(result.savedPaths, isEmpty);
      // No chunks are older than 2hr — lastChunkEndBefore returns -1.
      // max(-1, -1 - 2) = -1.
      expect(result.lastSafeSegmentIndex, equals(-1));

      extractor.destroy();
    });

    test('fast path — safety margin: 4 chunks outside 2hr window returns index respecting margin', () async {
      final extractor = ManualRecordingExtractor();

      final sessionDir = Directory('${tempDir.path}/raw_segments/103')..createSync(recursive: true);
      final tempOut = Directory('${tempDir.path}/out')..createSync();

      final now = DateTime(2026, 3, 17, 14, 0, 0);

      // 6 chunks: first 4 outside 2hr, last 2 inside
      final times = [
        now.subtract(const Duration(hours: 5)),
        now.subtract(const Duration(hours: 4)),
        now.subtract(const Duration(hours: 3)),
        now.subtract(const Duration(hours: 2, minutes: 30)),
        now.subtract(const Duration(hours: 1)),
        now,
      ];

      final chunks = <File>[];
      for (int i = 0; i < times.length; i++) {
        chunks.add(_buildChunkFile(sessionDir, '103_$i.bin', 10, 5, times[i]));
      }

      final batch = DailyBatch(
        dateString: '2026-03-17',
        date: DateTime(2026, 3, 17),
        rawSegments: chunks,
        finalizedRecordings: [],
        markerTimestamps: [],
      );

      final result = await extractor.process(batch, tempOut.path);

      expect(result.savedPaths, isEmpty);

      // First 4 chunks (indices 0-3) are outside the 2hr window.
      // lastChunkEndBefore returns 3.
      // After safety margin of 2: max(-1, 3 - 2) = 1.
      expect(result.lastSafeSegmentIndex, equals(1));

      extractor.destroy();
    });
  });

  // ─── RecordingsManager getDailyBatches star loading tests ──────────────────

  group('RecordingsManager getDailyBatches', () {
    test('loads stars from markers.txt', () async {
      final directory = tempDir;
      mockPathProvider.tempPath = directory.path;

      // Create a session folder with a markers.txt file
      final sessionDir = Directory('${directory.path}/raw_segments/200')..createSync(recursive: true);

      // Star at 2026-03-17 10:00:00 UTC
      final starTime = DateTime.utc(2026, 3, 17, 10, 0, 0);
      final starEpochSec = starTime.millisecondsSinceEpoch ~/ 1000;

      final starFile = File('${sessionDir.path}/markers.txt');
      starFile.writeAsStringSync('$starEpochSec\n');

      // Create at least one chunk so the date appears in batches
      _buildChunkFile(sessionDir, '200_0.bin', 10, 5, starTime);

      final manager = RecordingsManager();
      final batches = await manager.getDailyBatches();

      // Find the batch for 2026-03-17
      final dateString =
          '${starTime.year}-${starTime.month.toString().padLeft(2, '0')}-${starTime.day.toString().padLeft(2, '0')}';
      final batch = batches.where((b) => b.dateString == dateString).firstOrNull;

      expect(batch, isNotNull, reason: 'Batch for $dateString should exist');
      expect(batch!.markerTimestamps.length, equals(1));

      // The timestamp should match the UTC epoch second we wrote
      final loadedStar = batch.markerTimestamps.first;
      expect(loadedStar.millisecondsSinceEpoch, equals(starEpochSec * 1000));
    });

    test('ignores malformed lines in markers.txt', () async {
      final directory = tempDir;
      mockPathProvider.tempPath = directory.path;

      final sessionDir = Directory('${directory.path}/raw_segments/201')..createSync(recursive: true);

      final starTime = DateTime.utc(2026, 3, 17, 11, 0, 0);
      final starEpochSec = starTime.millisecondsSinceEpoch ~/ 1000;

      final starFile = File('${sessionDir.path}/markers.txt');
      // Valid line, empty line, non-numeric line
      starFile.writeAsStringSync('$starEpochSec\n\nnot-a-number\n');

      _buildChunkFile(sessionDir, '201_0.bin', 10, 5, starTime);

      final manager = RecordingsManager();
      final batches = await manager.getDailyBatches();

      final dateString =
          '${starTime.year}-${starTime.month.toString().padLeft(2, '0')}-${starTime.day.toString().padLeft(2, '0')}';
      final batch = batches.where((b) => b.dateString == dateString).firstOrNull;

      expect(batch, isNotNull, reason: 'Batch for $dateString should exist');
      // Only the valid line should produce a star; empty and non-numeric are ignored
      expect(batch!.markerTimestamps.length, equals(1));
    });
  });
}
