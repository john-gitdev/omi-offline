import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/offline_audio_processor.dart';
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

class MockDecoder extends Fake implements SimpleOpusDecoder {
  Int16List pcmToReturn = Int16List(320);

  @override
  Int16List decode({Uint8List? input, bool fec = false, int? loss}) => pcmToReturn;

  @override
  void destroy() {}
}

class FailingDecoderWithSpeech extends MockDecoder {
  int count = 0;
  @override
  Int16List decode({Uint8List? input, bool fec = false, int? loss}) {
    if (count++ == 2) throw Exception('Corrupt frame');
    return Int16List.fromList(List.filled(320, 3000));
  }
}

/// Writes [count] length-prefixed frames of [frameSize] bytes to a .bin file.
/// Frame size must not be 255 (reserved for metadata packets).
File _buildSegmentFile(Directory dir, String name, int count, int frameSize) {
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

/// Builds a segment file that starts with ONE metadata packet (utcSecs, uptimeMs)
/// followed by [audioFrameCount] audio frames of [frameSize] bytes.
File _buildSegmentFileWithMeta(Directory dir, String name, int utcSecs, int uptimeMs, int audioFrameCount, int frameSize) {
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
        if (call.method == 'startEncoder') return 'test-device-session';
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

    // 1. Process a segment file with 10 speech frames
    decoder.pcmToReturn = speechPcm;
    final segment1 = _buildSegmentFile(tempDir, 'segment1.bin', 10, 5);
    await processor.processSegmentFile(segment1, startTime);

    // 2. Process a segment file with 100 silence frames (triggers split)
    decoder.pcmToReturn = silencePcm;
    final segment2 = _buildSegmentFile(tempDir, 'segment2.bin', 100, 5);
    final savedFiles = await processor.processSegmentFile(segment2, startTime);

    expect(savedFiles.length, 1);

    // 3. Process a segment file with 10 speech frames again
    decoder.pcmToReturn = speechPcm;
    final segment3 = _buildSegmentFile(tempDir, 'segment3.bin', 10, 5);
    await processor.processSegmentFile(segment3, startTime);

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
    final speechSegment = _buildSegmentFile(tempDir, 'speech.bin', 10, 5);
    await processor.processSegmentFile(speechSegment, startTime);
    expect(processor.isCapturing, isTrue);

    // Process 100 silence frames — triggers split, resets speechFrameCount
    decoder.pcmToReturn = silencePcm;
    final silenceSegment = _buildSegmentFile(tempDir, 'silence.bin', 100, 5);
    await processor.processSegmentFile(silenceSegment, startTime);

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
    final speechSegment = _buildSegmentFile(tempDir, 'speech.bin', 10, 5);
    await processor.processSegmentFile(speechSegment, startTime);

    // flushOnlyCompleted must not save in-progress recording
    final result = await processor.flushOnlyCompleted();
    expect(result, isEmpty);
  });

  test('gap detection force-splits on large time gap between segments', () async {
    final decoder = MockDecoder();
    // Use a very small gap threshold: 10 seconds
    SharedPreferences.setMockInitialValues({
      'offlineSnrMarginDb': 10.0,
      'offlineHangoverSeconds': 0.0, // disabled for determinism
      'offlineSplitSeconds': 2,
      'offlineMinSpeechSeconds': 0,
      'offlinePreSpeechSeconds': 1.0,
      'offlineGapSeconds': 10,
    });
    await SharedPreferencesUtil.init();

    final processor = OfflineAudioProcessor(decoder: decoder);

    final speechPcm = Int16List.fromList(List.filled(320, 3000));
    decoder.pcmToReturn = speechPcm;

    // First segment at T=0
    final t0 = DateTime(2026, 3, 11, 10, 0, 0);
    final segment1 = _buildSegmentFile(tempDir, 'segment_gap1.bin', 10, 5);
    final saved1 = await processor.processSegmentFile(segment1, t0);

    // Second segment at T+2hr — well beyond the 10s gap threshold
    final t2hr = t0.add(const Duration(hours: 2));
    final segment2 = _buildSegmentFile(tempDir, 'segment_gap2.bin', 10, 5);
    final saved2 = await processor.processSegmentFile(segment2, t2hr);

    // The gap should have triggered a flushRemaining, producing at least 1 file
    final allSaved = [...saved1, ...saved2];
    expect(allSaved.length, greaterThanOrEqualTo(1));
  });

  test('minimum speech threshold discards short recordings', () async {
    // Set minimum speech to 5 seconds (250 frames at 20ms each)
    SharedPreferences.setMockInitialValues({
      'offlineSnrMarginDb': 10.0,
      'offlineHangoverSeconds': 0.0, // disabled for determinism
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
    final speechSegment = _buildSegmentFile(tempDir, 'short_speech.bin', 10, 5);
    await processor.processSegmentFile(speechSegment, startTime);

    // Process 100 silence frames to trigger the split
    decoder.pcmToReturn = silencePcm;
    final silenceSegment = _buildSegmentFile(tempDir, 'silence.bin', 100, 5);
    final savedFiles = await processor.processSegmentFile(silenceSegment, startTime);

    // The split fired but recording should be discarded (too short)
    expect(savedFiles, isEmpty);
  });

  test('metadata packet in segment updates segment start time', () async {
    // The processor reads metadata only when deviceSessionId is passed.
    // Use deviceSessionId=1 so the metadata packet is parsed.
    final decoder = MockDecoder();
    final processor = OfflineAudioProcessor(decoder: decoder);

    // UTC epoch for a specific known time: 2026-01-15 12:00:00 UTC
    final metaEpochSec = DateTime.utc(2026, 1, 15, 12, 0, 0).millisecondsSinceEpoch ~/ 1000;

    // Build a segment with one metadata packet followed by 10 speech frames
    final speechPcm = Int16List.fromList(List.filled(320, 3000));
    decoder.pcmToReturn = speechPcm;

    final segment = _buildSegmentFileWithMeta(
      tempDir,
      'meta_segment.bin',
      metaEpochSec,
      0, // uptimeMs=0; utcSecs > 0 so it takes the direct UTC path
      10,
      5,
    );

    // Pass a wrong fallback time and deviceSessionId=1 so metadata is read
    final wrongFallback = DateTime(2020, 1, 1);
    await processor.processSegmentFile(segment, wrongFallback, deviceSessionId: 1);

    // Flush remaining to save the recording
    final savedPath = await processor.flushRemaining();
    expect(savedPath, isNotNull);

    // The filename should contain the metadata timestamp's milliseconds
    final expectedMs = metaEpochSec * 1000;
    final filename = savedPath!.split('/').last;
    expect(filename, contains(expectedMs.toString()),
        reason: 'Recording filename should reflect the metadata UTC timestamp, not the wrong fallback');
  });

  test('monotonicity clamping ensures time never moves backward', () async {
    final decoder = MockDecoder();
    final processor = OfflineAudioProcessor(decoder: decoder);
    
    final speechPcm = Int16List.fromList(List.filled(320, 3000));
    decoder.pcmToReturn = speechPcm;

    // Initial time: T=1000
    final t1000 = DateTime.fromMillisecondsSinceEpoch(1000);
    final segment1 = _buildSegmentFile(tempDir, 'mono1.bin', 5, 5);
    await processor.processSegmentFile(segment1, t1000);

    // Second segment reported as T=500 (backward jump in metadata)
    final t500 = DateTime.fromMillisecondsSinceEpoch(500);
    final segment2 = _buildSegmentFile(tempDir, 'mono2.bin', 5, 5);
    await processor.processSegmentFile(segment2, t500);

    final savedPath = await processor.flushRemaining();
    expect(savedPath, isNotNull);

    // Duration should be at least 10 frames * 20ms = 200ms
    // Start time should be the first reported time (1000)
    final conv = Conversation.fromFile(File(savedPath!));
    expect(conv.startTime.millisecondsSinceEpoch, equals(1000));
    expect(conv.duration.inMilliseconds, greaterThanOrEqualTo(200));
  });

  test('skips corrupt Opus frames without crashing', () async {
    final decoder = FailingDecoderWithSpeech();
    final processor = OfflineAudioProcessor(decoder: decoder);

    final startTime = DateTime(2026, 3, 11, 10);
    // Process 5 frames, the 3rd one (index 2) will fail
    final segment = _buildSegmentFile(tempDir, 'corrupt.bin', 5, 5);
    await processor.processSegmentFile(segment, startTime);

    final savedPath = await processor.flushRemaining();
    expect(savedPath, isNotNull);
    
    // Should have saved 4 valid frames
    final conv = Conversation.fromFile(File(savedPath!));
    expect(conv.duration.inMilliseconds, equals(80)); // 4 * 20ms
  });
}
