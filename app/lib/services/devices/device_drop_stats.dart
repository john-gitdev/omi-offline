import 'dart:convert';

/// Snapshot of the firmware's SD-write drop counters, read from the
/// 0x19B10062 diagnostics characteristic.
///
/// `blockDrops`: 440-byte storage blocks the SD queue rejected (each ~5 Opus
/// frames / ~100 ms audio).
/// `streamFrameDrops`: individual audio frames dropped in write_to_file()
/// when the SD msgq saturated (typically during card-internal stalls).
/// `bootFrameDrops`: frames lost during the SD mount/boot window.
/// `lastBlockDropUptimeMs`: firmware uptime at the most recent block drop
/// (0 = none since boot).
/// `currentUptimeMs`: firmware uptime at the moment of the read — used to
/// render "X ago" without trusting the phone clock.
///
/// `failedConnCount` / `lastFailedConnDuringSlowAdv`: cumulative BLE connect
/// callbacks that reported an outright failure, persisted across reboots.
/// Appended to the characteristic at offset 20 — 0 / false on older firmware
/// that returns only the legacy 20 bytes. Note this counter does NOT catch the
/// common "visible but unconnectable" outage; see [estabFailCount]. See NOTES.md
/// "BLE: advertising but won't connect".
class DeviceDropStats {
  final int blockDrops;
  final int lastBlockDropUptimeMs;
  final int streamFrameDrops;
  final int bootFrameDrops;
  final int currentUptimeMs;
  final int failedConnCount;
  final bool lastFailedConnDuringSlowAdv;

  /// PCM blocks dropped before Opus encode because the codec ring buffer was
  /// full (encoder starved). Each ~= one mic chunk (~100 ms). Appended at
  /// offset 28 — 0 on older firmware that returns only the first 28 bytes.
  final int codecFrameDrops;

  /// High-water mark of the firmware SD write queue (sd_msgq) occupancy since
  /// boot, out of SD_REQ_QUEUE_MSGS (120). Shows how close the write path runs
  /// to the drop edge — low peak = plenty of headroom. Appended at offset 32;
  /// 0 on older firmware.
  final int msgqPeakDepth;

  /// Times the firmware forced an audio-write turn over pending reads because a
  /// steady read stream would otherwise have starved writes (write fairness
  /// engaged). Appended at offset 36; 0 on older firmware.
  final int writeFairActivations;

  /// Links that came up and then died with HCI 0x3e (CONN_FAIL_TO_ESTAB) — no
  /// data-channel packet exchanged in the first 6 connection events.
  ///
  /// This is the counter that identifies a "visible but unconnectable" outage,
  /// and [failedConnCount] does not: on a peripheral the controller reports the
  /// connection as successful the moment it receives CONNECT_IND, so the host
  /// takes the success path and only learns of the failure at disconnect.
  ///
  /// Nonzero after an outage → the Omi *did* receive the connect requests and the
  /// link died at establishment (peripheral controller / RF / coexistence). Flat,
  /// with the central logging 0x3e → the Omi never heard them, so the fault is on
  /// the central. Appended at offset 40; 0 on older firmware.
  final int estabFailCount;

  /// Priority Recording lifecycle counters, appended at offsets 44–52 (60-byte
  /// firmware); 0 on older builds. These make a lost Priority Recording traceable
  /// from the app log alone, no RTT capture:
  ///
  /// `priorityRecordStarts`: 0xFFFFFFF8 start-marker writes attempted (a priority
  /// recording opened). `priorityRecordStops`: priority recordings ended —
  /// `starts > stops` means one was left open. `markerWriteDrops`: inline markers
  /// (start/stop/tap/mute) that failed to persist to SD. The empty-bin counters
  /// that complete this group are documented on their own fields below (offsets 56
  /// and 96), because only one of the two means anything was lost.
  ///
  /// The tell-tale for the vanished-priority-recording bug is `priorityRecordStarts`
  /// moving while `markerWriteDrops` also moves and no high-priority recording
  /// surfaces — the marker + audio were dropped on-device.
  final int priorityRecordStarts;
  final int priorityRecordStops;
  final int markerWriteDrops;

