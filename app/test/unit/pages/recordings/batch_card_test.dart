import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/pages/recordings/batch_card.dart';
import 'package:omi/pages/recordings/recordings_types.dart';

/// Unit coverage for [filterBatchRows]' trailing-ghost suppression (the
/// `foldWindow` argument). A discard that abuts an open draft and is still a
/// fold candidate must be hidden from the default `visible` tab so it doesn't
/// read as a contradiction under the "Conversation in progress" banner — but
/// only there, and never for un-foldable (bin-less) ghosts, so nothing becomes
/// unrecoverable.
void main() {
  final jsonl = File('/tmp/does-not-need-to-exist/discards.jsonl');

  Conversation draft(DateTime start, {Duration duration = const Duration(minutes: 5)}) => Conversation(
        file: File('/tmp/recording_${start.millisecondsSinceEpoch}_draft.wav'),
        startTime: start,
        duration: duration,
      );

  DiscardRecord ghost(
    DateTime start, {
    Duration duration = const Duration(minutes: 1),
    List<String> bins = const ['s/a.bin'],
    String reason = 'flush_noise',
  }) =>
      DiscardRecord(
        startTime: start,
        endTime: start.add(duration),
        reason: reason,
        maxVoiceProb: 0.2,
        relativeBins: bins,
        sourceJsonl: jsonl,
        audioMs: duration.inMilliseconds,
      );

  Batch batch({
    List<Conversation> drafts = const [],
    List<DiscardRecord> discards = const [],
    List<Conversation> finalized = const [],
  }) =>
      Batch(
        dateString: '2026-07-09',
        date: DateTime(2026, 7, 9),
        rawSegments: const [],
        draftRecordings: drafts,
        finalizedRecordings: finalized,
        discards: discards,
      );

  // Draft runs 8:08–8:13; a below-minimum ghost abuts it at 8:13–8:14.
  final draftStart = DateTime(2026, 7, 9, 20, 8);
  final draftEnd = DateTime(2026, 7, 9, 20, 13); // start + 5m
  final abuttingGhost = ghost(draftEnd); // 8:13–8:14
  const twoMinWindow = Duration(seconds: 120);

  group('filterBatchRows trailing-ghost suppression', () {
    test('hides a ghost that abuts an open draft within the fold window (visible tab)', () {
      final rows = filterBatchRows(
        batch(drafts: [draft(draftStart)], discards: [abuttingGhost]),
        RecordingFilterMode.visible,
        0,
        foldWindow: twoMinWindow,
      );
      expect(rows.discards, isEmpty);
    });

    test('shows the same ghost when foldWindow is off (default) — no behaviour change for existing callers', () {
      final rows = filterBatchRows(
        batch(drafts: [draft(draftStart)], discards: [abuttingGhost]),
        RecordingFilterMode.visible,
        0,
      );
      expect(rows.discards, [abuttingGhost]);
    });

    test('shows the ghost in the Hidden and All tabs so it stays reachable/recoverable', () {
      for (final mode in [RecordingFilterMode.hidden, RecordingFilterMode.all]) {
        final rows = filterBatchRows(
          batch(drafts: [draft(draftStart)], discards: [abuttingGhost]),
          mode,
          0,
          foldWindow: twoMinWindow,
        );
        expect(rows.discards, [abuttingGhost], reason: 'mode=$mode must not suppress');
      }
    });

    test('shows a ghost that starts beyond the fold window after the draft (not a fold candidate)', () {
      final farGhost = ghost(draftEnd.add(const Duration(minutes: 3))); // gap 3m > 2m window
      final rows = filterBatchRows(
        batch(drafts: [draft(draftStart)], discards: [farGhost]),
        RecordingFilterMode.visible,
        0,
        foldWindow: twoMinWindow,
      );
      expect(rows.discards, [farGhost]);
    });

    test('shows a ghost that starts just before the draft end — the stitch pass skips it (never folds)', () {
      // gap < 0: RecordingsManager._stitchDraftRecordings does `if (gap < 0)
      // continue`, so this ghost is never folded and must remain a visible row.
      final overlapGhost = ghost(draftEnd.subtract(const Duration(seconds: 10)));
      final rows = filterBatchRows(
        batch(drafts: [draft(draftStart)], discards: [overlapGhost]),
        RecordingFilterMode.visible,
        0,
        foldWindow: twoMinWindow,
      );
      expect(rows.discards, [overlapGhost]);
    });

    test('shows a long trailing ghost whose gap + duration reaches the fold window', () {
      // gap 90s + duration 60s = 150s >= the 120s window, so the finalize/stitch
      // pass would finalize the draft rather than fold this ghost in — it is a
      // real standalone row and must stay visible.
      final longGhost = ghost(draftEnd.add(const Duration(seconds: 90)), duration: const Duration(seconds: 60));
      final rows = filterBatchRows(
        batch(drafts: [draft(draftStart)], discards: [longGhost]),
        RecordingFilterMode.visible,
        0,
        foldWindow: twoMinWindow,
      );
      expect(rows.discards, [longGhost]);
    });

    test('shows a ghost that starts well before the draft end', () {
      final earlyGhost = ghost(draftEnd.subtract(const Duration(minutes: 2)));
      final rows = filterBatchRows(
        batch(drafts: [draft(draftStart)], discards: [earlyGhost]),
        RecordingFilterMode.visible,
        0,
        foldWindow: twoMinWindow,
      );
      expect(rows.discards, [earlyGhost]);
    });

    test('hides a cross-midnight trailing ghost matched against a draft supplied via openDrafts', () {
      // The draft lives in the previous day's batch; the ghost sits in this
      // (empty-draft) batch just after it. The stitch pass folds across date
      // folders, so passing the global draft set must suppress it here too.
      final crossDayDraft = draft(DateTime(2026, 7, 9, 23, 58), duration: const Duration(minutes: 1)); // ends 23:59
      final afterMidnightGhost = ghost(DateTime(2026, 7, 10, 0, 0)); // gap 1m, +1m dur = 2m, < 2m? no → boundary
      final nearGhost = ghost(DateTime(2026, 7, 9, 23, 59, 30), duration: const Duration(seconds: 20)); // gap 30s
      final rows = filterBatchRows(
        batch(discards: [nearGhost, afterMidnightGhost]), // batch has NO local drafts
        RecordingFilterMode.visible,
        0,
        foldWindow: twoMinWindow,
        openDrafts: [crossDayDraft],
      );
      // nearGhost: gap 30s + 20s = 50s < 120s → folded ⇒ hidden.
      // afterMidnightGhost: gap 60s + 60s = 120s, not < 120s → shown.
      expect(rows.discards, [afterMidnightGhost]);
    });

    test('openDrafts overrides batch drafts: an empty global set disables suppression', () {
      final rows = filterBatchRows(
        batch(drafts: [draft(draftStart)], discards: [abuttingGhost]),
        RecordingFilterMode.visible,
        0,
        foldWindow: twoMinWindow,
        openDrafts: const [],
      );
      expect(rows.discards, [abuttingGhost]);
    });

    test('never hides a bin-less (muted) ghost — those are never folded', () {
      final muted = ghost(draftEnd, bins: const [], reason: 'muted');
      final rows = filterBatchRows(
        batch(drafts: [draft(draftStart)], discards: [muted]),
        RecordingFilterMode.visible,
        0,
        foldWindow: twoMinWindow,
      );
      expect(rows.discards, [muted]);
    });

    test('shows the ghost when there is no open draft', () {
      final rows = filterBatchRows(
        batch(discards: [abuttingGhost]),
        RecordingFilterMode.visible,
        0,
        foldWindow: twoMinWindow,
      );
      expect(rows.discards, [abuttingGhost]);
    });

    test('suppression leaves recordings untouched', () {
      final rec = Conversation(
        file: File('/tmp/recording_1.wav'),
        startTime: DateTime(2026, 7, 9, 18, 11),
        duration: const Duration(minutes: 90),
      );
      final rows = filterBatchRows(
        batch(drafts: [draft(draftStart)], discards: [abuttingGhost], finalized: [rec]),
        RecordingFilterMode.visible,
        0,
        foldWindow: twoMinWindow,
      );
      expect(rows.recordings, [rec]);
      expect(rows.discards, isEmpty);
    });
  });
}
