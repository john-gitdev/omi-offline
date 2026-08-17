import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omi/backend/preferences.dart';
import 'package:omi/utils/other/time_utils.dart';

/// Parsed metadata for a single processed recording (M4A or WAV).
class Conversation {
  final File file;
  final DateTime startTime;
  final Duration duration;
  final String? uploadKey;
  final int? sessionId;
  final int? startUptime;
  // True when the audio was uploaded to an integration and the local file was
  // deleted. Only the .meta sidecar remains; the conversation cannot be played.
  final bool passthrough;
  final bool forceSynced;
  // True iff VAD ended this recording at the max-duration cap (vadMaxConversationMinutes)
  // rather than because of detected silence. pruneConsumedBins uses this to decide whether
  // raw bin files extending past rec_end may be safely deleted (silence-ended) or must be
  // preserved (cap-ended, since bin tail may hold the post-cap continuation).
  //
  // Defaults to true so that old recordings whose .meta predates the flag are treated
  // conservatively (no aggressive pruning past rec_end).
  final bool capEnded;
  final bool? isSilero;

  /// The recording mode this audio was captured in: true manual, false auto,
  /// null "not recorded". Stamped by `VadAudioProcessor._saveMetadata` into flag
  /// byte [3] as a modeKnown/manual pair — two bits precisely so null stays
  /// expressible, since every `.meta` written before this reads 0 and a single
  /// bit would relabel the whole back catalogue as one mode.
  ///
  /// Distinct from [isSilero], which is not the mode: it records whether a
  /// Silero session loaded, and is false for manual mode, for auto with Silero
  /// switched off, AND for auto where the model failed to load.
  final bool? recordedManual;
  final List<String> relativeBins;

  const Conversation({
    required this.file,
    required this.startTime,
    required this.duration,
    this.uploadKey,
    this.sessionId,
    this.startUptime,
    this.passthrough = false,
    this.forceSynced = false,
    this.capEnded = true,
    this.isSilero,
    this.recordedManual,
    this.relativeBins = const [],
  });

  /// Decodes the mode pair out of `.meta` flag byte [3]. modeKnown (0x08) gates
  /// manual (0x10), so an unstamped byte answers null rather than "auto".
  static bool? modeFromFlagByte(int flagByte) => (flagByte & 0x08) == 0 ? null : (flagByte & 0x10) != 0;

  DateTime get endTime => startTime.add(duration);

  /// True when this recording was saved with an unknown timestamp (device had no RTC sync).
  bool get isUnknown {
    final name = file.path.split('/').last;
    return name.startsWith('unknown_') || name.startsWith('session_');
  }

