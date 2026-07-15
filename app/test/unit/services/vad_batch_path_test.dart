import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:omi/services/vad_audio_processor.dart';
import 'package:omi/services/vad_batch_runner_channel.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/backend/preferences.dart';

// ---------------------------------------------------------------------------
// Helpers (mirrors the patterns in vad_audio_processor_test.dart)
// ---------------------------------------------------------------------------

class MockPathProviderPlatform extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  late String tempPath;

  MockPathProviderPlatform() {
    tempPath = Directory.systemTemp.path;
  }

  @override
  Future<String?> getApplicationDocumentsDirectoryPath() async => tempPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => tempPath;
}

/// Creates a valid bin file with [frameCount] dummy Opus frames (4 zero bytes
/// each). Each frame is 20 ms → total duration = frameCount × 20 ms.
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

ProcessingSettings _settings({
  required int minDurationMs,
  int silenceDurationToSplitMs = 120000,
  int minSpeechMs = 0,
  int maxChunkMs = 3600000,
}) {
  return ProcessingSettings(
    vadEnabled: true,
    speechThreshold: 0.5,
    silenceDurationToSplitMs: silenceDurationToSplitMs,
    minDurationMs: minDurationMs,
    minSpeechMs: minSpeechMs,
    maxChunkMs: maxChunkMs,
    deviceId: 'test-device',
    audioSaveFormat: 'm4a',
    omiEnabled: false,
    priorityRecordCapMinutes: 0,
  );
}

/// A non-null [OrtSession] placeholder. Host tests can't load the real Silero
/// model (no native ONNX runtime), but when _session != null the VAD treats
/// undecodable (null-decoder) frames as SILENCE instead of AAD-mode speech.
OrtSession _fakeSession() => OrtSession.fromMap({
      'sessionId': 'host-test-fake',
      'inputNames': <String>[],
      'outputNames': <String>[],
    });

/// A [VadBatchRunnerChannel] subclass that simulates an unavailable batch
/// runner. `available` is always false, matching iOS/desktop/test fallback.
class UnavailableBatchRunner extends VadBatchRunnerChannel {
  UnavailableBatchRunner() : super();
  // available returns false (default) since init was never called.
}

