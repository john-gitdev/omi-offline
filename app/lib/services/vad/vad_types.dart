import 'dart:convert';

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
  /// [SharedPreferencesUtil.processingModeSwitchHistory].
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

/// One recording-mode switch: when it happened, and the processing settings
/// that were live immediately BEFORE it.
///
/// A recording mode is a property of the audio, not of the toggle — the Omi
/// records for hours without the phone, and the processor reads the live prefs
/// at run time, so without this a backlog is re-cut by a mode it was never
/// recorded in. The history is the list of these, ascending: audio starting
/// before an entry's [atUtcSeconds] (and at or after the previous entry's) is
/// processed with that entry's [settings]; audio after the last entry uses the
/// current mode.
///
/// A list rather than a single "previous mode" because switches nest: flip
/// twice before the backlog drains and there are two boundaries in the audio,
/// each needing its own settings. Collapsing them to one loses the middle span.
class ModeSwitchRecord {
  /// Epoch SECONDS, to compare directly against the firmware `timerStart` in a
  /// bin's folder name. Written from the phone clock; the two are kept in step
  /// by the time-sync write on connect, so the residual error is clock drift —
  /// which can only misfile a bin that started within seconds of the switch.
  final int atUtcSeconds;

  /// The OUTGOING mode's settings. Captured before the mode flip, so
  /// `ProcessingSettings.fromPrefs()` still describes the mode being left.
  final ProcessingSettings settings;

  const ModeSwitchRecord({required this.atUtcSeconds, required this.settings});

  /// Bounds the stored history. Sixteen switches with an undrained backlog
  /// behind every one of them is not a real state; the cap exists so a bug or a
  /// user hammering the toggle can't grow a preference without limit. Overflow
  /// drops the OLDEST, whose audio then falls to the next entry's settings —
  /// degraded for the oldest span only, never unbounded.
  static const int maxEntries = 16;

  Map<String, dynamic> toJson() => {'at': atUtcSeconds, 'settings': settings.toJson()};

  factory ModeSwitchRecord.fromJson(Map<String, dynamic> j) => ModeSwitchRecord(
        atUtcSeconds: j['at'] as int,
        settings: ProcessingSettings.fromJson(Map<String, dynamic>.from(j['settings'] as Map)),
      );

  static String encode(List<ModeSwitchRecord> history) =>
      history.isEmpty ? '' : jsonEncode(history.map((e) => e.toJson()).toList());

  /// Never throws. A history that can't be read means every bin falls back to
  /// the current mode — the pre-history behaviour, degraded but not broken —
  /// and that is strictly better than an unreadable preference wedging the
  /// processing pipeline on every run.
  static List<ModeSwitchRecord> decode(String raw) {
    if (raw.isEmpty) return const [];
    try {
      final list =
          (jsonDecode(raw) as List).map((e) => ModeSwitchRecord.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      list.sort((a, b) => a.atUtcSeconds.compareTo(b.atUtcSeconds));
      return list;
    } catch (_) {
      return const [];
    }
  }

  /// Appends [entry] and re-sorts. Sorting rather than trusting append order
  /// covers a phone clock that steps backwards between two switches, which
  /// would otherwise leave the list unordered and break the ascending scan that
  /// assigns each bin to the first entry it predates.
  static List<ModeSwitchRecord> append(List<ModeSwitchRecord> history, ModeSwitchRecord entry) {
    final next = [...history, entry]..sort((a, b) => a.atUtcSeconds.compareTo(b.atUtcSeconds));
    return next.length <= maxEntries ? next : next.sublist(next.length - maxEntries);
  }

  /// Drops the leading entries that can no longer govern any audio.
  ///
  /// Only a PREFIX is ever dropped, and that is not a simplification — both
  /// conditions are monotone along the ascending list. An entry is older than
  /// every entry after it, so if it has aged out they have not; and
  /// `anyBinBefore` is monotone in the same direction, so if some bin predates
  /// entry i it also predates every later entry. The first entry that survives
  /// therefore proves every entry after it survives too.
  ///
  /// [anyBinBefore] must be answered from every raw bin on disk, NOT from the
  /// ones a given run is allowed to process: a bin still mid-transfer is
  /// pre-switch audio that the processable filter hides, and an interrupted
  /// sync handing over to processing is exactly when that happens.
  /// [lastSyncPartial] covers the other half — the Omi keeps recording while
  /// disconnected, so a cut-short sync means pre-switch files that have not
  /// reached the phone at all.
  ///
  /// [maxAgeSeconds] is the escape hatch. An Omi that is never fully drained
  /// would otherwise hold an entry forever, and every live entry is one more
  /// pass per processing run.
  static List<ModeSwitchRecord> retire({
    required List<ModeSwitchRecord> history,
    required int nowUtcSeconds,
    required bool Function(int atUtcSeconds) anyBinBefore,
    required bool lastSyncPartial,
    required int maxAgeSeconds,
  }) {
    int drop = 0;
    for (final e in history) {
      final aged = nowUtcSeconds - e.atUtcSeconds > maxAgeSeconds;
      final drained = !anyBinBefore(e.atUtcSeconds) && !lastSyncPartial;
      if (!aged && !drained) break;
      drop++;
    }
    return drop == 0 ? history : history.sublist(drop);
  }
}
