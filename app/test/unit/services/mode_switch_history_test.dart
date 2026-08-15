import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';
import 'package:omi/services/vad/vad_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The recording-mode switch history decides which settings cut which audio.
/// Send a stretch to the wrong entry and it is processed by the mode it was NOT
/// recorded in — auto audio chopped at every AAD wake by manual's
/// `vadSplitSeconds = 0`, or a deliberate manual capture filed as a recoverable
/// ghost row by auto's speech filter.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // ModeSettings.fromJson falls back to the live prefs per field, and
    // SharedPreferencesUtil.init touches secure storage on the way up.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall call) async => call.method == 'readAll' ? <String, String>{} : null,
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  ModeSettings mode({required int splitMs, int minSpeechMs = 0}) => ModeSettings(
        vadEnabled: splitMs > 0,
        speechThreshold: 0.5,
        silenceDurationToSplitMs: splitMs,
        minDurationMs: 0,
        minSpeechMs: minSpeechMs,
        maxChunkMs: 0x7FFFFFFFFFFFFFFF,
      );

  /// Real firmware `timerStart` from the 2026-08-14 log. Test timestamps are
  /// offsets from it because anything at or below kMinValidEpoch (2000-01-01)
  /// is treated as a pre-time-sync bin and reads as 0 — the case its own test
  /// below covers deliberately.
  const int base = 1786741941;

  ModeSwitchRecord entry(int at, {int splitMs = 120000}) =>
      ModeSwitchRecord(atUtcSeconds: base + at, settings: mode(splitMs: splitMs));

  group('encode / decode', () {
    test('round-trips a multi-entry history in order', () {
      final history = [entry(100, splitMs: 120000), entry(200, splitMs: 0)];
      final restored = ModeSwitchRecord.decode(ModeSwitchRecord.encode(history));

      expect(restored.map((e) => e.atUtcSeconds), [base + 100, base + 200]);
      expect(restored[0].settings.silenceDurationToSplitMs, 120000);
      expect(restored[1].settings.silenceDurationToSplitMs, 0);
      // The sentinel is the largest int Dart holds; a JSON round trip that
      // widened it to a double would silently disable the max-duration cap.
      expect(restored[0].settings.maxChunkMs, 0x7FFFFFFFFFFFFFFF);
    });

    test('an empty history encodes to the empty string, not "[]"', () {
      // '' is the pref's "nothing pending" value and the fast path out of the
      // drain; '[]' would parse fine but read as a pending switch at a glance.
      expect(ModeSwitchRecord.encode(const []), '');
      expect(ModeSwitchRecord.decode(''), isEmpty);
    });

    test('unreadable JSON degrades to no history instead of throwing', () {
      // Falling back means every bin uses the current mode — the pre-history
      // behaviour. Throwing would wedge the processing pipeline on every run.
      expect(ModeSwitchRecord.decode('{not json'), isEmpty);
      expect(ModeSwitchRecord.decode('[{"at":1}]'), isEmpty); // no settings key
    });

    test('decode sorts, so a clock that stepped backwards cannot unorder it', () {
      final raw = ModeSwitchRecord.encode([entry(300), entry(100)]);
      expect(ModeSwitchRecord.decode(raw).map((e) => e.atUtcSeconds), [base + 100, base + 300]);
    });

    test('a field missing from an older entry falls back to the live value', () {
      final live = ProcessingSettings.fromPrefs().mode;
      final partial = ModeSettings.fromJson({'silenceDurationToSplitMs': 0});
      expect(partial.silenceDurationToSplitMs, 0, reason: 'the field that IS present wins');
      expect(partial.minSpeechMs, live.minSpeechMs);
      expect(partial.vadEnabled, live.vadEnabled);
    });
  });

  group('append', () {
    test('keeps entries ascending', () {
      var h = ModeSwitchRecord.append(const [], entry(200));
      h = ModeSwitchRecord.append(h, entry(100)); // clock stepped back
      expect(h.map((e) => e.atUtcSeconds), [base + 100, base + 200]);
    });

    test('caps the history by dropping the OLDEST', () {
      var h = <ModeSwitchRecord>[];
      for (int i = 1; i <= ModeSwitchRecord.maxEntries + 3; i++) {
        h = ModeSwitchRecord.append(h, entry(i * 10));
      }
      expect(h.length, ModeSwitchRecord.maxEntries);
      // Newest survive: the dropped span falls to the next entry's settings,
      // degraded for the oldest audio only rather than unbounded growth.
      expect(h.first.atUtcSeconds, base + 40);
      expect(h.last.atUtcSeconds, base + (ModeSwitchRecord.maxEntries + 3) * 10);
    });
  });

  group('retireExpired', () {
    test('drops an entry the retention cutoff has passed', () {
      // Everything that entry governed was recorded before it, so it is all past
      // its keep-window and the next sweep deletes it — whichever mode's rules
      // cut it. The entry cannot change the outcome any more.
      final h = [entry(100), entry(500)];
      expect(ModeSwitchRecord.retireExpired(h, base + 300).map((e) => e.atUtcSeconds), [base + 500]);
    });

    test('keeps an entry the cutoff has not reached', () {
      final h = [entry(500)];
      expect(ModeSwitchRecord.retireExpired(h, base + 300), hasLength(1));
    });

    test('an entry exactly at the cutoff is dropped', () {
      // Off-by-one worth spelling out. An entry at T governs audio recorded
      // strictly BEFORE T, and the sweep deletes recordings strictly before the
      // cutoff. So at T == cutoff everything the entry governs is inside the
      // sweep's range and the entry is already moot — `> cutoff` keeps, `<=`
      // drops. (The two `strictly before`s are what make the boundaries line up;
      // if either were inclusive this would have to keep it.)
      expect(ModeSwitchRecord.retireExpired([entry(300)], base + 300), isEmpty);
      expect(ModeSwitchRecord.retireExpired([entry(301)], base + 300), hasLength(1));
    });

    test('retention off drops nothing', () {
      // "Always Keep" is the default (keepRecordingsDays = -1) and passthrough is
      // 0; both mean no sweep, so nothing an entry governs is ever deleted for
      // age and maxEntries stays the only bound.
      final h = [entry(100), entry(500)];
      expect(ModeSwitchRecord.retireExpired(h, null), hasLength(2));
    });

    test('an empty history stays empty', () {
      expect(ModeSwitchRecord.retireExpired(const [], base + 300), isEmpty);
    });
  });

  group('withMode', () {
    test('replaces the mode-shaped fields and keeps the global ones live', () {
      // The point of storing only six fields: a replaced Omi's id or a changed
      // save format must NOT be frozen into a pending backlog.
      final live = ProcessingSettings.fromPrefs();
      final applied = live.withMode(mode(splitMs: 0, minSpeechMs: 0));

      expect(applied.silenceDurationToSplitMs, 0);
      expect(applied.minSpeechMs, 0);
      expect(applied.deviceId, live.deviceId);
      expect(applied.audioSaveFormat, live.audioSaveFormat);
      expect(applied.omiEnabled, live.omiEnabled);
      expect(applied.priorityRecordCapMinutes, live.priorityRecordCapMinutes);
    });
  });

  /// The whole decision: which bins each pass gets, and with what settings.
  group('planModeSwitchPasses', () {
    /// One batch holding bins named by their firmware `timerStart`, the way the
    /// sync layer writes them: raw_segments/<timerStart>/<timerStart>_<sid>.bin
    List<Batch> batchOf(List<int> timerStarts) => [
          Batch(
            dateString: '2026-08-14',
            date: DateTime(2026, 8, 14),
            rawSegments: timerStarts.map((o) {
              final t = base + o;
              return File('/docs/raw_segments/$t/${t}_99.bin');
            }).toList(),
            draftRecordings: const [],
            finalizedRecordings: const [],
          )
        ];

    /// Bin start times as the offsets [batchOf] was given, so expectations read
    /// in the same small numbers the test wrote.
    List<int> binsIn(List<Batch> bs) =>
        bs.expand((b) => b.rawSegments).map((f) => RecordingsController.binStartUtcSeconds(f) - base).toList();

    test('no history means one pass under the current mode', () {
      final passes = RecordingsController.planModeSwitchPasses(batchOf([1000, 2000]), const []);
      expect(passes, hasLength(1));
      expect(passes.single.settings, isNull);
      expect(binsIn(passes.single.batches), [1000, 2000]);
    });

    test('splits a backlog either side of one switch', () {
      final passes = RecordingsController.planModeSwitchPasses(
        batchOf([1000, 1500, 2500, 3000]),
        [entry(2000, splitMs: 120000)],
      );
      expect(passes, hasLength(2));
      expect(passes[0].settings!.silenceDurationToSplitMs, 120000, reason: 'the mode being left');
      expect(binsIn(passes[0].batches), [1000, 1500]);
      expect(passes[1].settings, isNull, reason: 'current mode');
      expect(binsIn(passes[1].batches), [2500, 3000]);
    });

    test('gives each span of two switches its own settings', () {
      // The case a single "previous mode" snapshot could not express: the middle
      // span belongs to neither the oldest mode nor the current one.
      final passes = RecordingsController.planModeSwitchPasses(
        batchOf([100, 1500, 2500]),
        [entry(1000, splitMs: 120000), entry(2000, splitMs: 0)],
      );
      expect(passes, hasLength(3));
      expect(binsIn(passes[0].batches), [100]);
      expect(passes[0].settings!.silenceDurationToSplitMs, 120000);
      expect(binsIn(passes[1].batches), [1500]);
      expect(passes[1].settings!.silenceDurationToSplitMs, 0);
      expect(binsIn(passes[2].batches), [2500]);
      expect(passes[2].settings, isNull);
    });

    test('every bin lands in exactly one pass', () {
      // The invariant that matters: a bin in two passes is decoded twice, a bin
      // in none is never processed and its file is never reclaimed.
      final all = [100, 900, 1000, 1500, 2000, 2500];
      final passes = RecordingsController.planModeSwitchPasses(
        batchOf(all),
        [entry(1000), entry(2000)],
      );
      expect(passes.expand((p) => binsIn(p.batches)).toList()..sort(), all);
    });

    test('a bin exactly at a switch instant belongs to the NEW mode', () {
      // `< at` not `<= at`: the stamp is the moment the new mode took effect.
      final passes = RecordingsController.planModeSwitchPasses(batchOf([2000]), [entry(2000)]);
      expect(passes, hasLength(1));
      expect(passes.single.settings, isNull);
    });

    test('an empty pass is dropped, so a drained entry costs nothing', () {
      // Entries are never retired, so this is what a spent one does: match
      // nothing and disappear from the plan.
      final passes = RecordingsController.planModeSwitchPasses(batchOf([5000]), [entry(1000), entry(2000)]);
      expect(passes, hasLength(1));
      expect(passes.single.settings, isNull);
      expect(binsIn(passes.single.batches), [5000]);
    });

    test('a pre-time-sync bin lands in the oldest pass', () {
      // No usable clock, so it reads as 0 — older than any switch. That is the
      // safe side: audio predating a working clock predates today's switch.
      final passes = RecordingsController.planModeSwitchPasses(
        [
          Batch(
            dateString: 'unorganized',
            date: DateTime(2026, 8, 14),
            rawSegments: [File('/docs/raw_segments/session_99/1234_99.bin')],
            draftRecordings: const [],
            finalizedRecordings: const [],
          )
        ],
        [entry(1000)],
      );
      expect(passes, hasLength(2));
      expect(passes[0].settings, isNotNull);
      expect(passes[1].batches.every((b) => b.rawSegments.isEmpty), isTrue);
    });

    test('carries drafts, markers and discards into every pass unchanged', () {
      // processAll reads none of them for bin selection, but dropping them would
      // silently change the early-return and force-sync branches downstream.
      final src = [
        Batch(
          dateString: '2026-08-14',
          date: DateTime(2026, 8, 14),
          rawSegments: [File('/docs/raw_segments/500/500_99.bin')],
          draftRecordings: const [],
          finalizedRecordings: const [],
          markerTimestamps: [DateTime(2026, 8, 14, 12)],
        )
      ];
      final passes = RecordingsController.planModeSwitchPasses(src, [entry(1000)]);
      expect(passes.every((p) => p.batches.single.markerTimestamps.length == 1), isTrue);
    });
  });
}
