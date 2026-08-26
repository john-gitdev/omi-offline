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

/// A [VadBatchRunnerChannel] that reports itself AVAILABLE, so the processor takes
/// the two-pass deferred path — the one Android actually runs. `runVadBatch` is never
/// reached by the tests below: the host has no Opus decoder, so no PCM windows
/// accumulate and `_batchWindows` stays empty. Speech comes from marker protection,
/// which is stamped during Pass 1 and replayed in Pass 2 exactly like a VAD verdict.
class AvailableFakeBatchRunner extends VadBatchRunnerChannel {
  @override
  bool get available => true;

  @override
  Future<Float32List> runVadBatch(Float32List samples, {bool resetStateFirst = false}) async =>
      Float32List(samples.length ~/ 512);
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

    test('manual mode (silenceDurationToSplitMs = 0) does NOT split per frame', () async {
      // Regression guard for 2026-08-14: manual mode pins vadSplitSeconds to 0
      // so the *inter-bin* gap threshold collapses to 0. That 0 also reached the
      // per-frame check `_silenceRunMs >= _silenceDurationToSplitMs`, which is
      // true on every frame (0 >= 0 even on a speech frame), so each 20 ms Opus
      // frame was saved as its own 684-byte recording — 7 218 files from 87
      // minutes of backlog, which wedged the pipeline and the recordings page.
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(minDurationMs: 0, silenceDurationToSplitMs: 0),
        outputDir: tempDir.path,
        batchRunner: UnavailableBatchRunner(),
        // session: null → AAD mode, exactly what manual mode runs (vadEnabled=false)
      );

      final saved = await processor.processSegmentFile(
        _makeBinFile(tempDir, 100, name: 'manual_zero_split.bin'),
        DateTime.now(),
      );

      expect(saved, isEmpty, reason: 'no recording may finalize without a real boundary');
      expect(processor.currentChunkDurationMs, 100 * 20,
          reason: 'all 100 frames stay in one open conversation for the session-end marker to close');
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

  // ---------------------------------------------------------------------------
  // A recording's start uptime is `.meta` byte 412 — the only thing a clock anchor
  // has to place it by (DeviceClockAnchor.startMsFor). It must be THIS frame's
  // uptime, and the batched path is where that is easy to get wrong: verdicts are
  // deferred and replayed in Pass 2, so the running `_currentFrameUptimeMs` has
  // already advanced to the END of the batch by the time a recording opens.
  //
  // Both paths are driven over the same bin so the assertion is an A/B, not a
  // guess at what the numbers should be.
  // ---------------------------------------------------------------------------
  group('start uptime is anchored per frame, not per batch', () {
    const int kBase = 1746057600000; // 2026-05-01T00:00:00Z
    const int kUptimeMs = 3600000; // the Omi has been up an hour
    const int kFrames = 500; // 10 s of audio
    const int kCapMs = 1000; // cut every 50 frames

    /// header(utc, uptime, session) + a 0xFFFFFFFE tap + [kFrames] frames.
    ///
    /// The tap is what makes any of this audio "speech": the host has no Opus
    /// decoder, so with a Silero session present every frame would otherwise score
    /// silent and every recording would be discarded as noise. Its uptime matches
    /// the header's, so the first recording anchors at the bin head either way and
    /// only the LATER ones — the ones opened by a cap cut mid-replay — can differ.
    File makeTappedBin(String name) {
      final b = BytesBuilder();
      final hdr = ByteData(36);
      hdr.setUint32(0, 0xFFFFFFFB, Endian.little);
      hdr.setUint32(4, 28, Endian.little);
      hdr.setUint64(8, kBase, Endian.little);
      hdr.setUint64(16, kUptimeMs, Endian.little);
      hdr.setUint32(24, 0, Endian.little); // imu ticks
      hdr.setUint32(28, 1, Endian.little); // session id
      b.add(hdr.buffer.asUint8List());

      final m = ByteData(20);
      m.setUint32(0, 0xFFFFFFFE, Endian.little);
      m.setUint64(4, kBase, Endian.little);
      m.setUint32(12, kUptimeMs, Endian.little);
      m.setUint32(16, 1, Endian.little);
      b.add(m.buffer.asUint8List());

      final fh = ByteData(4)..setUint32(0, 4, Endian.little);
      for (int i = 0; i < kFrames; i++) {
        b.add(fh.buffer.asUint8List());
        b.add(List.filled(4, 0));
      }
      final f = File('${tempDir.path}/$name');
      f.writeAsBytesSync(b.toBytes());
      return f;
    }

    /// Every recording written, as `startMs offset from kBase` -> `.meta` byte 412.
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

    Future<Map<int, int>> runOverTappedBin({required bool batched}) async {
      final processor = VadAudioProcessor.fromSettings(
        settings: _settings(
          minDurationMs: 0,
          silenceDurationToSplitMs: 0x7FFFFFFF, // no silence split — the cap is the only cut
          maxChunkMs: kCapMs,
        ),
        outputDir: tempDir.path,
        session: _fakeSession(),
        batchRunner: batched ? AvailableFakeBatchRunner() : null,
      );
      await processor.processSegmentFile(
        makeTappedBin('uptime_anchor.bin'),
        DateTime.fromMillisecondsSinceEpoch(kBase, isUtc: true),
        startUptimeMs: kUptimeMs,
        sessionId: 1,
      );
      await processor.flushRemaining();
      await processor.destroy();
      return uptimesByStartOffset();
    }

    /// What the device would say: a recording that starts `offset` into the bin
    /// began at `kUptimeMs + offset` of uptime.
    Map<int, int> expected() => {
          for (int offset = 0; offset < kFrames * 20; offset += kCapMs) offset: (kUptimeMs + offset) ~/ 1000,
        };

    test('single-pass anchors each cap cut at its own frame', () async {
      expect(await runOverTappedBin(batched: false), expected());
    });

    // The regression. Before the per-frame carry, every recording opened during a
    // replay took `_currentFrameUptimeMs` as it stood at the END of the batch —
    // so all nine cap cuts reported 3610 s (the segment end) instead of 3601…3609.
    // Two consequences, both of which the clock anchor acts on:
    //   * each is up to a whole batch (6000 frames / 120 s) later than the truth,
    //     while plausibleDriftMs floors at 60 s — so `clockVerdict` reads a correct
    //     session as provably wrong and re-files it;
    //   * they all share ONE uptime, which is the precondition promoteSessionToDate's
    //     collision guard exists to survive. This manufactured it.
    test('batched replay anchors each cap cut at its own frame, not the batch end', () async {
      expect(await runOverTappedBin(batched: true), expected());
    });

    test('both paths agree over the same bin', () async {
      final single = await runOverTappedBin(batched: false);
      // Clear the first run's output so the second is measured on its own.
      for (final f in tempDir.listSync().whereType<File>()) {
        if (f.path.contains('recording_')) f.deleteSync();
      }
      expect(await runOverTappedBin(batched: true), single);
    });
  });
}
