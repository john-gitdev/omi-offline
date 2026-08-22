import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/recordings_manager.dart';

/// Guards `RecordingsManager.pruneEmptyRawBins`.
///
/// An empty bin is one the DEVICE advertised as 0 bytes — the firmware opened a
/// file and rotated it without a frame reaching the card. Nothing reclaimed them:
/// a bin is deleted only when a recording that consumed it is finalized, and an
/// empty bin feeds no recording. Their presence alone kept `activeBatches`
/// non-empty, so every processing cycle spawned an isolate and loaded the Silero
/// model to decode nothing.
///
/// The hazard the sweep has to avoid is that a bin being downloaded RIGHT NOW is
/// also 0 bytes. Deleting one destroys the resume target: the next sync rewinds to
/// offset 0, re-fetches the whole file, and re-decodes it into a second
/// overlapping recording. `Wal.isIncompleteTransfer` requires
/// `storageTotalBytes > 0`, so the mid-transfer set separates the two exactly —
/// and an unreadable WAL state must skip the sweep rather than guess.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('prune_empty_bins_test');
    await Directory('${tmp.path}/raw_segments').create(recursive: true);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<File> makeBin(String rel, {int bytes = 0}) async {
    final f = File('${tmp.path}/raw_segments/$rel');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(List<int>.filled(bytes, 0xAB));
    return f;
  }

  Batch batchWith(List<File> segments) => Batch(
        dateString: '2026-08-21',
        date: DateTime(2026, 8, 21),
        rawSegments: segments,
        draftRecordings: const [],
        finalizedRecordings: const [],
      );

  const String empty = '1787334441/1787334441_3394048838.bin';
  const String whole = '1787335043/1787335043_3394048838.bin';

  group('pruneEmptyRawBins', () {
    test('deletes an empty bin, strips it from the batch, and drops its folder', () async {
      final emptyBin = await makeBin(empty);
      final wholeBin = await makeBin(whole, bytes: 64);

      final out = await RecordingsManager.pruneEmptyRawBins([
        batchWith([emptyBin, wholeBin])
      ], const <String>{});

      expect(await emptyBin.exists(), isFalse,
          reason: 'nothing can ever reference it, so nothing reclaims it but this');
      expect(await emptyBin.parent.exists(), isFalse, reason: 'the folder it left behind goes too');
      expect(await wholeBin.exists(), isTrue);
      expect(out.single.rawSegments.map((f) => f.path), [wholeBin.path],
          reason: 'stripped in memory as well as on disk — otherwise this run still spins up an isolate for it');
    });

    test('leaves a mid-transfer bin alone even though it is also 0 bytes', () async {
      final downloading = await makeBin(empty);

      final out = await RecordingsManager.pruneEmptyRawBins([
        batchWith([downloading])
      ], {
        empty
      });

      expect(await downloading.exists(), isTrue,
          reason: 'this is the next sync\'s resume target — deleting it re-fetches and duplicates the whole file');
      expect(out.single.rawSegments, hasLength(1));
    });

    test('a null protection set skips the sweep entirely (fail closed)', () async {
      final emptyBin = await makeBin(empty);

      final out = await RecordingsManager.pruneEmptyRawBins([
        batchWith([emptyBin])
      ], null);

      expect(await emptyBin.exists(), isTrue,
          reason: 'unreadable WAL state means an empty bin cannot be told from a download in flight');
      expect(out.single.rawSegments, hasLength(1));
    });

    test('leaves a folder that still holds another bin', () async {
      final emptyBin = await makeBin('1787334441/1787334441_3394048838.bin');
      final sibling = await makeBin('1787334441/1787334441_99.bin', bytes: 8);

      await RecordingsManager.pruneEmptyRawBins([
        batchWith([emptyBin, sibling])
      ], const <String>{});

      expect(await emptyBin.exists(), isFalse);
      expect(await sibling.exists(), isTrue);
      expect(await sibling.parent.exists(), isTrue);
    });

    test('nothing to prune returns the batches untouched', () async {
      final wholeBin = await makeBin(whole, bytes: 64);
      final batches = [
        batchWith([wholeBin])
      ];

      expect(identical(await RecordingsManager.pruneEmptyRawBins(batches, const <String>{}), batches), isTrue);
    });
  });
}
