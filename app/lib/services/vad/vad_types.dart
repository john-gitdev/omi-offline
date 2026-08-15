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
  // Firmware Priority Recording safety cap in minutes (0x19B10014); 0 = no cap.
  // Bounds a restored priority latch whose 0xFFFFFFFC stop was lost, so a runaway
  // force-capture can't keep swallowing auto recordings. See VadAudioProcessor.
  final int priorityRecordCapMinutes;

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
    required this.priorityRecordCapMinutes,
  });

  /// Round-trips through SharedPreferences so a mode switch can freeze the
  /// OUTGOING mode's settings and keep processing the audio recorded under them
  /// with them. Only the fields that change how audio is cut have to survive —
  /// but all of them are written, since a partial snapshot is the kind of thing
  /// that silently rots when a field is added. See
  /// [SharedPreferencesUtil.processingPreSwitchSettings].
  Map<String, dynamic> toJson() => {
        'vadEnabled': vadEnabled,
        'speechThreshold': speechThreshold,
        'silenceDurationToSplitMs': silenceDurationToSplitMs,
        'minDurationMs': minDurationMs,
        'minSpeechMs': minSpeechMs,
        'maxChunkMs': maxChunkMs,
        'deviceId': deviceId,
        'audioSaveFormat': audioSaveFormat,
        'omiEnabled': omiEnabled,
        'priorityRecordCapMinutes': priorityRecordCapMinutes,
      };

  /// Inverse of [toJson]. Every field falls back to the live pref rather than a
  /// hardcoded default, so a snapshot written by an older build (missing a field
  /// added since) degrades to current behaviour for that field instead of
  /// inventing one.
  factory ProcessingSettings.fromJson(Map<String, dynamic> j) {
    final live = ProcessingSettings.fromPrefs();
    return ProcessingSettings(
      vadEnabled: j['vadEnabled'] as bool? ?? live.vadEnabled,
      speechThreshold: (j['speechThreshold'] as num?)?.toDouble() ?? live.speechThreshold,
      silenceDurationToSplitMs: j['silenceDurationToSplitMs'] as int? ?? live.silenceDurationToSplitMs,
      minDurationMs: j['minDurationMs'] as int? ?? live.minDurationMs,
      minSpeechMs: j['minSpeechMs'] as int? ?? live.minSpeechMs,
      maxChunkMs: j['maxChunkMs'] as int? ?? live.maxChunkMs,
      deviceId: j['deviceId'] as String? ?? live.deviceId,
      audioSaveFormat: j['audioSaveFormat'] as String? ?? live.audioSaveFormat,
      omiEnabled: j['omiEnabled'] as bool? ?? live.omiEnabled,
      priorityRecordCapMinutes: j['priorityRecordCapMinutes'] as int? ?? live.priorityRecordCapMinutes,
    );
  }

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
      priorityRecordCapMinutes: p.priorityRecordMaxMinutes,
    );
  }
}