  /// Rotations that closed a bin holding nothing but its 36-byte header.
  ///
  /// **This is not a loss signal**, and treating it as one produced false "lost
  /// Priority Recording" reports. An empty bin means nothing at all reached the card
  /// for that segment, and an ACCEPTED marker cannot be the missing part — the firmware
  /// force-drains a marker's partial block immediately, so a marker the SD queue takes
  /// puts the bin well past header-only. (Rejected, it stays buffered and lands in the
  /// NEXT bin instead, leaving this one empty — that needs a full SD queue.) What is
  /// left is a rotation that landed where
  /// nothing was being written: in auto mode, any silent stretch. Two Force Syncs
  /// across a quiet lunch break move this and mean nothing.
  ///
  /// [markerWriteDrops] is the loss signal and stands on its own. Do not read the two
  /// together: both are boot-cumulative totals that identify no segment, so a marker
  /// dropped in one recording and an empty bin from an idle rotation an hour later are
  /// indistinguishable from a correlated loss. Firmware `oo-3.0.2` and later record WHY
  /// each empty bin happened, timestamped, in the 0x0063 event log — see
  /// `DiagLogRecord.rotateReasonLabel`. That is where correlation belongs.
  final int emptyBinRotations;

  /// Session-end marker (0xFFFFFFFC) emits attempted from the firmware finalize
  /// path, appended at offset 60 (68-byte firmware); 0 on older builds. Pins the
  /// "lost stop marker" question: if a priority/manual stop leaves no app-visible
  /// marker but this moved, the marker was emitted-then-dropped (see
  /// [markerPauseGateSaves]); if it did NOT move, the emit path never fired.
  final int sessionEndMarkerEmits;

  /// Marker-bearing storage blocks the firmware RESCUED at its `sd_write_paused`
  /// gate — written through the pause instead of dropped (offset 64; 0 on older
  /// builds). Before firmware oo-2.5.9 this exact block was silently discarded (the
  /// one marker-loss path that bumps no other counter), so this counted the losses;
  /// now it counts rescues, so a nonzero value with recordings finalizing means the
  /// fix is firing.
  final int markerPauseGateSaves;

  /// Peak stack usage (bytes) of the SD worker and codec/encode threads since boot,
  /// appended at offsets 68–72 (76-byte firmware); 0 on older builds or when the
  /// firmware's stack-info configs are off. These are gauges (high-water since boot),
  /// not counters — displayed raw against the configured stack sizes, never
  /// baseline-subtracted. Large unused headroom (`used` well below the configured
  /// size) means the stack is over-provisioned and reclaimable.
  final int sdWorkerStackUsed;
  final int codecStackUsed;

  /// Ring backend only: the slowest single SD primitive since boot, packed as
  /// `(tag << 24) | duration_ms`, tag 1=write 2=read 3=CTRL_SYNC. Appended at
  /// offset 76; 0 on older firmware or the LittleFS backend. Pinpoints a
  /// queue-full drop burst to the exact stalling disk op — see [ringMaxIoMs] /
  /// [ringMaxIoOp].
  final int ringMaxIoRaw;

  /// Ring backend only: count of write_sectors / CTRL_SYNC failures (EIO) since
  /// boot (offset 80; 0 on older firmware / LittleFS). A nonzero value with a
  /// small [ringMaxIoMs] means the NAND was *rejecting* writes, not merely slow.
  final int ringIoErrors;

  /// Duration (ms) of the slowest SD primitive, decoded from [ringMaxIoRaw].
  int get ringMaxIoMs => ringMaxIoRaw & 0x00FFFFFF;

  /// The disk op behind [ringMaxIoMs]: 'write', 'read', 'sync', or '—'.
  String get ringMaxIoOp {
    switch ((ringMaxIoRaw >> 24) & 0xFF) {
      case 1:
        return 'write';
      case 2:
        return 'read';
      case 3:
        return 'sync';
      default:
        return '—';
    }
  }

  /// Device uptime (ms) at the last mic frame the VAD processed (offset 84; 0 on
  /// firmware older than oo-2.10.0, or before the first frame). Against
  /// [currentUptimeMs] this is the only direct answer to "is the mic delivering
  /// right now" — see [micSilentForMs]. It exists because a parked or wedged mic
  /// produces *no* event-log records at all, so a quiet log cannot distinguish
  /// "nothing happened" from "the mic stopped".
  final int lastMicFrameUptimeMs;

  /// Total ms the VAD has held a recording open since boot (offset 88; 0 on older
  /// firmware). Against [currentUptimeMs] this is the capture duty cycle — the
  /// fraction of the day being encoded and written, which is what the auto-mode
  /// threshold actually costs.
  final int voicedMs;

  /// How long the mic has been silent, or `null` when the firmware doesn't report
  /// it (or hasn't delivered a first frame yet). Small values are normal — frames
  /// arrive every 100 ms; minutes mean the mic is parked or stopped.
  int? get micSilentForMs {
    if (lastMicFrameUptimeMs == 0) return null;
    // Unsigned 32-bit delta, not a clamped subtraction. Both values are u32 device
    // uptimes that wrap every ~49.7 days; a naive subtraction across the wrap goes
    // negative, and clamping that to 0 reports "the mic is alive" — masking a parked
    // or wedged mic in exactly the direction that hides a fault.
    return (currentUptimeMs - lastMicFrameUptimeMs) & 0xFFFFFFFF;
  }

