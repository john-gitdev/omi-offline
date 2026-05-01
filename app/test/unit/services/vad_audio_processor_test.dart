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

/// Creates a valid bin file with [frameCount] dummy Opus frames (4 zero bytes each).
/// Each frame is 20 ms → total duration = frameCount * 20 ms.
File _makeBinFile(Directory dir, int frameCount, {String name = 'test.bin'}) {
  final f = File('${dir.path}/$name');
  final builder = BytesBuilder();
  const frameLength = 4;
  final header = ByteData(4)..setUint32(0, frameLength, Endian.little);
  for (int i = 0; i < frameCount; i++) {
    builder.add(header.buffer.asUint8List());
    builder.add(List.filled(frameLength, 0));
  }
  f.writeAsBytesSync(builder.toBytes());
  return f;
}

ProcessingSettings _settings({required int minDurationMs, required bool discardShort}) {
  return ProcessingSettings(
    vadEnabled: true,
    speechThreshold: 0.5,
    silenceDurationToSplitMs: 120000,
    minDurationMs: minDurationMs,
    discardShort: discardShort,
    maxChunkMs: 3600000,
    deviceId: 'test-device',
    convertOpusToM4a: false,
    omiSyncEnabled: false,
  );
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

  group('short recording threshold (discardShort / keep)', () {
    // Each dummy frame = 20 ms. 10 frames = 200 ms, 300 frames = 6000 ms.

    test('discardShort=true fires guard when duration is below threshold', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 5000, discardShort: true),
        outputDir: tempDir.path,
      );
      await processor.processSegmentFile(_makeBinFile(tempDir, 10, name: 'a.bin'), DateTime.now());
      await processor.flushRemaining();
      expect(processor.discardGuardFiredOnLastFlush, isTrue);
      processor.destroy();
    });

    test('discardShort=false does not fire guard when duration is below threshold', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 5000, discardShort: false),
        outputDir: tempDir.path,
      );
      await processor.processSegmentFile(_makeBinFile(tempDir, 10, name: 'b.bin'), DateTime.now());
      await processor.flushRemaining();
      expect(processor.discardGuardFiredOnLastFlush, isFalse);
      processor.destroy();
    });

    test('discardShort=true does not fire guard when duration meets threshold', () async {
      // 300 frames = 6000 ms >= 5000 ms threshold
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 5000, discardShort: true),
        outputDir: tempDir.path,
      );
      await processor.processSegmentFile(_makeBinFile(tempDir, 300, name: 'c.bin'), DateTime.now());
      await processor.flushRemaining();
      expect(processor.discardGuardFiredOnLastFlush, isFalse);
      processor.destroy();
    });

    test('discardShort=true does not fire guard when threshold is 0 (Off)', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0, discardShort: true),
        outputDir: tempDir.path,
      );
      await processor.processSegmentFile(_makeBinFile(tempDir, 10, name: 'd.bin'), DateTime.now());
      await processor.flushRemaining();
      expect(processor.discardGuardFiredOnLastFlush, isFalse);
      processor.destroy();
    });
  });
}
