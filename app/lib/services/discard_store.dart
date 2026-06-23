import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/utils/logger.dart';

/// All persistence and querying of VAD-dropped stretches recorded in
/// `recordings/<date>/discards.jsonl`. Extracted from RecordingsManager so the
/// discard ledger (write / read / coalesce / delete / expire) lives in one
/// cohesive, independently-testable unit. RecordingsManager keeps thin static
/// wrappers so existing call sites are unchanged.
class DiscardStore {
  DiscardStore._();

  /// Consecutive discard records whose inter-record gap is within this tolerance
  /// are coalesced into a single entry by [getDiscardsForDate], so a long
  /// ambient-noise period surfaces as one row instead of dozens of back-to-back
  /// ~2-minute ghosts. Back-to-back chunks abut at ~0 gap (the next conversation
  /// is re-anchored to the frame right after a silence split); this window only
  /// needs to absorb RTC drift / inter-file rounding. It is far below the
  /// multi-minute gap a real saved recording or a device-idle (AAD-sleep) period
  /// introduces, so genuinely separate noise periods stay separate.
  static const Duration discardMergeGap = Duration(seconds: 30);

  /// Parses a persisted `binRanges` map tolerantly into per-bin DISJOINT
  /// intervals (`{rel: [[s, e], ...]}`). A single record is written as a flat
  /// `[startByte, endByte]` (one contiguous span); accepts both that flat form
  /// and a nested list of pairs. Absent/malformed ⇒ empty map (Recover falls
  /// back to whole-bin).
  static Map<String, List<List<int>>> _parseBinRanges(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, List<List<int>>>{};
    raw.forEach((k, v) {
      if (k is! String || v is! List || v.isEmpty) return;
      // Flat `[s, e]` (the persisted single-record form) vs nested `[[s, e], ...]`.
      final pairs = v.first is List ? v : [v];
      final intervals = <List<int>>[];
      for (final p in pairs) {
        if (p is List && p.length == 2) {
          final s = p[0], e = p[1];
          if (s is int && e is int && e > s) intervals.add([s, e]);
        }
      }
      if (intervals.isNotEmpty) out[k] = _mergeIntervals(intervals);
    });
    return out;
  }

  /// Sorts and merges only OVERLAPPING or byte-ADJACENT intervals (`end == next
  /// start`). Disjoint intervals (a real gap between them) stay separate, so a
  /// gap that belongs to an un-discarded recording is never swallowed.
  static List<List<int>> _mergeIntervals(List<List<int>> intervals) {
    if (intervals.length < 2) return intervals;
    final sorted = [...intervals]..sort((a, b) => a[0].compareTo(b[0]));
    final out = <List<int>>[
      [sorted.first[0], sorted.first[1]]
    ];
    for (var i = 1; i < sorted.length; i++) {
      final last = out.last;
      final cur = sorted[i];
      if (cur[0] <= last[1]) {
        if (cur[1] > last[1]) last[1] = cur[1];
      } else {
        out.add([cur[0], cur[1]]);
      }
    }
    return out;
  }

  /// Unions two per-bin interval maps, keeping each bin's spans DISJOINT. Unlike
  /// a `[min, max]` hull, this preserves the gap between two non-adjacent noise
  /// stretches in the same bin — the gap is un-discarded audio that Recover must
  /// not re-derive.
  static Map<String, List<List<int>>> _unionBinRanges(Map<String, List<List<int>>> a, Map<String, List<List<int>>> b) {
    final out = <String, List<List<int>>>{
      for (final e in a.entries)
        e.key: [
          for (final iv in e.value) [iv[0], iv[1]]
        ]
    };
    b.forEach((k, v) {
      final cur = out[k];
      if (cur == null) {
        out[k] = [
          for (final iv in v) [iv[0], iv[1]]
        ];
      } else {
        out[k] = _mergeIntervals([...cur, ...v]);
      }
    });
    return out;
  }

