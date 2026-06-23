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

/// Covers the discard ledger's `binRanges` byte-slice data layer added for
/// byte-range Recover Discard: persistence round-trip, tolerant parsing of
/// legacy/malformed records, and the per-bin range UNION performed when
/// time-adjacent discards coalesce. (The slice CAPTURE side is covered in
/// vad_audio_processor_test.dart; the decode-time slicing itself can't be
/// exercised on the host — dummy frames don't Opus-decode.)
void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    tempDir = Directory.systemTemp.createTempSync('discard_binranges_test');
    PathProviderPlatform.instance = MockPathProvider()..tempPath = tempDir.path;
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  String dateOf(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  Future<void> writeJsonl(String dateStr, List<Map<String, dynamic>> records) async {
    final dir = Directory(p.join(tempDir.path, 'recordings', dateStr));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'discards.jsonl')).writeAsString('${records.map(jsonEncode).join('\n')}\n');
  }

  Map<String, dynamic> rec({
    required int startMs,
    required int endMs,
    String reason = 'flush_noise',
    double maxVoiceProb = 0.05,
    List<String>? relativeBins,
    Object? binRanges,
    int? audioMs,
  }) {
    final m = <String, dynamic>{
      'startMs': startMs,
      'endMs': endMs,
      'reason': reason,
      'maxVoiceProb': maxVoiceProb,
      'relativeBins': relativeBins ?? ['s/a.bin'],
    };
    if (binRanges != null) m['binRanges'] = binRanges;
    if (audioMs != null) m['audioMs'] = audioMs;
    return m;
  }

  group('binRanges persistence round-trip', () {
    test('parses a recorded byte slice back into binRanges', () async {
      final base = DateTime(2026, 4, 1, 9).millisecondsSinceEpoch;
      final dateStr = dateOf(base);
      await writeJsonl(dateStr, [
        rec(startMs: base, endMs: base + 600, relativeBins: [
          's/a.bin'
        ], binRanges: {
          's/a.bin': [800, 1400]
        }),
      ]);

      final loaded = await RecordingsManager.getDiscardsForDate(dateStr);
      expect(loaded.single.relativeBins, ['s/a.bin']);
      expect(loaded.single.binRanges, {
        's/a.bin': [
          [800, 1400]
        ]
      });
    });

    test('a legacy record with no binRanges field parses to an empty map', () async {
      final base = DateTime(2026, 4, 2, 9).millisecondsSinceEpoch;
      final dateStr = dateOf(base);
      await writeJsonl(dateStr, [
        rec(startMs: base, endMs: base + 600, relativeBins: ['s/a.bin'])
      ]);

      final loaded = await RecordingsManager.getDiscardsForDate(dateStr);
      expect(loaded.single.binRanges, isEmpty, reason: 'legacy => whole-bin recover fallback');
    });

    test('malformed / invalid range entries are dropped, valid ones kept (no throw)', () async {
      final base = DateTime(2026, 4, 3, 9).millisecondsSinceEpoch;
      final dateStr = dateOf(base);
      await writeJsonl(dateStr, [
        rec(startMs: base, endMs: base + 600, relativeBins: [
          's/a.bin',
          's/b.bin'
        ], binRanges: {
          's/a.bin': [800, 1400], // valid
          's/bad-len.bin': [800], // wrong length
          's/bad-len3.bin': [800, 1400, 9], // wrong length
          's/empty.bin': [1400, 800], // end <= start
          's/bad-type.bin': 'nope', // not a list
        }),
      ]);

      final loaded = await RecordingsManager.getDiscardsForDate(dateStr);
      expect(loaded.single.binRanges, {
        's/a.bin': [
          [800, 1400]
        ]
      });
    });
  });

  group('binRanges union on coalesce', () {
    test('same-bin DISJOINT spans stay separate (gap is un-discarded audio)', () async {
      final base = DateTime(2026, 4, 4, 9).millisecondsSinceEpoch;
      final dateStr = dateOf(base);
      await writeJsonl(dateStr, [
        rec(startMs: base, endMs: base + 1000, reason: 'silence_only', relativeBins: [
          's/a.bin'
        ], binRanges: {
          's/a.bin': [800, 1000]
        }),
        // Coalesces in time, but the byte spans have a 200-byte gap (frames that
        // belong to a recording between the two noise stretches). The gap must
        // NOT be swallowed into a hull, else Recover re-derives that audio.
        rec(startMs: base + 1000, endMs: base + 2000, reason: 'noise_silence_split', relativeBins: [
          's/a.bin'
        ], binRanges: {
          's/a.bin': [1200, 1500]
        }),
      ]);

      final loaded = await RecordingsManager.getDiscardsForDate(dateStr);
      expect(loaded.length, 1, reason: 'adjacent chunks collapse to one row');
      expect(loaded.single.binRanges, {
        's/a.bin': [
          [800, 1000],
          [1200, 1500]
        ]
      });
    });

    test('same-bin byte-adjacent / overlapping spans DO merge', () async {
      final base = DateTime(2026, 4, 4, 10).millisecondsSinceEpoch;
      final dateStr = dateOf(base);
      await writeJsonl(dateStr, [
        rec(startMs: base, endMs: base + 1000, reason: 'silence_only', relativeBins: [
          's/a.bin'
        ], binRanges: {
          's/a.bin': [800, 1000]
        }),
        // Byte-contiguous (end == next start) → one merged interval.
        rec(startMs: base + 1000, endMs: base + 2000, reason: 'silence_only', relativeBins: [
          's/a.bin'
        ], binRanges: {
          's/a.bin': [1000, 1500]
        }),
      ]);

      final loaded = await RecordingsManager.getDiscardsForDate(dateStr);
      expect(loaded.single.binRanges, {
        's/a.bin': [
          [800, 1500]
        ]
      });
    });

    test('different bins each carry their own span in the merged record', () async {
      final base = DateTime(2026, 4, 5, 9).millisecondsSinceEpoch;
      final dateStr = dateOf(base);
      await writeJsonl(dateStr, [
        rec(startMs: base, endMs: base + 1000, reason: 'silence_only', relativeBins: [
          's/a.bin'
        ], binRanges: {
          's/a.bin': [800, 2000]
        }),
        rec(startMs: base + 1000, endMs: base + 2000, reason: 'silence_only', relativeBins: [
          's/b.bin'
        ], binRanges: {
          's/b.bin': [36, 1500]
        }),
      ]);

      final loaded = await RecordingsManager.getDiscardsForDate(dateStr);
      expect(loaded.length, 1);
      expect(loaded.single.relativeBins, ['s/a.bin', 's/b.bin']);
      expect(loaded.single.binRanges, {
        's/a.bin': [
          [800, 2000]
        ],
        's/b.bin': [
          [36, 1500]
        ],
      });
    });

    test('mixing a legacy (no-range) chunk yields only the ranged bin (recover then falls back)', () async {
      final base = DateTime(2026, 4, 6, 9).millisecondsSinceEpoch;
      final dateStr = dateOf(base);
      await writeJsonl(dateStr, [
        rec(startMs: base, endMs: base + 1000, reason: 'silence_only', relativeBins: ['s/a.bin']), // legacy, no range
        rec(startMs: base + 1000, endMs: base + 2000, reason: 'silence_only', relativeBins: [
          's/b.bin'
        ], binRanges: {
          's/b.bin': [36, 1500]
        }),
      ]);

      final loaded = await RecordingsManager.getDiscardsForDate(dateStr);
      expect(loaded.single.relativeBins, ['s/a.bin', 's/b.bin']);
      // s/a.bin has no range → binRanges doesn't cover every bin → recoverDiscard's
      // allSliceable check is false → safe whole-bin reprocess.
      expect(loaded.single.binRanges, {
        's/b.bin': [
          [36, 1500]
        ]
      });
    });
  });

  group('audioMs (recorded-audio duration shown / recovered)', () {
    test('single record: audioDuration uses audioMs, not the wall-clock span', () async {
      final base = DateTime(2026, 4, 9, 9).millisecondsSinceEpoch;
      final dateStr = dateOf(base);
      // 77s wall-clock span, but only 26s of actual recorded audio.
      await writeJsonl(dateStr, [
        rec(startMs: base, endMs: base + 77000, audioMs: 26000),
      ]);
      final loaded = await RecordingsManager.getDiscardsForDate(dateStr);
      expect(loaded.single.duration, const Duration(seconds: 77), reason: 'span unchanged');
      expect(loaded.single.audioDuration, const Duration(seconds: 26), reason: 'display = recorded audio');
    });

    test('legacy record without audioMs falls back to the span', () async {
      final base = DateTime(2026, 4, 10, 9).millisecondsSinceEpoch;
      final dateStr = dateOf(base);
      await writeJsonl(dateStr, [rec(startMs: base, endMs: base + 30000)]); // no audioMs
      final loaded = await RecordingsManager.getDiscardsForDate(dateStr);
      expect(loaded.single.audioDuration, const Duration(seconds: 30));
    });

    test('coalesced record SUMS constituents\' audioMs (gaps between carry no audio)', () async {
      final base = DateTime(2026, 4, 11, 9).millisecondsSinceEpoch;
      final dateStr = dateOf(base);
      await writeJsonl(dateStr, [
        // Two stretches 25s apart (coalesce), 10s + 8s of real audio = 18s.
        rec(startMs: base, endMs: base + 10000, reason: 'silence_only', relativeBins: ['s/a.bin'], audioMs: 10000),
        rec(
            startMs: base + 35000,
            endMs: base + 43000,
            reason: 'silence_only',
            relativeBins: ['s/b.bin'],
            audioMs: 8000),
      ]);
      final loaded = await RecordingsManager.getDiscardsForDate(dateStr);
      expect(loaded.length, 1, reason: 'within 30s gap → one row');
      expect(loaded.single.duration, const Duration(seconds: 43), reason: 'span includes the 25s silent gap');
      expect(loaded.single.audioDuration, const Duration(seconds: 18), reason: 'audio is additive, no gap');
    });
  });

  group('sibling-bin protection (discardedRelBinPathsExcludingSpan)', () {
    test('a bin shared by a sibling discard outside the span is protected', () async {
      final base = DateTime(2026, 4, 7, 9).millisecondsSinceEpoch;
      final dateStr = dateOf(base);
      await writeJsonl(dateStr, [
        // Record A (being recovered): a HEAD slice of shared.bin + its own bin.
        rec(startMs: base, endMs: base + 1000, relativeBins: [
          's/shared.bin',
          's/onlyA.bin'
        ], binRanges: {
          's/shared.bin': [56, 56900],
          's/onlyA.bin': [0, 100],
        }),
        // Record B (sibling, later span): a TAIL slice of the SAME bin.
        rec(startMs: base + 5000, endMs: base + 6000, relativeBins: [
          's/shared.bin'
        ], binRanges: {
          's/shared.bin': [56920, 60712]
        }),
      ]);

      // Recovering A's span must protect the shared bin (B still needs its tail)
      // but NOT A's exclusive bin (safe to delete once A is recovered).
      final protectedSiblings = await RecordingsManager.discardedRelBinPathsExcludingSpan(base, base + 1000);
      expect(protectedSiblings, {'s/shared.bin'});
      expect(protectedSiblings.contains('s/onlyA.bin'), isFalse);
    });

    test('recovering the whole coalesced span protects nothing of its own', () async {
      final base = DateTime(2026, 4, 8, 9).millisecondsSinceEpoch;
      final dateStr = dateOf(base);
      await writeJsonl(dateStr, [
        rec(startMs: base, endMs: base + 1000, relativeBins: ['s/a.bin']),
        rec(startMs: base + 1000, endMs: base + 2000, relativeBins: ['s/b.bin']),
      ]);
      // Both records fall inside [base, base+2000] → both are constituents → none protected.
      final protectedSiblings = await RecordingsManager.discardedRelBinPathsExcludingSpan(base, base + 2000);
      expect(protectedSiblings, isEmpty);
    });
  });
}
