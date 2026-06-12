import 'package:omi/backend/preferences.dart';

/// Thrown from inside the `VadAudioProcessor` decode loop when the caller-supplied
/// `isCancelled` callback flips to true. The isolate entry catches this as a
/// clean abort (no error message, no draft flush) so the watchdog never has to
/// force-kill the isolate — an `Isolate.kill(immediate)` while parked in an
/// ONNX/Opus FFI call corrupts native state and takes the whole app down.
class VadProcessingCancelled implements Exception {
  const VadProcessingCancelled();
  @override
  String toString() => 'VadProcessingCancelled';
}

/// All VAD/processing settings captured from SharedPreferences in the main isolate
/// before spawning the processing isolate. All fields are primitives — safe to send
/// across isolate boundaries.
class ProcessingSettings {
  final bool vadEnabled;
  final double speechThreshold;
  final int silenceDurationToSplitMs;
  final int minDurationMs;
  final int minSpeechMs;
  final int maxChunkMs;
  final String deviceId; // used to generate upload key in .meta sidecar
  final String audioSaveFormat;
  final bool omiEnabled;

  const ProcessingSettings({
    required this.vadEnabled,
    required this.speechThreshold,
    required this.silenceDurationToSplitMs,
    required this.minDurationMs,
    required this.minSpeechMs,
    required this.maxChunkMs,
    required this.deviceId,
    required this.audioSaveFormat,
    required this.omiEnabled,
  });

  factory ProcessingSettings.fromPrefs() {
    final p = SharedPreferencesUtil();
    return ProcessingSettings(
      vadEnabled: p.vadEnabled,
      speechThreshold: p.vadSpeechThreshold,
      silenceDurationToSplitMs: p.vadSplitSeconds * 1000,
      minDurationMs: p.filterMinDurationSeconds * 1000,
      minSpeechMs: p.vadMinSpeechSeconds * 1000,
      maxChunkMs: p.vadMaxConversationMinutes == 0 ? 0x7FFFFFFFFFFFFFFF : p.vadMaxConversationMinutes * 60 * 1000,
      deviceId: p.btDevice.id,
      audioSaveFormat: p.audioSaveFormat,
      omiEnabled: p.omiEnabled,
    );
  }
}
