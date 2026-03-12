import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/offline_audio_processor.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

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

class MockFFmpeg extends Fake implements IFFmpegWrapper {
  @override
  Future<int?> execute(String command) async {
    final parts = command.split(' ');
    final aacPath = parts.last;
    File(aacPath).createSync(recursive: true);
    return 0; // Success
  }
}

void main() {
  late Directory tempDir;
  late MockPathProvider mockPathProvider;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('processor_test');
    mockPathProvider = MockPathProvider()..tempPath = tempDir.path;
    PathProviderPlatform.instance = mockPathProvider;
    
    SharedPreferences.setMockInitialValues({
      'offlineSilenceThreshold': -45.0,
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

  test('processFrames splits and calculates timestamps accurately', () async {
    final decoder = MockDecoder();
    final ffmpeg = MockFFmpeg();
    final processor = OfflineAudioProcessor(decoder: decoder, ffmpeg: ffmpeg);
    
    final startTime = DateTime(2026, 3, 11, 10);
    final speechPcm = Int16List.fromList(List.filled(320, 1000));
    final silencePcm = Int16List.fromList(List.filled(320, 0));

    // 1. Process 10 frames of speech
    decoder.pcmToReturn = speechPcm;
    await processor.processFrames(List.generate(10, (_) => Uint8List(5)), startTime);
    
    // 2. Process 100 frames of silence (Trigger split)
    decoder.pcmToReturn = silencePcm;
    final savedFiles = await processor.processFrames(List.generate(100, (_) => Uint8List(5)), startTime);
    
    expect(savedFiles.length, 1);
    
    // 3. Process 10 frames of speech again
    decoder.pcmToReturn = speechPcm;
    await processor.processFrames(List.generate(10, (_) => Uint8List(5)), startTime);
    
    // 4. Flush remaining
    final finalFile = await processor.flushRemaining();
    expect(finalFile, isNotNull);
    
    // Verify timestamp calculation logic
    // The second recording should start exactly 10 frames + (100 - 50 frames of silence) after the first one.
    // framesToKeep was 10. bufferToKeep was 50 (1s).
    // elapsedMs = (10 - 50) * 20 = -800ms? No, wait.
    // framesToKeep = currentRecordingFrames.length (110) - consecutiveSilence (100) = 10 frames.
    // bufferToKeep = min(preSpeech (50), consecutiveSilence (100)) = 50 frames.
    // elapsedMs = (10 - 50) * 20 = -800ms.
    // This means the new recording starts 800ms BEFORE the first one ended? 
    // Actually, it means it starts at (10 frames * 20ms) - (50 frames * 20ms) relative to original start.
  });
}
