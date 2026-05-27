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

class MockPathProviderPlatform extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
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

File _makeBinFileWithHeader(
  Directory dir,
  int frameCount, {
  String name = 'test_with_header.bin',
  required int utcStartMs,
  required int uptimeStartMs,
  required int imuTicks,
  required int sessionId,
}) {
  final f = File('${dir.path}/$name');
  final builder = BytesBuilder();

  // 36-byte header
  final headerData = ByteData(36);
  headerData.setUint32(0, 0xFFFFFFFB, Endian.little);
  headerData.setUint32(4, 28, Endian.little);
  headerData.setUint64(8, utcStartMs, Endian.little);
  headerData.setUint64(16, uptimeStartMs, Endian.little);
  headerData.setUint32(24, imuTicks, Endian.little);
  headerData.setUint32(28, sessionId, Endian.little);
  headerData.setUint32(32, 1, Endian.little); // version 1
  builder.add(headerData.buffer.asUint8List());

  const frameLength = 4;
  final frameHeader = ByteData(4)..setUint32(0, frameLength, Endian.little);
  for (int i = 0; i < frameCount; i++) {
    builder.add(frameHeader.buffer.asUint8List());
    builder.add(List.filled(frameLength, 0));
  }
  f.writeAsBytesSync(builder.toBytes());
  return f;
}

