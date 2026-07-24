import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/services/recordings_manager.dart';

/// Guards `RecordingsManager.stripBinsByRelPath`, the pure filter behind the
/// background-processing guards that hold back discarded and still-mid-transfer
/// bins. The processing pass PRUNES every bin it consumes, so a bin wrongly left
/// in a batch is decoded and deleted — data-loss / duplication shaped.
///
/// Regression this backstops: an interrupted active bin (walOffset < advertised
/// size) was decoded into a draft and pruned by the BACKGROUND path
/// (processAllCompletedSessions), which — unlike the foreground pipeline — had no
/// incomplete-transfer guard. The next sync re-fetched the whole bin and re-opened
/// it as its own overlapping recording, duplicating ~4 min of audio. The guard now
/// lives in processAll via this helper, so every background caller is covered.
void main() {
  File bin(String rel) => File('/docs/raw_segments/$rel');

  Batch batchWith(List<File> segments) => Batch(
        dateString: '2026-07-24',
        date: DateTime(2026, 7, 24),
        rawSegments: segments,
        draftRecordings: const [],
        finalizedRecordings: const [],
      );

  const String partial = '1784861858/1784861858_213890738.bin';
  const String wholeA = '1784860656/1784860656_213890738.bin';
  const String wholeB = '1784861257/1784861257_213890738.bin';

  group('stripBinsByRelPath', () {
    test('empty exclude set returns the exact same list instance (no-op)', () {
      final batches = [
        batchWith([bin(wholeA), bin(partial)])
      ];
      expect(identical(RecordingsManager.stripBinsByRelPath(batches, const {}), batches), isTrue);
    });

    test('removes only the mid-transfer bin, keeps its whole siblings', () {
      final batches = [
        batchWith([bin(wholeA), bin(wholeB), bin(partial)])
      ];
      final out = RecordingsManager.stripBinsByRelPath(batches, {partial});
      final keptRel = out.single.rawSegments.map((f) => f.path.split('/raw_segments/').last).toList();
      expect(keptRel, [wholeA, wholeB]);
      expect(keptRel, isNot(contains(partial)));
    });

    test('an unchanged batch is returned by identity (no needless rebuild)', () {
      final batch = batchWith([bin(wholeA), bin(wholeB)]);
      final out = RecordingsManager.stripBinsByRelPath([batch], {partial});
      expect(identical(out.single, batch), isTrue);
    });

    test('a batch that loses a bin is rebuilt, preserving its other fields', () {
      final batch = batchWith([bin(wholeA), bin(partial)]);
      final out = RecordingsManager.stripBinsByRelPath([batch], {partial});
      expect(identical(out.single, batch), isFalse);
      expect(out.single.dateString, batch.dateString);
      expect(out.single.date, batch.date);
    });

    test('excluding every bin empties the batch (caller drops it as inactive)', () {
      final batches = [
        batchWith([bin(wholeA), bin(partial)])
      ];
      final out = RecordingsManager.stripBinsByRelPath(batches, {wholeA, partial});
      expect(out.single.rawSegments, isEmpty);
    });

    test('a path outside raw_segments/ is always kept (defensive)', () {
      final odd = File('/docs/processing_temp/combined/recording_fs320_1.bin');
      final out = RecordingsManager.stripBinsByRelPath([
        batchWith([odd])
      ], {
        partial,
        'processing_temp/combined/recording_fs320_1.bin',
      });
      expect(out.single.rawSegments, [odd]);
    });

    test('filters across multiple batches independently', () {
      final batches = [
        batchWith([bin(wholeA), bin(partial)]),
        batchWith([bin(wholeB)]),
      ];
      final out = RecordingsManager.stripBinsByRelPath(batches, {partial});
      expect(out[0].rawSegments.map((f) => f.path.split('/raw_segments/').last), [wholeA]);
      expect(out[1].rawSegments.map((f) => f.path.split('/raw_segments/').last), [wholeB]);
    });
  });
}
