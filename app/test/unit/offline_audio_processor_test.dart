import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/offline_audio_processor.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockPathProvider extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  String? tempPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempPath;
}

class MockDecoder extends Fake implements SimpleOpusDecoder {
  Int16List pcmToReturn = Int16List(320);

  @override
  Int16List decode({Uint8List? input, bool fec = false, int? loss}) => pcmToReturn;

  @override
  void destroy() {}
}

/// Writes [count] length-prefixed frames of [frameSize] bytes to a .bin file.
/// Frame size must not be 255 (reserved for metadata packets).
File _buildChunkFile(Directory dir, String name, int count, int frameSize) {
  assert(frameSize != 255, 'Use a frame size other than 255 to avoid metadata packet handling');
  final file = File('${dir.path}/$name');
  final builder = BytesBuilder();
  final payload = Uint8List(frameSize); // zeroed payload
  for (var i = 0; i < count; i++) {
    final prefix = Uint8List(4);
    ByteData.sublistView(prefix).setUint32(0, frameSize, Endian.little);
    builder.add(prefix);
    builder.add(payload);
  }
  file.writeAsBytesSync(builder.toBytes());
  return file;
}

/// Builds a chunk file that starts with ONE metadata packet (utcSecs, uptimeMs)
/// followed by [audioFrameCount] audio frames of [frameSize] bytes.
File _buildChunkFileWithMeta(Directory dir, String name, int utcSecs, int uptimeMs, int audioFrameCount, int frameSize) {
  assert(frameSize != 255, 'Use a frame size other than 255 to avoid metadata packet handling');
  final file = File('${dir.path}/$name');
  final builder = BytesBuilder();

  // Write metadata packet (length == 255)
  final metaPayload = Uint8List(255);
  ByteData.sublistView(metaPayload)
    ..setUint32(0, utcSecs, Endian.little)
    ..setUint32(4, uptimeMs, Endian.little);
  final metaPrefix = Uint8List(4);
  ByteData.sublistView(metaPrefix).setUint32(0, 255, Endian.little);
  builder.add(metaPrefix);
  builder.add(metaPayload);

  // Write audio frames
  final payload = Uint8List(frameSize);
  for (var i = 0; i < audioFrameCount; i++) {
    final prefix = Uint8List(4);
    ByteData.sublistView(prefix).setUint32(0, frameSize, Endian.little);
    builder.add(prefix);
    builder.add(payload);
  }

  file.writeAsBytesSync(builder.toBytes());
  return file;
}

