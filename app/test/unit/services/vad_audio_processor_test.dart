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
    priorityRecordCapMinutes: 0,
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

    test('a reboot splits the recording — the IMU counter cannot bridge it', () async {
      // This replaced a test that asserted the opposite, and the swap is the point.
      //
      // The old test fed file 2 a counter that had carried straight on across the reboot
      // (100000 -> 102358, exactly the gap in ticks) and asserted the two files stitched.
      // It passed for years. The firmware never produces that: lsm6dsl_timestamp_reset()
      // sits inside the PERIODIC checkpoint, so the counter restarts near zero and
      // imu_ticks means "since the last checkpoint", not "since boot". The test was
      // pinning an assumption about the device rather than the device.
      //
      // Measured on hardware 2026-08-19: 37748 ticks before a reboot, 0 after, which the
      // old subtraction read as ~29.8 h of wrap-around rather than a gap. So this now
      // pins what actually happens — a session change splits — with the tick values the
      // firmware really writes.
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0),
        outputDir: tempDir.path,
      );

      const utcEpochMs = 1000000000000;
      final startTime = DateTime.fromMillisecondsSinceEpoch(utcEpochMs, isUtc: true);

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

      const gapMs = 15000;
      const nextUtcEpochMs = utcEpochMs + 100 + gapMs;
      final file2Start = DateTime.fromMillisecondsSinceEpoch(nextUtcEpochMs, isUtc: true);

      final file2 = _makeBinFileWithHeader(
        tempDir,
        5,
        name: 'file2_imu.bin',
        utcStartMs: nextUtcEpochMs,
        uptimeStartMs: 5000, // rebooted, uptime restarts
        imuTicks: 0, // rebooted, and the checkpoint reset the counter
        sessionId: 2,
      );
      await processor.processSegmentFile(file2, file2Start);

      // The session change ends the first recording, so only file 2's audio is open —
      // no stitch, and no 15 s of padding.
      expect(processor.currentChunkDurationMs, 100);
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

      // A test named "IMU Tick Rollover: handles 24-bit rollover correctly" lived here.
      // It fed session 2 a counter that had wrapped straight past session 1's value
      // (0xFFFF00 -> 0x000100) and asserted the two stitched into one recording. It has
      // been removed with the IMU Bridge it pinned: the firmware resets that counter in
      // its periodic checkpoint, so it never carries across a reboot at all, wrapped or
      // otherwise, and the test was asserting a device behaviour that does not exist.
      // See the note in VadAudioProcessor where the bridge used to be. The real crossing
      // is covered by 'a reboot splits the recording' above.
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
          priorityRecordCapMinutes: 0,
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

    // Regression: the boundary has to be stamped into the .meta of the recording
    // that STARTS at it. The processor cuts correctly inside a run, but a run ends
    // by flushing whatever is open as a `_draft`, and RecordingsManager's cross-run
    // stitcher — which sees only timestamps and gaps — then rejoined both sides at
    // gap 0. That is how a 2 h Priority Recording surfaced as 2 h 18 m: 15 min of
    // pre-tap audio on the front, 3 min of post-stop audio on the back.
    test('0xFFFFFFF8, and the audio resuming after 0xFFFFFFFC, are stamped hardStart in .meta', () async {
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
      void frames(int n) {
        for (int i = 0; i < n; i++) {
          builder.add(fhdr.buffer.asUint8List());
          builder.add(List.filled(4, 0));
        }
      }

      // Auto recording → priority start → priority span → stop → resume → tail.
      frames(10);
      final start = ByteData(20)
        ..setUint32(0, 0xFFFFFFF8, Endian.little)
        ..setUint64(4, kBase + 200, Endian.little)
        ..setUint32(12, 0, Endian.little)
        ..setUint32(16, 1, Endian.little);
      builder.add(start.buffer.asUint8List());
      frames(10);
      builder.add((ByteData(20)..setUint32(0, 0xFFFFFFFC, Endian.little)).buffer.asUint8List());
      // Resume 5 min later — past the 110 s file-gap threshold, so the tail anchors
      // to the resume time and gets a filename of its own. (0xFFFFFFFD carries UTC
      // *seconds*, not ms, so a sub-second offset here would round the tail back
      // onto the first recording's timestamp and overwrite its .meta.)
      final resume = ByteData(20)
        ..setUint32(0, 0xFFFFFFFD, Endian.little)
        ..setUint32(4, kBase ~/ 1000 + 300, Endian.little)
        ..setUint32(8, 300000, Endian.little);
      builder.add(resume.buffer.asUint8List());
      frames(10);
      final file = File('${tempDir.path}/hardstart.bin')..writeAsBytesSync(builder.toBytes());

      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      final saved = await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      final flushed = await proc.flushRemaining();
      await proc.destroy();

      // Read the wire layout directly rather than through the production parser, so
      // this pins the byte position too: flag byte [3] at flagOffset = 417 + keyLen,
      // bit 0x01 = isSilero, bit 0x02 = hardStart.
      Uint8List metaOf(String audioPath) =>
          File(audioPath.replaceAll(RegExp(r'\.(wav|m4a)$'), '.meta')).readAsBytesSync();
      int flagByte3(String audioPath) {
        final meta = metaOf(audioPath);
        return meta[417 + meta[416] + 3];
      }

      expect(saved.length, 2, reason: 'F8 closes the prior auto recording, FC closes the priority one');
      expect(flagByte3(saved[0]) & 0x02, 0, reason: 'the pre-tap auto recording starts at no boundary');
      expect(flagByte3(saved[1]) & 0x02, 0x02, reason: 'the priority recording starts AT the 0xFFFFFFF8');
      expect(flushed, isNotNull, reason: 'the post-stop audio is a recording of its own');
      expect(flagByte3(flushed!) & 0x02, 0x02, reason: 'the audio after the 0xFFFFFFFC starts at that boundary');

      // The flag shares its byte with isSilero, which must survive the packing —
      // and the production reader must agree with the layout asserted above.
      expect(flagByte3(saved[1]) & 0x01, 0, reason: 'vadEnabled:false → isSilero clear alongside a set hardStart');
      expect(RecordingsManager.metaMarksHardStart(metaOf(saved[1])), isTrue);
      expect(RecordingsManager.metaMarksHardStart(metaOf(saved[0])), isFalse);

      // The other half: each recording CLOSED at a boundary is stamped hardEnd. That
      // is the half that survives a run, which matters because the successor often
      // does not exist yet (below).
      expect(flagByte3(saved[0]) & 0x04, 0x04, reason: 'the auto recording was closed by the 0xFFFFFFF8');
      expect(flagByte3(saved[1]) & 0x04, 0x04, reason: 'the priority recording was closed by the 0xFFFFFFFC');
      expect(flagByte3(flushed) & 0x04, 0, reason: 'the tail was closed by the end of the run, not a boundary');

      // The mode pair shares the same byte and must not disturb — or be
      // disturbed by — the boundary flags asserted above. markerSettings()
      // leaves `manual` unset, so these recordings carry no mode.
      expect(flagByte3(saved[1]) & 0x18, 0, reason: 'no mode claimed when the caller supplied none');
    });

    // The mode is stamped at the single funnel every persisted recording passes
    // through, in the same byte as isSilero/hardStart/hardEnd. Two bits, so
    // "unknown" stays expressible: a .meta from before this feature reads 0, and
    // one bit would relabel the whole back catalogue as whichever mode 0 meant.
    group('recording-mode stamp (.meta flag byte [3], bits 0x08/0x10)', () {
      ProcessingSettings modeSettings(bool? manual) => ProcessingSettings(
            vadEnabled: false,
            speechThreshold: 0.5,
            silenceDurationToSplitMs: 120000,
            minDurationMs: 0,
            minSpeechMs: 0,
            maxChunkMs: 0x7FFFFFFFFFFFFFFF,
            deviceId: '',
            audioSaveFormat: 'wav',
            omiEnabled: false,
            priorityRecordCapMinutes: 0,
            manual: manual,
          );

      /// A plain bin: 0xFFFFFFFB header + [n] frames, no markers.
      File plainBin(String name, int n) {
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
        for (int i = 0; i < n; i++) {
          builder.add(fhdr.buffer.asUint8List());
          builder.add(List.filled(4, 0));
        }
        return File('${tempDir.path}/$name')..writeAsBytesSync(builder.toBytes());
      }

      Future<int> stampFor(bool? manual, String name) async {
        final proc = VadAudioProcessor.fromSettings(settings: modeSettings(manual), outputDir: tempDir.path);
        await proc.processSegmentFile(plainBin(name, 20), DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
        final flushed = await proc.flushRemaining();
        await proc.destroy();
        expect(flushed, isNotNull, reason: 'the run should have written a recording to inspect');
        final meta = File(flushed!.replaceAll(RegExp(r'\.(wav|m4a)$'), '.meta')).readAsBytesSync();
        return meta[417 + meta[416] + 3];
      }

      test('manual mode sets modeKnown AND manual', () async {
        expect(await stampFor(true, 'mode_manual.bin') & 0x18, 0x18);
      });

      test('auto mode sets modeKnown ALONE — the manual bit must stay clear', () async {
        expect(await stampFor(false, 'mode_auto.bin') & 0x18, 0x08);
      });

      // The reachable case: RecordingsController.recoverDiscard hand-builds a
      // synthetic ProcessingSettings to re-derive one discarded span, and the mode
      // that span was recorded in is not recoverable from a discard record. A
      // non-nullable field with a default would have stamped every recovered
      // discard with a mode nobody verified.
      test('an unknown mode writes NEITHER bit, so the reader still says unknown', () async {
        final byte = await stampFor(null, 'mode_unknown.bin');
        expect(byte & 0x18, 0);
        expect(Conversation.modeFromFlagByte(byte), isNull);
      });

      test('the production reader agrees with the byte the processor wrote', () async {
        expect(Conversation.modeFromFlagByte(await stampFor(true, 'mode_rt_manual.bin')), true);
        expect(Conversation.modeFromFlagByte(await stampFor(false, 'mode_rt_auto.bin')), false);
      });
    });

    // The firmware rotates the bin at a priority stop, so a 0xFFFFFFFC sits at the
    // END of a bin and the audio after it is in the bin still being written — the one
    // a sync cannot fetch yet. So the boundary routinely arrives as the last thing in
    // a run, its successor runs later, and _hardStartPending (in-memory, and the
    // checkpoint carrying it is deleted on clean completion) is gone by then. Only the
    // hardEnd stamp on the closed recording survives to hold the boundary.
    test('a boundary at the very end of a run still leaves the closing recording stamped', () async {
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
      // Stop marker as the final bytes of the final bin — nothing follows it.
      builder.add((ByteData(20)..setUint32(0, 0xFFFFFFFC, Endian.little)).buffer.asUint8List());
      final file = File('${tempDir.path}/boundary_at_eof.bin')..writeAsBytesSync(builder.toBytes());

      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      final saved = await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      expect(await proc.flushRemaining(), isNull, reason: 'the marker consumed everything');
      await proc.destroy();

      expect(saved.length, 1);
      final meta = File(saved[0].replaceAll(RegExp(r'\.(wav|m4a)$'), '.meta')).readAsBytesSync();
      expect(RecordingsManager.metaMarksHardEnd(meta), isTrue,
          reason: 'nothing can be appended to this recording in any later run');
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

    // The firmware rotates the bin BEFORE writing a 0xFFFFFFF8, so the marker
    // normally arrives at a bin head with nothing buffered — no recording is closed,
    // so there is no hardEnd to carry the boundary and hardStart is the only stamp
    // that can. This is why both halves exist rather than just the durable one.
    test('a priority start at a bin head stamps hardStart with no recording to close', () async {
      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      final saved = await proc.processSegmentFile(priorityBin('prio_binhead.bin', frames: 10, stop: true),
          DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      await proc.destroy();

      expect(saved.length, 1, reason: 'nothing was buffered at the F8 — only the priority recording is written');
      final meta = File(saved[0].replaceAll(RegExp(r'\.(wav|m4a)$'), '.meta')).readAsBytesSync();
      expect(RecordingsManager.metaMarksHardStart(meta), isTrue,
          reason: 'the boundary rides on the recording that OPENED at it');
      expect(RecordingsManager.metaMarksHardEnd(meta), isTrue, reason: 'and its own 0xFFFFFFFC closed it');
    });

    test('serialize/restore preserves _inPriorityRecording and the high-priority marker', () async {
      // Leave the processor mid-Priority-Recording (start + frames, no stop).
      final file = priorityBin('priority_serde.bin', frames: 10);
      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      await proc.processSegmentFile(file, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      final state = await proc.serializeState();
      await proc.destroy();

      expect(state, isNotNull);
      expect(state!['ipr'], isTrue, reason: '_inPriorityRecording must survive serialization');
      expect(state['poa'], kBase + 200, reason: 'open time is serialized');
      final pm = (state['pm'] as List).cast<Map<String, dynamic>>();
      expect(pm.any((m) => m['hp'] == true), isTrue, reason: 'queued high-priority marker must survive');

      // Round-trip into a fresh processor and re-serialize — state must persist. Give
      // the span a recent open time first: kBase is historical, so restoreState's age
      // ceiling would (correctly) drop a >6h-old span. A real recording's open time is
      // ~now, so this reflects production.
      state['poa'] = DateTime.now().millisecondsSinceEpoch;
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

    test('Priority Recording ends at a session change between bins (device rebooted)', () async {
      // Bin A: priority start + 10 force-captured frames, session 1, NO stop.
      final binA = priorityBin('priority_splitA.bin', frames: 10);
      // Bin B: a fresh session (id 2), 10 min later, + 10 frames + a 0xFFFFFFFC.
      // A session-id change can ONLY mean the device rebooted — device_session_id is
      // a per-boot random value (firmware transport.c) — and the firmware never
      // resumes a Priority Recording after a reboot (the 65535 threshold is
      // runtime-only, button.c), so no 0xFFFFFFFC ever follows for the abandoned
      // recording. Force-capturing across the boundary would run unbounded, so the
      // priority span MUST end at the reboot; the post-reboot audio is normal auto.
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
      final inPriorityAfterReboot = proc.inPriorityRecording;
      final flushed = await proc.flushRemaining();
      final edls = proc.consumePendingEdlData();
      await proc.destroy();

      expect(savedA.length, 0, reason: 'no boundary inside bin A (no stop yet)');
      // The reboot guard clears force-capture at the session change, so the priority
      // portion (bin A) finalizes at the reboot boundary and bin B's FC finalizes the
      // post-reboot auto recording — two recordings, not one unbounded span.
      expect(inPriorityAfterReboot, isFalse, reason: 'a session change (reboot) ends the priority force-capture span');
      expect(savedB.length, 2, reason: 'priority portion closes at the reboot; bin B closes at its FC');
      expect(flushed, isNull);
      // The high-priority flag survives on bin A's finalized portion.
      expect(edls.where((e) => e['isHighPriority'] == true).length, 1,
          reason: 'the pre-reboot priority portion keeps its red marker');
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

    test('hasOpenPriorityWithoutAudio is true only between a marker-only start and the first buffered frame', () async {
      final proc = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
      expect(proc.hasOpenPriorityWithoutAudio, isFalse, reason: 'no priority recording yet');

      // Marker landed with no trailing audio: the checkpoint must not advance
      // past this bin or a resume would skip the start marker.
      final markerOnly = priorityBin('prio_cp_markeronly.bin', frames: 0);
      await proc.processSegmentFile(markerOnly, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
      expect(proc.hasOpenPriorityWithoutAudio, isTrue);

      // A following bin of forced audio buffers frames → checkpoint may advance.
      final contBuilder = BytesBuilder();
      final h = ByteData(36)
        ..setUint32(0, 0xFFFFFFFB, Endian.little)
        ..setUint32(4, 28, Endian.little)
        ..setUint64(8, kBase + 200, Endian.little)
        ..setUint64(16, 0, Endian.little)
        ..setUint32(24, 0, Endian.little)
        ..setUint32(28, 1, Endian.little);
      contBuilder.add(h.buffer.asUint8List());
      final fhdr = ByteData(4)..setUint32(0, 4, Endian.little);
      for (int i = 0; i < 10; i++) {
        contBuilder.add(fhdr.buffer.asUint8List());
        contBuilder.add(List.filled(4, 0));
      }
      final cont = File('${tempDir.path}/prio_cp_cont.bin')..writeAsBytesSync(contBuilder.toBytes());
      await proc.processSegmentFile(cont, DateTime.fromMillisecondsSinceEpoch(kBase + 200, isUtc: true));
      expect(proc.hasOpenPriorityWithoutAudio, isFalse, reason: 'forced audio buffered → safe to advance checkpoint');

      await proc.destroy();
    });

    group('Priority latch across a sync boundary (force-sync mid-recording)', () {
      // A Priority Recording that spans a force-sync is processed in two separate
      // runs (fresh isolate each time). The checkpoint is deleted on clean
      // completion / discarded on a shifted segment list, so a priority-latch
      // sentinel carries _inPriorityRecording into the next run — otherwise the
      // continuation is re-VAD'd as normal auto mode and loses force-capture.

      test('persist writes {sessionId, openedAtMs}; a fresh sentinel restores force-capture', () async {
        final latchPath = '${tempDir.path}/latch_rt.json';

        // Run 1: open a priority recording, then the run ends before the stop.
        final p1 = VadAudioProcessor.fromSettings(
            settings: markerSettings(), outputDir: tempDir.path, priorityStatePath: latchPath);
        await p1.processSegmentFile(
            priorityBin('rt1.bin', frames: 10), DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
        expect(p1.inPriorityRecording, isTrue);
        expect(p1.currentSessionId, 1);
        await p1.persistPriorityLatch();
        await p1.destroy();

        final written = jsonDecode(File(latchPath).readAsStringSync()) as Map<String, dynamic>;
        expect(written['sessionId'], 1);
        expect(written['openedAtMs'], kBase + 200,
            reason: 'the 0xFFFFFFF8 wall time — the origin the audio-domain cap measures from');
        expect(written.containsKey('capMinutes'), isTrue,
            reason: 'the cap armed at open is snapshotted so a later Settings change cannot move the bound');

        // Run 2: the sentinel restores force-capture as written. kBase is historical
        // by years and that is deliberately irrelevant now — restore no longer asks
        // how long ago the recording opened in real time.
        final p2 = VadAudioProcessor.fromSettings(
            settings: markerSettings(), outputDir: tempDir.path, priorityStatePath: latchPath);
        expect(p2.inPriorityRecording, isFalse, reason: 'fresh processor starts outside a priority recording');
        await p2.restorePriorityLatch();
        expect(p2.inPriorityRecording, isTrue, reason: 'latch restored → force-capture continues');
        await p2.destroy();
      });

      test('restorePriorityLatch keeps an ancient latch — age is not evidence of a lost stop', () async {
        // The Omi records for days without seeing the phone, so "opened 7 hours ago in
        // real time" says nothing about whether its 0xFFFFFFFC arrived. It used to drop
        // the latch here, which re-VAD'd a legitimate force-captured stretch purely
        // because syncing had been delayed. The bound now lives in the audio (below).
        final latchPath = '${tempDir.path}/latch_stale.json';
        final sevenHoursAgo = DateTime.now().millisecondsSinceEpoch - (7 * 60 * 60 * 1000);
        File(latchPath)
            .writeAsStringSync(jsonEncode({'sessionId': 1, 'openedAtMs': sevenHoursAgo, 'ts': sevenHoursAgo}));
        final p = VadAudioProcessor.fromSettings(
            settings: markerSettings(), outputDir: tempDir.path, priorityStatePath: latchPath);
        await p.restorePriorityLatch();
        expect(p.inPriorityRecording, isTrue, reason: 'a long-delayed sync must not cost force-capture');
        expect(File(latchPath).existsSync(), isTrue, reason: 'and the sentinel survives for the next run');
        await p.destroy();
      });

      ProcessingSettings capSettings(int capMinutes) => ProcessingSettings(
            vadEnabled: false,
            speechThreshold: 0.5,
            silenceDurationToSplitMs: 120000,
            minDurationMs: 0,
            minSpeechMs: 0,
            maxChunkMs: 0x7FFFFFFFFFFFFFFF,
            deviceId: '',
            audioSaveFormat: 'wav',
            omiEnabled: false,
            priorityRecordCapMinutes: capMinutes,
          );

      // The safety cap is enforced against the AUDIO's own device clock: a
      // continuation bin whose frames sit `audioAgeMin` past the 0xFFFFFFF8 either
      // stays inside the span or ends it, and the phone's clock never enters it. Each
      // case runs a fresh sentinel + continuation so a dropped 0xFFFFFFFC is bounded
      // exactly where the firmware would have stopped, however late the bins arrive.
      Future<bool> stillCapturingAfter({
        required String name,
        required int audioAgeMin,
        int? snapshotCapMinutes,
        required int prefCapMinutes,
      }) async {
        final latchPath = '${tempDir.path}/$name';
        // Opened "now" in real time; only the AUDIO is old.
        final openedAtMs = DateTime.now().millisecondsSinceEpoch;
        File(latchPath).writeAsStringSync(jsonEncode({
          'sessionId': 1,
          'openedAtMs': openedAtMs,
          if (snapshotCapMinutes != null) 'capMinutes': snapshotCapMinutes,
          'ts': openedAtMs,
        }));
        final p = VadAudioProcessor.fromSettings(
            settings: capSettings(prefCapMinutes), outputDir: tempDir.path, priorityStatePath: latchPath);
        await p.restorePriorityLatch();
        expect(p.inPriorityRecording, isTrue, reason: 'restore never refuses on age now');
        // Continuation bin (same session) whose audio lands audioAgeMin past the open.
        await p.processSegmentFile(
          _makeBinFile(tempDir, 10, name: '${name}_cont.bin'),
          DateTime.fromMillisecondsSinceEpoch(openedAtMs + audioAgeMin * 60 * 1000, isUtc: true),
          sessionId: 1,
        );
        final open = p.inPriorityRecording;
        await p.destroy();
        return open;
      }

      test('the cap is measured in the audio, so a late sync keeps force-capture', () async {
        // 90 minutes of audio under a 120-minute cap: inside the bound, still capturing
        // — and it stays that way no matter when the bins reach the phone.
        expect(await stillCapturingAfter(name: 'aud_in.json', audioAgeMin: 90, prefCapMinutes: 120), isTrue);
      });

      test('the cap closes a span whose audio has passed it (the 0xFFFFFFFC was lost)', () async {
        // 200 minutes of audio under a 120-minute cap: the firmware would have stopped
        // at 120, so the marker is gone. Cut here and treat the rest as auto mode.
        expect(await stillCapturingAfter(name: 'aud_out.json', audioAgeMin: 200, prefCapMinutes: 120), isFalse);
      });

      test('a run opening already past the cap closes the span without inventing a fragment', () async {
        // The boundary can land at a run START — earlier runs consumed the pre-cap
        // audio — so the frame that trips the cap is the first one buffered. Nothing
        // may be saved there (the "recording" would be that one 20 ms frame); the
        // stamp goes on the audio that follows instead. This is also why the cap is
        // enforced in the ingestion loop and not in the deferred verdict, which only
        // ever sees frames already appended.
        final latchPath = '${tempDir.path}/aud_runstart.json';
        final openedAtMs = DateTime.now().millisecondsSinceEpoch;
        File(latchPath).writeAsStringSync(jsonEncode({'sessionId': 1, 'openedAtMs': openedAtMs, 'ts': openedAtMs}));
        final p = VadAudioProcessor.fromSettings(
            settings: capSettings(120), outputDir: tempDir.path, priorityStatePath: latchPath);
        await p.restorePriorityLatch();

        final saved = await p.processSegmentFile(
          _makeBinFile(tempDir, 10, name: 'runstart_cont.bin'),
          DateTime.fromMillisecondsSinceEpoch(openedAtMs + 200 * 60 * 1000, isUtc: true),
          sessionId: 1,
        );
        expect(saved, isEmpty, reason: 'no audio buffered before the cap tripped — nothing to save');
        expect(p.inPriorityRecording, isFalse, reason: 'the span is over');
        expect(File(latchPath).existsSync(), isFalse, reason: 'the sentinel goes with it');

        final flushed = await p.flushRemaining();
        expect(flushed, isNotNull, reason: 'the post-cap audio is an ordinary recording');
        final meta = File(flushed!.replaceAll(RegExp(r'\.(wav|m4a)$'), '.meta')).readAsBytesSync();
        expect(RecordingsManager.metaMarksHardStart(meta), isTrue,
            reason: 'the cut is the hard boundary the lost 0xFFFFFFFC would have been');
        await p.destroy();
      });

      test('cap 0 (no firmware cap) falls back to a 6 h bound on the audio', () async {
        expect(await stillCapturingAfter(name: 'aud_nocap_in.json', audioAgeMin: 300, prefCapMinutes: 0), isTrue);
        expect(await stillCapturingAfter(name: 'aud_nocap_out.json', audioAgeMin: 400, prefCapMinutes: 0), isFalse);
      });

      test('the cap snapshotted at open wins over a mid-recording Settings change', () async {
        // Opened under 120 (bound 122); user then shrank the pref to 30. 90 min of
        // audio is inside the recording's OWN bound → keep capturing.
        expect(
            await stillCapturingAfter(
                name: 'snap120_pref30.json', audioAgeMin: 90, snapshotCapMinutes: 120, prefCapMinutes: 30),
            isTrue);
        // Symmetric: opened under 30 (bound 32), pref later raised to 120. The
        // firmware armed the 30-minute recording, so 90 min of audio is past it.
        expect(
            await stillCapturingAfter(
                name: 'snap30_pref120.json', audioAgeMin: 90, snapshotCapMinutes: 30, prefCapMinutes: 120),
            isFalse);
      });

      // Bin with a 0xFFFFFFFB header (anchors uptime + session=1) + 10 frames + a
      // 0xFFFFFFFD resume + 10 frames. The header uptime lets isClockJump distinguish a
      // real silence gap (uptime advances with UTC) from an RTC correction (uptime flat).
      File makeResumeBin(String name, {required int resumeUtcSeconds, required int resumeUptimeMs}) {
        final builder = BytesBuilder();
        final hdr = ByteData(36);
        hdr.setUint32(0, 0xFFFFFFFB, Endian.little);
        hdr.setUint32(4, 28, Endian.little);
        hdr.setUint64(8, kBase, Endian.little);
        hdr.setUint64(16, 0, Endian.little);
        hdr.setUint32(24, 0, Endian.little);
        hdr.setUint32(28, 1, Endian.little); // sessionId = 1 (matches the restored latch)
        builder.add(hdr.buffer.asUint8List());
        final fhdr = ByteData(4)..setUint32(0, 4, Endian.little);
        for (int i = 0; i < 10; i++) {
          builder.add(fhdr.buffer.asUint8List());
          builder.add(List.filled(4, 0));
        }
        final resume = ByteData(20);
        resume.setUint32(0, 0xFFFFFFFD, Endian.little);
        resume.setUint32(4, resumeUtcSeconds, Endian.little);
        resume.setUint32(8, resumeUptimeMs, Endian.little);
        builder.add(resume.buffer.asUint8List());
        for (int i = 0; i < 10; i++) {
          builder.add(fhdr.buffer.asUint8List());
          builder.add(List.filled(4, 0));
        }
        return File('${tempDir.path}/$name')..writeAsBytesSync(builder.toBytes());
      }

      Future<VadAudioProcessor> restoredLatchProc(String latchPath) async {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        File(latchPath)
            .writeAsStringSync(jsonEncode({'sessionId': 1, 'openedAtMs': nowMs, 'capMinutes': 0, 'ts': nowMs}));
        final p = VadAudioProcessor.fromSettings(
            settings: markerSettings(), outputDir: tempDir.path, priorityStatePath: latchPath);
        await p.restorePriorityLatch();
        expect(p.inPriorityRecording, isTrue, reason: 'latch restored → force-capture');
        return p;
      }

      test('restored latch auto-closes on a large resume gap (device already left force-capture)', () async {
        final latchPath = '${tempDir.path}/latch_staleresume.json';
        final p = await restoredLatchProc(latchPath);
        // ~40 s gap, uptime advancing in step → a real silence, not a clock jump.
        final bin = makeResumeBin('stale_resume.bin', resumeUtcSeconds: (kBase ~/ 1000) + 40, resumeUptimeMs: 40000);
        await p.processSegmentFile(bin, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
        expect(p.inPriorityRecording, isFalse,
            reason: 'a >=15 s real resume gap in a restored latch closes the stale force-capture');
        expect(File(latchPath).existsSync(), isFalse, reason: 'stale sentinel cleared on auto-close');
        await p.destroy();
      });

      test('restored latch survives a small resume gap (WAKE re-arm, not a stop)', () async {
        final latchPath = '${tempDir.path}/latch_smallresume.json';
        final p = await restoredLatchProc(latchPath);
        // ~1 s gap — like a hardware WAKE re-arming mid-force-capture. Must NOT close.
        final bin = makeResumeBin('small_resume.bin', resumeUtcSeconds: (kBase ~/ 1000) + 1, resumeUptimeMs: 1000);
        await p.processSegmentFile(bin, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
        expect(p.inPriorityRecording, isTrue,
            reason: 'a sub-15 s resume gap must NOT close a legit force-capture latch');
        expect(File(latchPath).existsSync(), isTrue, reason: 'sentinel kept — latch still open');
        await p.destroy();
      });

      test('restored latch survives a clock jump (large UTC gap, flat uptime — not silence)', () async {
        final latchPath = '${tempDir.path}/latch_clockjump.json';
        final p = await restoredLatchProc(latchPath);
        // Large UTC jump (~40 s) but uptime barely moves → an RTC correction, not
        // silence. Must NOT terminate the still-active priority recording.
        final bin = makeResumeBin('clockjump_resume.bin', resumeUtcSeconds: (kBase ~/ 1000) + 40, resumeUptimeMs: 300);
        await p.processSegmentFile(bin, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
        expect(p.inPriorityRecording, isTrue,
            reason: 'a clock jump (flat uptime) is not silence, so it must not close the latch');
        expect(File(latchPath).existsSync(), isTrue, reason: 'sentinel kept — latch still open');
        await p.destroy();
      });

      test('stale-latch break finalizes a SHORT recovered priority recording (bypasses noise filter)', () async {
        final latchPath = '${tempDir.path}/latch_shortrecovery.json';
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        File(latchPath)
            .writeAsStringSync(jsonEncode({'sessionId': 1, 'openedAtMs': nowMs, 'capMinutes': 0, 'ts': nowMs}));
        // session != null + minSpeechMs far above the buffered span → without the forced
        // flag the split's short-speech noise filter would DISCARD the recovered priority
        // audio. It's force-captured (user-intended), so it must be finalized instead.
        const settings = ProcessingSettings(
          vadEnabled: true,
          speechThreshold: 0.5,
          silenceDurationToSplitMs: 120000,
          minDurationMs: 0,
          minSpeechMs: 60000,
          maxChunkMs: 0x7FFFFFFFFFFFFFFF,
          deviceId: '',
          audioSaveFormat: 'wav',
          omiEnabled: false,
          priorityRecordCapMinutes: 0,
        );
        final p = VadAudioProcessor.fromSettings(
            settings: settings, outputDir: tempDir.path, priorityStatePath: latchPath, session: _fakeSession());
        await p.restorePriorityLatch();
        expect(p.inPriorityRecording, isTrue);

        final bin = makeResumeBin('short_recovery.bin', resumeUtcSeconds: (kBase ~/ 1000) + 40, resumeUptimeMs: 40000);
        final saved = await p.processSegmentFile(bin, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));

        expect(p.inPriorityRecording, isFalse, reason: 'stale latch closed at the large resume gap');
        expect(saved, isNotEmpty,
            reason: 'a short recovered priority recording is finalized (forced), not discarded as noise');
        await p.destroy();
      });

      test('restored latch keeps the continuation force-captured across a splitting gap', () async {
        final latchPath = '${tempDir.path}/latch_behavior.json';
        // Sentinel as if run 1 left a priority recording open in session 1.
        File(latchPath).writeAsStringSync(
            jsonEncode({'sessionId': 1, 'openedAtMs': DateTime.now().millisecondsSinceEpoch, 'ts': 0}));

        final p = VadAudioProcessor.fromSettings(
            settings: markerSettings(), outputDir: tempDir.path, priorityStatePath: latchPath);
        await p.restorePriorityLatch();
        expect(p.inPriorityRecording, isTrue);

        // Two continuation bins, SAME session (1), 5 min apart. The 5-min inter-file
        // gap far exceeds the 110 s split threshold (and advancing uptimes keep it a
        // genuine silence, not a clock jump), so normal auto mode would split. Inside
        // the restored priority span it must NOT split.
        final c1 = _makeBinFileWithHeader(tempDir, 10,
            name: 'fs_c1.bin', utcStartMs: kBase + 300000, uptimeStartMs: 300000, imuTicks: 0, sessionId: 1);
        await p.processSegmentFile(c1, DateTime.fromMillisecondsSinceEpoch(kBase + 300000, isUtc: true));
        final c2 = _makeBinFileWithHeader(tempDir, 10,
            name: 'fs_c2.bin', utcStartMs: kBase + 600000, uptimeStartMs: 600000, imuTicks: 0, sessionId: 1);
        final savedC2 =
            await p.processSegmentFile(c2, DateTime.fromMillisecondsSinceEpoch(kBase + 600000, isUtc: true));

        expect(savedC2, isEmpty, reason: 'force-capture: the 5-min gap must not split the priority continuation');
        expect(p.inPriorityRecording, isTrue, reason: 'still open — no stop marker yet');
        await p.destroy();
      });

      test('control: WITHOUT the latch the same continuation gap splits', () async {
        // Identical bins, but no latch → normal auto mode, so the gap splits.
        final p = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
        final c1 = _makeBinFileWithHeader(tempDir, 10,
            name: 'ctl_c1.bin', utcStartMs: kBase + 300000, uptimeStartMs: 300000, imuTicks: 0, sessionId: 1);
        await p.processSegmentFile(c1, DateTime.fromMillisecondsSinceEpoch(kBase + 300000, isUtc: true));
        final c2 = _makeBinFileWithHeader(tempDir, 10,
            name: 'ctl_c2.bin', utcStartMs: kBase + 600000, uptimeStartMs: 600000, imuTicks: 0, sessionId: 1);
        final savedC2 =
            await p.processSegmentFile(c2, DateTime.fromMillisecondsSinceEpoch(kBase + 600000, isUtc: true));

        expect(savedC2, isNotEmpty, reason: 'normal auto mode: the 5-min gap splits, finalizing the prior chunk');
        expect(p.inPriorityRecording, isFalse);
        await p.destroy();
      });

      test('reboot guard: a session change on the continuation drops the restored latch', () async {
        final latchPath = '${tempDir.path}/latch_reboot.json';
        File(latchPath).writeAsStringSync(
            jsonEncode({'sessionId': 1, 'openedAtMs': DateTime.now().millisecondsSinceEpoch, 'ts': 0}));

        final p = VadAudioProcessor.fromSettings(
            settings: markerSettings(), outputDir: tempDir.path, priorityStatePath: latchPath);
        await p.restorePriorityLatch();
        expect(p.inPriorityRecording, isTrue);

        // Continuation from a DIFFERENT session → the device rebooted while the
        // recording was open; the firmware abandoned it, so force-capture must end.
        final rebooted = _makeBinFileWithHeader(tempDir, 10,
            name: 'latch_reboot.bin', utcStartMs: kBase + 300000, uptimeStartMs: 300000, imuTicks: 0, sessionId: 2);
        await p.processSegmentFile(rebooted, DateTime.fromMillisecondsSinceEpoch(kBase + 300000, isUtc: true));
        expect(p.inPriorityRecording, isFalse, reason: 'session change (reboot) ends the restored priority span');

        await p.persistPriorityLatch();
        expect(File(latchPath).existsSync(), isFalse, reason: 'the stale latch is removed once the reboot is detected');
        await p.destroy();
      });

      test('reboot guard ends force-capture on a HEADERLESS bin from a new session', () async {
        final latchPath = '${tempDir.path}/latch_reboot_hl.json';
        File(latchPath).writeAsStringSync(
            jsonEncode({'sessionId': 1, 'openedAtMs': DateTime.now().millisecondsSinceEpoch, 'ts': 0}));
        final p = VadAudioProcessor.fromSettings(
            settings: markerSettings(), outputDir: tempDir.path, priorityStatePath: latchPath);
        await p.restorePriorityLatch();
        expect(p.inPriorityRecording, isTrue);

        // A headerless bin (no 0xFFFFFFFB) whose session id comes from the CALLER
        // (filename metadata), not a header. The resolved-sessionId guard must still
        // fire so the new session's audio isn't force-captured into the priority span.
        final headerless = _makeBinFile(tempDir, 10, name: 'headerless_reboot.bin');
        await p.processSegmentFile(headerless, DateTime.fromMillisecondsSinceEpoch(kBase + 300000, isUtc: true),
            sessionId: 2);
        expect(p.inPriorityRecording, isFalse, reason: 'headerless bin from a new session ends the span too');
        await p.destroy();
      });

      test('a 0xFFFFFFFC clears the sentinel mid-run (robust to an abrupt exit)', () async {
        final latchPath = '${tempDir.path}/latch_stop.json';
        // A latch left open by a prior run.
        File(latchPath).writeAsStringSync(
            jsonEncode({'sessionId': 1, 'openedAtMs': DateTime.now().millisecondsSinceEpoch, 'ts': 0}));
        final p = VadAudioProcessor.fromSettings(
            settings: markerSettings(), outputDir: tempDir.path, priorityStatePath: latchPath);
        await p.restorePriorityLatch();
        expect(p.inPriorityRecording, isTrue);
        expect(File(latchPath).existsSync(), isTrue);

        // Continuation bin (session 1): header + 10 frames + the 0xFFFFFFFC stop.
        final b = BytesBuilder();
        b.add((ByteData(36)
              ..setUint32(0, 0xFFFFFFFB, Endian.little)
              ..setUint32(4, 28, Endian.little)
              ..setUint64(8, kBase, Endian.little)
              ..setUint64(16, 0, Endian.little)
              ..setUint32(24, 0, Endian.little)
              ..setUint32(28, 1, Endian.little))
            .buffer
            .asUint8List());
        final fhdr = ByteData(4)..setUint32(0, 4, Endian.little);
        for (int i = 0; i < 10; i++) {
          b.add(fhdr.buffer.asUint8List());
          b.add(List.filled(4, 0));
        }
        b.add((ByteData(20)..setUint32(0, 0xFFFFFFFC, Endian.little)).buffer.asUint8List());
        final contStop = File('${tempDir.path}/cont_stop.bin')..writeAsBytesSync(b.toBytes());

        // The stop clears the sentinel immediately — no end-of-run persist call here.
        await p.processSegmentFile(contStop, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
        expect(p.inPriorityRecording, isFalse, reason: 'the 0xFFFFFFFC stop closed the priority recording');
        expect(File(latchPath).existsSync(), isFalse,
            reason: 'sentinel cleared AT the stop, not deferred to end of run');
        await p.destroy();
      });

      test('persistPriorityLatch writes nothing when no priority recording is open', () async {
        final latchPath = '${tempDir.path}/latch_none.json';
        final p = VadAudioProcessor.fromSettings(
            settings: markerSettings(), outputDir: tempDir.path, priorityStatePath: latchPath);
        await p.persistPriorityLatch();
        expect(File(latchPath).existsSync(), isFalse);
        await p.destroy();
      });

      test('restoreState fails closed on an open priority span with no session id (legacy checkpoint)', () async {
        // Real mid-priority state, then strip 'prs' to mimic a checkpoint written
        // before the session-id field existed. Without a session id the reboot guard
        // can't fire, so force-capture must NOT be restored.
        final p1 = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
        await p1.processSegmentFile(
            priorityBin('failclosed.bin', frames: 10), DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
        final state = (await p1.serializeState())!;
        await p1.destroy();
        expect(state['ipr'], isTrue);
        expect(state['prs'], 1, reason: 'new state carries the session id');
        state.remove('prs');

        final p2 = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
        await p2.restoreState(state);
        expect(p2.inPriorityRecording, isFalse, reason: 'no session id to reboot-guard → fail closed');
        await p2.destroy();
      });

      test('restoreState fails closed on an open priority span with no open time (no poa)', () async {
        // Strip 'poa' to mimic a checkpoint from an intermediate build that had the
        // session id but not the open time. Without it the audio-domain safety cap has
        // no origin to measure from, so force-capture must NOT be restored.
        final p1 = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
        await p1.processSegmentFile(
            priorityBin('failclosed_poa.bin', frames: 10), DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
        final state = (await p1.serializeState())!;
        await p1.destroy();
        expect(state['ipr'], isTrue);
        expect(state['poa'], kBase + 200, reason: 'new state carries the open time');
        state.remove('poa');

        final p2 = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
        await p2.restoreState(state);
        expect(p2.inPriorityRecording, isFalse, reason: 'no open time to measure the cap from → fail closed');
        await p2.destroy();
      });

      test('restorePriorityLatch fails closed and clears a sentinel with no session id', () async {
        final latchPath = '${tempDir.path}/latch_nosession.json';
        File(latchPath).writeAsStringSync(jsonEncode({'ts': 0})); // no sessionId
        final p = VadAudioProcessor.fromSettings(
            settings: markerSettings(), outputDir: tempDir.path, priorityStatePath: latchPath);
        await p.restorePriorityLatch();
        expect(p.inPriorityRecording, isFalse, reason: 'no session id → do not re-arm force-capture');
        expect(File(latchPath).existsSync(), isFalse, reason: 'the un-guardable sentinel is removed');
        await p.destroy();
      });

      test('restorePriorityLatch fails closed on a sentinel with a session id but no timestamp', () async {
        final latchPath = '${tempDir.path}/latch_nots.json';
        File(latchPath).writeAsStringSync(jsonEncode({'sessionId': 1})); // no openedAtMs, no ts
        final p = VadAudioProcessor.fromSettings(
            settings: markerSettings(), outputDir: tempDir.path, priorityStatePath: latchPath);
        await p.restorePriorityLatch();
        expect(p.inPriorityRecording, isFalse, reason: 'no open time to measure the cap from → fail closed');
        expect(File(latchPath).existsSync(), isFalse);
        await p.destroy();
      });

      test('restorePriorityLatch restores a legacy sentinel via the recent ts fallback', () async {
        final latchPath = '${tempDir.path}/latch_tsfallback.json';
        // Legacy sentinel: session id + a recent persist 'ts', but no openedAtMs.
        File(latchPath).writeAsStringSync(jsonEncode({'sessionId': 1, 'ts': DateTime.now().millisecondsSinceEpoch}));
        final p = VadAudioProcessor.fromSettings(
            settings: markerSettings(), outputDir: tempDir.path, priorityStatePath: latchPath);
        await p.restorePriorityLatch();
        expect(p.inPriorityRecording, isTrue, reason: 'the ts gives the cap an origin → safe to restore');
        await p.destroy();
      });

      test('restoreState keeps a checkpoint whose span opened long ago in real time', () async {
        // Mirrors the sentinel rule: a resumed checkpoint is not aged out either. The
        // audio decides, so an Omi that was away from the phone for hours resumes its
        // force-capture instead of having the rest of it re-VAD'd as auto mode.
        final p1 = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
        await p1.processSegmentFile(
            priorityBin('failclosed_stale.bin', frames: 10), DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
        final state = (await p1.serializeState())!;
        await p1.destroy();
        expect(state['ipr'], isTrue);
        state['poa'] = DateTime.now().millisecondsSinceEpoch - (7 * 60 * 60 * 1000);

        final p2 = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
        await p2.restoreState(state);
        expect(p2.inPriorityRecording, isTrue, reason: 'real-time age is not evidence the 0xFFFFFFFC was lost');
        await p2.destroy();
      });

      test('restorePriorityLatch drops a future-dated latch (negative age must not bypass the bound)', () async {
        final latchPath = '${tempDir.path}/latch_future.json';
        final oneDayFuture = DateTime.now().millisecondsSinceEpoch + (24 * 60 * 60 * 1000);
        File(latchPath).writeAsStringSync(jsonEncode({'sessionId': 1, 'openedAtMs': oneDayFuture, 'ts': oneDayFuture}));
        final p = VadAudioProcessor.fromSettings(
            settings: markerSettings(), outputDir: tempDir.path, priorityStatePath: latchPath);
        await p.restorePriorityLatch();
        expect(p.inPriorityRecording, isFalse, reason: 'a future openedAtMs is bogus → fail closed, not force-capture');
        expect(File(latchPath).existsSync(), isFalse);
        await p.destroy();
      });

      test('restoreState fails closed on a future-dated checkpoint span', () async {
        final p1 = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
        await p1.processSegmentFile(
            priorityBin('failclosed_future.bin', frames: 10), DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));
        final state = (await p1.serializeState())!;
        await p1.destroy();
        state['poa'] = DateTime.now().millisecondsSinceEpoch + (24 * 60 * 60 * 1000); // 1 day in the future
        final p2 = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
        await p2.restoreState(state);
        expect(p2.inPriorityRecording, isFalse, reason: 'a future open time is bogus → fail closed');
        await p2.destroy();
      });

      test('a Priority Recording opening in the first bin after a reboot adopts the NEW session', () async {
        final p = VadAudioProcessor.fromSettings(settings: markerSettings(), outputDir: tempDir.path);
        // Bin A: ordinary auto audio in session 1 (sets _currentSessionId = 1).
        final a = _makeBinFileWithHeader(tempDir, 10,
            name: 'reb_a.bin', utcStartMs: kBase, uptimeStartMs: 1000, imuTicks: 0, sessionId: 1);
        await p.processSegmentFile(a, DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));

        // Bin B: a fresh session (2, reboot) whose FIRST frame is the 0xFFFFFFF8 start —
        // so _currentSessionId is still 1 when the marker is handled. The priority span
        // must anchor to session 2 (this bin), not the stale 1.
        final bb = BytesBuilder();
        bb.add((ByteData(36)
              ..setUint32(0, 0xFFFFFFFB, Endian.little)
              ..setUint32(4, 28, Endian.little)
              ..setUint64(8, kBase + 300000, Endian.little)
              ..setUint64(16, 300000, Endian.little)
              ..setUint32(24, 0, Endian.little)
              ..setUint32(28, 2, Endian.little))
            .buffer
            .asUint8List());
        bb.add((ByteData(20)
              ..setUint32(0, 0xFFFFFFF8, Endian.little)
              ..setUint64(4, kBase + 300000, Endian.little)
              ..setUint32(12, 300000, Endian.little)
              ..setUint32(16, 2, Endian.little))
            .buffer
            .asUint8List());
        final fh = ByteData(4)..setUint32(0, 4, Endian.little);
        for (int i = 0; i < 10; i++) {
          bb.add(fh.buffer.asUint8List());
          bb.add(List.filled(4, 0));
        }
        final binB = File('${tempDir.path}/reb_b.bin')..writeAsBytesSync(bb.toBytes());
        await p.processSegmentFile(binB, DateTime.fromMillisecondsSinceEpoch(kBase + 300000, isUtc: true));
        expect(p.inPriorityRecording, isTrue, reason: 'priority opened in the new session');

        // Bin C: continuation in the SAME new session (2). The reboot guard must NOT
        // fire — it would if the span had wrongly anchored to session 1.
        final c = _makeBinFileWithHeader(tempDir, 10,
            name: 'reb_c.bin', utcStartMs: kBase + 600000, uptimeStartMs: 600000, imuTicks: 0, sessionId: 2);
        await p.processSegmentFile(c, DateTime.fromMillisecondsSinceEpoch(kBase + 600000, isUtc: true));
        expect(p.inPriorityRecording, isTrue,
            reason: 'same-session continuation must not be ended by a stale session anchor');
        await p.destroy();
      });
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
          priorityRecordCapMinutes: 0,
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

  // A Stop tapped shortly after a sync writes its 0xFFFFFFFC into a bin of its
  // own — the sync rotated the active bin, so the audio the stop ends was
  // already fetched, decoded, and flushed as a `_draft` by an earlier run. The
  // processor then meets the marker with nothing in memory to finalize, and the
  // hard-end stamp it normally writes through the file it saves has no file to
  // land on. It must hand the boundary out instead, or the draft is stranded as
  // "Conversation in progress" — permanently, in manual mode, where
  // vadSplitSeconds is 0 and the manager's gap rule is disabled.
  group('session-end with no audio buffered (stop arrives after its own run)', () {
    const int kBase = 1746057600000; // 2026-05-01 UTC, past the year-2000 guard

    ProcessingSettings settings() => const ProcessingSettings(
          vadEnabled: false,
          speechThreshold: 0.5,
          silenceDurationToSplitMs: 0, // manual mode
          minDurationMs: 0,
          minSpeechMs: 0,
          maxChunkMs: 0x7FFFFFFFFFFFFFFF,
          deviceId: '',
          audioSaveFormat: 'wav',
          omiEnabled: false,
          priorityRecordCapMinutes: 0,
        );

    File writeBin(String name, {required int frames, required int stopUtcMs}) {
      final b = BytesBuilder();
      final fhdr = ByteData(4)..setUint32(0, 4, Endian.little);
      for (int i = 0; i < frames; i++) {
        b.add(fhdr.buffer.asUint8List());
        b.add(List.filled(4, 0));
      }
      final m = ByteData(20);
      m.setUint32(0, 0xFFFFFFFC, Endian.little);
      m.setUint64(4, stopUtcMs, Endian.little);
      m.setUint32(12, 0, Endian.little);
      m.setUint32(16, 1, Endian.little);
      b.add(m.buffer.asUint8List());
      final f = File('${tempDir.path}/$name');
      f.writeAsBytesSync(b.toBytes());
      return f;
    }

    test('a marker-only bin queues the stop time for the on-disk draft', () async {
      final proc = VadAudioProcessor.fromSettings(settings: settings(), outputDir: tempDir.path);
      await proc.processSegmentFile(writeBin('stop_only.bin', frames: 0, stopUtcMs: kBase + 5000),
          DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));

      expect(proc.consumePendingDraftHardEnds(), [kBase + 5000]);
      expect(proc.consumePendingDraftHardEnds(), isEmpty, reason: 'drained, not re-reported every segment');
      await proc.destroy();
    });

    test('a stop that DOES close buffered audio queues nothing (control)', () async {
      // The ordinary case: audio and its stop in the same bin. The flush writes
      // the hard end into the recording's own .meta, so there is no draft to fix.
      final proc = VadAudioProcessor.fromSettings(settings: settings(), outputDir: tempDir.path);
      await proc.processSegmentFile(writeBin('stop_with_audio.bin', frames: 10, stopUtcMs: kBase + 5000),
          DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true));

      expect(proc.consumePendingDraftHardEnds(), isEmpty);
      await proc.destroy();
    });
  });

  // ---------------------------------------------------------------------------
  // The running per-frame uptime counter across a bin boundary.
  //
  // `_currentFrameUptimeMs` advances only per DECODED FRAME, but an inter-file gap is
  // padded into the recording as silence without any frames — so at every stitched
  // boundary the counter falls behind the device by the size of the gap, and the error
  // accumulates across boundaries. The next recording to open takes its start uptime
  // from that counter, so once the lag passes `plausibleDriftMs` (60 s floor) the clock
  // anchor reads a CORRECT recording as provably wrong and re-files the session.
  //
  // The geometry below is measured from a real 117-bin session (device session
  // 1193025564, 2026-08-28). Consecutive bins there drift by 20 ms to 500 s between
  // what the counter accrued and what the device's own uptime says:
  //
  //     boundary      d_uptime    d_audio    counter behind by
  //     ...939249      141222     141340        -118 ms
  //     ...940511      601661     600540        1121 ms
  //     ...944604      601160     579940       21220 ms   <- stitches, accumulates
  //     ...941199      688399     186720      501679 ms   <- too big; splits instead
  //
  // Only gaps under `vadSplitSeconds - 10 s` stitch, so a single boundary can hide at
  // most that much — but nothing bounds the SUM across a long recording.
  // ---------------------------------------------------------------------------
  group('frame-uptime re-anchor at a bin boundary', () {
    const int kBase = 1746057600000; // 2026-05-01T00:00:00Z
    const int kUp1 = 3600000; // bin 1 opens an hour into the boot
    const int kFrames1 = 100; // 2 s of audio
    const int kGapMs = 30000; // 30 s of wall clock with no frames — padded, stitched
    const int kFrames2 = 600; // 12 s of audio
    const int kCapMs = 40000; // > 2 s + 30 s, so the boundary STITCHES rather than cuts

    // Bin 2's audio begins here in device uptime. The running counter, left alone,
    // would be at kUp1 + kFrames1*20 — short by the entire gap, because the padding is
    // added to _currentChunkDurationMs and _currentRefs but never to the counter.
    const int kUp2 = kUp1 + kFrames1 * 20 + kGapMs;

    /// A bin carrying a real `0xFFFFFFFB` metadata header, optionally with a button-tap
    /// marker after [markerAfter] frames.
    File makeBin(String name,
        {required int utcMs, required int uptimeMs, required int sessionId, required int frames, int? markerAfter}) {
      final b = BytesBuilder();
      final hdr = ByteData(36);
      hdr.setUint32(0, 0xFFFFFFFB, Endian.little);
      hdr.setUint32(4, 28, Endian.little);
      hdr.setUint64(8, utcMs, Endian.little);
      hdr.setUint64(16, uptimeMs, Endian.little);
      hdr.setUint32(24, 0, Endian.little); // imu ticks
      hdr.setUint32(28, sessionId, Endian.little);
      b.add(hdr.buffer.asUint8List());
      final fh = ByteData(4)..setUint32(0, 4, Endian.little);
      for (int i = 0; i < frames; i++) {
        if (markerAfter != null && i == markerAfter) {
          final m = ByteData(20);
          m.setUint32(0, 0xFFFFFFFE, Endian.little);
          m.setUint64(4, utcMs + i * 20, Endian.little);
          m.setUint32(12, uptimeMs + i * 20, Endian.little);
          m.setUint32(16, sessionId, Endian.little);
          b.add(m.buffer.asUint8List());
        }
        b.add(fh.buffer.asUint8List());
        b.add(List.filled(4, 0));
      }
      final f = File('${tempDir.path}/$name');
      f.writeAsBytesSync(b.toBytes());
      return f;
    }

    ProcessingSettings boundarySettings() => const ProcessingSettings(
          vadEnabled: false, // AAD: every frame is speech, so the cap is the only cut
          speechThreshold: 0.5,
          silenceDurationToSplitMs: 120000, // gaps under 110 s stitch rather than split
          minDurationMs: 0,
          minSpeechMs: 0,
          maxChunkMs: kCapMs,
          deviceId: '',
          audioSaveFormat: 'wav',
          omiEnabled: false,
          priorityRecordCapMinutes: 0,
        );

    /// `.meta` byte 412 for every recording written, keyed by start-ms offset from kBase.
    Map<int, int> uptimesByStartOffset() {
      final out = <int, int>{};
      for (final f in tempDir.listSync().whereType<File>()) {
        final n = f.path.split(Platform.pathSeparator).last;
        if (!n.startsWith('recording_') || !n.endsWith('.meta')) continue;
        final startMs = int.parse(n.substring('recording_'.length, n.length - '.meta'.length));
        out[startMs - kBase] = ByteData.sublistView(f.readAsBytesSync()).getUint32(412, Endian.little);
      }
      return out;
    }

    Future<Map<int, int>> runTwoBins({required int session2, required int uptime2, int? markerAfter}) async {
      final proc = VadAudioProcessor.fromSettings(settings: boundarySettings(), outputDir: tempDir.path);
      await proc.processSegmentFile(
        makeBin('b1.bin', utcMs: kBase, uptimeMs: kUp1, sessionId: 1, frames: kFrames1, markerAfter: markerAfter),
        DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true),
        startUptimeMs: kUp1,
        sessionId: 1,
      );
      await proc.processSegmentFile(
        makeBin('b2.bin',
            utcMs: kBase + kFrames1 * 20 + kGapMs, uptimeMs: uptime2, sessionId: session2, frames: kFrames2),
        DateTime.fromMillisecondsSinceEpoch(kBase + kFrames1 * 20 + kGapMs, isUtc: true),
        startUptimeMs: uptime2,
        sessionId: session2,
      );
      await proc.flushRemaining();
      await proc.destroy();
      return uptimesByStartOffset();
    }

    // The recording stays OPEN across the boundary: the gap is under the split
    // threshold and `chunk + gap` stays under the cap, so neither the split at :1090 nor
    // the inter-file cut at :1108 fires and the refs are still populated at bin entry —
    // which is what puts execution on the re-anchor branch at all. (Getting this wrong
    // is easy: a smaller cap takes the inter-file cut, empties the refs, and the
    // `_currentRefs.isEmpty` arm then sets the right answer for the wrong reason.)
    //
    // The cap then cuts 8 s into bin 2, and the recording that opens there must carry
    // bin 2's own uptime line. Without the re-anchor the counter is short by the whole
    // 30 s gap — a recording claiming to have begun before the bin it is made of.
    test('a recording opened after a stitched boundary is anchored to the new bin', () async {
      final uptimes = await runTwoBins(session2: 1, uptime2: kUp2);
      const cutOffset = kCapMs; // the cap cuts when the chunk reaches kCapMs
      expect(uptimes.containsKey(cutOffset), isTrue, reason: 'expected a cap cut inside bin 2, got ${uptimes.keys}');
      // Device truth: that instant is kFrames1*20 + kGapMs into bin 1's line, i.e.
      // 8 s past bin 2's header.
      const expected = (kUp2 + (kCapMs - kFrames1 * 20 - kGapMs)) ~/ 1000;
      expect(uptimes[cutOffset], expected,
          reason:
              'without the re-anchor this reads ${(kUp1 + kCapMs - kGapMs) ~/ 1000}s — short by the ${kGapMs ~/ 1000}s gap');
    });

    // The re-anchor is gated on the session id MATCHING, because uptime restarts at
    // zero every boot. A session change normally splits (emptying the refs and taking
    // the other arm), but `splitTriggered` is suppressed inside a marker window and
    // inside a Priority Recording — so a reboot there lands on the re-anchor with a
    // counter from the previous boot. Here a tap in bin 1 holds the 50 s window open
    // across the boundary, which is the reachable shape of that case.
    //
    // Adopting bin 2's near-zero uptime would hand the next recording a start uptime of
    // a few seconds, which the clock anchor then reads as the whole session being an
    // hour wrong.
    test('a bin from a DIFFERENT session never re-anchors the counter', () async {
      const int freshBootUptime = 5000; // the new boot is 5 s old
      final uptimes = await runTwoBins(session2: 2, uptime2: freshBootUptime, markerAfter: 50);
      for (final e in uptimes.entries) {
        expect(e.value * 1000, greaterThanOrEqualTo(kUp1),
            reason: 'recording at +${e.key}ms claims uptime ${e.value}s — it adopted the new boot\'s counter');
      }
    });
  });
}
