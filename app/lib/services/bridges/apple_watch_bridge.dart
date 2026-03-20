import 'dart:typed_data';

import 'package:omi/gen/flutter_communicator.g.dart';

/// Public bridge that implements Pigeon callbacks and forwards them to Dart-side listeners.
class AppleWatchFlutterBridge implements WatchRecorderFlutterAPI {
  final void Function(Uint8List bytes, int segmentIndex, bool isLast, double sampleRate)? onSegment;
  final void Function()? onRecordingStartedCb;
  final void Function()? onRecordingStoppedCb;
  final void Function(String error)? onRecordingErrorCb;
  final void Function(bool granted)? onMicPermissionCb;
  final void Function(bool granted)? onMainAppMicPermissionCb;
  final void Function(double batteryLevel, int batteryState)? onBatteryUpdateCb;

  AppleWatchFlutterBridge({
    this.onSegment,
    this.onRecordingStartedCb,
    this.onRecordingStoppedCb,
    this.onRecordingErrorCb,
    this.onMicPermissionCb,
    this.onMainAppMicPermissionCb,
    this.onBatteryUpdateCb,
  });

  @override
  void onAudioData(Uint8List audioData) {}

  @override
  void onAudioSegment(Uint8List audioSegment, int segmentIndex, bool isLast, double sampleRate) {
    onSegment?.call(audioSegment, segmentIndex, isLast, sampleRate);
  }

  @override
  void onRecordingStarted() {
    onRecordingStartedCb?.call();
  }

  @override
  void onRecordingStopped() {
    onRecordingStoppedCb?.call();
  }

  @override
  void onRecordingError(String error) {
    onRecordingErrorCb?.call(error);
  }

  @override
  void onMicrophonePermissionResult(bool granted) {
    onMicPermissionCb?.call(granted);
  }

  @override
  void onMainAppMicrophonePermissionResult(bool granted) {
    onMainAppMicPermissionCb?.call(granted);
  }

  @override
  void onWatchBatteryUpdate(double batteryLevel, int batteryState) {
    onBatteryUpdateCb?.call(batteryLevel, batteryState);
  }
}
