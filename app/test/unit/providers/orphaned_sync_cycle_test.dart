import 'package:flutter_test/flutter_test.dart';
import 'package:omi/providers/device_provider.dart';

/// The rule that decides whether a background sync cycle whose process died should be
/// reported as a skip, and at what time.
///
/// It is the last line of defence for the resting notification's honesty. The alarm's own
/// check ([SyncAlarmReceiver], Dart-not-up) covers a cycle that never began; this covers
/// one that began and was then killed. Both halves of the rule can fail toward the same
/// bad outcome — a fabricated "Skipped" written over a real result — so both are pinned
/// here rather than left to a code read.
void main() {
  int? verdict({required int startedMs, required int lastStatusMs}) =>
      DeviceProvider.orphanedCycleStatusMs(startedMs: startedMs, lastStatusMs: lastStatusMs);

  group('orphaned sync cycle', () {
    test('no marker means nothing to report', () {
      expect(verdict(startedMs: 0, lastStatusMs: 1000), isNull);
      expect(verdict(startedMs: 0, lastStatusMs: 0), isNull);
    });

    // What this file CANNOT express: the `startedMs <= 0` guard in the rule is not
    // independently provable. Mutating it to `< 0` leaves every test here green, because
    // both fields are epoch-ms from DateTime.now() and never negative, so the
    // `lastStatusMs >= startedMs` check below already returns null for every no-marker
    // input. The guard is kept for readability — "0 means no marker" is the field's
    // documented meaning — not because a test holds it.

    test('a cycle with no outcome after it is reported, stamped when it began', () {
      // Not "now": the process died when it died, and the line has to say so. A run that
      // started at 3:45 AM and was killed reads "Last Sync: Skipped • 3:45 AM" whenever
      // the app is next opened, however much later that is.
      expect(verdict(startedMs: 5000, lastStatusMs: 4999), 5000);
      expect(verdict(startedMs: 5000, lastStatusMs: 0), 5000);
    });

    test('an outcome recorded after the cycle began wins', () {
      // The cycle did finish and something already said how — a foreground sync, or the
      // alarm recording its own skip. Re-reporting it would move a real result backwards.
      expect(verdict(startedMs: 5000, lastStatusMs: 5001), isNull);
    });

    test('an outcome recorded at the exact start instant wins', () {
      // The boundary is the one a `>` instead of `>=` would invert, and it fails toward
      // fabricating a skip over a real outcome — so it is pinned explicitly.
      expect(verdict(startedMs: 5000, lastStatusMs: 5000), isNull);
    });
  });
}
