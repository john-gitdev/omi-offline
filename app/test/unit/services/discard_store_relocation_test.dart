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
/// delete sweep, while staying recoverable. These tests exercise the CONSUMER
/// side (resolve / delete / reclaim / protect) against a bin physically living
/// in `discarded_segments/`. The move itself happens inside processAll's
/// per-segment delete handler, which needs an isolate + Opus and is not host-
/// testable; the resolver fallback keeps every consumer correct either way.
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
}