  int get fileSizeBytes {
    try {
      return file.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  /// Parses start time from the filename (`recording_<millis>.m4a` or `.wav`) and
  /// reads duration from the `.meta` sidecar if present, otherwise falls back to
  /// WAV file size calculation.
  static Conversation fromFile(File file) {
    final name = file.path.split('/').last;
    final nameNoExt = name.split('.').first;
    final parts = nameNoExt.split('_');

    // Format: recording_<ts> or recording_<ts>_draft
    int? millis;
    if (parts.length >= 2) {
      // Find the first part that is a long numeric timestamp (e.g. seconds or millis)
      for (final p in parts) {
        final val = int.tryParse(p);
        if (val != null && val > 0) {
          millis = val;
          break;
        }
      }
    }

    DateTime startTime;
    if (millis != null && millis > 0) {
      startTime = DateTime.fromMillisecondsSinceEpoch(millis);
    } else {
      try {
        startTime = file.lastModifiedSync();
      } catch (_) {
        startTime = DateTime.now();
      }
    }

    // Try .meta sidecar for authoritative duration
    final basePath = file.path.contains('.') ? file.path.substring(0, file.path.lastIndexOf('.')) : file.path;
    final metaFile = File('$basePath.meta');
    if (metaFile.existsSync()) {
      try {
        final metaBytes = metaFile.readAsBytesSync();
        if (metaBytes.length >= 8) {
          final bd = ByteData.sublistView(metaBytes);
          final durationMs = bd.getUint32(4, Endian.little);

          int? sessionId;
          int? startUptime;
          if (metaBytes.length >= 416) {
            sessionId = bd.getUint32(408, Endian.little);
            startUptime = bd.getUint32(412, Endian.little);
          }

          String? uploadKey;
          bool passthrough = false;
          bool forceSynced = false;
          // Default true so recordings whose .meta predates the capEnded byte are treated
          // conservatively by pruneConsumedBins (no aggressive prune past rec_end).
          bool capEnded = true;
          bool? isSilero;
          bool? recordedManual;
          List<String> relativeBins = const [];
          if (metaBytes.length >= 417) {
            final keyLen = metaBytes[416];
            if (417 + keyLen <= metaBytes.length) {
              try {
                uploadKey = String.fromCharCodes(metaBytes, 417, 417 + keyLen);
              } catch (_) {
                uploadKey = null;
              }
              final flagOffset = 417 + keyLen;
              if (metaBytes.length > flagOffset) {
                passthrough = (metaBytes[flagOffset] & 0x01) != 0;
              }
              if (metaBytes.length > flagOffset + 1) {
                forceSynced = (metaBytes[flagOffset + 1] & 0x01) != 0;
              }
              if (metaBytes.length > flagOffset + 2) {
                capEnded = (metaBytes[flagOffset + 2] & 0x01) != 0;
              }
              if (metaBytes.length > flagOffset + 3) {
                isSilero = (metaBytes[flagOffset + 3] & 0x01) != 0;
                recordedManual = modeFromFlagByte(metaBytes[flagOffset + 3]);
              }

              // Still derived from whether byte [3] is PRESENT, never from the
              // mode bits inside it: the mode adds no bytes, so the count is
              // unchanged and every .meta already on disk keeps its bins tail.
              final binsOffset = flagOffset + (isSilero != null ? 4 : 3);
              if (metaBytes.length >= binsOffset + 4) {
                final binsLen = bd.getUint32(binsOffset, Endian.little);
                if (metaBytes.length >= binsOffset + 4 + binsLen) {
                  try {
                    final binsJson = utf8.decode(metaBytes.sublist(binsOffset + 4, binsOffset + 4 + binsLen));
                    relativeBins = (jsonDecode(binsJson) as List)
                        .cast<String>()
                        .map((p) => p.split('/raw_segments/').last)
                        .toList();
                  } catch (_) {}
                }
              }
            }
          }
          // Fall back to filename (without extension) as upload key for recordings
          // processed before the upload key was written to the .meta sidecar.
          final effectiveKey = uploadKey ?? file.path.split('/').last.split('.').first;
          return Conversation(
            file: file,
            startTime: startTime,
            duration: Duration(milliseconds: durationMs),
            uploadKey: effectiveKey,
            sessionId: sessionId,
            startUptime: startUptime,
            passthrough: passthrough,
            forceSynced: forceSynced,
            capEnded: capEnded,
            isSilero: isSilero,
            recordedManual: recordedManual,
            relativeBins: relativeBins,
          );
        }
      } catch (_) {
        // Fall through to size-based estimate
      }
    }

    // Size-based duration estimate
    // For WAV: 16kHz 16-bit mono = 32000 bytes/sec
    // For M4A: We use ~32kbps (4000 bytes/sec)
    final path = file.path.toLowerCase();
    final isWav = path.endsWith('.wav');
    final isM4a = path.endsWith('.m4a');

    int fileSize = 0;
    try {
      fileSize = file.lengthSync();
    } catch (_) {}

    int durationMs = 0;
    if (isWav && fileSize > 44) {
      durationMs = ((fileSize - 44) / 32000.0 * 1000).round();
    } else if (isM4a && fileSize > 0) {
      // Rough estimate for compressed audio to allow marker resolution
      durationMs = (fileSize / 4000.0 * 1000).round();
    }

    final fallbackKey = file.path.split('/').last.split('.').first;
    return Conversation(
      file: file,
      startTime: startTime,
      duration: Duration(milliseconds: durationMs),
      uploadKey: fallbackKey,
    );
  }

  /// Builds a passthrough Conversation from a standalone .meta file (no audio file).
  /// Returns null if the meta file does not have the passthrough flag set or cannot be parsed.
  static Future<Conversation?> fromMetaOnly(File metaFile) async {
    try {
      final metaBytes = await metaFile.readAsBytes();
      if (metaBytes.length < 8) return null;

      final bd = ByteData.sublistView(metaBytes);
      final durationMs = bd.getUint32(4, Endian.little);
      if (durationMs == 0) return null;

      int? sessionId;
      int? startUptime;
      if (metaBytes.length >= 416) {
        sessionId = bd.getUint32(408, Endian.little);
        startUptime = bd.getUint32(412, Endian.little);
      }

      String? uploadKey;
      bool passthrough = false;
      bool forceSynced = false;
      bool capEnded = true; // see Conversation.capEnded — default conservative
      bool? isSilero;
      bool? recordedManual;
      if (metaBytes.length >= 417) {
        final keyLen = metaBytes[416];
        if (417 + keyLen <= metaBytes.length) {
          try {
            uploadKey = String.fromCharCodes(metaBytes, 417, 417 + keyLen);
          } catch (_) {}
          final flagOffset = 417 + keyLen;
          if (metaBytes.length > flagOffset) {
            passthrough = (metaBytes[flagOffset] & 0x01) != 0;
          }
          if (metaBytes.length > flagOffset + 1) {
            forceSynced = (metaBytes[flagOffset + 1] & 0x01) != 0;
          }
          if (metaBytes.length > flagOffset + 2) {
            capEnded = (metaBytes[flagOffset + 2] & 0x01) != 0;
          }
          if (metaBytes.length > flagOffset + 3) {
            isSilero = (metaBytes[flagOffset + 3] & 0x01) != 0;
            recordedManual = modeFromFlagByte(metaBytes[flagOffset + 3]);
          }
        }
      }

      if (!passthrough) return null;

      // Reconstruct the virtual audio path from the meta filename.
      final metaName = metaFile.path.split('/').last;
      final baseName = metaName.contains('.') ? metaName.substring(0, metaName.lastIndexOf('.')) : metaName;
      final virtualAudioFile = File('${metaFile.parent.path}/$baseName.m4a');

      final millisStr = baseName.contains('_') ? baseName.split('_').last : null;
      final millis = millisStr != null ? int.tryParse(millisStr) : null;
      final startTime =
          millis != null && millis > 0 ? DateTime.fromMillisecondsSinceEpoch(millis) : await metaFile.lastModified();

      return Conversation(
        file: virtualAudioFile,
        startTime: startTime,
        duration: Duration(milliseconds: durationMs),
        uploadKey: uploadKey,
        sessionId: sessionId,
        startUptime: startUptime,
        passthrough: true,
        forceSynced: forceSynced,
        capEnded: capEnded,
        isSilero: isSilero,
        recordedManual: recordedManual,
      );
    } catch (_) {
      return null;
    }
  }

  /// Parses start time from the filename (`recording_<millis>.m4a` or `.wav`) and
  /// reads duration from the `.meta` sidecar if present, otherwise falls back to
  /// WAV file size calculation. Asynchronous version.
  static Future<Conversation> fromFileAsync(File file) async {
    final name = file.path.split('/').last;
    // Find the first numeric underscore-segment so `recording_<ts>_draft.wav`
    // parses too. Taking the last segment would grab "draft" and wrongly fall
    // back to lastModified (≈ now), making the draft's end overshoot wall-clock.
    final nameNoExt = name.split('.').first;
    int? millis;
    for (final part in nameNoExt.split('_')) {
      final val = int.tryParse(part);
      if (val != null && val > 0) {
        millis = val;
        break;
      }
    }
    DateTime startTime;
    if (millis != null && millis > 0) {
      startTime = DateTime.fromMillisecondsSinceEpoch(millis);
    } else {
      try {
        startTime = await file.lastModified();
      } catch (_) {
        startTime = DateTime.now();
      }
    }

    // Try .meta sidecar for authoritative duration
    final basePath = file.path.contains('.') ? file.path.substring(0, file.path.lastIndexOf('.')) : file.path;
    final metaFile = File('$basePath.meta');
    if (await metaFile.exists()) {
      try {
        final metaBytes = await metaFile.readAsBytes();
        if (metaBytes.length >= 8) {
          final bd = ByteData.sublistView(metaBytes);
          final durationMs = bd.getUint32(4, Endian.little);

          int? sessionId;
          int? startUptime;
          if (metaBytes.length >= 416) {
            sessionId = bd.getUint32(408, Endian.little);
            startUptime = bd.getUint32(412, Endian.little);
          }

          String? uploadKey;
          bool passthrough = false;
          bool forceSynced = false;
          // Default true so recordings whose .meta predates the capEnded byte are treated
          // conservatively by pruneConsumedBins (no aggressive prune past rec_end).
          bool capEnded = true;
          bool? isSilero;
          bool? recordedManual;
          if (metaBytes.length >= 417) {
            final keyLen = metaBytes[416];
            if (417 + keyLen <= metaBytes.length) {
              try {
                uploadKey = String.fromCharCodes(metaBytes, 417, 417 + keyLen);
              } catch (_) {
                uploadKey = null;
              }
              final flagOffset = 417 + keyLen;
              if (metaBytes.length > flagOffset) {
                passthrough = (metaBytes[flagOffset] & 0x01) != 0;
              }
              if (metaBytes.length > flagOffset + 1) {
                forceSynced = (metaBytes[flagOffset + 1] & 0x01) != 0;
              }
              if (metaBytes.length > flagOffset + 2) {
                capEnded = (metaBytes[flagOffset + 2] & 0x01) != 0;
              }
              if (metaBytes.length > flagOffset + 3) {
                isSilero = (metaBytes[flagOffset + 3] & 0x01) != 0;
                recordedManual = modeFromFlagByte(metaBytes[flagOffset + 3]);
              }
            }
          }
          // Fall back to filename (without extension) as upload key for recordings
          // processed before the upload key was written to the .meta sidecar.
          final effectiveKey = uploadKey ?? file.path.split('/').last.split('.').first;
          return Conversation(
            file: file,
            startTime: startTime,
            duration: Duration(milliseconds: durationMs),
            uploadKey: effectiveKey,
            sessionId: sessionId,
            startUptime: startUptime,
            passthrough: passthrough,
            forceSynced: forceSynced,
            capEnded: capEnded,
            isSilero: isSilero,
            recordedManual: recordedManual,
          );
        }
      } catch (_) {
        // Fall through to size-based estimate
      }
    }

    // Size-based duration estimate — only valid for WAV files.
    // For M4A/other formats without a .meta sidecar, return 0 to avoid a wildly wrong duration.
    final isWav = file.path.endsWith('.wav');
    int fileSize = 0;
    try {
      fileSize = await file.length();
    } catch (_) {}
    final pcmBytes = isWav && fileSize > 44 ? fileSize - 44 : 0;
    final durationMs = (pcmBytes / 32000.0 * 1000).round();
    final fallbackKey = file.path.split('/').last.split('.').first;
    return Conversation(
      file: file,
      startTime: startTime,
      duration: Duration(milliseconds: durationMs),
      uploadKey: fallbackKey,
    );
  }

  String get timeRangeLabel {
    // Show inclusive end: subtract 1s so a 30-min segment displays as HH:MM–HH:29, not HH:MM–HH:30.
    // We use the actual end time to determine the label, not a duration added to a truncated start.
    final end = startTime.add(duration);
    final inclusiveEnd = duration.inSeconds > 0 ? end.subtract(const Duration(seconds: 1)) : end;
    return '${fmtHourMin(startTime)} – ${fmtHourMin(inclusiveEnd)}';
  }

  String get durationLabel {
    final totalSecs = (duration.inMilliseconds / 1000).round();
    final mins = totalSecs ~/ 60;
    final secs = totalSecs % 60;
    return mins > 0 ? '${mins}m ${secs}s' : '${secs}s';
  }

  String get sizeLabel {
    if (passthrough) return '';
    final bytes = fileSizeBytes;
    String size;
    if (bytes >= 1024 * 1024) {
      size = '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      size = '${(bytes / 1024).toStringAsFixed(0)} KB';
    } else {
      size = '$bytes B';
    }
    final label = modeLabel;
    return label == null ? size : '$size  ·  $label';
  }

  /// The trailing designation on a recording row, or null for none.
  ///
  /// | state | label |
  /// |---|---|
  /// | mode known, manual | `Manual` |
  /// | mode known, auto, Silero ran | `Auto/VAD` |
  /// | mode known, auto, Silero did not | `Auto/AAD` |
  /// | mode unknown, Silero ran | `Auto/VAD` |
  /// | mode unknown, Silero did not | `AAD` |
  /// | no flag byte at all | *(null)* |
  ///
  /// Manual drops the detector half deliberately: manual mode pins
  /// `vadEnabled = false` (`applyRecordingModeDefaults`), so every manual
  /// recording is AAD by construction and `Manual/AAD` would spend a word saying
  /// nothing. On an auto row the same word is real information — Silero versus
  /// the bare amplitude gate.
  ///
  /// **The unknown-mode rows are two different answers, not one.** `isSilero ==
  /// true` proves the recording is NOT manual — Silero only runs when
  /// `vadEnabled` is set, which manual mode pins off — so a legacy `.meta` with
  /// that bit can be promoted to `Auto/VAD` for free, no migration. The reverse
  /// does not hold: `isSilero == false` is manual, auto-with-Silero-off and
  /// auto-with-a-model-that-failed-to-load all at once, so it keeps the old bare
  /// `AAD` and ages out as those recordings are replaced. Guessing "manual"
  /// there because manual is the default is exactly what the modeKnown bit
  /// exists to avoid.
  String? get modeLabel {
    // Off restores the original strings exactly, including their silences.
    if (!SharedPreferencesUtil().showRecordingMode) {
      if (isSilero == true) return 'VAD';
      if (isSilero == false) return 'AAD';
      return null;
    }
    if (recordedManual == true) return 'Manual';
    if (recordedManual == false || isSilero == true) return isSilero == true ? 'Auto/VAD' : 'Auto/AAD';
    if (isSilero == false) return 'AAD';
    return null;
  }
}

class Batch {
  final String dateString;
  final DateTime date;
  final List<File> rawSegments;
  final List<Conversation> draftRecordings;
  final List<Conversation> finalizedRecordings;
  final List<DateTime> markerTimestamps;
  final List<DiscardRecord> discards;

  Batch({
    required this.dateString,
    required this.date,
    required this.rawSegments,
    required this.draftRecordings,
    required this.finalizedRecordings,
    this.markerTimestamps = const [],
    this.discards = const [],
  });
}

/// One stretch of audio that VAD silently dropped, surfaced in the recordings
/// list as a greyed-out "ghost" row so the user can see what was lost and try
/// to recover it. Source of truth is `recordings/<date>/discards.jsonl`.
class DiscardRecord {
  /// How long a VAD-dropped stretch remains recoverable before the recovery
  /// sweep prunes it. Owns the single source of truth for this window;
  /// RecordingsManager references DiscardRecord.discardRetentionWindow.
  static const Duration discardRetentionWindow = Duration(hours: 48);

  final DateTime startTime;
  final DateTime endTime;
  final String reason;
  final double maxVoiceProb;
  final List<String> relativeBins;
  // Per-bin list of DISJOINT `[startByte, endByte)` byte slices this discard
  // consumed, keyed by the same `<rel>` tail as [relativeBins]. A single
  // persisted record is one contiguous span, so its on-disk form is a flat
  // `[s, e]`; coalescing several time-adjacent records keeps each one's span
  // SEPARATE (a list) instead of collapsing to a `[min, max]` hull — otherwise
  // the hull would swallow the un-discarded audio (real recordings) sitting
  // between two noise stretches in the same ~5-min bin, and Recover would
  // re-derive it into a bloated clip. Populated for discards written since
  // byte-range recovery landed; empty for legacy records (Recover then falls
  // back to whole-bin). Lets Recover re-derive only the discarded spans.
  final Map<String, List<List<int>>> binRanges;
  // Total duration of the audio the device ACTUALLY recorded for this discard
  // (sum of decoded-frame durations), excluding device-asleep gaps — i.e. the
  // length the recovered clip will be. [duration] (endTime - startTime) is the
  // wall-clock SPAN, which can be much longer when the firmware's AAD slept
  // between stretches (gaps that carry no audio). The UI shows [audioDuration]
  // so a "30s of audio" ghost recovers to a 30s clip and reads as 30s; retention
  // and removal still key off the real span. 0 ⇒ legacy record (falls back to
  // the span). Coalesced rows sum their constituents' audioMs.
  final int audioMs;
  final File sourceJsonl;

  const DiscardRecord({
    required this.startTime,
    required this.endTime,
    required this.reason,
    required this.maxVoiceProb,
    required this.relativeBins,
    required this.sourceJsonl,
    this.binRanges = const {},
    this.audioMs = 0,
  });

  Duration get duration => endTime.difference(startTime);

  /// Length of the actually-recorded audio (what Recover produces). Falls back
  /// to the wall-clock span for legacy records that predate the field.
  Duration get audioDuration => audioMs > 0 ? Duration(milliseconds: audioMs) : duration;
  DateTime get expiresAt => endTime.add(discardRetentionWindow);
  bool get isNoise => reason.contains('noise');

  /// A muted stretch (mic off via double-tap-hold / app toggle). Has no bins and
  /// no recoverable audio — surfaced as a delete-only ghost row.
  bool get isMuted => reason == 'muted';

  /// Stable identity for UI keys/comparisons: source file + startMs + bins hash.
  String get id => '${sourceJsonl.path}:${startTime.millisecondsSinceEpoch}:${relativeBins.join(",")}';
}

/// A marker: a device button tap and the segment(s) it was tagged to.
/// [segments] is empty when the backing m4a has not yet been produced (pending).
class MarkerConversation {
  final DateTime markerTime;
  final File? segment; // null = pending (no m4a produced yet)
  final int markerOffsetMs; // ms from segment start to the button press
  final int cropStartMs; // user-adjustable crop start, default 0
  final int cropEndMs; // user-adjustable crop end, default = segment duration
  final File edlFile;
  final bool userSaved;
  // True for a Priority Recording marker (auto-mode RECORD_START). Rendered red
  // ("Priority Recording") instead of the amber bookmark, gated on the
  // showHighPriorityMarker visibility pref.
  final bool isHighPriority;

  const MarkerConversation({
    required this.markerTime,
    required this.edlFile,
    this.segment,
    this.markerOffsetMs = 0,
    this.cropStartMs = 0,
    this.cropEndMs = 0,
    this.userSaved = false,
    this.isHighPriority = false,
  });

  bool get isPending => segment == null;
  String get markerTimeLabel => fmtHourMin(markerTime);

  String get timeRangeLabel {
    if (segment == null) return '';
    return Conversation.fromFile(segment!).timeRangeLabel;
  }
}
