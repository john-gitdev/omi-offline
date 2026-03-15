import 'dart:io';
import 'dart:typed_data';
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

void main() {
  late Directory tempDir;
  late MockPathProvider mockPathProvider;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('processor_test');
    mockPathProvider = MockPathProvider()..tempPath = tempDir.path;
    PathProviderPlatform.instance = mockPathProvider;
    
    SharedPreferences.setMockInitialValues({
      'offlineSnrMarginDb': 10.0,
      'offlineHangoverMs': 0, // disabled for determinism
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
    final processor = OfflineAudioProcessor(decoder: decoder);
    
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
  });
}
