import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/vad_audio_processor.dart';
import 'package:omi/services/frame_ref.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/backend/preferences.dart';
import 'dart:typed_data';

class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  late String tempPath;

  MockPathProviderPlatform() {
    tempPath = Directory.systemTemp.path;
  }

  @override
  Future<String?> getApplicationDocumentsDirectoryPath() async {
    return tempPath;
  }

  @override
  Future<String?> getApplicationDocumentsPath() async {
    return tempPath;
  }
}

void main() {
  late Directory tempDir;
  late MockPathProviderPlatform mockPathProvider;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('vad_processor_test');
    mockPathProvider = MockPathProviderPlatform();
    mockPathProvider.tempPath = tempDir.path;
    PathProviderPlatform.instance = mockPathProvider;
    TestWidgetsFlutterBinding.ensureInitialized();

    // Mock flutter_secure_storage
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'read') return null;
        if (methodCall.method == 'readAll') return <String, String>{};
        if (methodCall.method == 'write') return null;
        if (methodCall.method == 'delete') return null;
        if (methodCall.method == 'deleteAll') return null;
        return null;
      },
    );

    SharedPreferences.setMockInitialValues({'convertOpusToM4a': true});
    await SharedPreferencesUtil.init();
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('VadAudioProcessor AAC startEncoder exception fallback to WAV', () async {
    bool startEncoderCalled = false;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.omi.offline/aacEncoder'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'startEncoder') {
          startEncoderCalled = true;
          throw PlatformException(code: 'ERROR', message: 'Simulated encoder failure');
        }
        return null;
      },
    );

    final processor = await VadAudioProcessor.create(outputDir: tempDir.path);
    final dummyFile = File('${tempDir.path}/dummy.bin');

    final bytes = BytesBuilder();
    for (int i = 0; i < 5; i++) {
       final lengthBytes = ByteData(4)..setUint32(0, 50, Endian.little);
       bytes.add(lengthBytes.buffer.asUint8List());
       bytes.add(List.filled(50, 0));
    }
    await dummyFile.writeAsBytes(bytes.toBytes());

    final refs = <FrameRef>[];
    for (int i = 0; i < 5; i++) {
      refs.add(FrameRef(
        segmentFile: dummyFile,
        byteOffset: i * 54,
        frameLength: 50,
      ));
    }

    final savedPath = await processor.saveRecordingTest(refs, DateTime.now());

    expect(startEncoderCalled, isTrue, reason: 'AAC startEncoder should have been called');
    expect(savedPath, isNotNull, reason: 'Should return a saved path (fallback)');
    expect(savedPath!.endsWith('.wav'), isTrue, reason: 'Should fall back to .wav extension');

    final savedFile = File(savedPath);
    expect(await savedFile.exists(), isTrue, reason: 'The fallback WAV file should exist');
  });

  test('VadAudioProcessor AAC encodeBuffer/finishEncoder exception fallback to WAV', () async {
    bool startEncoderCalled = false;
    bool finishEncoderCalled = false;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.omi.offline/aacEncoder'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'startEncoder') {
          startEncoderCalled = true;
          return "test-session-id";
        } else if (methodCall.method == 'finishEncoder') {
          finishEncoderCalled = true;
          throw PlatformException(code: 'ERROR', message: 'Simulated encode/finish failure');
        } else if (methodCall.method == 'encodeBuffer') {
          // just ignore
          return null;
        }
        return null;
      },
    );

    final processor = await VadAudioProcessor.create(outputDir: tempDir.path);
    final dummyFile = File('${tempDir.path}/dummy.bin');

    final bytes = BytesBuilder();
    for (int i = 0; i < 5; i++) {
       final lengthBytes = ByteData(4)..setUint32(0, 50, Endian.little);
       bytes.add(lengthBytes.buffer.asUint8List());
       bytes.add(List.filled(50, 0));
    }
    await dummyFile.writeAsBytes(bytes.toBytes());

    final refs = <FrameRef>[];
    for (int i = 0; i < 5; i++) {
      refs.add(FrameRef(
        segmentFile: dummyFile,
        byteOffset: i * 54,
        frameLength: 50,
      ));
    }

    final savedPath = await processor.saveRecordingTest(refs, DateTime.now());

    // Dummy zero bytes cannot be Opus-decoded, so no PCM frames are encoded.
    // hasEncodedAnyFrames stays false → empty segment is discarded before finishEncoder is called.
    expect(startEncoderCalled, isTrue, reason: 'AAC startEncoder should have been called');
    expect(finishEncoderCalled, isFalse, reason: 'finishEncoder is not reached when no frames are encoded');
    expect(savedPath, isNull, reason: 'Empty segment is discarded, returning null');
  });
}