  static String _dateStringFromMillis(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// Appends one JSONL record to `recordings/<date>/discards.jsonl`. The date
  /// folder is derived from the record's startMs in local time.
  static Future<void> persistDiscardRecord(String docsPath, Map<String, dynamic> rec) async {
    final dateStr = _dateStringFromMillis(rec['startMs'] as int);
    final dir = Directory('$docsPath/recordings/$dateStr');
    await dir.create(recursive: true);
    final file = File('${dir.path}/discards.jsonl');
    await file.writeAsString('${jsonEncode(rec)}\n', mode: FileMode.append, flush: true);
  }

  /// Walks all `recordings/<date>/discards.jsonl` files and returns parsed
  /// records grouped by their containing file. Malformed lines are skipped.
  static Future<List<({File jsonl, List<Map<String, dynamic>> records})>> _readAllDiscardRecords() async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return const [];
    final out = <({File jsonl, List<Map<String, dynamic>> records})>[];
    await for (final dayDir in recordingsDir.list()) {
      if (dayDir is! Directory) continue;
      final jsonl = File('${dayDir.path}/discards.jsonl');
      if (!await jsonl.exists()) continue;
      final records = <Map<String, dynamic>>[];
      for (final line in (await jsonl.readAsString()).split('\n')) {
        if (line.isEmpty) continue;
        try {
          records.add(jsonDecode(line) as Map<String, dynamic>);
        } catch (e) {
          Logger.error('DiscardStore: Skipping malformed discard line in ${jsonl.path}: $e');
        }
      }
      out.add((jsonl: jsonl, records: records));
    }
    return out;
  }

  /// Relative bin paths (`<session>/<file>.bin` tail) that already have a
  /// persisted discard record and are therefore NOT awaiting processing —
  /// shared by [processAll]'s reprocess-strip and the "minutes to process"
  /// estimate so the two never disagree.
  ///
  /// Reads the FULL persisted set rather than per-batch discards: a record is
  /// filed under its conversation's local-date folder, which routinely differs
  /// from the bin's own raw-segment batch (raw batches are keyed off the bin
  /// filename's timestamp, and callers pre-filter to rawSegments-bearing days),
  /// so a per-batch derivation drops cross-date records and the bins re-run VAD
  /// every sync cycle (inflating "minutes to process", never finalizing).
  /// `silence_trimmed` is excluded — recording-adjacent trailing silence that
  /// is not a reprocess guard. No longer generated since the June 2026 change
  /// that keeps trailing silence in the recording, but legacy discards.jsonl
  /// files may still contain it, so the guard stays for backward compatibility.
  ///
  static Future<Set<String>> discardedRelBinPaths() async {
    final out = <String>{};
    for (final group in await _readAllDiscardRecords()) {
      for (final rec in group.records) {
        if (rec['reason'] == 'silence_trimmed') continue;
        final bins = rec['relativeBins'];
        if (bins is List) out.addAll(bins.cast<String>());
      }
    }
    return out;
  }

  /// Relative bin paths referenced by discard records that are NOT constituents
  /// of the span `[spanStartMs, spanEndMs]` — i.e. SIBLING discards. Recover
  /// Discard uses this to protect a bin that a sibling ghost still needs: two
  /// discards routinely share one ~5-min bin (e.g. a head slice and a tail
  /// slice), and recovering one must not delete the bin out from under the
  /// other. The span-membership test mirrors [removeDiscardRecord] so a
  /// (possibly coalesced) recovered record's own constituents are excluded,
  /// while everything else — including a sibling that shares a bin — is kept.
  static Future<Set<String>> discardedRelBinPathsExcludingSpan(int spanStartMs, int spanEndMs) async {
    final out = <String>{};
    for (final group in await _readAllDiscardRecords()) {
      for (final rec in group.records) {
        if (rec['reason'] == 'silence_trimmed') continue;
        final s = rec['startMs'] as int;
        final e = rec['endMs'] as int;
        if (s >= spanStartMs && e <= spanEndMs) continue; // a constituent of the recovered record
        final bins = rec['relativeBins'];
        if (bins is List) out.addAll(bins.cast<String>());
      }
    }
    return out;
  }

  /// Parses `recordings/<dateString>/discards.jsonl` into [DiscardRecord]s.
  /// Returns an empty list if the file does not exist. Malformed lines are
  /// skipped with a warning.
  static Future<List<DiscardRecord>> getDiscardsForDate(String dateString) async {
    final directory = await getApplicationDocumentsDirectory();
    final jsonl = File('${directory.path}/recordings/$dateString/discards.jsonl');
    if (!await jsonl.exists()) return const [];
    final out = <DiscardRecord>[];
    final seen = <String>{};
    for (final line in (await jsonl.readAsString()).split('\n')) {
      if (line.isEmpty) continue;
      try {
        final m = jsonDecode(line) as Map<String, dynamic>;
        final rec = DiscardRecord(
          startTime: DateTime.fromMillisecondsSinceEpoch(m['startMs'] as int),
          endTime: DateTime.fromMillisecondsSinceEpoch(m['endMs'] as int),
          reason: m['reason'] as String,
          maxVoiceProb: (m['maxVoiceProb'] as num).toDouble(),
          relativeBins: (m['relativeBins'] as List).cast<String>(),
          binRanges: _parseBinRanges(m['binRanges']),
          audioMs: (m['audioMs'] as num?)?.toInt() ?? 0,
          sourceJsonl: jsonl,
        );
        if (rec.reason == 'silence_trimmed') continue;
        if (seen.add(rec.id)) out.add(rec);
      } catch (e) {
        Logger.error('DiscardStore: skipping malformed discard line in ${jsonl.path}: $e');
      }
    }
    out.sort((a, b) => a.startTime.compareTo(b.startTime));
    return _coalesceDiscards(out);
  }

