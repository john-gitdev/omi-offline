import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockPathProvider extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  String? tempPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempPath;
  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

/// Covers the discard-bin relocation lifecycle: once a discard's bin is fully
/// processed it is moved out of `raw_segments/` into `discarded_segments/` so it
/// can't be reprocessed/appended by a Force Process or wiped by the session-id
/// delete sweep, while staying recoverable. These tests exercise the move itself
/// ([RecordingsManager.retainDiscardBin]) plus the CONSUMER side (resolve /
/// delete / reclaim / protect) against a bin physically living in
/// `discarded_segments/`. The full in-isolate delete handler that drives the move
/// in production needs an isolate + Opus and is not host-testable, but the move
/// primitive and the resolver fallback that keeps every consumer correct are.
void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    tempDir = Directory.systemTemp.createTempSync('discard_relocation_test');
    PathProviderPlatform.instance = MockPathProvider()..tempPath = tempDir.path;
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  String dateOf(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  Future<void> writeJsonl(String dateStr, List<Map<String, dynamic>> records) async {
    final dir = Directory(p.join(tempDir.path, 'recordings', dateStr));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'discards.jsonl')).writeAsString('${records.map(jsonEncode).join('\n')}\n');
  }

  /// Creates a non-empty bin at `<base>/<rel>` (rel uses `/`), returning the File.
  Future<File> writeBin(String base, String rel, {int size = 64}) async {
    final f = File(p.join(tempDir.path, base, p.joinAll(rel.split('/'))));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(List<int>.filled(size, 0));
    return f;
  }

  Map<String, dynamic> rec({
    required int startMs,
    required int endMs,
    List<String>? relativeBins,
  }) =>
      {
        'startMs': startMs,
        'endMs': endMs,
        'reason': 'flush_noise',
        'maxVoiceProb': 0.05,
        'relativeBins': relativeBins ?? ['s/a.bin'],
      };

  test('resolveDiscardBin prefers discarded_segments, else raw_segments, else raw fallback', () async {
    // Only in raw_segments → returns the raw path.
    await writeBin('raw_segments', 's/a.bin');
    final r1 = await RecordingsManager.resolveDiscardBin(tempDir.path, 's/a.bin');
    expect(r1.path.replaceAll('\\', '/').contains('/raw_segments/'), isTrue);
    expect(await r1.exists(), isTrue);

    // Relocated copy present → the discarded_segments path wins.
    await writeBin('discarded_segments', 's/a.bin');
    final r2 = await RecordingsManager.resolveDiscardBin(tempDir.path, 's/a.bin');
    expect(r2.path.replaceAll('\\', '/').contains('/discarded_segments/'), isTrue);
    expect(await r2.exists(), isTrue);

    // Missing everywhere → falls back to the (non-existent) raw path.
    final r3 = await RecordingsManager.resolveDiscardBin(tempDir.path, 's/missing.bin');
    expect(r3.path.replaceAll('\\', '/').contains('/raw_segments/'), isTrue);
    expect(await r3.exists(), isFalse);
  });

  test('removeDiscardRecord(deleteBins) deletes a bin relocated to discarded_segments', () async {
    final base = DateTime.now().millisecondsSinceEpoch;
    final dateStr = dateOf(base);
    final bin = await writeBin('discarded_segments', 's/a.bin');
    await writeJsonl(dateStr, [rec(startMs: base, endMs: base + 500)]);

    final loaded = await RecordingsManager.getDiscardsForDate(dateStr);
    expect(loaded, hasLength(1));
    await RecordingsManager.removeDiscardRecord(loaded.single, deleteBins: true);

    expect(await bin.exists(), isFalse, reason: 'the relocated bin is deleted, not just the raw_segments path');
    expect(await File(p.join(tempDir.path, 'recordings', dateStr, 'discards.jsonl')).exists(), isFalse,
        reason: 'sole record removed → jsonl gone');
    expect(await Directory(p.join(tempDir.path, 'discarded_segments', 's')).exists(), isFalse,
        reason: 'emptied relocated session folder cleaned up');
  });

  test('recovery sweep reclaims an EXPIRED discard\'s relocated bin and keeps an in-window one', () async {
    final windowMs = DiscardRecord.discardRetentionWindow.inMilliseconds;
    final now = DateTime.now().millisecondsSinceEpoch;
    final expiredEnd = now - windowMs - 60000;
    final expiredStart = expiredEnd - 1000;
    final freshEnd = now - 1000;
    final freshStart = freshEnd - 1000;

    final expiredBin = await writeBin('discarded_segments', 'sx/old.bin');
    final freshBin = await writeBin('discarded_segments', 'sy/new.bin');
    await writeJsonl(dateOf(expiredStart), [
      rec(startMs: expiredStart, endMs: expiredEnd, relativeBins: ['sx/old.bin'])
    ]);
    await writeJsonl(dateOf(freshStart), [
      rec(startMs: freshStart, endMs: freshEnd, relativeBins: ['sy/new.bin'])
    ]);

    await RecordingsManager.runRecoverySweep();

    expect(await expiredBin.exists(), isFalse, reason: 'expired relocated bin reclaimed from discarded_segments');
    expect(await freshBin.exists(), isTrue, reason: 'in-window relocated bin retained');
    expect(await Directory(p.join(tempDir.path, 'discarded_segments', 'sx')).exists(), isFalse,
        reason: 'emptied relocated folder cleaned');
    expect(await Directory(p.join(tempDir.path, 'discarded_segments', 'sy')).exists(), isTrue);
  });

  test('a relocated bin shared by an in-window sibling is NOT reclaimed even if one record expired', () async {
    final windowMs = DiscardRecord.discardRetentionWindow.inMilliseconds;
    final now = DateTime.now().millisecondsSinceEpoch;
    final expiredEnd = now - windowMs - 60000;
    final freshEnd = now - 1000;

    final shared = await writeBin('discarded_segments', 's/shared.bin');
    // Expired record references the shared bin...
    await writeJsonl(dateOf(expiredEnd - 1000), [
      rec(startMs: expiredEnd - 1000, endMs: expiredEnd, relativeBins: ['s/shared.bin'])
    ]);
    // ...but an in-window sibling (different day file) still references it.
    await writeJsonl(dateOf(freshEnd - 1000), [
      rec(startMs: freshEnd - 1000, endMs: freshEnd, relativeBins: ['s/shared.bin'])
    ]);

    await RecordingsManager.runRecoverySweep();

    expect(await shared.exists(), isTrue, reason: 'globally-protected by the in-window sibling across day files');
  });

  test('activeDiscardProtectedPaths resolves to the relocated discarded_segments path', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await writeBin('discarded_segments', 's/a.bin');
    await writeJsonl(dateOf(now), [rec(startMs: now - 1000, endMs: now)]);

    final protected = await RecordingsManager.activeDiscardProtectedPaths();
    expect(
      protected.any((path) => path.replaceAll('\\', '/').contains('/discarded_segments/') && path.endsWith('a.bin')),
      isTrue,
    );
  });

  group('retainDiscardBin (the relocation move itself)', () {
    test('moves a bin raw_segments/ → discarded_segments/, then resolveDiscardBin finds it there', () async {
      // This is the exact round-trip _stitchDiscard relies on: after the bin is
      // relocated, every consumer must resolve it from discarded_segments/.
      final src = await writeBin('raw_segments', 's/a.bin');

      final moved = await RecordingsManager.retainDiscardBin(tempDir.path, src.path);

      expect(moved, isTrue);
      expect(await src.exists(), isFalse, reason: 'source removed from the processing pool');
      final dest = File(p.join(tempDir.path, 'discarded_segments', 's', 'a.bin'));
      expect(await dest.exists(), isTrue, reason: 'relocated under discarded_segments/');

      final resolved = await RecordingsManager.resolveDiscardBin(tempDir.path, 's/a.bin');
      expect(resolved.path.replaceAll('\\', '/').contains('/discarded_segments/'), isTrue);
      expect(await resolved.exists(), isTrue);
    });

    test('preserves bin bytes through the move', () async {
      final payload = List<int>.generate(128, (i) => (i * 7) & 0xFF);
      final src = File(p.join(tempDir.path, 'raw_segments', 's', 'a.bin'));
      await src.parent.create(recursive: true);
      await src.writeAsBytes(payload);

      expect(await RecordingsManager.retainDiscardBin(tempDir.path, src.path), isTrue);

      final dest = File(p.join(tempDir.path, 'discarded_segments', 's', 'a.bin'));
      expect(await dest.readAsBytes(), equals(payload));
    });

    test('creates nested destination session folders', () async {
      final src = await writeBin('raw_segments', 'session_42/1700000000_42.bin');

      expect(await RecordingsManager.retainDiscardBin(tempDir.path, src.path), isTrue);
      expect(
        await File(p.join(tempDir.path, 'discarded_segments', 'session_42', '1700000000_42.bin')).exists(),
        isTrue,
      );
    });

    test('is a no-op (false) for a path already under discarded_segments/', () async {
      // Mirrors a sibling-protected bin re-touched during a Recover run: it is
      // already relocated, so the handler must leave it in place.
      final already = await writeBin('discarded_segments', 's/a.bin');

      expect(await RecordingsManager.retainDiscardBin(tempDir.path, already.path), isFalse);
      expect(await already.exists(), isTrue, reason: 'already-relocated bin untouched');
      expect(
        await File(p.join(tempDir.path, 'raw_segments', 's', 'a.bin')).exists(),
        isFalse,
        reason: 'no stray raw_segments/ copy minted',
      );
    });

    test('returns false when the source bin does not exist', () async {
      final ghostPath = p.join(tempDir.path, 'raw_segments', 's', 'gone.bin');
      expect(await RecordingsManager.retainDiscardBin(tempDir.path, ghostPath), isFalse);
      expect(await File(p.join(tempDir.path, 'discarded_segments', 's', 'gone.bin')).exists(), isFalse);
    });

    test('is idempotent: a second move of an already-relocated bin is a harmless false', () async {
      final src = await writeBin('raw_segments', 's/a.bin');
      expect(await RecordingsManager.retainDiscardBin(tempDir.path, src.path), isTrue);
      // The original raw path no longer exists → second call sees no source.
      expect(await RecordingsManager.retainDiscardBin(tempDir.path, src.path), isFalse);
      expect(await File(p.join(tempDir.path, 'discarded_segments', 's', 'a.bin')).exists(), isTrue);
    });
  });

  group('nextSliceOffset (recover/fold byte-slice gating)', () {
    test('empty ranges → -1 (stop)', () {
      expect(RecordingsManager.nextSliceOffset(const [], 0), -1);
    });
    test('offset before the first range jumps to its start', () {
      expect(
          RecordingsManager.nextSliceOffset([
            [100, 200]
          ], 40),
          100);
    });
    test('offset inside a range is unchanged', () {
      expect(
          RecordingsManager.nextSliceOffset([
            [100, 200]
          ], 150),
          150);
    });
    test('offset in a gap jumps to the next range start', () {
      expect(
          RecordingsManager.nextSliceOffset([
            [100, 200],
            [400, 500]
          ], 260),
          400);
    });
    test('offset at a range end advances to the next range (exclusive end)', () {
      expect(
          RecordingsManager.nextSliceOffset([
            [100, 200],
            [400, 500]
          ], 200),
          400);
    });
    test('offset past the last range → -1', () {
      expect(
          RecordingsManager.nextSliceOffset([
            [100, 200]
          ], 200),
          -1);
      expect(
          RecordingsManager.nextSliceOffset([
            [100, 200]
          ], 999),
          -1);
    });
  });

  group('retireFoldedGhosts (record + solely-owned bin cleanup after a fold)', () {
    String jsonlPath(String dateStr) => p.join(tempDir.path, 'recordings', dateStr, 'discards.jsonl');

    test('removes the record and deletes a relocated bin the ghost solely owns', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final bin = await writeBin('discarded_segments', 's/a.bin');
      await writeJsonl(dateOf(now), [
        rec(startMs: now - 1000, endMs: now, relativeBins: ['s/a.bin'])
      ]);
      final folded = (await RecordingsManager.getDiscardsForDate(dateOf(now))).single;

      await RecordingsManager.retireFoldedGhosts([folded]);

      expect(await bin.exists(), isFalse, reason: 'solely-owned relocated bin deleted');
      expect(await File(jsonlPath(dateOf(now))).exists(), isFalse, reason: 'sole record removed → jsonl gone');
      expect(await Directory(p.join(tempDir.path, 'discarded_segments', 's')).exists(), isFalse,
          reason: 'emptied folder cleaned');
    });

    test('keeps a bin a REMAINING sibling discard still references', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final dayAgo = now - 25 * 3600 * 1000; // guaranteed different calendar day
      final shared = await writeBin('discarded_segments', 's/shared.bin');
      await writeJsonl(dateOf(dayAgo), [
        rec(startMs: dayAgo, endMs: dayAgo + 1000, relativeBins: ['s/shared.bin'])
      ]);
      await writeJsonl(dateOf(now), [
        rec(startMs: now - 1000, endMs: now, relativeBins: ['s/shared.bin'])
      ]);
      final folded = (await RecordingsManager.getDiscardsForDate(dateOf(dayAgo))).single;

      await RecordingsManager.retireFoldedGhosts([folded]);

      expect(await shared.exists(), isTrue, reason: 'sibling on another day still references it');
      expect(await File(jsonlPath(dateOf(dayAgo))).exists(), isFalse, reason: 'folded record removed');
      expect(await File(jsonlPath(dateOf(now))).exists(), isTrue, reason: 'sibling record untouched');
    });

    test('leaves a raw_segments bin (possible draft straddle) untouched', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final rawBin = await writeBin('raw_segments', 's/raw.bin'); // never relocated
      await writeJsonl(dateOf(now), [
        rec(startMs: now - 1000, endMs: now, relativeBins: ['s/raw.bin'])
      ]);
      final folded = (await RecordingsManager.getDiscardsForDate(dateOf(now))).single;

      await RecordingsManager.retireFoldedGhosts([folded]);

      expect(await rawBin.exists(), isTrue, reason: 'a still-in-pool raw bin is left to the safe-to-delete pass');
      expect(await File(jsonlPath(dateOf(now))).exists(), isFalse, reason: 'record still removed');
    });

    test('two folded ghosts sharing a bin both retire → shared bin deleted (no mutual protection)', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final dayAgo = now - 25 * 3600 * 1000;
      final shared = await writeBin('discarded_segments', 's/shared.bin');
      await writeJsonl(dateOf(dayAgo), [
        rec(startMs: dayAgo, endMs: dayAgo + 1000, relativeBins: ['s/shared.bin'])
      ]);
      await writeJsonl(dateOf(now), [
        rec(startMs: now - 1000, endMs: now, relativeBins: ['s/shared.bin'])
      ]);
      final g1 = (await RecordingsManager.getDiscardsForDate(dateOf(dayAgo))).single;
      final g2 = (await RecordingsManager.getDiscardsForDate(dateOf(now))).single;

      await RecordingsManager.retireFoldedGhosts([g1, g2]);

      expect(await shared.exists(), isFalse,
          reason: 'records removed before computing protection, so neither shields the other');
    });
  });

  group('orphan-twin deletion across both roots (a bin duplicated in raw + discarded)', () {
    test('removeDiscardRecord(deleteBins) deletes BOTH the raw and discarded copies', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final dateStr = dateOf(now);
      // A duplicate twin (e.g. adjustment-mode copy-back recreated the raw copy
      // of an already-relocated bin). Deleting only the resolved copy would leave
      // the raw orphan to re-enter the processing pool.
      final rawTwin = await writeBin('raw_segments', 's/a.bin');
      final discardedTwin = await writeBin('discarded_segments', 's/a.bin');
      await writeJsonl(dateStr, [rec(startMs: now, endMs: now + 500)]);
      final loaded = (await RecordingsManager.getDiscardsForDate(dateStr)).single;

      await RecordingsManager.removeDiscardRecord(loaded, deleteBins: true);

      expect(await rawTwin.exists(), isFalse, reason: 'orphan raw twin also deleted (no reprocess resurrection)');
      expect(await discardedTwin.exists(), isFalse);
      expect(await Directory(p.join(tempDir.path, 'raw_segments', 's')).exists(), isFalse,
          reason: 'emptied raw folder cleaned');
      expect(await Directory(p.join(tempDir.path, 'discarded_segments', 's')).exists(), isFalse);
    });

    test('recovery sweep reclaims an expired bin duplicated across BOTH roots', () async {
      final windowMs = DiscardRecord.discardRetentionWindow.inMilliseconds;
      final now = DateTime.now().millisecondsSinceEpoch;
      final expiredEnd = now - windowMs - 60000;
      final expiredStart = expiredEnd - 1000;
      final rawTwin = await writeBin('raw_segments', 'sx/old.bin');
      final discardedTwin = await writeBin('discarded_segments', 'sx/old.bin');
      await writeJsonl(dateOf(expiredStart), [
        rec(startMs: expiredStart, endMs: expiredEnd, relativeBins: ['sx/old.bin'])
      ]);

      await RecordingsManager.runRecoverySweep();

      expect(await rawTwin.exists(), isFalse, reason: 'expired raw twin reclaimed');
      expect(await discardedTwin.exists(), isFalse, reason: 'expired discarded twin reclaimed');
    });
  });
}
