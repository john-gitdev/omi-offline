import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/vad/vad_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The recording-mode switch history decides which settings cut which audio.
/// An entry lost early sends a backlog through the mode it was NOT recorded in —
/// auto audio chopped at every AAD wake by manual's `vadSplitSeconds = 0`, or a
/// deliberate manual capture discarded as noise by auto's speech filter. So the
/// ordering, the retirement rule and the round trip are all load-bearing.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // ProcessingSettings.fromJson falls back to the live prefs per field, and
    // SharedPreferencesUtil.init touches secure storage on the way up.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall call) async => call.method == 'readAll' ? <String, String>{} : null,
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  ProcessingSettings settings({required int splitMs, int minSpeechMs = 0}) => ProcessingSettings(
        vadEnabled: splitMs > 0,
        speechThreshold: 0.5,
        silenceDurationToSplitMs: splitMs,
        minDurationMs: 0,
        minSpeechMs: minSpeechMs,
        maxChunkMs: 0x7FFFFFFFFFFFFFFF,
        deviceId: 'dev',
        audioSaveFormat: 'wav',
        omiEnabled: false,
        priorityRecordCapMinutes: 120,
      );

  ModeSwitchRecord entry(int at, {int splitMs = 120000}) =>
      ModeSwitchRecord(atUtcSeconds: at, settings: settings(splitMs: splitMs));

  group('encode / decode', () {
    test('round-trips a multi-entry history in order', () {
      final history = [entry(100, splitMs: 120000), entry(200, splitMs: 0)];
      final restored = ModeSwitchRecord.decode(ModeSwitchRecord.encode(history));

      expect(restored.map((e) => e.atUtcSeconds), [100, 200]);
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
      expect(ModeSwitchRecord.decode(raw).map((e) => e.atUtcSeconds), [100, 300]);
    });
  });

  group('append', () {
    test('keeps entries ascending', () {
      var h = ModeSwitchRecord.append(const [], entry(200));
      h = ModeSwitchRecord.append(h, entry(100)); // clock stepped back
      expect(h.map((e) => e.atUtcSeconds), [100, 200]);
    });

    test('caps the history by dropping the OLDEST', () {
      var h = <ModeSwitchRecord>[];
      for (int i = 1; i <= ModeSwitchRecord.maxEntries + 3; i++) {
        h = ModeSwitchRecord.append(h, entry(i * 10));
      }
      expect(h.length, ModeSwitchRecord.maxEntries);
      // Newest survive: the dropped span falls to the next entry's settings,
      // degraded for the oldest audio only rather than unbounded growth.
      expect(h.first.atUtcSeconds, 40);
      expect(h.last.atUtcSeconds, (ModeSwitchRecord.maxEntries + 3) * 10);
    });
  });

  group('retire', () {
    List<ModeSwitchRecord> retire(
      List<ModeSwitchRecord> history, {
      required int now,
      required bool Function(int) anyBinBefore,
      bool partial = false,
      int maxAge = 7 * 24 * 3600,
    }) =>
        ModeSwitchRecord.retire(
          history: history,
          nowUtcSeconds: now,
          anyBinBefore: anyBinBefore,
          lastSyncPartial: partial,
          maxAgeSeconds: maxAge,
        );

    test('retires a drained entry', () {
      final h = [entry(100)];
      expect(retire(h, now: 200, anyBinBefore: (_) => false), isEmpty);
    });

    test('keeps an entry while a bin on disk still predates it', () {
      // Includes the mid-transfer case: isProcessableBin hides a downloading bin
      // from the run's partition, so "nothing to process" is not "nothing left".
      // That is the ordinary state when an interrupted sync hands over.
      final h = [entry(100)];
      expect(retire(h, now: 200, anyBinBefore: (_) => true), hasLength(1));
    });

    test('keeps an entry after a partial sync even with nothing on disk', () {
      // The Omi keeps recording while disconnected, so a cut-short sync means it
      // may still hold pre-switch files that never reached the phone.
      final h = [entry(100)];
      expect(retire(h, now: 200, anyBinBefore: (_) => false, partial: true), hasLength(1));
    });

    test('retires only the leading run, keeping later entries', () {
      // Bins exist before 300 but not before 100/200 → drop the first two.
      final h = [entry(100), entry(200), entry(300)];
      final kept = retire(h, now: 400, anyBinBefore: (at) => at > 250);
      expect(kept.map((e) => e.atUtcSeconds), [300]);
    });

    test('stops at the first surviving entry even if a later one looks drained', () {
      // Guards the prefix assumption. Both conditions are monotone along the
      // ascending list, so a later entry can never be retirable once an earlier
      // one is not — and dropping out of the middle would misassign every bin
      // after it.
      final h = [entry(100), entry(200)];
      final kept = retire(h, now: 400, anyBinBefore: (at) => at == 100);
      expect(kept.map((e) => e.atUtcSeconds), [100, 200]);
    });

    test('retires on age even with bins on disk and a partial sync', () {
      // The escape hatch: every live entry costs a processing pass per run, and
      // an Omi that is never fully drained would otherwise hold one forever.
      final h = [entry(100)];
      expect(retire(h, now: 100 + 8 * 24 * 3600, anyBinBefore: (_) => true, partial: true), isEmpty);
      expect(retire(h, now: 100 + 6 * 24 * 3600, anyBinBefore: (_) => true, partial: true), hasLength(1));
    });

    test('an empty history retires to empty', () {
      expect(retire(const [], now: 1, anyBinBefore: (_) => false), isEmpty);
    });
  });
}