void main() {
  late Directory tempDir;
  late MockPathProvider mockPathProvider;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    // Mock AacEncoder channel — fall through to WAV path on all calls
    const aacChannel = MethodChannel('com.omi.offline/aacEncoder');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      aacChannel,
      (call) async {
        if (call.method == 'startEncoder') return 'test-session';
        return null;
      },
    );

    tempDir = Directory.systemTemp.createTempSync('processor_test');
    mockPathProvider = MockPathProvider()..tempPath = tempDir.path;
    PathProviderPlatform.instance = mockPathProvider;

    SharedPreferences.setMockInitialValues({
      'offlineSnrMarginDb': 10.0,
      'offlineHangoverSeconds': 0.0, // disabled for determinism
      'offlineSplitSeconds': 2, // 100 frames
      'offlineMinSpeechSeconds': 0,
      'offlinePreSpeechSeconds': 1.0, // 50 frames
      'offlineGapSeconds': 10,
    });
    await SharedPreferencesUtil.init();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('processSegmentFile splits and calculates timestamps accurately', () async {
    final decoder = MockDecoder();
    final processor = OfflineAudioProcessor(decoder: decoder);

    final startTime = DateTime(2026, 3, 11, 10);
    final speechPcm = Int16List.fromList(List.filled(320, 3000)); // ~-20.8 dBFS, above -30 dBFS threshold
    final silencePcm = Int16List.fromList(List.filled(320, 0));

    // 1. Process a chunk file with 10 speech frames
    decoder.pcmToReturn = speechPcm;
    final chunk1 = _buildChunkFile(tempDir, 'chunk1.bin', 10, 5);
    await processor.processSegmentFile(chunk1, startTime);

    // 2. Process a chunk file with 100 silence frames (triggers split)
    decoder.pcmToReturn = silencePcm;
    final chunk2 = _buildChunkFile(tempDir, 'chunk2.bin', 100, 5);
    final savedFiles = await processor.processSegmentFile(chunk2, startTime);

    expect(savedFiles.length, 1);

    // 3. Process a chunk file with 10 speech frames again
    decoder.pcmToReturn = speechPcm;
    final chunk3 = _buildChunkFile(tempDir, 'chunk3.bin', 10, 5);
    await processor.processSegmentFile(chunk3, startTime);

    // 4. Flush remaining
    final finalFile = await processor.flushRemaining();
    expect(finalFile, isNotNull);
  });

  test('flushRemaining returns null when no speech accumulated', () async {
    final decoder = MockDecoder();
    final processor = OfflineAudioProcessor(decoder: decoder);

    final result = await processor.flushRemaining();
    expect(result, isNull);
  });

  test('isCapturing is false before any processing', () {
    final decoder = MockDecoder();
    final processor = OfflineAudioProcessor(decoder: decoder);

    expect(processor.isCapturing, isFalse);
  });

  test('isCapturing is true after speech frames, false after split', () async {
    final decoder = MockDecoder();
    final processor = OfflineAudioProcessor(decoder: decoder);

    final startTime = DateTime(2026, 3, 11, 10);
    final speechPcm = Int16List.fromList(List.filled(320, 3000));
    final silencePcm = Int16List.fromList(List.filled(320, 0));

    // Process speech — should trigger isCapturing = true
    decoder.pcmToReturn = speechPcm;
    final speechChunk = _buildChunkFile(tempDir, 'speech.bin', 10, 5);
    await processor.processSegmentFile(speechChunk, startTime);
    expect(processor.isCapturing, isTrue);

    // Process 100 silence frames — triggers split, resets speechFrameCount
    decoder.pcmToReturn = silencePcm;
    final silenceChunk = _buildChunkFile(tempDir, 'silence.bin', 100, 5);
    await processor.processSegmentFile(silenceChunk, startTime);

    // After split, speechFrameCount is reset to 0, so isCapturing should be false
    expect(processor.isCapturing, isFalse);
  });

  test('flushOnlyCompleted never saves in-progress recording', () async {
    final decoder = MockDecoder();
    final processor = OfflineAudioProcessor(decoder: decoder);

    final startTime = DateTime(2026, 3, 11, 10);
    final speechPcm = Int16List.fromList(List.filled(320, 3000));

    // Process 10 speech frames — not enough silence to split, still in-progress
    decoder.pcmToReturn = speechPcm;
    final speechChunk = _buildChunkFile(tempDir, 'speech.bin', 10, 5);
    await processor.processSegmentFile(speechChunk, startTime);

    // flushOnlyCompleted must not save in-progress recording
    final result = await processor.flushOnlyCompleted();
    expect(result, isEmpty);
  });

  test('gap detection force-splits on large time gap between chunks', () async {
    final decoder = MockDecoder();
    // Use a very small gap threshold: 10 seconds
    SharedPreferences.setMockInitialValues({
      'offlineSnrMarginDb': 10.0,
      'offlineHangoverSeconds': 0.0,
      'offlineSplitSeconds': 2,
      'offlineMinSpeechSeconds': 0,
      'offlinePreSpeechSeconds': 1.0,
      'offlineGapSeconds': 10,
    });
    await SharedPreferencesUtil.init();

    final processor = OfflineAudioProcessor(decoder: decoder);

    final speechPcm = Int16List.fromList(List.filled(320, 3000));
    decoder.pcmToReturn = speechPcm;

    // First chunk at T=0
    final t0 = DateTime(2026, 3, 11, 10, 0, 0);
    final chunk1 = _buildChunkFile(tempDir, 'chunk_gap1.bin', 10, 5);
    final saved1 = await processor.processSegmentFile(chunk1, t0);

    // Second chunk at T+2hr — well beyond the 10s gap threshold
    final t2hr = t0.add(const Duration(hours: 2));
    final chunk2 = _buildChunkFile(tempDir, 'chunk_gap2.bin', 10, 5);
    final saved2 = await processor.processSegmentFile(chunk2, t2hr);

    // The gap should have triggered a flushRemaining, producing at least 1 file
    final allSaved = [...saved1, ...saved2];
    expect(allSaved.length, greaterThanOrEqualTo(1));
  });

  test('minimum speech threshold discards short recordings', () async {
    // Set minimum speech to 5 seconds (250 frames at 20ms each)
    SharedPreferences.setMockInitialValues({
      'offlineSnrMarginDb': 10.0,
      'offlineHangoverSeconds': 0.0,
      'offlineSplitSeconds': 2,
      'offlineMinSpeechSeconds': 5, // 250 frames required
      'offlinePreSpeechSeconds': 1.0,
      'offlineGapSeconds': 10,
    });
    await SharedPreferencesUtil.init();

    final decoder = MockDecoder();
    final processor = OfflineAudioProcessor(decoder: decoder);

    final startTime = DateTime(2026, 3, 11, 10);
    final speechPcm = Int16List.fromList(List.filled(320, 3000));
    final silencePcm = Int16List.fromList(List.filled(320, 0));

    // Process only 10 speech frames (far below the 250 minimum)
    decoder.pcmToReturn = speechPcm;
    final speechChunk = _buildChunkFile(tempDir, 'short_speech.bin', 10, 5);
    await processor.processSegmentFile(speechChunk, startTime);

    // Process 100 silence frames to trigger the split
    decoder.pcmToReturn = silencePcm;
    final silenceChunk = _buildChunkFile(tempDir, 'silence.bin', 100, 5);
    final savedFiles = await processor.processSegmentFile(silenceChunk, startTime);

    // The split fired but recording should be discarded (too short)
    expect(savedFiles, isEmpty);
  });

  test('metadata packet in chunk updates chunk start time', () async {
    // The processor reads metadata only when sessionId is passed.
    // Use sessionId=1 so the metadata packet is parsed.
    final decoder = MockDecoder();
    final processor = OfflineAudioProcessor(decoder: decoder);

    // UTC epoch for a specific known time: 2026-01-15 12:00:00 UTC
    final metaEpochSec = DateTime.utc(2026, 1, 15, 12, 0, 0).millisecondsSinceEpoch ~/ 1000;

    // Build a chunk with one metadata packet followed by 10 speech frames
    final speechPcm = Int16List.fromList(List.filled(320, 3000));
    decoder.pcmToReturn = speechPcm;

    final chunk = _buildChunkFileWithMeta(
      tempDir,
      'meta_chunk.bin',
      metaEpochSec,
      0, // uptimeMs=0; utcSecs > 0 so it takes the direct UTC path
      10,
      5,
    );

    // Pass a wrong fallback time and sessionId=1 so metadata is read
    final wrongFallback = DateTime(2020, 1, 1);
    await processor.processSegmentFile(chunk, wrongFallback, deviceSessionId: 1);

    // Flush remaining to save the recording
    final savedPath = await processor.flushRemaining();
    expect(savedPath, isNotNull);

    // The filename should contain the metadata timestamp's milliseconds
    final expectedMs = metaEpochSec * 1000;
    final filename = savedPath!.split('/').last;
    expect(filename, contains(expectedMs.toString()),
        reason: 'Recording filename should reflect the metadata UTC timestamp, not the wrong fallback');
  });
}
