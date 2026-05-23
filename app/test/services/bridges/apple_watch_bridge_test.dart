import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/bridges/apple_watch_bridge.dart';

void main() {
  group('AppleWatchFlutterBridge', () {
    test('onAudioSegment correctly forwards arguments', () {
      bool called = false;
      final expectedBytes = Uint8List.fromList([1, 2, 3]);
      final expectedSegmentIndex = 2;
      final expectedIsLast = true;
      final expectedSampleRate = 16000.0;

      final bridge = AppleWatchFlutterBridge(
        onSegment: (bytes, segmentIndex, isLast, sampleRate) {
          called = true;
          expect(bytes, expectedBytes);
          expect(segmentIndex, expectedSegmentIndex);
          expect(isLast, expectedIsLast);
          expect(sampleRate, expectedSampleRate);
        },
      );

      bridge.onAudioSegment(expectedBytes, expectedSegmentIndex, expectedIsLast, expectedSampleRate);
      expect(called, isTrue);
    });

    test('onRecordingStarted correctly forwards arguments', () {
      bool called = false;
      final bridge = AppleWatchFlutterBridge(
        onRecordingStartedCb: () {
          called = true;
        },
      );
      bridge.onRecordingStarted();
      expect(called, isTrue);
    });

    test('onRecordingStopped correctly forwards arguments', () {
      bool called = false;
      final bridge = AppleWatchFlutterBridge(
        onRecordingStoppedCb: () {
          called = true;
        },
      );
      bridge.onRecordingStopped();
      expect(called, isTrue);
    });

    test('onRecordingError correctly forwards arguments', () {
      bool called = false;
      final expectedError = 'test error';
      final bridge = AppleWatchFlutterBridge(
        onRecordingErrorCb: (error) {
          called = true;
          expect(error, expectedError);
        },
      );
      bridge.onRecordingError(expectedError);
      expect(called, isTrue);
    });

    test('onMicrophonePermissionResult correctly forwards arguments', () {
      bool called = false;
      final expectedGranted = true;
      final bridge = AppleWatchFlutterBridge(
        onMicPermissionCb: (granted) {
          called = true;
          expect(granted, expectedGranted);
        },
      );
      bridge.onMicrophonePermissionResult(expectedGranted);
      expect(called, isTrue);
    });

    test('onMainAppMicrophonePermissionResult correctly forwards arguments', () {
      bool called = false;
      final expectedGranted = false;
      final bridge = AppleWatchFlutterBridge(
        onMainAppMicPermissionCb: (granted) {
          called = true;
          expect(granted, expectedGranted);
        },
      );
      bridge.onMainAppMicrophonePermissionResult(expectedGranted);
      expect(called, isTrue);
    });

    test('onWatchBatteryUpdate correctly forwards arguments', () {
      bool called = false;
      final expectedBatteryLevel = 0.85;
      final expectedBatteryState = 2;
      final bridge = AppleWatchFlutterBridge(
        onBatteryUpdateCb: (batteryLevel, batteryState) {
          called = true;
          expect(batteryLevel, expectedBatteryLevel);
          expect(batteryState, expectedBatteryState);
        },
      );
      bridge.onWatchBatteryUpdate(expectedBatteryLevel, expectedBatteryState);
      expect(called, isTrue);
    });

    test('callbacks are optional and do not crash if not provided', () {
      final bridge = AppleWatchFlutterBridge();
      // Should not throw any exception
      bridge.onAudioData(Uint8List.fromList([]));
      bridge.onAudioSegment(Uint8List.fromList([]), 0, false, 16000.0);
      bridge.onRecordingStarted();
      bridge.onRecordingStopped();
      bridge.onRecordingError('error');
      bridge.onMicrophonePermissionResult(true);
      bridge.onMainAppMicrophonePermissionResult(true);
      bridge.onWatchBatteryUpdate(0.5, 1);
    });
  });
}