  /// Merges time-adjacent [DiscardRecord]s (input MUST be sorted by startTime)
  /// so a continuous noise/silence period reads as one entry. The merged record
  /// spans `[first.start, max(end)]`, unions the referenced bins, keeps the
  /// highest `maxVoiceProb`, and reports a noise reason if any constituent was
  /// noise (so the UI's noise-vs-too-short label stays accurate for the common
  /// ambient-noise case). Two records merge when the later one starts within
  /// [discardMergeGap] of the running end — overlaps included.
  static List<DiscardRecord> _coalesceDiscards(List<DiscardRecord> sorted) {
    if (sorted.length < 2) return sorted;
    final merged = <DiscardRecord>[];

    DateTime start = sorted.first.startTime;
    DateTime end = sorted.first.endTime;
    double maxProb = sorted.first.maxVoiceProb;
    final bins = <String>{...sorted.first.relativeBins};
    Map<String, List<List<int>>> ranges = sorted.first.binRanges;
    // Recorded-audio length is ADDITIVE across constituents (the gaps between
    // them carry no audio), so sum it rather than spanning first.start→max.end.
    int audioMs = sorted.first.audioMs;
    String reason = sorted.first.reason;
    bool noise = sorted.first.isNoise;
    File src = sorted.first.sourceJsonl;

    DiscardRecord build() => DiscardRecord(
          startTime: start,
          endTime: end,
          reason: reason,
          maxVoiceProb: maxProb,
          relativeBins: bins.toList()..sort(),
          binRanges: ranges,
          audioMs: audioMs,
          sourceJsonl: src,
        );

    for (var i = 1; i < sorted.length; i++) {
      final r = sorted[i];
      // Muted intervals never merge — they're a distinct kind (no bins, delete-only),
      // so a muted record always flushes as its own ghost row and is never absorbed
      // into an adjacent noise/too-short discard (or vice versa).
      final mergeable = reason != 'muted' && !r.isMuted;
      if (mergeable && r.startTime.difference(end) <= discardMergeGap) {
        if (r.endTime.isAfter(end)) end = r.endTime;
        if (r.maxVoiceProb > maxProb) maxProb = r.maxVoiceProb;
        bins.addAll(r.relativeBins);
        ranges = _unionBinRanges(ranges, r.binRanges);
        audioMs += r.audioMs;
        if (!noise && r.isNoise) {
          noise = true;
          reason = r.reason;
        }
      } else {
        merged.add(build());
        start = r.startTime;
        end = r.endTime;
        maxProb = r.maxVoiceProb;
        bins
          ..clear()
          ..addAll(r.relativeBins);
        ranges = r.binRanges;
        audioMs = r.audioMs;
        reason = r.reason;
        noise = r.isNoise;
        src = r.sourceJsonl;
      }
    }
    merged.add(build());
    return merged;
  }

