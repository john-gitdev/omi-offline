import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/vad_audio_processor.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:omi/services/recordings_manager.dart';
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

ProcessingSettings _settings({int minDurationMs = 0}) {
  return ProcessingSettings(
    vadEnabled: true,
    speechThreshold: 0.5,
    silenceDurationToSplitMs: 120000,
    minDurationMs: minDurationMs,
    minSpeechMs: 0,
    maxChunkMs: 3600000,
    deviceId: 'test-device',
    audioSaveFormat: 'm4a',
    omiEnabled: false,
  );
}

/// A non-null [OrtSession] placeholder. Host tests can't load the real Silero
/// model (no native ONNX runtime), but the silence-split tests need
/// `_session != null` so the VAD treats undecodable (null-decoder) frames as
/// SILENCE instead of AAD-mode speech. The session is never invoked — the null
/// decoder skips `_runVad` entirely — so a fromMap placeholder is sufficient.
OrtSession _fakeSession() =>
    OrtSession.fromMap({'sessionId': 'host-test-fake', 'inputNames': <String>[], 'outputNames': <String>[]});

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

    // Mock flutter_onnxruntime so a placeholder OrtSession's close()/dispose()
    // are no-ops (host tests have no native ONNX runtime).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter_onnxruntime'),
      (MethodCall methodCall) async => null,
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

  group('relBinPath (never drops a ref to an empty bin list)', () {
    test('extracts the tail after /raw_segments/', () {
      expect(
        VadAudioProcessor.relBinPath('/data/user/0/com.x/app_flutter/raw_segments/1782066159/1782066159_1.bin'),
        '1782066159/1782066159_1.bin',
      );
    });

    test('uses the LAST /raw_segments/ if the path nests it', () {
      expect(
        VadAudioProcessor.relBinPath('/a/raw_segments/b/raw_segments/1700/1700_2.bin'),
        '1700/1700_2.bin',
      );
    });

    test('normalises backslashes', () {
      expect(
        VadAudioProcessor.relBinPath(r'C:\app\raw_segments\1700\1700_3.bin'),
        '1700/1700_3.bin',
      );
    });

    test('falls back to the last two components when not under raw_segments', () {
      // The defensive case the old guard dropped (→ empty bins → un-mergeable).
      expect(VadAudioProcessor.relBinPath('/data/app/processing_temp/combined/1700_4.bin'), 'combined/1700_4.bin');
    });
  });

  // Recover-discards byte-range ownership. A discard whose frames occupy only
  // PART of a ~5-min bin now records that bin's consumed byte slice in a separate
  // `binRanges` field (relativeBins stays a bare path list, so prune/protect/sweep
  // are unaffected). recoverDiscard passes the slice to processSegmentFile so it
  // re-derives ONLY the discarded span, never the neighbor recording sharing the
  // bin — the overlapping/oversized-recovery bug. (A full runtime audio repro
  // isn't possible in this host harness: dummy zero-byte frames don't Opus-decode,
  // so no recording is saved — see the AAC-fallback tests above — so the discard
  // metadata that drives the slice is pinned at the logic level here.)
  group('recover-discards byte-range ownership', () {
    List<FrameRef> subBinRefs(File bin) => <FrameRef>[
          // Frames occupying only bytes [800, 1400) of a bin also owned by a
          // neighbor recording (the straddle case the firmware's ~5-min bins make routine).
          FrameRef(segmentFile: bin, byteOffset: 800, frameLength: 20),
          FrameRef(segmentFile: bin, byteOffset: 1376, frameLength: 20),
        ];

    test('relativeBins stays a bare path (path-keyed consumers unaffected)', () async {
      final p = await VadAudioProcessor.create(outputDir: tempDir.path);
      final bin = File('${tempDir.path}/raw_segments/1700000000/1700000000_7.bin');
      final rec = p.buildDiscardRecordForTest(
          subBinRefs(bin), DateTime.fromMillisecondsSinceEpoch(1700000000000), 600, 'flush_too_short_duration');
      final bins = (rec!['relativeBins'] as List).cast<String>();
      expect(bins, ['1700000000/1700000000_7.bin']);
      expect(bins.single.contains('@'), isFalse,
          reason: 'the byte slice lives in binRanges, not mangled into the path');
    });

    test('records the consumed byte slice [minOffset, maxOffset+len) in binRanges', () async {
      final p = await VadAudioProcessor.create(outputDir: tempDir.path);
      final bin = File('${tempDir.path}/raw_segments/1700000000/1700000000_7.bin');
      final rec = p.buildDiscardRecordForTest(
          subBinRefs(bin), DateTime.fromMillisecondsSinceEpoch(1700000000000), 600, 'flush_too_short_duration');
      final ranges = (rec!['binRanges'] as Map).cast<String, List<int>>();
      // start = min byteOffset (800); end = max(byteOffset + 4-byte len prefix +
      // 4-byte-aligned payload) = 1376 + 4 + 20 = 1400.
      expect(ranges['1700000000/1700000000_7.bin'], [800, 1400]);
    });
  });

  group('AAD resume-split flood guard', () {
    test('a lone short split does NOT coalesce; a run of 3 latches', () async {
      final p = await VadAudioProcessor.create(outputDir: tempDir.path);
      expect(p.aadFloodStep(closingMs: 20, hasRefs: true), false, reason: '1st tiny split still splits');
      expect(p.aadFloodStep(closingMs: 20, hasRefs: true), false, reason: '2nd tiny split still splits');
      expect(p.aadFloodStep(closingMs: 20, hasRefs: true), true,
          reason: '3rd consecutive tiny split latches flood mode');
      expect(p.aadFloodActive, true);
    });

    test('a non-tiny split resets the run (lone short notes never merge)', () async {
      final p = await VadAudioProcessor.create(outputDir: tempDir.path);
      expect(p.aadFloodStep(closingMs: 20, hasRefs: true), false);
      expect(p.aadFloodStep(closingMs: 20, hasRefs: true), false);
      expect(p.aadFloodStep(closingMs: 5000, hasRefs: true), false,
          reason: 'a real-length recording clears the counter');
      expect(p.aadFloodActive, false);
      expect(p.aadFloodStep(closingMs: 20, hasRefs: true), false, reason: 'back at count 1 — no coalesce');
    });

    test('latch persists once set, then clears at a real boundary', () async {
      final p = await VadAudioProcessor.create(outputDir: tempDir.path);
      for (var i = 0; i < 3; i++) {
        p.aadFloodStep(closingMs: 20, hasRefs: true);
      }
      expect(p.aadFloodActive, true);
      // Once latched, even a now-grown coalesced recording stays coalesced
      // (we don't re-split mid-flood).
      expect(p.aadFloodStep(closingMs: 9000, hasRefs: true), true, reason: 'latched: keeps coalescing');
      // A genuine conversation boundary (flushRemaining → _resetState) ends it.
      p.resetStateForTest();
      expect(p.aadFloodActive, false);
      expect(p.aadFloodStep(closingMs: 9000, hasRefs: true), false, reason: 'post-boundary non-tiny splits normally');
    });

    test('a marker with no buffered audio does not accrue toward the flood run', () async {
      final p = await VadAudioProcessor.create(outputDir: tempDir.path);
      expect(p.aadFloodStep(closingMs: 0, hasRefs: false), false);
      expect(p.aadFloodStep(closingMs: 0, hasRefs: false), false);
      expect(p.aadFloodStep(closingMs: 0, hasRefs: false), false);
      expect(p.aadFloodActive, false, reason: 'no buffered audio ⇒ no junk recording closed here');
    });
  });

  group('short recording threshold (always kept; filter only hides)', () {
    // Each dummy frame = 20 ms. 10 frames = 200 ms, 300 frames = 6000 ms.
    // discardShortRecordings was removed: the duration guard never permanently
    // drops audio anymore — short recordings are saved and merely filtered from
    // the list. These tests assert the guard stays quiet across thresholds.

    test('does not fire guard when duration is below threshold (now always kept)', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 5000),
        outputDir: tempDir.path,
      );
      await processor.processSegmentFile(_makeBinFile(tempDir, 10, name: 'a.bin'), DateTime.now());
      await processor.flushRemaining();
      expect(processor.discardGuardFiredOnLastFlush, isFalse);
      await processor.destroy();
    });

    test('does not fire guard when duration is below threshold (second file)', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 5000),
        outputDir: tempDir.path,
      );
      await processor.processSegmentFile(_makeBinFile(tempDir, 10, name: 'b.bin'), DateTime.now());
      await processor.flushRemaining();
      expect(processor.discardGuardFiredOnLastFlush, isFalse);
      await processor.destroy();
    });

    test('does not fire guard when duration meets threshold', () async {
      // 300 frames = 6000 ms >= 5000 ms threshold
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 5000),
        outputDir: tempDir.path,
      );
      await processor.processSegmentFile(_makeBinFile(tempDir, 300, name: 'c.bin'), DateTime.now());
      await processor.flushRemaining();
      expect(processor.discardGuardFiredOnLastFlush, isFalse);
      await processor.destroy();
    });

    test('does not fire guard when threshold is 0 (Off)', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0),
        outputDir: tempDir.path,
      );
      await processor.processSegmentFile(_makeBinFile(tempDir, 10, name: 'd.bin'), DateTime.now());
      await processor.flushRemaining();
      expect(processor.discardGuardFiredOnLastFlush, isFalse);
      await processor.destroy();
    });

    test('gaps under 10 seconds are stitched without padding', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0),
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
      await processor.destroy();
    });

    test('consecutive in-stream silence splits advance the timeline (no overlapping discards)', () async {
      // Regression: after _splitOnSilence reset _recordingStartTime to null mid-file,
      // the next frame used to re-anchor to segmentStartTime (the file start) instead of
      // the current frame's wall clock — so every chunk in a long ambient-noise stream got
      // the SAME start timestamp and the discards stacked on top of each other in the UI.
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0),
        outputDir: tempDir.path,
        session: _fakeSession(),
      );

      // Host tests run with a null Opus decoder → every frame is treated as silence, so the
      // app-side silence split fires purely on frame count. 6000 frames = 120 000 ms =
      // silenceDurationToSplitMs, so 12 100 frames produces exactly two silence_only splits.
      final startTime = DateTime(2024, 1, 1, 10, 0, 0);
      await processor.processSegmentFile(
        _makeBinFile(tempDir, 12100, name: 'ambient.bin'),
        startTime,
      );

      final discards = processor.consumePendingDiscards();
      expect(discards.length, 2, reason: 'two 120 s silence runs in one file → two discards');

      final firstStart = discards[0]['startMs'] as int;
      final firstEnd = discards[0]['endMs'] as int;
      final secondStart = discards[1]['startMs'] as int;
      expect(firstStart, startTime.millisecondsSinceEpoch);
      // The second chunk must start AFTER the first ends, not back-dated to the file start.
      expect(secondStart, greaterThan(firstStart), reason: 'second chunk must not reuse the file-start timestamp');
      expect(secondStart, greaterThanOrEqualTo(firstEnd), reason: 'chunks must not overlap');
      await processor.destroy();
    });

    test('real consecutive processor discards coalesce to one entry via getDiscardsForDate', () async {
      // End-to-end guard on the load-bearing assumption behind discard coalescing:
      // real processor output for a continuous-noise stream must abut within the
      // merge tolerance. The synthetic recordings_manager test checks the merge
      // logic; this checks that genuine discards actually feed into it as one row.
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0),
        outputDir: tempDir.path,
        session: _fakeSession(),
      );

      final startTime = DateTime(2024, 1, 1, 10, 0, 0);
      await processor.processSegmentFile(
        _makeBinFile(tempDir, 12100, name: 'ambient_e2e.bin'),
        startTime,
      );
      final discards = processor.consumePendingDiscards();
      expect(discards.length, 2, reason: 'two 120 s silence runs → two raw discards');

      // Persist them exactly as RecordingsManager._persistDiscardRecord would
      // (one JSON object per line) under the date folder derived from startMs.
      final d0 = DateTime.fromMillisecondsSinceEpoch(discards[0]['startMs'] as int);
      final dateStr = '${d0.year}-${d0.month.toString().padLeft(2, '0')}-${d0.day.toString().padLeft(2, '0')}';
      final jsonlDir = Directory('${tempDir.path}/recordings/$dateStr')..createSync(recursive: true);
      File('${jsonlDir.path}/discards.jsonl').writeAsStringSync('${discards.map(jsonEncode).join('\n')}\n');

      final merged = await RecordingsManager.getDiscardsForDate(dateStr);
      expect(merged.length, 1, reason: 'two abutting processor discards must collapse to a single UI entry');
      expect(merged.first.startTime.millisecondsSinceEpoch, discards[0]['startMs']);
      expect(merged.first.endTime.millisecondsSinceEpoch, discards[1]['endMs']);
      await processor.destroy();
    });

    test('gaps over 10 seconds but under threshold are padded', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0),
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
      await processor.destroy();
    });

    test('clock sync jumps (uptime gap < 5s) are NOT padded even if > 10s', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0),
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
      await processor.destroy();
    });

    test('IMU Bridge: stitches audio across reboots using IMU tick delta', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0),
        outputDir: tempDir.path,
      );

      const utcEpochMs = 1000000000000;
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
      const gapMs = 15000;
      const nextUtcEpochMs = utcEpochMs + 100 + gapMs;
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
      await processor.destroy();
    });

    test('AAD Padding: pads offline gaps with digital silence using VAD resume marker', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0),
        outputDir: tempDir.path,
      );

      const startTimeMs = 1000000000000;
      final startTime = DateTime.fromMillisecondsSinceEpoch(startTimeMs, isUtc: true);
      const startUptime = 10000;

      const framesBefore = 50; // 1000 ms
      const framesAfter = 50; // 1000 ms
      const sleepGapMs = 5000; // 5 seconds of VAD sleep

      const vadResumeUtcSeconds = (startTimeMs + (framesBefore * 20) + sleepGapMs) ~/ 1000;
      const vadResumeUptimeMs = startUptime + (framesBefore * 20) + sleepGapMs;

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
      await processor.destroy();
    });

    group('High-Precision Timestamp Pipeline', () {
      test('RTC Sync Jitter: handles small negative gaps gracefully', () async {
        final processor = VadAudioProcessor.fromSettings(
          settings: _settings(minDurationMs: 0),
          outputDir: tempDir.path,
        );

        const startSeconds = 1713892490;
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
        const resumeSeconds = startSeconds; // Same second
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
            binWithJitter, DateTime.fromMillisecondsSinceEpoch(startSeconds * 1000, isUtc: true));

        // Duration: 200ms (file1) + 0ms (jitter) + 100ms (jitter.bin) = 300ms
        expect(processor.currentChunkDurationMs, 300);
        await processor.destroy();
      });

      test('IMU Tick Rollover: handles 24-bit rollover correctly', () async {
        final processor = VadAudioProcessor.fromSettings(
          settings: _settings(minDurationMs: 0),
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
        await processor.destroy();
      });
    });
  });

  group('Marker pipeline (0xFFFFFFFE button-tap)', () {
    // Reference epoch: 2026-05-01 00:00:00 UTC (well past year-2000 guard)
    const int kBase = 1746057600000;

    ProcessingSettings markerSettings() => const ProcessingSettings(
          vadEnabled: false,
          speechThreshold: 0.5,
          silenceDurationToSplitMs: 120000,
          minDurationMs: 0,
          minSpeechMs: 0,
          maxChunkMs: 0x7FFFFFFFFFFFFFFF,
          deviceId: '',
          audioSaveFormat: 'wav',
          omiEnabled: false,
        );

    /// Bin: 0xFFFFFFFB header + [before] frames + 0xFFFFFFFE marker + [after] frames.
    File makeTappedBin(
      String name, {
      required int utcStartMs,
      int before = 0,
      int after = 0,
      int markerUtcMs = 0,
    }) {
      final builder = BytesBuilder();
      // header
      final hdr = ByteData(36);
      hdr.setUint32(0, 0xFFFFFFFB, Endian.little);
      hdr.setUint32(4, 28, Endian.little);
      hdr.setUint64(8, utcStartMs, Endian.little);
      hdr.setUint64(16, 0, Endian.little);
      hdr.setUint32(24, 0, Endian.little);
      hdr.setUint32(28, 1, Endian.little);
      builder.add(hdr.buffer.asUint8List());
      // audio frames
      final fhdr = ByteData(4)..setUint32(0, 4, Endian.little);
      for (int i = 0; i < before; i++) {
        builder.add(fhdr.buffer.asUint8List());
        builder.add(List.filled(4, 0));
      }
      // marker packet
      final m = ByteData(20);
      m.setUint32(0, 0xFFFFFFFE, Endian.little);
      m.setUint64(4, markerUtcMs, Endian.little);
      m.setUint32(12, 0, Endian.little);
      m.setUint32(16, 1, Endian.little);
      builder.add(m.buffer.asUint8List());
      // more frames
      for (int i = 0; i < after; i++) {
        builder.add(fhdr.buffer.asUint8List());
        builder.add(List.filled(4, 0));
      }
      final f = File('${tempDir.path}/$name');
      f.writeAsBytesSync(builder.toBytes());
      return f;
    }

    test('mid-recording tap: offsetMs equals frames-before × 20ms', () async {
      // 10 frames (200 ms) before tap, 10 frames after → offsetMs = 200.
      // markerUtcMs = kBase+200 is within 60 s of audio wall time → RTC used for markerMs.
      final file = makeTappedBin('mid.bin', utcStartMs: kBase, before: 10, after: 10, markerUtcMs: kBase + 200);
      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      await proc.flushRemaining(isDraft: true);
      final edls = proc.consumePendingEdlData();
      await proc.destroy();

      expect(edls.length, 1);
      expect(edls[0]['offsetMs'], 200);
      expect(edls[0]['markerMs'], kBase + 200);
      expect((edls[0]['filename'] as String).isNotEmpty, isTrue);
    });

    test('tap at start (no prior frames): offsetMs = 0', () async {
      final file = makeTappedBin('start.bin', utcStartMs: kBase, before: 0, after: 20, markerUtcMs: kBase);
      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      await proc.flushRemaining(isDraft: true);
      final edls = proc.consumePendingEdlData();
      await proc.destroy();

      expect(edls.length, 1);
      expect(edls[0]['offsetMs'], 0);
      expect(edls[0]['markerMs'], kBase);
    });

    test('bad marker UTC (epoch 0) falls back to audio wall time', () async {
      // 5 frames before tap: lastFrameWallTime = kBase + 4*20 = kBase+80.
      // _currentChunkDurationMs = 5*20 = 100.
      final file = makeTappedBin('badutc.bin', utcStartMs: kBase, before: 5, after: 10, markerUtcMs: 0);
      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      await proc.flushRemaining(isDraft: true);
      final edls = proc.consumePendingEdlData();
      await proc.destroy();

      // markerUtcMs = 0 → falls back to lastFrameWallTime = kBase + 4*20.
      expect(edls.length, 1);
      expect(edls[0]['markerMs'], kBase + 80);
      expect(edls[0]['offsetMs'], 100);
    });

    test('marker UTC drifting >60s from audio wall time: keeps audio time (B8)', () async {
      // _isDerivedTimestamp=false (header has valid UTC). 10 frames before tap.
      // lastFrameWallTime = kBase + 9*20 = kBase+180.
      // markerUtcMs = kBase+180+90000 → drift 90s > 60s → audio time kept.
      final file =
          makeTappedBin('drift.bin', utcStartMs: kBase, before: 10, after: 10, markerUtcMs: kBase + 180 + 90000);
      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      await proc.flushRemaining(isDraft: true);
      final edls = proc.consumePendingEdlData();
      await proc.destroy();

      expect(edls.length, 1);
      // Audio wall time used — NOT the drifted RTC.
      expect(edls[0]['markerMs'], kBase + 180);
      expect(edls[0]['markerMs'], isNot(kBase + 180 + 90000));
    });

    test('tap with zero surrounding audio emits orphan EDL (empty filename)', () async {
      // No frames before or after → _currentRefs stays empty → orphan path.
      final file = makeTappedBin('orphan.bin', utcStartMs: kBase, before: 0, after: 0, markerUtcMs: kBase + 1000);
      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      await proc.flushRemaining(isDraft: true);
      final edls = proc.consumePendingEdlData();
      await proc.destroy();

      expect(edls.length, 1);
      expect(edls[0]['filename'], '');
      expect(edls[0]['markerMs'], kBase + 1000);
      expect(edls[0]['offsetMs'], 0);
    });

    test('session-end marker (0xFFFFFFFC) finalizes and sets sessionEndPendingResume', () async {
      // Build bin: header + 10 frames + 0xFFFFFFFC session-end + 5 trailing frames.
      // The session-end should finalize the recording; the 5 trailing frames should be dropped.
      final builder = BytesBuilder();
      final hdr = ByteData(36);
      hdr.setUint32(0, 0xFFFFFFFB, Endian.little);
      hdr.setUint32(4, 28, Endian.little);
      hdr.setUint64(8, kBase, Endian.little);
      hdr.setUint64(16, 0, Endian.little);
      hdr.setUint32(24, 0, Endian.little);
      hdr.setUint32(28, 1, Endian.little);
      builder.add(hdr.buffer.asUint8List());
      final fhdr = ByteData(4)..setUint32(0, 4, Endian.little);
      // Pre-session-end: 10 frames + button tap (so _forcedByMarker=true)
      final tapMarker = ByteData(20);
      tapMarker.setUint32(0, 0xFFFFFFFE, Endian.little);
      tapMarker.setUint64(4, kBase + 100, Endian.little);
      tapMarker.setUint32(12, 0, Endian.little);
      tapMarker.setUint32(16, 1, Endian.little);
      for (int i = 0; i < 10; i++) {
        builder.add(fhdr.buffer.asUint8List());
        builder.add(List.filled(4, 0));
      }
      builder.add(tapMarker.buffer.asUint8List());
      // Session-end packet
      final endMarker = ByteData(20);
      endMarker.setUint32(0, 0xFFFFFFFC, Endian.little);
      builder.add(endMarker.buffer.asUint8List());
      // Trailing junk frames (should be skipped by sessionEndPendingResume)
      for (int i = 0; i < 5; i++) {
        builder.add(fhdr.buffer.asUint8List());
        builder.add(List.filled(4, 0));
      }
      final file = File('${tempDir.path}/sessionend.bin')..writeAsBytesSync(builder.toBytes());

      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      final saved = await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      // flushRemaining should have nothing left (session-end already saved the recording)
      final flushed = await proc.flushRemaining();
      await proc.destroy();

      // The 10-frame recording should be saved by the session-end marker path.
      expect(saved.length, 1, reason: 'session-end should produce one finalized recording');
      expect(flushed, isNull, reason: 'nothing remaining after session-end flush');
    });

    test('priority-recording marker (0xFFFFFFF8) finalizes prior, opens red recording, stops at 0xFFFFFFFC', () async {
      // Bin: header + 10 frames + 0xFFFFFFF8 priority-start + 10 frames + 0xFFFFFFFC stop.
      // F8 finalizes the prior auto recording and opens a high-priority one; FC stops it.
      final builder = BytesBuilder();
      final hdr = ByteData(36);
      hdr.setUint32(0, 0xFFFFFFFB, Endian.little);
      hdr.setUint32(4, 28, Endian.little);
      hdr.setUint64(8, kBase, Endian.little);
      hdr.setUint64(16, 0, Endian.little);
      hdr.setUint32(24, 0, Endian.little);
      hdr.setUint32(28, 1, Endian.little);
      builder.add(hdr.buffer.asUint8List());
      final fhdr = ByteData(4)..setUint32(0, 4, Endian.little);
      // 10 frames of prior auto recording.
      for (int i = 0; i < 10; i++) {
        builder.add(fhdr.buffer.asUint8List());
        builder.add(List.filled(4, 0));
      }
      // Priority-start marker at kBase + 200 (same payload layout as button-tap).
      final start = ByteData(20);
      start.setUint32(0, 0xFFFFFFF8, Endian.little);
      start.setUint64(4, kBase + 200, Endian.little);
      start.setUint32(12, 0, Endian.little);
      start.setUint32(16, 1, Endian.little);
      builder.add(start.buffer.asUint8List());
      // 10 frames captured inside the priority recording.
      for (int i = 0; i < 10; i++) {
        builder.add(fhdr.buffer.asUint8List());
        builder.add(List.filled(4, 0));
      }
      // Session-end stop.
      final end = ByteData(20)..setUint32(0, 0xFFFFFFFC, Endian.little);
      builder.add(end.buffer.asUint8List());
      final file = File('${tempDir.path}/priority.bin')..writeAsBytesSync(builder.toBytes());

      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      final saved = await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      final flushed = await proc.flushRemaining();
      final edls = proc.consumePendingEdlData();
      await proc.destroy();

      // Two finalized recordings: the prior auto recording (closed by F8) and the
      // priority recording (closed by FC).
      expect(saved.length, 2, reason: 'F8 closes the prior recording, FC closes the priority one');
      expect(flushed, isNull, reason: 'nothing remaining after the FC stop');
      // Exactly one EDL — the priority marker — flagged high-priority at offset 0.
      expect(edls.length, 1);
      expect(edls[0]['isHighPriority'], isTrue);
      expect(edls[0]['markerMs'], kBase + 200);
      expect(edls[0]['offsetMs'], 0);
      expect((edls[0]['filename'] as String).isNotEmpty, isTrue,
          reason: 'priority marker anchors to the new recording, not an orphan');
    });

    // Builds [header + 0xFFFFFFF8 priority-start + `frames` frames + optional FC].
    File priorityBin(String name, {required int frames, bool stop = false}) {
      final builder = BytesBuilder();
      final hdr = ByteData(36);
      hdr.setUint32(0, 0xFFFFFFFB, Endian.little);
      hdr.setUint32(4, 28, Endian.little);
      hdr.setUint64(8, kBase, Endian.little);
      hdr.setUint64(16, 0, Endian.little);
      hdr.setUint32(24, 0, Endian.little);
      hdr.setUint32(28, 1, Endian.little);
      builder.add(hdr.buffer.asUint8List());
      final start = ByteData(20);
      start.setUint32(0, 0xFFFFFFF8, Endian.little);
      start.setUint64(4, kBase + 200, Endian.little);
      start.setUint32(12, 0, Endian.little);
      start.setUint32(16, 1, Endian.little);
      builder.add(start.buffer.asUint8List());
      final fhdr = ByteData(4)..setUint32(0, 4, Endian.little);
      for (int i = 0; i < frames; i++) {
        builder.add(fhdr.buffer.asUint8List());
        builder.add(List.filled(4, 0));
      }
      if (stop) {
        builder.add((ByteData(20)..setUint32(0, 0xFFFFFFFC, Endian.little)).buffer.asUint8List());
      }
      return File('${tempDir.path}/$name')..writeAsBytesSync(builder.toBytes());
    }

    test('serialize/restore preserves _inPriorityRecording and the high-priority marker', () async {
      // Leave the processor mid-Priority-Recording (start + frames, no stop).
      final file = priorityBin('priority_serde.bin', frames: 10);
      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      final state = await proc.serializeState();
      await proc.destroy();

      expect(state, isNotNull);
      expect(state!['ipr'], isTrue, reason: '_inPriorityRecording must survive serialization');
      final pm = (state['pm'] as List).cast<Map<String, dynamic>>();
      expect(pm.any((m) => m['hp'] == true), isTrue, reason: 'queued high-priority marker must survive');

      // Round-trip into a fresh processor and re-serialize — state must persist.
      final proc2 = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      await proc2.restoreState(state);
      final state2 = await proc2.serializeState();
      await proc2.destroy();
      expect(state2, isNotNull);
      expect(state2!['ipr'], isTrue);
      expect((state2['pm'] as List).cast<Map<String, dynamic>>().any((m) => m['hp'] == true), isTrue);
    });

    test('priority-start with no audio emits a high-priority orphan marker', () async {
      final file = priorityBin('priority_orphan.bin', frames: 0);
      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      final saved = await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      await proc.flushRemaining(isDraft: true);
      final edls = proc.consumePendingEdlData();
      await proc.destroy();

      expect(saved.length, 0, reason: 'no audio to finalize');
      expect(edls.length, 1);
      expect(edls[0]['isHighPriority'], isTrue);
      expect(edls[0]['filename'], '', reason: 'no surrounding audio → orphan');
      expect(edls[0]['markerMs'], kBase + 200);
    });

    test('priority Start immediately followed by Stop yields a high-priority orphan, no recording', () async {
      final file = priorityBin('priority_empty.bin', frames: 0, stop: true);
      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      final saved = await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      final flushed = await proc.flushRemaining();
      final edls = proc.consumePendingEdlData();
      await proc.destroy();

      expect(saved.length, 0);
      expect(flushed, isNull);
      expect(edls.length, 1);
      expect(edls[0]['isHighPriority'], isTrue);
      expect(edls[0]['filename'], '');
    });

    test('Priority Recording does not split across a session change between bins', () async {
      // Bin A: priority start + 10 force-captured frames, session 1, NO stop.
      final binA = priorityBin('priority_splitA.bin', frames: 10);
      // Bin B: a fresh session (id 2), 10 min later, + 10 frames + the 0xFFFFFFFC
      // stop. A session change / large gap normally forces an inter-file split;
      // inside a Priority Recording it must be suppressed so RECORD_START/STOP
      // stay the only boundaries.
      final bBuilder = BytesBuilder();
      final bHdr = ByteData(36);
      bHdr.setUint32(0, 0xFFFFFFFB, Endian.little);
      bHdr.setUint32(4, 28, Endian.little);
      bHdr.setUint64(8, kBase + 600000, Endian.little); // 10 min after bin A
      bHdr.setUint64(16, 0, Endian.little);
      bHdr.setUint32(24, 0, Endian.little);
      bHdr.setUint32(28, 2, Endian.little); // different session id
      bBuilder.add(bHdr.buffer.asUint8List());
      final fhdr = ByteData(4)..setUint32(0, 4, Endian.little);
      for (int i = 0; i < 10; i++) {
        bBuilder.add(fhdr.buffer.asUint8List());
        bBuilder.add(List.filled(4, 0));
      }
      bBuilder.add((ByteData(20)..setUint32(0, 0xFFFFFFFC, Endian.little)).buffer.asUint8List());
      final binB = File('${tempDir.path}/priority_splitB.bin')..writeAsBytesSync(bBuilder.toBytes());

      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      final savedA = await proc.processSegmentFile(binA, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      final savedB =
          await proc.processSegmentFile(binB, DateTime.fromMillisecondsSinceEpoch(kBase + 600000, isUtc: true));
      final flushed = await proc.flushRemaining();
      await proc.destroy();

      expect(savedA.length, 0, reason: 'no boundary inside bin A (no stop yet)');
      // Without the _inPriorityRecording guard the session change would split the
      // span into two recordings; the guard keeps it as one.
      expect(savedB.length, 1, reason: 'FC stop finalizes the single spanning priority recording');
      expect(flushed, isNull);
    });

    test('open priority marker bin with no buffered audio is retained for the next run', () async {
      // Marker landed at the tail of a sync with no trailing frames (frames: 0).
      final file = priorityBin('priority_retain.bin', frames: 0);
      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      // End-of-run draft flush produces nothing (no audio) ...
      await proc.flushRemaining(isDraft: true);
      // ... but the marker bin must NOT be released: the next run re-sees the
      // 0xFFFFFFF8 marker and re-enters force-capture. Releasing it would drop the
      // priority recording's red marker and force-capture on the next pass.
      final safe = proc.consumeSafeToDeletePaths();
      await proc.destroy();
      expect(safe.contains(file.path), isFalse, reason: 'open priority marker bin must stay on disk');
    });

    test('priority marker bin is released once the recording captures audio and stops', () async {
      // Contrast with the retention case: a finalized priority recording no longer
      // needs its source bin pinned.
      final file = priorityBin('priority_released.bin', frames: 10, stop: true);
      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      await proc.flushRemaining();
      final safe = proc.consumeSafeToDeletePaths();
      await proc.destroy();
      expect(safe.contains(file.path), isTrue, reason: 'a stopped priority recording releases its source bin');
    });

    group('Marker Protection Window', () {
      test('VAD resume within 50s of marker tap is ignored for split', () async {
        final builder = BytesBuilder();
        final hdr = ByteData(36);
        hdr.setUint32(0, 0xFFFFFFFB, Endian.little);
        hdr.setUint32(4, 28, Endian.little);
        hdr.setUint64(8, kBase, Endian.little);
        hdr.setUint64(16, 0, Endian.little);
        hdr.setUint32(24, 0, Endian.little);
        hdr.setUint32(28, 1, Endian.little);
        builder.add(hdr.buffer.asUint8List());

        final fhdr = ByteData(4)..setUint32(0, 4, Endian.little);
        for (int i = 0; i < 10; i++) {
          builder.add(fhdr.buffer.asUint8List());
          builder.add(List.filled(4, 0));
        }

        // Marker tap at kBase + 100000
        final tapMarker = ByteData(20);
        tapMarker.setUint32(0, 0xFFFFFFFE, Endian.little);
        tapMarker.setUint64(4, kBase + 100000, Endian.little);
        tapMarker.setUint32(12, 0, Endian.little);
        tapMarker.setUint32(16, 1, Endian.little);
        builder.add(tapMarker.buffer.asUint8List());

        // VAD Resume at kBase + 130000
        // Gap from last frame (kBase + 200) is 129.8s (exceeds 120s silence threshold)
        // But it is within 50s of the marker UTC (100000 + 50000 = 150000 >= 130000)
        final resumeMarker = ByteData(20);
        resumeMarker.setUint32(0, 0xFFFFFFFD, Endian.little);
        resumeMarker.setUint32(4, (kBase ~/ 1000) + 130, Endian.little); // vadUtcSeconds
        resumeMarker.setUint32(8, 130000, Endian.little); // vadUptimeMs
        builder.add(resumeMarker.buffer.asUint8List());

        for (int i = 0; i < 10; i++) {
          builder.add(fhdr.buffer.asUint8List());
          builder.add(List.filled(4, 0));
        }

        final file = File('${tempDir.path}/protection.bin')..writeAsBytesSync(builder.toBytes());
        final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
        await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
        await proc.flushRemaining(isDraft: true);
        final edls = proc.consumePendingEdlData();
        await proc.destroy();

        // Should only be one EDL because the split was blocked by protection
        expect(edls.length, 1, reason: 'Split should be blocked by marker protection window');
      });

      test('VAD resume > 50s after marker tap triggers split', () async {
        final builder = BytesBuilder();
        final hdr = ByteData(36);
        hdr.setUint32(0, 0xFFFFFFFB, Endian.little);
        hdr.setUint32(4, 28, Endian.little);
        hdr.setUint64(8, kBase, Endian.little);
        hdr.setUint64(16, 0, Endian.little);
        hdr.setUint32(24, 0, Endian.little);
        hdr.setUint32(28, 1, Endian.little);
        builder.add(hdr.buffer.asUint8List());

        final fhdr = ByteData(4)..setUint32(0, 4, Endian.little);
        for (int i = 0; i < 10; i++) {
          builder.add(fhdr.buffer.asUint8List());
          builder.add(List.filled(4, 0));
        }

        // Marker tap at kBase + 100000
        final tapMarker = ByteData(20);
        tapMarker.setUint32(0, 0xFFFFFFFE, Endian.little);
        tapMarker.setUint64(4, kBase + 100000, Endian.little);
        tapMarker.setUint32(12, 0, Endian.little);
        tapMarker.setUint32(16, 1, Endian.little);
        builder.add(tapMarker.buffer.asUint8List());

        // VAD Resume at kBase + 160000
        // > 50s from marker UTC (160000 > 150000)
        final resumeMarker = ByteData(20);
        resumeMarker.setUint32(0, 0xFFFFFFFD, Endian.little);
        resumeMarker.setUint32(4, (kBase ~/ 1000) + 160, Endian.little);
        resumeMarker.setUint32(8, 160000, Endian.little);
        builder.add(resumeMarker.buffer.asUint8List());

        for (int i = 0; i < 10; i++) {
          builder.add(fhdr.buffer.asUint8List());
          builder.add(List.filled(4, 0));
        }

        final file = File('${tempDir.path}/protection_split.bin')..writeAsBytesSync(builder.toBytes());
        final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
        final saved = await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
        await proc.flushRemaining(isDraft: true);
        final edls = proc.consumePendingEdlData();
        await proc.destroy();

        // Split should occur because we are outside the 50s protection window
        // One saved file from the split, and one remaining EDL for the new session
        expect(saved.length, 1, reason: 'First segment should be saved upon split');
        expect(edls.length, 1, reason: 'Second segment should still be pending');
      });

      test('wall-clock fallback when marker hardware RTC is 0', () async {
        final builder = BytesBuilder();
        final hdr = ByteData(36);
        hdr.setUint32(0, 0xFFFFFFFB, Endian.little);
        hdr.setUint32(4, 28, Endian.little);
        hdr.setUint64(8, kBase, Endian.little);
        hdr.setUint64(16, 0, Endian.little);
        hdr.setUint32(24, 0, Endian.little);
        hdr.setUint32(28, 1, Endian.little);
        builder.add(hdr.buffer.asUint8List());

        final fhdr = ByteData(4)..setUint32(0, 4, Endian.little);
        // 5000 frames = 100 seconds
        for (int i = 0; i < 5000; i++) {
          builder.add(fhdr.buffer.asUint8List());
          builder.add(List.filled(4, 0));
        }

        // Audio wall time is now kBase + 100000.
        // Marker with 0 RTC.
        final tapMarker = ByteData(20);
        tapMarker.setUint32(0, 0xFFFFFFFE, Endian.little);
        tapMarker.setUint64(4, 0, Endian.little);
        tapMarker.setUint32(12, 0, Endian.little);
        tapMarker.setUint32(16, 1, Endian.little);
        builder.add(tapMarker.buffer.asUint8List());

        // VAD Resume at +30s from wall-clock (130s total)
        final resumeMarker = ByteData(20);
        resumeMarker.setUint32(0, 0xFFFFFFFD, Endian.little);
        resumeMarker.setUint32(4, (kBase ~/ 1000) + 130, Endian.little);
        resumeMarker.setUint32(8, 130000, Endian.little);
        builder.add(resumeMarker.buffer.asUint8List());

        for (int i = 0; i < 10; i++) {
          builder.add(fhdr.buffer.asUint8List());
          builder.add(List.filled(4, 0));
        }

        final file = File('${tempDir.path}/protection_fallback.bin')..writeAsBytesSync(builder.toBytes());
        final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
        await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
        await proc.flushRemaining(isDraft: true);
        final edls = proc.consumePendingEdlData();
        await proc.destroy();

        // Because marker UTC was 0, it should fallback to audio wall time (kBase + 100000).
        // The VAD resume at kBase + 130000 is within 50000ms of that, so it should not split.
        expect(edls.length, 1, reason: 'Split should be blocked by wall-clock fallback protection');
      });
    });
  });

  group('Mute markers (0xFFFFFFFA mute-on / 0xFFFFFFF9 mute-off)', () {
    const int kBase = 1746057600000; // 2026-05-01 UTC, past the year-2000 guard

    ProcessingSettings muteSettings() => const ProcessingSettings(
          vadEnabled: false,
          speechThreshold: 0.5,
          silenceDurationToSplitMs: 120000,
          minDurationMs: 0,
          minSpeechMs: 0,
          maxChunkMs: 0x7FFFFFFFFFFFFFFF,
          deviceId: '',
          audioSaveFormat: 'wav',
          omiEnabled: false,
        );

    void addHeader(BytesBuilder b, {required int utcStartMs, int sessionId = 1}) {
      final hdr = ByteData(36);
      hdr.setUint32(0, 0xFFFFFFFB, Endian.little);
      hdr.setUint32(4, 28, Endian.little);
      hdr.setUint64(8, utcStartMs, Endian.little);
      hdr.setUint64(16, 0, Endian.little);
      hdr.setUint32(24, 0, Endian.little);
      hdr.setUint32(28, sessionId, Endian.little);
      b.add(hdr.buffer.asUint8List());
    }

    void addFrames(BytesBuilder b, int n) {
      final fhdr = ByteData(4)..setUint32(0, 4, Endian.little);
      for (int i = 0; i < n; i++) {
        b.add(fhdr.buffer.asUint8List());
        b.add(List.filled(4, 0));
      }
    }

    void addMarker(BytesBuilder b, int tag, int utcMs) {
      final m = ByteData(20);
      m.setUint32(0, tag, Endian.little);
      m.setUint64(4, utcMs, Endian.little);
      m.setUint32(12, 0, Endian.little);
      m.setUint32(16, 1, Endian.little);
      b.add(m.buffer.asUint8List());
    }

    File writeBin(String name, BytesBuilder b) {
      final f = File('${tempDir.path}/$name');
      f.writeAsBytesSync(b.toBytes());
      return f;
    }

    test('mute-on then mute-off emits one muted discard spanning the interval', () async {
      final b = BytesBuilder();
      addHeader(b, utcStartMs: kBase);
      addMarker(b, 0xFFFFFFFA, kBase + 1000); // mute-on
      addMarker(b, 0xFFFFFFF9, kBase + 5000); // mute-off
      final file = writeBin('mute_pair.bin', b);

      final proc = VadAudioProcessor.fromSettings(settings: muteSettings(), outputDir: tempDir.path);
      await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      final discards = proc.consumePendingDiscards();
      await proc.destroy();

      expect(discards.length, 1);
      expect(discards[0]['reason'], 'muted');
      expect(discards[0]['startMs'], kBase + 1000);
      expect(discards[0]['endMs'], kBase + 5000);
      expect((discards[0]['relativeBins'] as List).isEmpty, isTrue, reason: 'muted intervals have no recoverable bins');
    });

    test('mute-off with no open interval emits nothing', () async {
      final b = BytesBuilder();
      addHeader(b, utcStartMs: kBase);
      addMarker(b, 0xFFFFFFF9, kBase + 2000); // mute-off only
      final file = writeBin('mute_off_only.bin', b);

      final proc = VadAudioProcessor.fromSettings(settings: muteSettings(), outputDir: tempDir.path);
      await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      final discards = proc.consumePendingDiscards();
      await proc.destroy();

      expect(discards.where((d) => d['reason'] == 'muted'), isEmpty);
    });

    test('mute-on finalizes the in-progress recording (like session-end)', () async {
      // 10 captured frames (forced by a button tap) then mute-on → recording saved.
      final b = BytesBuilder();
      addHeader(b, utcStartMs: kBase);
      addFrames(b, 10);
      addMarker(b, 0xFFFFFFFE, kBase + 100); // button tap forces capture
      addMarker(b, 0xFFFFFFFA, kBase + 5000); // mute-on finalizes
      final file = writeBin('mute_finalize.bin', b);

      final proc = VadAudioProcessor.fromSettings(settings: muteSettings(), outputDir: tempDir.path);
      final saved = await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      final flushed = await proc.flushRemaining();
      await proc.destroy();

      expect(saved.length, 1, reason: 'mute-on should finalize the in-progress recording');
      expect(flushed, isNull, reason: 'nothing remaining after mute-on finalize');
    });

    test('mute-on with bad UTC (epoch 0) falls back to audio wall time', () async {
      // 5 frames → lastFrameWallTime = kBase + 4*20 = kBase+80; mute-on utc=0 falls back to it.
      final b = BytesBuilder();
      addHeader(b, utcStartMs: kBase);
      addFrames(b, 5);
      addMarker(b, 0xFFFFFFFA, 0); // mute-on, pre-time-sync
      addMarker(b, 0xFFFFFFF9, kBase + 9000); // mute-off (valid)
      final file = writeBin('mute_badutc.bin', b);

      final proc = VadAudioProcessor.fromSettings(settings: muteSettings(), outputDir: tempDir.path);
      await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      final discards = proc.consumePendingDiscards();
      await proc.destroy();

      final muted = discards.where((d) => d['reason'] == 'muted').toList();
      expect(muted.length, 1);
      expect(muted[0]['startMs'], kBase + 80, reason: 'fell back to audio wall time');
    });

    test('session change closes an open muted interval at the new session start', () async {
      // File 1 (session 1): frames + button tap + mute-on, no mute-off (interval left open).
      final b1 = BytesBuilder();
      addHeader(b1, utcStartMs: kBase, sessionId: 1);
      addFrames(b1, 10);
      addMarker(b1, 0xFFFFFFFE, kBase + 100);
      addMarker(b1, 0xFFFFFFFA, kBase + 5000);
      final file1 = writeBin('mute_sess1.bin', b1);

      // File 2 (session 2): device rebooted while muted → mute cleared in firmware.
      final b2 = BytesBuilder();
      addHeader(b2, utcStartMs: kBase + 60000, sessionId: 2);
      addFrames(b2, 5);
      final file2 = writeBin('mute_sess2.bin', b2);

      final proc = VadAudioProcessor.fromSettings(settings: muteSettings(), outputDir: tempDir.path);
      await proc.processSegmentFile(file1, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      await proc.processSegmentFile(file2, DateTime.fromMillisecondsSinceEpoch(kBase + 60000, isUtc: true));
      final discards = proc.consumePendingDiscards();
      await proc.flushRemaining(isDraft: true);
      await proc.destroy();

      final muted = discards.where((d) => d['reason'] == 'muted').toList();
      expect(muted.length, 1, reason: 'session change should close the open muted interval');
      expect(muted[0]['startMs'], kBase + 5000);
      expect(muted[0]['endMs'], kBase + 60000, reason: 'closed at the new session start');
    });

    test('button tap alone leaves the guaranteed-save window set (control)', () async {
      // Establishes the baseline the next two tests contrast against: a tap opens
      // the 50 s window, and an ordinary flush (silence/file split) PRESERVES it
      // via _resetState — which is exactly why a hard boundary must clear it.
      final b = BytesBuilder();
      addHeader(b, utcStartMs: kBase);
      addFrames(b, 10);
      addMarker(b, 0xFFFFFFFE, kBase + 100); // tap → window = kBase+100+50000
      final file = writeBin('tap_keeps_window.bin', b);

      final proc = VadAudioProcessor.fromSettings(settings: muteSettings(), outputDir: tempDir.path);
      await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      await proc.flushRemaining(isDraft: true);
      expect(proc.markerProtectedUntilMs, kBase + 50100,
          reason: 'tap sets the window and an ordinary flush must preserve it');
      await proc.destroy();
    });

    test('mute-on clears the guaranteed-save window (no leak past unmute)', () async {
      // Tap opens the window; a mute-on well inside it finalizes the protected
      // recording and consumes the tap, so the window must not survive the mute —
      // otherwise a quick unmute inside the original 50 s would force-promote
      // marker-less noise.
      final b = BytesBuilder();
      addHeader(b, utcStartMs: kBase);
      addFrames(b, 10);
      addMarker(b, 0xFFFFFFFE, kBase + 100); // tap → window = kBase+50100
      addMarker(b, 0xFFFFFFFA, kBase + 5000); // mute-on, well inside the window
      final file = writeBin('mute_clears_window.bin', b);

      final proc = VadAudioProcessor.fromSettings(settings: muteSettings(), outputDir: tempDir.path);
      final saved = await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      expect(saved.length, 1, reason: 'mute-on still finalizes the protected recording');
      expect(proc.markerProtectedUntilMs, isNull,
          reason: 'mute boundary inside the window must end the guaranteed-save window');
      await proc.destroy();
    });

    test('session-end (manual stop) clears the guaranteed-save window', () async {
      // Same hard-boundary contract as mute-on, for the 0xFFFFFFFC manual-stop path.
      final b = BytesBuilder();
      addHeader(b, utcStartMs: kBase);
      addFrames(b, 10);
      addMarker(b, 0xFFFFFFFE, kBase + 100); // tap → window = kBase+50100
      addMarker(b, 0xFFFFFFFC, kBase + 5000); // manual-stop session-end, inside the window
      final file = writeBin('sessionend_clears_window.bin', b);

      final proc = VadAudioProcessor.fromSettings(settings: muteSettings(), outputDir: tempDir.path);
      final saved = await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      expect(saved.length, 1, reason: 'session-end still finalizes the protected recording');
      expect(proc.markerProtectedUntilMs, isNull, reason: 'manual stop is a hard boundary and must end the window');
      await proc.destroy();
    });
  });
}
