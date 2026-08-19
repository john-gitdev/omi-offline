import 'dart:convert';

/// One observation pairing the Omi's uptime with the phone's wall clock.
///
/// The Omi has no clock of its own. It learns the time only when a phone connects,
/// and forgets it on every restart. Between a restart and the next connection it
/// either guesses (see the IMU bridge in `imu.c`) or admits it does not know — and
/// the guess can be badly wrong, because the counter it guesses from is 24-bit at
/// 6.4 ms and wraps every ~29.8 h. A wrap makes the gap look SMALLER, not larger, so
/// an Omi left in a drawer for 31 h reports 1.2 h and nothing on the device can
/// contradict it.
///
/// The phone can. It knows the real time and it can ask the Omi how long it has been
/// running (`nowUptimeMs`, offset 16 of the 0x0062 diagnostics read), and every
/// recording's `.meta` carries the uptime it started at. That is enough to place
/// every recording in the session exactly:
///
///     start = startUptime + (phone wall clock - Omi uptime at the same instant)
///
/// **Valid for exactly one hardware session.** Each boot gets a fresh
/// `device_session_id` and restarts the uptime counter from zero, and the gap between
/// two sessions is unknowable — when the Omi dies, its uptime counter and the IMU
/// counter both reset, so nothing survives to measure it. Recordings from an earlier,
/// already-ended session therefore keep no timestamp at all and stay Unorganized.
/// That is the honest answer, not a limitation being tolerated.
class DeviceClockAnchor {
  /// The hardware session this anchor describes. An anchor is meaningless against
  /// any other session's recordings.
  final int sessionId;

  /// The Omi's uptime, in milliseconds, at the moment of the observation.
  final int deviceUptimeMs;

  /// The phone's UTC clock at that same moment.
  final int wallClockMs;

  const DeviceClockAnchor({
    required this.sessionId,
    required this.deviceUptimeMs,
    required this.wallClockMs,
  });

  /// How long the Omi had been running when this anchor was taken. Doubles as the
  /// longest a recording in this session can have been waiting, which is what bounds
  /// the drift below.
  int get sessionDurationMs => deviceUptimeMs;

  /// The wall-clock start for a recording that began at [startUptimeSec] of this
  /// session's uptime (`.meta` stores it in whole seconds).
  int startMsFor(int startUptimeSec) => (startUptimeSec * 1000) + (wallClockMs - deviceUptimeMs);

  /// The most the Omi's own clock could plausibly have drifted over this session.
  ///
  /// Deliberately not a tuned constant. The Omi's uptime runs off the nRF's LFCLK,
  /// which is tens of ppm on a crystal and a few hundred on the internal RC; 1000 ppm
  /// is a deliberate over-estimate of both, so this can never fire on a healthy clock.
  /// The floor covers short sessions, where BLE round-trip latency rather than drift
  /// dominates the measurement.
  ///
  /// This is what separates "the Omi was a little off" from "the Omi's guess wrapped".
  /// The two are orders of magnitude apart — seconds of drift against a ~29.8 h
  /// aliasing error — so nothing here needs to be tuned finely to land in the gap.
  int get plausibleDriftMs {
    const floorMs = 60 * 1000;
    final drift = (sessionDurationMs / 1000).round(); // 1000 ppm == 1 ms per second
    return drift > floorMs ? drift : floorMs;
  }

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'deviceUptimeMs': deviceUptimeMs,
        'wallClockMs': wallClockMs,
      };

  static DeviceClockAnchor? fromJson(Map<String, dynamic> json) {
    final s = json['sessionId'];
    final u = json['deviceUptimeMs'];
    final w = json['wallClockMs'];
    if (s is! int || u is! int || w is! int) return null;
    return DeviceClockAnchor(sessionId: s, deviceUptimeMs: u, wallClockMs: w);
  }

  String encode() => jsonEncode(toJson());

  static DeviceClockAnchor? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? fromJson(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'DeviceClockAnchor(session=$sessionId, uptime=${deviceUptimeMs}ms, wall=$wallClockMs)';
}

/// What should happen to one recording, given an anchor.
enum ClockVerdict {
  /// Not this session — the anchor says nothing about it. Leave it exactly as it is,
  /// Unorganized or otherwise.
  otherSession,

  /// The recording carries no usable uptime, so the anchor cannot place it.
  unplaceable,

  /// The recording's own timestamp already agrees with the anchor. Never touched:
  /// re-filing a correct recording can only make it worse.
  alreadyCorrect,

  /// The recording has no timestamp at all (`unknown_`) and the anchor can give it
  /// one.
  fileUnknown,

  /// The recording claims a time the anchor proves wrong — the drawer case, where the
  /// Omi's guess wrapped and it filed a day of audio under a confident wrong date.
  correctWrong,
}

/// Decides what to do with one recording. Pure: no I/O, no clock reads, so the whole
/// decision is unit-testable without a device.
///
/// [recordedSessionId] / [startUptimeSec] / [claimedStartMs] come from the recording's
/// `.meta` and filename; [isUnknown] is true for an `unknown_`-prefixed file.
ClockVerdict clockVerdict({
  required DeviceClockAnchor anchor,
  required int? recordedSessionId,
  required int? startUptimeSec,
  required int claimedStartMs,
  required bool isUnknown,
}) {
  if (recordedSessionId == null || recordedSessionId != anchor.sessionId) {
    return ClockVerdict.otherSession;
  }
  if (startUptimeSec == null || startUptimeSec <= 0) {
    return ClockVerdict.unplaceable;
  }
  if (isUnknown) {
    return ClockVerdict.fileUnknown;
  }
  final expected = anchor.startMsFor(startUptimeSec);
  final off = (expected - claimedStartMs).abs();
  return off > anchor.plausibleDriftMs ? ClockVerdict.correctWrong : ClockVerdict.alreadyCorrect;
}
