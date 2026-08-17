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

  /// Which recording mode this audio was captured in, stamped into the `.meta`
  /// so the recordings list can say `Manual` / `Auto/VAD` / `Auto/AAD` instead of
  /// the bare codec label. Purely descriptive — nothing in the processing path
  /// branches on it, and it must stay that way: the flat vad* fields above are
  /// what actually decide how audio is cut, and a second source of truth for the
  /// same decision is the 2026-08-14 split-state bug waiting to happen.
  ///
  /// **Nullable, meaning "not known".** Not every construction site has an
  /// honest answer: discard recovery (RecordingsController.recoverDiscard)
  /// hand-builds a synthetic settings object to re-derive one span, and the mode
  /// that span was recorded in is not recoverable from a discard record. Null
  /// there leaves the mode bits unwritten, which renders as the pre-feature
  /// label rather than a confident guess. A non-nullable field with a default
  /// would have stamped every recovered discard with whatever that default was.
  final bool? manual;

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
    this.manual,
  });

  /// The mode-shaped half of these settings — the six fields a recording-mode
  /// switch actually changes. See [ModeSettings].
  ModeSettings get mode => ModeSettings(
        vadEnabled: vadEnabled,
        speechThreshold: speechThreshold,
        silenceDurationToSplitMs: silenceDurationToSplitMs,
        minDurationMs: minDurationMs,
        minSpeechMs: minSpeechMs,
        maxChunkMs: maxChunkMs,
        manual: manual,
      );

  /// These settings with the mode-shaped fields replaced by [m].
  ///
  /// The remaining fields — device id, save format, integration flag, priority
  /// cap — are global, not per-mode, so they always come from the LIVE values
  /// here. Freezing them alongside the mode would keep processing a backlog with
  /// a replaced Omi's id, or writing a file format the user has since changed
  /// away from.
  ///
  /// [manual] comes from [m], not from here: it is the most mode-shaped field
  /// there is, and the whole point of a pass is that its audio predates the
  /// switch. Taking the live value would label a pre-switch backlog with the
  /// mode the user just moved to — the exact mislabelling the history exists to
  /// stop, only in the sidecar instead of the cut.
  ProcessingSettings withMode(ModeSettings m) => ProcessingSettings(
        vadEnabled: m.vadEnabled,
        speechThreshold: m.speechThreshold,
        silenceDurationToSplitMs: m.silenceDurationToSplitMs,
        minDurationMs: m.minDurationMs,
        minSpeechMs: m.minSpeechMs,
        maxChunkMs: m.maxChunkMs,
        deviceId: deviceId,
        audioSaveFormat: audioSaveFormat,
        omiEnabled: omiEnabled,
        priorityRecordCapMinutes: priorityRecordCapMinutes,
        manual: m.manual,
      );

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
      manual: p.manualMode,
    );
  }
}

/// The settings a recording mode decides — and nothing else.
///
/// Split out from [ProcessingSettings] so a mode switch stores six numbers
/// instead of a whole frozen configuration. The fields left behind (device id,
/// save format, integration flag, priority cap) are global: they have nothing to
/// do with which mode you are in, and freezing them would mean a backlog carried
/// on using a replaced Omi's id or an abandoned file format.
class ModeSettings {
  final bool vadEnabled;
  final double speechThreshold;
  final int silenceDurationToSplitMs;
  final int minDurationMs;
  final int minSpeechMs;
  final int maxChunkMs;

  /// The mode LABEL for this span — see [ProcessingSettings.manual]. Carried
  /// here rather than inferred from the numbers because inference collides:
  /// manual is `vadEnabled=false, split=0, minSpeech=0`, and an auto mode with
  /// Silero switched off and the split set to 0 is a legal configuration that
  /// looks identical.
  ///
  /// Null = not known, which is what an entry written before this field existed
  /// decodes to. Alone among these fields it does **not** fall back to the live
  /// value in [fromJson] — see the note there.
  final bool? manual;

  const ModeSettings({
    required this.vadEnabled,
    required this.speechThreshold,
    required this.silenceDurationToSplitMs,
    required this.minDurationMs,
    required this.minSpeechMs,
    required this.maxChunkMs,
    this.manual,
  });

  Map<String, dynamic> toJson() => {
        'vadEnabled': vadEnabled,
        'speechThreshold': speechThreshold,
        'silenceDurationToSplitMs': silenceDurationToSplitMs,
        'minDurationMs': minDurationMs,
        'minSpeechMs': minSpeechMs,
        'maxChunkMs': maxChunkMs,
        'manual': manual,
      };

  /// A field missing from an older build's stored entry falls back to the live
  /// value, so the entry degrades to current behaviour for that one field rather
  /// than inventing a default.
  ///
  /// **[manual] is the exception, and must stay one.** That rule works for the
  /// other six because they are *behaviours*: a missing one degrades to how the
  /// app behaves today, which is defensible. [manual] is a *claim about the
  /// past* — which mode this already-recorded audio was captured in — so the
  /// live value does not degrade it, it fabricates it. Concretely: an entry
  /// written by a build without this field is re-hydrated on the next decode,
  /// and `_recordModeSwitch` decodes the history before flipping
  /// `prefs.manualMode`, so the live value there is the OUTGOING mode. An entry
  /// recorded two switches ago would be stamped with it and written straight
  /// back — durably relabelling a backlog with a mode it was never recorded in,
  /// which is the whole failure the switch history exists to prevent. Null
  /// leaves the `.meta` mode bits unwritten and the row falls back to its
  /// pre-feature label.
  factory ModeSettings.fromJson(Map<String, dynamic> j) {
    final live = ProcessingSettings.fromPrefs().mode;
    return ModeSettings(
      vadEnabled: j['vadEnabled'] as bool? ?? live.vadEnabled,
      speechThreshold: (j['speechThreshold'] as num?)?.toDouble() ?? live.speechThreshold,
      silenceDurationToSplitMs: j['silenceDurationToSplitMs'] as int? ?? live.silenceDurationToSplitMs,
      minDurationMs: j['minDurationMs'] as int? ?? live.minDurationMs,
      minSpeechMs: j['minSpeechMs'] as int? ?? live.minSpeechMs,
      maxChunkMs: j['maxChunkMs'] as int? ?? live.maxChunkMs,
      manual: j['manual'] as bool?, // no live fallback — see above
    );
  }
}

