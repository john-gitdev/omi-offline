import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/device_clock_anchor.dart';

/// The Omi has no clock. These pin the rule that decides whose answer wins when the
/// Omi's idea of the time and the phone's disagree — the phone's, but only when it can
/// prove the Omi wrong.
void main() {
  // A device that has been running 10 hours, observed at a known wall clock.
  const wall = 1755600000000; // arbitrary fixed instant
  const upMs = 10 * 60 * 60 * 1000;
  const anchor = DeviceClockAnchor(sessionId: 42, deviceUptimeMs: upMs, wallClockMs: wall);

  // A recording that started 2 hours into that session.
  const recUptimeSec = 2 * 60 * 60;
  final correctStart = anchor.startMsFor(recUptimeSec);

  group('startMsFor', () {
    test('places a recording from its uptime and the anchor', () {
      // 10 h uptime now, recording began at 2 h => it started 8 h before the anchor.
      expect(correctStart, wall - (8 * 60 * 60 * 1000));
    });

    test('a recording at the anchor instant lands on the anchor', () {
      expect(anchor.startMsFor(upMs ~/ 1000), wall);
    });
  });

  group('clockVerdict', () {
    ClockVerdict verdict({
      int? session = 42,
      int? uptime = recUptimeSec,
      int? claimed,
      bool unknown = false,
    }) =>
        clockVerdict(
          anchor: anchor,
          recordedSessionId: session,
          startUptimeSec: uptime,
          claimedStartMs: claimed ?? correctStart,
          isUnknown: unknown,
        );

    test('a recording from another session is never touched', () {
      // Its uptime belongs to a different boot's counter, and the gap between two
      // sessions is unknowable — the Omi's uptime and IMU counters both reset when it
      // dies. This is the "recorded, never synced, then died" case.
      expect(verdict(session: 41), ClockVerdict.otherSession);
      expect(verdict(session: null), ClockVerdict.otherSession);
    });

    test('a recording with no usable uptime cannot be placed', () {
      expect(verdict(uptime: null), ClockVerdict.unplaceable);
      expect(verdict(uptime: 0), ClockVerdict.unplaceable);
    });

    test('an unknown recording from this session gets filed', () {
      expect(verdict(unknown: true), ClockVerdict.fileUnknown);
    });

    test('a recording that already agrees is left alone', () {
      expect(verdict(claimed: correctStart), ClockVerdict.alreadyCorrect);
    });

    test('ordinary clock drift is left alone, not "corrected"', () {
      // Seconds of disagreement is what a real LFCLK does over hours. Re-filing for
      // that would churn every recording on every connect for no gain.
      expect(verdict(claimed: correctStart + 30 * 1000), ClockVerdict.alreadyCorrect);
      expect(verdict(claimed: correctStart - 30 * 1000), ClockVerdict.alreadyCorrect);
    });

    test('a wrapped IMU guess is caught — the drawer case', () {
      // The counter is 24-bit at 6.4 ms, so it wraps every ~29.8 h and a wrap makes the
      // gap look SMALLER. An Omi left in a drawer for 31 h reports 1.2 h, and files a
      // day of audio under a confidently wrong date. That is the case this exists for.
      const wrapMs = 29 * 60 * 60 * 1000 + 48 * 60 * 1000;
      expect(verdict(claimed: correctStart - wrapMs), ClockVerdict.correctWrong);
      expect(verdict(claimed: correctStart + wrapMs), ClockVerdict.correctWrong);
    });
  });

  group('plausibleDriftMs', () {
    test('scales with how long the session has been running', () {
      // 1000 ppm is a deliberate over-estimate of any LFCLK, so a healthy clock can
      // never trip the correction.
      const long = DeviceClockAnchor(sessionId: 1, deviceUptimeMs: 24 * 60 * 60 * 1000, wallClockMs: wall);
      expect(long.plausibleDriftMs, 24 * 60 * 60); // 86.4 s over a day
    });

    test('never drops below a floor, where BLE latency dominates', () {
      const brief = DeviceClockAnchor(sessionId: 1, deviceUptimeMs: 5000, wallClockMs: wall);
      expect(brief.plausibleDriftMs, 60 * 1000);
    });

    test('stays far below the ~29.8 h aliasing error it must separate from', () {
      // A week of uptime still leaves three orders of magnitude of headroom, so the
      // threshold never needs tuning to land in the gap.
      const week = DeviceClockAnchor(sessionId: 1, deviceUptimeMs: 7 * 24 * 60 * 60 * 1000, wallClockMs: wall);
      expect(week.plausibleDriftMs, lessThan(29 * 60 * 60 * 1000));
    });
  });

  group('encode/decode', () {
    test('round-trips', () {
      final back = DeviceClockAnchor.decode(anchor.encode())!;
      expect(back.sessionId, anchor.sessionId);
      expect(back.deviceUptimeMs, anchor.deviceUptimeMs);
      expect(back.wallClockMs, anchor.wallClockMs);
    });

    test('rejects junk rather than throwing into the sync path', () {
      expect(DeviceClockAnchor.decode(null), isNull);
      expect(DeviceClockAnchor.decode(''), isNull);
      expect(DeviceClockAnchor.decode('not json'), isNull);
      expect(DeviceClockAnchor.decode('{"sessionId":1}'), isNull);
      expect(DeviceClockAnchor.decode('[1,2,3]'), isNull);
    });
  });

  group('DeviceClockAnchorSet', () {
    const a1 = DeviceClockAnchor(sessionId: 1, deviceUptimeMs: 1000, wallClockMs: wall);
    const a2 = DeviceClockAnchor(sessionId: 2, deviceUptimeMs: 2000, wallClockMs: wall);

    test('an unseen session has no anchor, so its recordings are left alone', () {
      const set = DeviceClockAnchorSet.empty();
      expect(set.forSession(1), isNull);
      expect(set.isEmpty, isTrue);
    });

    test('a session id of 0 or null never matches — 0 is "firmware did not say"', () {
      final set = const DeviceClockAnchorSet.empty().upsert(a1);
      expect(set.forSession(0), isNull);
      expect(set.forSession(null), isNull);
    });

    test('holds several sessions at once, so a reboot does not strand the old one', () {
      final set = const DeviceClockAnchorSet.empty().upsert(a1).upsert(a2);
      expect(set.forSession(1), isNotNull);
      expect(set.forSession(2), isNotNull);
    });

    test('a later observation of the same session replaces the earlier one', () {
      const later = DeviceClockAnchor(sessionId: 1, deviceUptimeMs: 9000, wallClockMs: wall + 8000);
      final set = const DeviceClockAnchorSet.empty().upsert(a1).upsert(later);
      expect(set.anchors.length, 1);
      expect(set.forSession(1)!.deviceUptimeMs, 9000);
    });

    test('drops the oldest once full, rather than growing without bound', () {
      var set = const DeviceClockAnchorSet.empty();
      for (var i = 1; i <= DeviceClockAnchorSet.maxEntries + 3; i++) {
        set = set.upsert(DeviceClockAnchor(sessionId: i, deviceUptimeMs: i * 1000, wallClockMs: wall));
      }
      expect(set.anchors.length, DeviceClockAnchorSet.maxEntries);
      expect(set.forSession(1), isNull, reason: 'oldest evicted');
      expect(set.forSession(DeviceClockAnchorSet.maxEntries + 3), isNotNull, reason: 'newest kept');
    });

    test('without() removes one session — the revert path, which must not re-apply', () {
      final set = const DeviceClockAnchorSet.empty().upsert(a1).upsert(a2).without(1);
      expect(set.forSession(1), isNull);
      expect(set.forSession(2), isNotNull);
    });

    test('round-trips through encode/decode', () {
      final set = const DeviceClockAnchorSet.empty().upsert(a1).upsert(a2);
      final back = DeviceClockAnchorSet.decode(set.encode());
      expect(back.anchors.length, 2);
      expect(back.forSession(2)!.deviceUptimeMs, 2000);
    });

    test('junk decodes to empty rather than throwing into the connect path', () {
      expect(DeviceClockAnchorSet.decode('not json').isEmpty, isTrue);
      expect(DeviceClockAnchorSet.decode('{"not":"a list"}').isEmpty, isTrue);
      expect(DeviceClockAnchorSet.decode('').isEmpty, isTrue);
      expect(DeviceClockAnchorSet.decode(null).isEmpty, isTrue);
    });

    test('skips malformed entries but keeps the good ones', () {
      const raw = '[{"sessionId":1,"deviceUptimeMs":1000,"wallClockMs":$wall},{"sessionId":"x"}]';
      final set = DeviceClockAnchorSet.decode(raw);
      expect(set.anchors.length, 1);
      expect(set.forSession(1), isNotNull);
    });
  });
}