File _makeBinFileWithVadResume(
  Directory dir,
  int frameCountBefore,
  int frameCountAfter, {
  String name = 'test_vad_resume.bin',
  required int vadUtcSeconds,
  required int vadUptimeMs,
}) {
  final f = File('${dir.path}/$name');
  final builder = BytesBuilder();

  const frameLength = 4;
  final frameHeader = ByteData(4)..setUint32(0, frameLength, Endian.little);

  // Frames before VAD sleep
  for (int i = 0; i < frameCountBefore; i++) {
    builder.add(frameHeader.buffer.asUint8List());
    builder.add(List.filled(frameLength, 0));
  }

  // VAD Resume Marker (0xFFFFFFFD)
  final markerData = ByteData(20);
  markerData.setUint32(0, 0xFFFFFFFD, Endian.little);
  markerData.setUint32(4, vadUtcSeconds, Endian.little);
  markerData.setUint32(8, vadUptimeMs, Endian.little);
  builder.add(markerData.buffer.asUint8List());

  // Frames after VAD sleep
  for (int i = 0; i < frameCountAfter; i++) {
    builder.add(frameHeader.buffer.asUint8List());
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
    minSpeechMs: 0,
    discardShort: discardShort,
    maxChunkMs: 3600000,
    deviceId: 'test-device',
    audioSaveFormat: 'm4a',
    omiEnabled: false,
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
      refs.add(FrameRef(segmentFile: dummyFile, byteOffset: i * 54, frameLength: 50));
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
      refs.add(FrameRef(segmentFile: dummyFile, byteOffset: i * 54, frameLength: 50));
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

    test('gaps under 10 seconds are stitched without padding', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0, discardShort: false),
        outputDir: tempDir.path,
      );

      final startTime = DateTime(2024, 1, 1, 10, 0, 0);
      const startUptime = 10000;
      // File 1: 5 frames = 100 ms
      await processor.processSegmentFile(
        _makeBinFile(tempDir, 5, name: 'file1.bin'),
        startTime,
        startUptimeMs: startUptime,
      );

      // File 2: starts 5 seconds after File 1 ends
      // File 1 end = 10:00:00.100, uptime end = 10100
      final file2Start = startTime.add(const Duration(milliseconds: 100 + 5000));
      const file2Uptime = startUptime + 100 + 5000;
      await processor.processSegmentFile(
        _makeBinFile(tempDir, 5, name: 'file2.bin'),
        file2Start,
        startUptimeMs: file2Uptime,
      );

      // Expected duration: 100ms (file1) + 100ms (file2) = 200ms
      // (Gap is 5s < 10s, so no padding even if uptime matches)
      expect(processor.currentChunkDurationMs, 200);
      processor.destroy();
    });

    test('gaps over 10 seconds but under threshold are padded', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0, discardShort: false),
        outputDir: tempDir.path,
      );

      final startTime = DateTime(2024, 1, 1, 10, 0, 0);
      const startUptime = 10000;
      // File 1: 5 frames = 100 ms
      await processor.processSegmentFile(
        _makeBinFile(tempDir, 5, name: 'file1.bin'),
        startTime,
        startUptimeMs: startUptime,
      );

      // File 2: starts 15 seconds after File 1 ends
      // File 1 end = 10:00:00.100, uptime end = 10100
      final file2Start = startTime.add(const Duration(milliseconds: 100 + 15000));
      const file2Uptime = startUptime + 100 + 15000; // Uptime advances normally (real silence)
      await processor.processSegmentFile(
        _makeBinFile(tempDir, 5, name: 'file2.bin'),
        file2Start,
        startUptimeMs: file2Uptime,
      );

      // Expected duration: 100ms (file1) + 100ms (file2) + 15000ms (padding) = 15200ms
      expect(processor.currentChunkDurationMs, 15200);
      processor.destroy();
    });

    test('clock sync jumps (uptime gap < 5s) are NOT padded even if > 10s', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0, discardShort: false),
        outputDir: tempDir.path,
      );

      final startTime = DateTime(2024, 1, 1, 10, 0, 0);
      const startUptime = 10000;
      // File 1: 5 frames = 100 ms
      await processor.processSegmentFile(
        _makeBinFile(tempDir, 5, name: 'file1.bin'),
        startTime,
        startUptimeMs: startUptime,
      );

      // File 2: starts 15 seconds after File 1 ends in UTC, but ONLY 100ms in Uptime (Clock Sync)
      final file2Start = startTime.add(const Duration(milliseconds: 100 + 15000));
      const file2Uptime = startUptime + 100; // Uptime didn't advance (it's a jump)
      await processor.processSegmentFile(
        _makeBinFile(tempDir, 5, name: 'file2.bin'),
        file2Start,
        startUptimeMs: file2Uptime,
      );

      // Expected duration: 100ms (file1) + 100ms (file2) = 200ms (No padding!)
      expect(processor.currentChunkDurationMs, 200);
      processor.destroy();
    });

    test('IMU Bridge: stitches audio across reboots using IMU tick delta', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0, discardShort: false),
        outputDir: tempDir.path,
      );

      final utcEpochMs = 1000000000000;
      final startTime = DateTime.fromMillisecondsSinceEpoch(utcEpochMs, isUtc: true);

      // File 1 (Session 1): 5 frames = 100 ms
      final file1 = _makeBinFileWithHeader(
        tempDir,
        5,
        name: 'file1_imu.bin',
        utcStartMs: utcEpochMs,
        uptimeStartMs: 10000,
        imuTicks: 100000,
        sessionId: 1,
      );

      await processor.processSegmentFile(file1, startTime);

      // File 2 (Session 2): Starts 15 seconds after File 1 ends
      // Gap = 15000 ms
      // File 1 duration = 100 ms.
      // Ticks passed during file 1 = 100 / 6.4 = 15
      // Ticks passed during gap = 15000 / 6.4 = 2343
      // Expected currentImuTicks = 100000 + 15 + 2343 = 102358
      final gapMs = 15000;
      final nextUtcEpochMs = utcEpochMs + 100 + gapMs;
      final file2Start = DateTime.fromMillisecondsSinceEpoch(nextUtcEpochMs, isUtc: true);

      final file2 = _makeBinFileWithHeader(
        tempDir,
        5,
        name: 'file2_imu.bin',
        utcStartMs: nextUtcEpochMs,
        uptimeStartMs: 5000, // Re-booted, uptime resets
        imuTicks: 102358,
        sessionId: 2, // Re-booted, session ID changes
      );

      await processor.processSegmentFile(file2, file2Start);

      // If IMU bridge works, session change doesn't split the file.
      // It should insert gap padding.
      // Expected: 100 (file1) + 15000 (padding) + 100 (file2) = 15200 ms
      expect(processor.currentChunkDurationMs, 15200);
      processor.destroy();
    });

    test('AAD Padding: pads offline gaps with digital silence using VAD resume marker', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0, discardShort: false),
        outputDir: tempDir.path,
      );

      final startTimeMs = 1000000000000;
      final startTime = DateTime.fromMillisecondsSinceEpoch(startTimeMs, isUtc: true);
      final startUptime = 10000;

      final framesBefore = 50; // 1000 ms
      final framesAfter = 50; // 1000 ms
      final sleepGapMs = 5000; // 5 seconds of VAD sleep

      final vadResumeUtcSeconds = (startTimeMs + (framesBefore * 20) + sleepGapMs) ~/ 1000;
      final vadResumeUptimeMs = startUptime + (framesBefore * 20) + sleepGapMs;

      final file = _makeBinFileWithVadResume(
        tempDir,
        framesBefore,
        framesAfter,
        vadUtcSeconds: vadResumeUtcSeconds,
        vadUptimeMs: vadResumeUptimeMs,
      );

      await processor.processSegmentFile(file, startTime, startUptimeMs: startUptime);

      // Expected:
      // 1000 ms (framesBefore)
      // + 5000 ms (padding inserted by VAD resume marker)
      // + 1000 ms (framesAfter)
      // = 7000 ms
      expect(processor.currentChunkDurationMs, 7000);
      processor.destroy();
    });

    group('High-Precision Timestamp Pipeline', () {
      test('RTC Sync Jitter: handles small negative gaps gracefully', () async {
        final processor = VadAudioProcessor.fromSettings(
          settings: _settings(minDurationMs: 0, discardShort: false),
          outputDir: tempDir.path,
        );

        final startSeconds = 1713892490;
        const startUptime = 10000;

        // 1. Process initial frames (10 frames = 200ms at 20ms/frame)
        await processor.processSegmentFile(
          _makeBinFile(tempDir, 10, name: 'file1.bin'),
          DateTime.fromMillisecondsSinceEpoch(startSeconds * 1000, isUtc: true),
          startUptimeMs: startUptime,
        );

        // 2. VAD Resume with "negative" gap due to RTC jitter
        // lastFrameEndTime = 10:00:00.200
        // newResumeTime = 10:00:00.195 (-5ms jitter)
        final resumeSeconds = startSeconds; // Same second
        const resumeUptime = startUptime + 200;

        final binWithJitter = _makeBinFileWithVadResume(
          tempDir,
          0, // 0 frames before
          5, // 5 frames after (100ms)
          name: 'jitter.bin',
          vadUtcSeconds: resumeSeconds,
          vadUptimeMs: resumeUptime,
        );

        // This should not crash and should treat negative gap as 0
        await processor.processSegmentFile(
          binWithJitter,
          DateTime.fromMillisecondsSinceEpoch(startSeconds * 1000, isUtc: true),
        );

        // Duration: 200ms (file1) + 0ms (jitter) + 100ms (jitter.bin) = 300ms
        expect(processor.currentChunkDurationMs, 300);
        processor.destroy();
      });

      test('IMU Tick Rollover: handles 24-bit rollover correctly', () async {
        final processor = VadAudioProcessor.fromSettings(
          settings: _settings(minDurationMs: 0, discardShort: false),
          outputDir: tempDir.path,
        );

        // Session 1 ends near max 24-bit (0xFFFFFF = 16777215)
        final file1 = _makeBinFileWithHeader(
          tempDir,
          5,
          name: 'rollover1.bin',
          utcStartMs: 1000000000000,
          uptimeStartMs: 10000,
          imuTicks: 0xFFFF00,
          sessionId: 1,
        );
        await processor.processSegmentFile(file1, DateTime.fromMillisecondsSinceEpoch(1000000000000));

        // Session 2 starts after rollover (e.g. at 0x000100)
        // Delta = 0x000100 - 0xFFFF00 = 0x000200 (using & 0xFFFFFF)
        // 0x000200 = 512 ticks = 512 * 6.4ms = 3276.8ms gap
        final file2 = _makeBinFileWithHeader(
          tempDir,
          5,
          name: 'rollover2.bin',
          utcStartMs: 1000000003376,
          uptimeStartMs: 5000,
          imuTicks: 0x000100,
          sessionId: 2,
        );
        await processor.processSegmentFile(file2, DateTime.fromMillisecondsSinceEpoch(1000000003376));

        // Stitching should occur because gap matches IMU delta
        expect(processor.currentSessionId, 1); // Stayed in session 1 due to bridge
        expect(processor.currentChunkDurationMs >= 3376 + 100, true);
        processor.destroy();
      });
    });
  });
}