/// One recording-mode switch: when it happened, and the mode settings that were
/// live immediately BEFORE it.
///
/// A recording mode is a property of the audio, not of the toggle — the Omi
/// records for hours without the phone, and the processor reads the live prefs
/// at run time, so without this a backlog is re-cut by a mode it was never
/// recorded in. The history is the list of these, ascending: audio starting
/// before an entry's [atUtcSeconds] (and at or after the previous entry's) is
/// processed with that entry's [settings]; audio after the last entry uses the
/// current mode.
///
/// A list rather than a single "previous mode" because switches nest: flip twice
/// before the backlog drains and there are two boundaries in the audio, each
/// needing its own settings. Collapsing them to one loses the middle span.
///
/// **An entry is only ever dropped when dropping it cannot matter.** An earlier
/// version expired entries once the backlog looked drained, and that produced
/// two of this feature's bugs — a bin still downloading is invisible to the run
/// that would have expired its entry, and an Omi that has not finished syncing
/// still holds audio from before the switch. Both meant a late arrival fell back
/// to the wrong mode and was KEPT that way, which is the entire failure this
/// exists to stop. What survives is [retireBefore], which drops an entry only
/// on evidence that no late arrival is possible (or that one would be deleted
/// rather than kept), and [maxEntries], which bounds the list. Absent that
/// evidence an entry lives indefinitely — it costs one list filter per run and
/// cannot be wrong, since it only ever governs audio older than itself and
/// matches nothing once none exists.
class ModeSwitchRecord {
  /// Epoch SECONDS, to compare directly against the firmware `timerStart` in a
  /// bin's folder name. Written from the phone clock; the two are kept in step
  /// by the time-sync write on connect, so the residual error is clock drift —
  /// which can only misfile a bin that started within seconds of the switch.
  final int atUtcSeconds;

  /// The OUTGOING mode's settings. Captured before the mode flip, so
  /// `ProcessingSettings.fromPrefs()` still describes the mode being left.
  final ModeSettings settings;

  const ModeSwitchRecord({required this.atUtcSeconds, required this.settings});

  /// Bounds the stored history, and is the only thing that ever removes an
  /// entry. Sixteen switches with undrained audio behind every one of them is
  /// not a real state; the cap exists so a bug or a user hammering the toggle
  /// can't grow a preference without limit. Overflow drops the OLDEST, whose
  /// audio then falls to the next entry's settings — degraded for the oldest
  /// span only, never unbounded.
  static const int maxEntries = 16;

  Map<String, dynamic> toJson() => {'at': atUtcSeconds, 'settings': settings.toJson()};

  factory ModeSwitchRecord.fromJson(Map<String, dynamic> j) => ModeSwitchRecord(
        atUtcSeconds: j['at'] as int,
        settings: ModeSettings.fromJson(Map<String, dynamic>.from(j['settings'] as Map)),
      );

  static String encode(List<ModeSwitchRecord> history) =>
      history.isEmpty ? '' : jsonEncode(history.map((e) => e.toJson()).toList());

  /// Never throws. A history that can't be read means every bin falls back to
  /// the current mode — the pre-history behaviour, degraded but not broken — and
  /// that is strictly better than an unreadable preference wedging the
  /// processing pipeline on every run. The caller reports and clears it.
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

  /// Drops every entry at or before [watermarkUtcSeconds] — the point before
  /// which no audio can still need its own settings. Null means there is no
  /// evidence yet and nothing is dropped.
  ///
  /// An entry governs only audio recorded strictly BEFORE its stamp, so an entry
  /// AT the watermark governs nothing and goes too. Ascending order makes this a
  /// prefix drop.
  ///
  /// The caller supplies the watermark; see
  /// RecordingsController.\_retirementWatermarkUtcSeconds for the two things that
  /// can establish one. What matters here is the shape of the guarantee: this is
  /// the safe form of a rule an earlier design got wrong. That version retired an
  /// entry as soon as its backlog *looked* processed, so a late arrival — a bin
  /// still downloading, or one the Omi had not handed over — was cut by the wrong
  /// mode and KEPT. A watermark is a statement that no such late arrival is
  /// possible, or that if one comes it will be deleted rather than kept. Retire
  /// only on evidence of that kind.
  static List<ModeSwitchRecord> retireBefore(List<ModeSwitchRecord> history, int? watermarkUtcSeconds) {
    if (watermarkUtcSeconds == null || history.isEmpty) return history;
    final kept = history.where((e) => e.atUtcSeconds > watermarkUtcSeconds).toList();
    return kept.length == history.length ? history : kept;
  }

  /// Appends [entry] and re-sorts. Sorting rather than trusting append order
  /// covers a phone clock that steps backwards between two switches, which would
  /// otherwise leave the list unordered and break the ascending scan that assigns
  /// each bin to the first entry it predates.
  static List<ModeSwitchRecord> append(List<ModeSwitchRecord> history, ModeSwitchRecord entry) {
    final next = [...history, entry]..sort((a, b) => a.atUtcSeconds.compareTo(b.atUtcSeconds));
    return next.length <= maxEntries ? next : next.sublist(next.length - maxEntries);
  }
}
