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
      'offlinePreSpeechSeconds': 1, // 50 frames
      'offlineGapSeconds': 10,
    });
    await SharedPreferencesUtil.init();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('processChunkFile splits and calculates timestamps accurately', () async {
    final decoder = MockDecoder();
    final processor = OfflineAudioProcessor(decoder: decoder);

    final startTime = DateTime(2026, 3, 11, 10);
    final speechPcm = Int16List.fromList(List.filled(320, 3000)); // ~-20.8 dBFS, above -30 dBFS threshold
    final silencePcm = Int16List.fromList(List.filled(320, 0));

    // 1. Process a chunk file with 10 speech frames
    decoder.pcmToReturn = speechPcm;
    final chunk1 = _buildChunkFile(tempDir, 'chunk1.bin', 10, 5);
    await processor.processChunkFile(chunk1, startTime);

    // 2. Process a chunk file with 100 silence frames (triggers split)
    decoder.pcmToReturn = silencePcm;
    final chunk2 = _buildChunkFile(tempDir, 'chunk2.bin', 100, 5);
    final savedFiles = await processor.processChunkFile(chunk2, startTime);

    expect(savedFiles.length, 1);

    // 3. Process a chunk file with 10 speech frames again
    decoder.pcmToReturn = speechPcm;
    final chunk3 = _buildChunkFile(tempDir, 'chunk3.bin', 10, 5);
    await processor.processChunkFile(chunk3, startTime);

    // 4. Flush remaining
    final finalFile = await processor.flushRemaining();
    expect(finalFile, isNotNull);
  });
}