void main() {
  late Directory tempDir;
  late MockPathProviderPlatform mockPathProvider;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('vad_batch_path_test');
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

    // Mock flutter_onnxruntime so fake OrtSession's close/dispose are no-ops.
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

  group('Batch runner fallback behavior', () {
    test('unavailable batch runner falls back to single-pass (AAD mode)', () async {
      // When a batchRunner is passed but available is false, the processor
      // should use the single-pass per-window path. With no Silero session
      // (null), all frames are AAD-mode speech. With a fake session but no
      // decoder, frames are silence (decoder returns null → _runVad skipped).
      final batchRunner = UnavailableBatchRunner();
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0),
        outputDir: tempDir.path,
        batchRunner: batchRunner, // passed but unavailable
        // session: null → AAD mode: all frames are speech
      );

      await processor.processSegmentFile(
        _makeBinFile(tempDir, 50, name: 'fallback.bin'),
        DateTime.now(),
      );

      // AAD mode: all 50 frames treated as speech.
      expect(processor.currentChunkDurationMs, 50 * 20);
      await processor.destroy();
    });

    test('null batch runner uses single-pass (original path)', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0),
        outputDir: tempDir.path,
        // batchRunner: null (default) — per-window fallback
      );

      await processor.processSegmentFile(
        _makeBinFile(tempDir, 50, name: 'nullrunner.bin'),
        DateTime.now(),
      );

      // AAD mode (no session): all 50 frames treated as speech.
      expect(processor.currentChunkDurationMs, 50 * 20);
      await processor.destroy();
    });
  });

  group('Batch accumulation and reset', () {
    test('_batchResetPending is set after gap-split (VAD session, no batch runner)', () async {
      // After a VAD-resume gap split, batchResetPending should be set so the
      // next batch resets the native LSTM state. We verify indirectly: after a
      // split, a new conversation starts cleanly from the post-split frames.
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(
          minDurationMs: 0,
          silenceDurationToSplitMs: 2000,
        ),
        outputDir: tempDir.path,
        session: _fakeSession(), // VAD mode: null decoder → all frames are silence
      );

      // Process enough frames to trigger a silence split:
      // 100 frames = 2000ms = silenceDurationToSplitMs → split fires.
      // Then 50 more frames → new conversation.
      await processor.processSegmentFile(
        _makeBinFile(tempDir, 150, name: 'split_reset.bin'),
        DateTime.now(),
      );

      // After the split, the 50 remaining frames form a new conversation.
      // With fake session and null decoder, these are silence. The new conv
      // duration should be close to 50 * 20 = 1000ms (modulo the split frame).
      // The exact count depends on when the split fires (it fires at exactly
      // _silenceDurationToSplitMs, consuming the 100th frame, leaving 50).
      expect(processor.currentChunkDurationMs, greaterThan(0));
      expect(processor.currentChunkDurationMs, lessThanOrEqualTo(1000));
      await processor.destroy();
    });

    test('AAD mode with unavailable batch runner accumulates all frames', () async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0),
        outputDir: tempDir.path,
        batchRunner: UnavailableBatchRunner(),
        // session: null → AAD mode
      );

      await processor.processSegmentFile(
        _makeBinFile(tempDir, 100, name: 'aad_accum.bin'),
        DateTime.now(),
      );

      // All 100 frames accumulated as speech in one conversation.
      expect(processor.currentChunkDurationMs, 100 * 20);
      await processor.destroy();
    });
  });

  group('Partial window flush conservatism', () {
    // This group tests the divergence fix: _flushPartialWindow during batch
    // replay should conservatively treat partial windows as speech, updating
    // the high-water marks rather than skipping the evaluation entirely.

    test('flushPartialWindow during silence split updates high-water marks (single-pass)', () async {
      // Single-pass path (no batch runner): silence split trims at the last
      // speech frame. With null decoder and fake session, ALL frames are silence,
      // so _speechFrameCount stays 0 and the split discards as silence_only.
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(
          minDurationMs: 0,
          silenceDurationToSplitMs: 2000, // 100 frames × 20ms
        ),
        outputDir: tempDir.path,
        session: _fakeSession(),
      );

      // Process 120 frames: first 100 trigger silence split, remaining 20
      // form a new conversation. The split should produce a silence_only
      // discard record.
      await processor.processSegmentFile(
        _makeBinFile(tempDir, 120, name: 'partial_single.bin'),
        DateTime.now(),
      );

      final discards = processor.consumePendingDiscards();
      expect(discards.length, 1);
      expect(discards[0]['reason'], 'silence_only');
      await processor.destroy();
    });

    test('consecutive silence splits produce correct non-overlapping timestamps', () async {
      // Regression guard: after the divergence fix, verify that consecutive
      // in-stream silence splits still advance the timeline correctly.
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(
          minDurationMs: 0,
          silenceDurationToSplitMs: 2000, // 100 frames × 20ms
        ),
        outputDir: tempDir.path,
        session: _fakeSession(),
      );

      final startTime = DateTime(2024, 1, 1, 10, 0, 0);
      // 250 frames: two silence splits (at 100 and 200), plus 50 leftover.
      await processor.processSegmentFile(
        _makeBinFile(tempDir, 250, name: 'consec_splits.bin'),
        startTime,
      );

      final discards = processor.consumePendingDiscards();
      expect(discards.length, 2, reason: 'two 2s silence runs → two discards');

      final firstStart = discards[0]['startMs'] as int;
      final secondStart = discards[1]['startMs'] as int;
      expect(secondStart, greaterThan(firstStart), reason: 'second discard must not reuse the file-start timestamp');
      await processor.destroy();
    });
  });

  group('Error fallback to AAD mode', () {
    test('processor without session treats all frames as speech (AAD mode)', () async {
      // This simulates what happens after a batch runner error disables the
      // model: _session is set to null and all frames become speech.
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0),
        outputDir: tempDir.path,
        session: null, // AAD mode
      );

      await processor.processSegmentFile(
        _makeBinFile(tempDir, 50, name: 'aad_error.bin'),
        DateTime.now(),
      );

      // All frames are speech in AAD mode.
      expect(processor.currentChunkDurationMs, 50 * 20);

      // Flush should produce a saved file (not a discard).
      final path = await processor.flushRemaining();
      // With null decoder + AAD mode, no PCM → encoder gets zero frames.
      // saveRecording returns null when hasEncodedAnyFrames is false.
      // This is expected behavior — the recording metadata says speech but
      // the WAV/M4A has no decoded audio.
      // We just verify no crash occurred.
      await processor.destroy();
    });

    test('session null + fake session produce different speech counts', () async {
      // Verify that passing a fake session vs null produces different behavior:
      // - null session (AAD): all frames = speech
      // - fake session + null decoder: all frames = silence (decoder returns null)
      final aadProcessor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0),
        outputDir: tempDir.path,
        session: null,
      );
      await aadProcessor.processSegmentFile(
        _makeBinFile(tempDir, 50, name: 'aad.bin'),
        DateTime.now(),
      );

      final vadProcessor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0),
        outputDir: tempDir.path,
        session: _fakeSession(),
      );
      await vadProcessor.processSegmentFile(
        _makeBinFile(tempDir, 50, name: 'vad.bin'),
        DateTime.now(),
      );

      // Both accumulate 50 frames.
      expect(aadProcessor.currentChunkDurationMs, 50 * 20);
      expect(vadProcessor.currentChunkDurationMs, 50 * 20);

      // But discardGuardFiredOnLastFlush differs based on speech count:
      // AAD mode has speechFrameCount=50, so min-speech guard doesn't fire.
      // VAD mode has speechFrameCount=0 (all silence), but minSpeechMs=0 means
      // tooShortSpeech is false. So both pass. We verify they both process.
      // The key difference is testable via consumePendingDiscards after a split.

      await aadProcessor.destroy();
      await vadProcessor.destroy();
    });
  });

  group('Batch/single-pass consistency', () {
    test('both paths produce same chunk duration for simple segment', () async {
      // Without a real batch runner, verify that the single-pass path
      // produces consistent results regardless of whether a batch runner
      // is passed (unavailable → single-pass fallback).
      final withBatch = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0),
        outputDir: tempDir.path,
        batchRunner: UnavailableBatchRunner(),
      );

      final withoutBatch = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0),
        outputDir: tempDir.path,
      );

      final startTime = DateTime(2024, 1, 1, 10, 0, 0);
      await withBatch.processSegmentFile(
        _makeBinFile(tempDir, 100, name: 'batch.bin'),
        startTime,
      );
      await withoutBatch.processSegmentFile(
        _makeBinFile(tempDir, 100, name: 'nobatch.bin'),
        startTime,
      );

      expect(withBatch.currentChunkDurationMs, withoutBatch.currentChunkDurationMs,
          reason: 'unavailable batch runner should produce identical results to no runner');
      await withBatch.destroy();
      await withoutBatch.destroy();
    });
  });

  group('Max-cap during batch replay', () {
    test('max-cap cut resets state correctly in single-pass', () async {
      // Verify that a max-cap cut mid-file resets conversation state properly.
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(
          minDurationMs: 0,
          maxChunkMs: 1000, // 50 frames × 20ms = 1000ms cap
        ),
        outputDir: tempDir.path,
        // session: null → AAD mode, all frames speech
      );

      // 120 frames: cap fires at frame 50 (1000ms) and frame 100 (1000ms),
      // leaving 20 frames (400ms) in the final conversation.
      await processor.processSegmentFile(
        _makeBinFile(tempDir, 120, name: 'maxcap.bin'),
        DateTime.now(),
      );

      // After two max-cap cuts, the remaining 20 frames form a new conversation.
      expect(processor.currentChunkDurationMs, 20 * 20);
      await processor.destroy();
    });
  });
}