  /// Capture duty as a 0..1 fraction of uptime, or `null` when unreported.
  double? get captureDutyFraction {
    if (voicedMs == 0 || currentUptimeMs <= 0) return null;
    // Both are u32 device counters and uptime wraps first (~49.7 days), after which
    // voiced time exceeds it and the ratio is meaningless. Report unavailable rather
    // than clamping to 1.0, which would state "this device records 100% of the time"
    // — a plausible-looking number that is simply wrong. Recovering the true duty
    // needs a wrap count the wire protocol does not carry.
    //
    // Known and accepted: this catches the FIRST wrap only. If voicedMs later wraps
    // too the ordering inverts and a wrong (low) figure returns — but that needs
    // ~60 days of unbroken uptime at the duty this device actually runs, and a DFU,
    // a flat cell or the watchdog all reboot it long before. Not worth a protocol
    // field for a gauge.
    if (voicedMs > currentUptimeMs) return null;
    return voicedMs / currentUptimeMs;
  }

  /// Advertising interval, packed `[active u8][desired u8]` (offset 92; 0 on firmware
  /// older than oo-2.10.0). 0 = fast (100–150 ms), 1 = slow (~1 s).
  ///
  /// Distinct from [lastFailedConnDuringSlowAdv] (offset 24), which is the mode during
  /// the last *failed* connection and says nothing about the current one. Advertising
  /// stops while connected, so the value read here is the interval that was in force
  /// when the phone found the device — which is the only way to confirm the device
  /// settles to the slow interval when idle.
  final int advModesRaw;

  /// True when the device was advertising on the slow (~1 s) interval.
  bool get advActiveSlow => (advModesRaw & 0xFF) == 1;

  /// True when slow is the *requested* interval. Differs from [advActiveSlow] only
  /// when a mode switch has been asked for and the advertising watchdog has not
  /// applied it yet — which is what a stuck switch looks like.
  bool get advDesiredSlow => ((advModesRaw >> 8) & 0xFF) == 1;

  /// The firmware's SD write-queue size (`SD_REQ_QUEUE_MSGS`), used as the denominator
  /// for [msgqPeakDepth]. The firmware doesn't send this as a field; it's derived from
  /// the payload length in the parser — the 76-byte payload is only produced by the
  /// build that also raised the queue to 120, so a shorter payload means the old 100.
  /// Prevents reporting a peak of 96 as `96/120` (healthy-looking) on firmware whose
  /// real ceiling is 100.
  final int sdQueueMax;

  /// The firmware's per-boot `device_session_id` — the id every recording made in
  /// this hardware session is stamped with in its `.meta`.
  ///
  /// Appended at offset 96; `0` on older firmware, and unambiguous because the
  /// firmware never issues 0 (`ensure_device_session_id()` re-rolls until non-zero).
  ///
  /// Read together with [currentUptimeMs] from the same payload, this is what makes a
  /// clock anchor trustworthy: the two fields come from one read, so they cannot
  /// disagree about which boot they describe. See `device_clock_anchor.dart`.
  final int deviceSessionId;

  final DateTime readAt;

  const DeviceDropStats({
    required this.blockDrops,
    required this.lastBlockDropUptimeMs,
    required this.streamFrameDrops,
    required this.bootFrameDrops,
    required this.currentUptimeMs,
    this.failedConnCount = 0,
    this.lastFailedConnDuringSlowAdv = false,
    this.codecFrameDrops = 0,
    this.msgqPeakDepth = 0,
    this.writeFairActivations = 0,
    this.estabFailCount = 0,
    this.priorityRecordStarts = 0,
    this.priorityRecordStops = 0,
    this.markerWriteDrops = 0,
    this.emptyBinRotations = 0,
    this.sessionEndMarkerEmits = 0,
    this.markerPauseGateSaves = 0,
    this.sdWorkerStackUsed = 0,
    this.codecStackUsed = 0,
    this.ringMaxIoRaw = 0,
    this.ringIoErrors = 0,
    this.lastMicFrameUptimeMs = 0,
    this.voicedMs = 0,
    this.advModesRaw = 0,
    this.sdQueueMax = 120,
    this.deviceSessionId = 0,
    required this.readAt,
  });

  bool get hasAnyDrops => blockDrops > 0 || streamFrameDrops > 0 || bootFrameDrops > 0 || codecFrameDrops > 0;