  /// Deletes a discard record (and optionally its referenced bins) atomically.
  /// Rewrites the source jsonl with all other records preserved. If the jsonl
  /// becomes empty it is removed.
  static Future<void> removeDiscardRecord(DiscardRecord d, {required bool deleteBins}) async {
    final directory = await getApplicationDocumentsDirectory();
    if (deleteBins) {
      for (final rel in d.relativeBins) {
        final binFile = File('${directory.path}/raw_segments/$rel');
        if (await binFile.exists()) {
          try {
            await binFile.delete();
          } catch (e) {
            Logger.error('DiscardStore: removeDiscardRecord delete bin failed: $e');
          }
          final folder = binFile.parent;
          if (await folder.exists()) {
            try {
              if (await folder.list().isEmpty) await folder.delete();
            } catch (_) {}
          }
        }
      }
    }
    if (!await d.sourceJsonl.exists()) return;
    final keep = <String>[];
    final targetMs = d.startTime.millisecondsSinceEpoch;
    final targetEndMs = d.endTime.millisecondsSinceEpoch;
    for (final line in (await d.sourceJsonl.readAsString()).split('\n')) {
      if (line.isEmpty) continue;
      try {
        final m = jsonDecode(line) as Map<String, dynamic>;
        // Range match (not exact equality): a record surfaced by
        // getDiscardsForDate may be a coalesced span covering several jsonl
        // lines. Drop every constituent line whose [startMs,endMs] falls within
        // the (possibly merged) target span. A non-merged record matches exactly,
        // so this stays correct for single records too.
        final s = m['startMs'] as int;
        final e = m['endMs'] as int;
        if (s >= targetMs && e <= targetEndMs) continue;
      } catch (_) {
        // Keep malformed lines so we don't quietly destroy data we couldn't parse.
        keep.add(line);
        continue;
      }
      keep.add(line);
    }
    if (keep.isEmpty) {
      try {
        await d.sourceJsonl.delete();
      } catch (_) {}
    } else {
      await d.sourceJsonl.writeAsString('${keep.join('\n')}\n', flush: true);
    }
  }

  /// Returns absolute bin paths that are still protected by an in-window
  /// discard record. Used by AM-off cleanup to skip these files.
  static Future<Set<String>> activeDiscardProtectedPaths() async {
    final directory = await getApplicationDocumentsDirectory();
    final cutoffMs = DateTime.now().subtract(DiscardRecord.discardRetentionWindow).millisecondsSinceEpoch;
    final protected = <String>{};
    for (final group in await _readAllDiscardRecords()) {
      for (final rec in group.records) {
        if ((rec['endMs'] as int) < cutoffMs) continue;
        for (final rel in (rec['relativeBins'] as List).cast<String>()) {
          protected.add('${directory.path}/raw_segments/$rel');
        }
      }
    }
    return protected;
  }

  /// Reclaims expired discard records and their referenced bins. Bins still
  /// claimed by any in-window record across any day's jsonl are preserved.
  /// (The caller is responsible for not racing an in-flight processing run.)
  static Future<void> reclaimExpired() async {
    final directory = await getApplicationDocumentsDirectory();
    final cutoffMs = DateTime.now().subtract(DiscardRecord.discardRetentionWindow).millisecondsSinceEpoch;

    final groups = await _readAllDiscardRecords();

    // First pass: collect every bin still protected by an in-window record,
    // across all day-jsonl files. An expired record's bin must not be deleted
    // if another active record (possibly in a different day file) references it.
    final globallyProtected = <String>{};
    for (final group in groups) {
      for (final rec in group.records) {
        if ((rec['endMs'] as int) < cutoffMs) continue;
        for (final rel in (rec['relativeBins'] as List).cast<String>()) {
          globallyProtected.add('${directory.path}/raw_segments/$rel');
        }
      }
    }

    for (final group in groups) {
      final activeRecords = <Map<String, dynamic>>[];
      final candidateDeletes = <String>{};
      for (final rec in group.records) {
        if ((rec['endMs'] as int) < cutoffMs) {
          for (final rel in (rec['relativeBins'] as List).cast<String>()) {
            candidateDeletes.add('${directory.path}/raw_segments/$rel');
          }
        } else {
          activeRecords.add(rec);
        }
      }
      candidateDeletes.removeAll(globallyProtected);
      for (final path in candidateDeletes) {
        final f = File(path);
        if (!await f.exists()) continue;
        try {
          await f.delete();
          Logger.debug('DiscardStore: RecoverySweep deleted expired bin $path');
        } catch (e) {
          Logger.error('DiscardStore: RecoverySweep failed to delete $path: $e');
        }
      }
      if (activeRecords.isEmpty) {
        try {
          await group.jsonl.delete();
        } catch (_) {}
      } else if (activeRecords.length != group.records.length) {
        await group.jsonl.writeAsString('${activeRecords.map(jsonEncode).join('\n')}\n', flush: true);
      }
    }

    // Drop any now-empty raw_segments/<session>/ folders.
    final rawDir = Directory('${directory.path}/raw_segments');
    if (await rawDir.exists()) {
      await for (final entity in rawDir.list()) {
        if (entity is! Directory) continue;
        try {
          if (await entity.list().isEmpty) await entity.delete();
        } catch (_) {}
      }
    }
  }
}
