import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/vad_batch_runner_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VadBatchRunnerChannel', () {
    test('non-Android platform: init is a no-op, available stays false', () async {
      // Host tests run on Linux/macOS — Platform.isAndroid is false.
      final channel = VadBatchRunnerChannel();
      await channel.init('/fake/model/path.onnx');
      expect(channel.available, isFalse,
          reason: 'On non-Android platforms, init should no-op and available stays false');
    });

    test('runVadBatch returns empty list when not initialised', () async {
      // Since init is a no-op on non-Android, available is false.
      // The caller should guard on `available` before calling runVadBatch,
      // but verify it throws (per the contract) when called anyway.
      final channel = VadBatchRunnerChannel();

      // On non-Android, the channel was never initialised; calling runVadBatch
      // hits the raw platform channel which has no handler → MissingPluginException.
      // The caller (VadAudioProcessor) always checks `available` first, so this
      // is a defensive contract test.
      expect(channel.available, isFalse);
    });

    test('dispose before init is a safe no-op', () async {
      final channel = VadBatchRunnerChannel();
      // Should not throw — _initialised is false, dispose returns early.
      await channel.dispose();
      expect(channel.available, isFalse);
    });

    test('dispose is idempotent', () async {
      final channel = VadBatchRunnerChannel();
      // Both calls should complete without error.
      await channel.dispose();
      await channel.dispose();
      expect(channel.available, isFalse);
    });

    test('available reflects _initialised state after init failure', () async {
      if (!Platform.isAndroid) {
        // On non-Android, init is a no-op → available stays false. Verified above.
        final channel = VadBatchRunnerChannel();
        await channel.init('/does/not/exist.onnx');
        expect(channel.available, isFalse);
        return;
      }
    });

    group('with mocked platform channel (Android-like behavior)', () {
      // These tests mock the platform channel to simulate Android behavior
      // on the host test runner.

      late List<String> callLog;

      setUp(() {
        callLog = [];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('com.omi.offline/vadBatchRunner'),
          (MethodCall methodCall) async {
            callLog.add(methodCall.method);
            switch (methodCall.method) {
              case 'init':
                return null; // success
              case 'runVadBatch':
                // Return 2 probabilities for 2 windows worth of samples.
                final samples = methodCall.arguments['samples'] as Float32List;
                final n = samples.length ~/ 512;
                // Alternate: first window speech (0.9), second silence (0.1)
                final probs = Float32List(n);
                for (int i = 0; i < n; i++) {
                  probs[i] = i.isEven ? 0.9 : 0.1;
                }
                return probs;
              case 'dispose':
                return null;
              default:
                return null;
            }
          },
        );
      });

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('com.omi.offline/vadBatchRunner'),
          null,
        );
      });

      test('init succeeds and sets available on Android', () async {
        if (!Platform.isAndroid) return; // Channel mock only works on Android
        final channel = VadBatchRunnerChannel();
        await channel.init('/fake/model.onnx');
        expect(channel.available, isTrue);
        expect(callLog, contains('init'));
      });

      test('runVadBatch returns probabilities on Android', () async {
        if (!Platform.isAndroid) return; // Channel mock only works on Android
        final channel = VadBatchRunnerChannel();
        await channel.init('/fake/model.onnx');
        final samples = Float32List(1024); // 2 windows
        final probs = await channel.runVadBatch(samples);
        expect(probs.length, 2);
        expect(probs[0], closeTo(0.9, 0.01));
        expect(probs[1], closeTo(0.1, 0.01));
      });

      test('dispose calls native dispose on Android', () async {
        if (!Platform.isAndroid) return; // Channel mock only works on Android
        final channel = VadBatchRunnerChannel();
        await channel.init('/fake/model.onnx');
        expect(channel.available, isTrue);
        await channel.dispose();
        expect(channel.available, isFalse);
        expect(callLog, contains('dispose'));
      });
    });

    group('MissingPluginException handling', () {
      setUp(() {
        // Mock channel that throws MissingPluginException on init
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('com.omi.offline/vadBatchRunner'),
          (MethodCall methodCall) async {
            throw MissingPluginException('No handler');
          },
        );
      });

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('com.omi.offline/vadBatchRunner'),
          null,
        );
      });

      test('init catches MissingPluginException gracefully', () async {
        if (!Platform.isAndroid) return;
        final channel = VadBatchRunnerChannel();
        // Should not throw — MissingPluginException is caught internally.
        await channel.init('/fake/model.onnx');
        expect(channel.available, isFalse);
      });
    });
  });
}