  /// Milliseconds since the most recent block drop, or `null` if none.
  int? get msSinceLastBlockDrop {
    if (lastBlockDropUptimeMs == 0) return null;
    return currentUptimeMs - lastBlockDropUptimeMs;
  }

  /// Serializes the boot-relative counters (every counter that resets to 0 when
  /// the device reboots — i.e. all of them except the flash-persisted connect-fail
  /// counters, which the app baselines separately) plus [currentUptimeMs] as the
  /// device-uptime at capture. Used to persist a "reset diagnostics" baseline across
  /// an app restart. Reboot detection on restore is counter-based, not uptime-based
  /// (see [looksRebootedFrom]); [currentUptimeMs] is retained only as provenance of
  /// when the reset was taken.
  String toBaselineJson() => jsonEncode({
        'blockDrops': blockDrops,
        'streamFrameDrops': streamFrameDrops,
        'bootFrameDrops': bootFrameDrops,
        'codecFrameDrops': codecFrameDrops,
        'msgqPeakDepth': msgqPeakDepth,
        'writeFairActivations': writeFairActivations,
        'priorityRecordStarts': priorityRecordStarts,
        'priorityRecordStops': priorityRecordStops,
        'markerWriteDrops': markerWriteDrops,
        'emptyBinRotations': emptyBinRotations,
        'sessionEndMarkerEmits': sessionEndMarkerEmits,
        'markerPauseGateSaves': markerPauseGateSaves,
        'currentUptimeMs': currentUptimeMs,
      });

  /// Rebuilds a baseline snapshot from [toBaselineJson]; returns null on malformed
  /// input. `readAt` is set to now, and the flash-persisted connect-fail counters
  /// and the derived last-drop uptime default to 0 (they are not part of this
  /// baseline).
  static DeviceDropStats? fromBaselineJson(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      int g(String k) => (j[k] as num?)?.toInt() ?? 0;
      return DeviceDropStats(
        blockDrops: g('blockDrops'),
        lastBlockDropUptimeMs: 0,
        streamFrameDrops: g('streamFrameDrops'),
        bootFrameDrops: g('bootFrameDrops'),
        currentUptimeMs: g('currentUptimeMs'),
        codecFrameDrops: g('codecFrameDrops'),
        msgqPeakDepth: g('msgqPeakDepth'),
        writeFairActivations: g('writeFairActivations'),
        priorityRecordStarts: g('priorityRecordStarts'),
        priorityRecordStops: g('priorityRecordStops'),
        markerWriteDrops: g('markerWriteDrops'),
        emptyBinRotations: g('emptyBinRotations'),
        sessionEndMarkerEmits: g('sessionEndMarkerEmits'),
        markerPauseGateSaves: g('markerPauseGateSaves'),
        readAt: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  /// True if this snapshot indicates the device rebooted since [baseline] was
  /// captured. Every counter serialized in the baseline resets to 0 on reboot and
  /// is monotonic within a boot, so any of them reading below the baseline can only
  /// mean a reboot (or a re-flash). This is deliberately used instead of comparing
  /// [currentUptimeMs]: the firmware uptime is a uint32 millisecond value that wraps
  /// every ~49.7 days, which an uptime comparison would misread as a reboot. When
  /// the baseline counters were all zero a reboot leaves nothing to detect here, but
  /// then the displayed "since reset" value (current − 0) is correct either way.
  ///
  /// A uint32 *counter* wrap could in theory also read as backwards, but unlike the
  /// uptime it is unreachable here: these are all boot-relative counters that reset
  /// to 0 every boot (only the flash-persisted connect-fail counters survive, and
  /// they are not compared here), and they increment on drops / rotations / user
  /// actions — orders of magnitude slower than a 1 kHz millisecond clock. Reaching
  /// 2^32 would take years of a single uninterrupted boot, which the battery life
  /// makes impossible, so a backwards counter is an unambiguous reboot signal.
  bool looksRebootedFrom(DeviceDropStats baseline) =>
      blockDrops < baseline.blockDrops ||
      streamFrameDrops < baseline.streamFrameDrops ||
      bootFrameDrops < baseline.bootFrameDrops ||
      codecFrameDrops < baseline.codecFrameDrops ||
      msgqPeakDepth < baseline.msgqPeakDepth ||
      writeFairActivations < baseline.writeFairActivations ||
      priorityRecordStarts < baseline.priorityRecordStarts ||
      priorityRecordStops < baseline.priorityRecordStops ||
      markerWriteDrops < baseline.markerWriteDrops ||
      emptyBinRotations < baseline.emptyBinRotations ||
      sessionEndMarkerEmits < baseline.sessionEndMarkerEmits ||
      markerPauseGateSaves < baseline.markerPauseGateSaves;
}
