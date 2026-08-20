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

/// The anchors the app is holding, keyed by hardware session.
///
/// A set rather than one current anchor, for two reasons.
///
/// The anchor outlives its session. It records "session S's uptime 0 was at wall clock
/// T", and that stays true forever — S ending does not invalidate it. Recordings from S
/// can still be sitting unsynced on the SD card when the Omi reboots into S', and they
/// arrive placeable only if S's anchor survived S'. Keeping one slot would throw away
/// the answer at the moment the device rebooted, which is precisely when the Omi's own
/// clock is least trustworthy.
///
/// And a user reverting a re-filed recording has to discard *that session's* anchor,
/// or the next processing pass silently re-files it. That is a keyed delete, which
/// needs keyed storage.
///
/// Bounded and oldest-first, because nothing here is worth unbounded growth: an anchor
/// is only ever consulted for recordings still on disk, and a device that has rebooted
/// [maxEntries] times since a recording was made has long since had it synced.
class DeviceClockAnchorSet {
  /// Oldest first. Bounded — see the class doc.
  static const int maxEntries = 8;

  final List<DeviceClockAnchor> anchors;

  const DeviceClockAnchorSet(this.anchors);

  const DeviceClockAnchorSet.empty() : anchors = const [];

  bool get isEmpty => anchors.isEmpty;

  /// The anchor for [sessionId], or null if this session was never observed live.
  ///
  /// Null is the honest answer and the caller must treat it as "leave the recording
  /// alone": a session the phone never saw running cannot be placed, because the gap
  /// between two sessions is unmeasurable once the counters have reset.
  DeviceClockAnchor? forSession(int? sessionId) {
    if (sessionId == null || sessionId == 0) return null;
    for (final a in anchors) {
      if (a.sessionId == sessionId) return a;
    }
    return null;
  }

  /// Adds [anchor], replacing any existing anchor for the same session.
  ///
  /// Replacing rather than keeping the first: a later observation of the same session
  /// is strictly better evidence. It is taken over a longer baseline, so any error in
  /// the phone's own reading (BLE round-trip, a moment's scheduling delay) is a smaller
  /// fraction of the span it is being used to measure.
  DeviceClockAnchorSet upsert(DeviceClockAnchor anchor) {
    final next = anchors.where((a) => a.sessionId != anchor.sessionId).toList()..add(anchor);
    if (next.length > maxEntries) {
      next.removeRange(0, next.length - maxEntries);
    }
    return DeviceClockAnchorSet(next);
  }

  /// Drops [sessionId]'s anchor. Used by the revert action — without it the next
  /// processing pass would re-apply the correction the user just undid.
  DeviceClockAnchorSet without(int sessionId) =>
      DeviceClockAnchorSet(anchors.where((a) => a.sessionId != sessionId).toList());

  String encode() => jsonEncode(anchors.map((a) => a.toJson()).toList());

  /// Never throws: this is decoded on the connect and processing paths, where a
  /// corrupt preference must cost the correction feature and nothing else.
  static DeviceClockAnchorSet decode(String? raw) {
    if (raw == null || raw.isEmpty) return const DeviceClockAnchorSet.empty();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const DeviceClockAnchorSet.empty();
      final out = <DeviceClockAnchor>[];
      for (final e in decoded) {
        if (e is Map<String, dynamic>) {
          final a = DeviceClockAnchor.fromJson(e);
          if (a != null) out.add(a);
        }
      }
      return DeviceClockAnchorSet(out);
    } catch (_) {
      return const DeviceClockAnchorSet.empty();
    }
  }
}

/// What the app did to a session's timestamps, and whether the user rejected it.
///
/// Two things have to survive a correction, and neither can be recovered afterwards.
///
/// **What the timestamps were.** A correction rewrites filenames, and nothing else
/// records the times they had. Without the original offset kept here, "undo" has nothing
/// to put back — it can only invent something, and the obvious guess (uptime read as an
/// epoch) lands in 1970 rather than on the date the Omi actually filed.
///
/// **That the user said no.** Dropping the session's anchor is *not* enough on its own.
/// The anchor is re-captured from any later diagnostics read, and while the Omi stays on
/// the same boot that is every reconnect — so the next processing pass would find the
/// session disagreeing with a fresh anchor and re-file it, silently undoing the user's
/// decision. A rejection has to be remembered against the session, not against the
/// anchor.
class ClockCorrectionLedger {
  /// Bounded for the same reason the anchors are: entries are only consulted for
  /// recordings still on disk.
  static const int maxEntries = 16;

  /// sessionId → (original offset in ms, user rejected the correction).
  final Map<int, ({int originalOffsetMs, bool reverted})> entries;

  const ClockCorrectionLedger(this.entries);

  const ClockCorrectionLedger.empty() : entries = const {};

  /// True when the user has undone this session's correction. [applyClockAnchors] must
  /// leave such a session alone however convincing a later anchor looks.
  bool isReverted(int? sessionId) => sessionId != null && (entries[sessionId]?.reverted ?? false);

  /// The offset the session's recordings carried before the app moved them, or null if
  /// this session was never corrected (so there is nothing to restore).
  int? originalOffsetFor(int? sessionId) => sessionId == null ? null : entries[sessionId]?.originalOffsetMs;

  /// Records that [sessionId] was corrected, remembering the offset it had first.
  ///
  /// Keeps an existing entry's offset if there is one: the first correction is the one
  /// that moved the recordings away from the device's own timestamps, so its offset is
  /// the one an undo has to restore. A second pass would otherwise overwrite it with the
  /// app's own previous answer.
  ClockCorrectionLedger recordCorrection(int sessionId, int originalOffsetMs) {
    if (entries.containsKey(sessionId)) return this;
    final next = Map<int, ({int originalOffsetMs, bool reverted})>.from(entries);
    next[sessionId] = (originalOffsetMs: originalOffsetMs, reverted: false);
    while (next.length > maxEntries) {
      next.remove(next.keys.first);
    }
    return ClockCorrectionLedger(next);
  }

  /// Marks [sessionId] as rejected by the user, keeping its original offset.
  ClockCorrectionLedger markReverted(int sessionId) {
    final existing = entries[sessionId];
    final next = Map<int, ({int originalOffsetMs, bool reverted})>.from(entries);
    next[sessionId] = (originalOffsetMs: existing?.originalOffsetMs ?? 0, reverted: true);
    while (next.length > maxEntries) {
      next.remove(next.keys.first);
    }
    return ClockCorrectionLedger(next);
  }

  String encode() => jsonEncode({
        for (final e in entries.entries) e.key.toString(): {'o': e.value.originalOffsetMs, 'r': e.value.reverted},
      });

  /// Never throws — a corrupt preference must cost the undo affordance, nothing else.
  static ClockCorrectionLedger decode(String? raw) {
    if (raw == null || raw.isEmpty) return const ClockCorrectionLedger.empty();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const ClockCorrectionLedger.empty();
      final out = <int, ({int originalOffsetMs, bool reverted})>{};
      decoded.forEach((k, v) {
        final id = int.tryParse(k.toString());
        if (id == null || v is! Map) return;
        final o = v['o'];
        final r = v['r'];
        if (o is! int) return;
        out[id] = (originalOffsetMs: o, reverted: r == true);
      });
      return ClockCorrectionLedger(out);
    } catch (_) {
      return const ClockCorrectionLedger.empty();
    }
  }
}
