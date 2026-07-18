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

  /// Priority Recording lifecycle counters, appended at offsets 44–56 (60-byte
  /// firmware); 0 on older builds. These make a lost Priority Recording traceable
  /// from the app log alone, no RTT capture:
  ///
  /// `priorityRecordStarts`: 0xFFFFFFF8 start-marker writes attempted (a priority
  /// recording opened). `priorityRecordStops`: priority recordings ended —
  /// `starts > stops` means one was left open. `markerWriteDrops`: inline markers
  /// (start/stop/tap/mute) that failed to persist to SD. `emptyBinRotations`:
  /// rotations that closed a bin holding no audio.
  ///
  /// The tell-tale for the vanished-priority-recording bug is `priorityRecordStarts`
  /// moving while `emptyBinRotations` (and/or `markerWriteDrops`) also moves and no
  /// high-priority recording surfaces — the marker + audio were dropped on-device.
  final int priorityRecordStarts;
  final int priorityRecordStops;
  final int markerWriteDrops;
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

  /// Opportunistic allocator-lookahead refills (idle-gc), appended at offsets
  /// 68–72 (76-byte firmware); 0 on older builds.
  ///
  /// `idleGcRuns`: times the firmware ran `lfs_fs_gc` during an AAD silence pause
  /// to pre-warm the block allocator off the write path. `idleGcMaxMs`: the longest
  /// such refill — a high-water mark that approximates how long a full-FS allocator
  /// traversal WOULD have stalled the write path had it fired mid-recording instead.
  /// Read together with [msgqPeakDepth]: nonzero `idleGcRuns` with a large
  /// `idleGcMaxMs` and a peak depth that stays clear of the queue ceiling means the
  /// scan is being absorbed during silence, as intended.
  final int idleGcRuns;
  final int idleGcMaxMs;

  /// Peak stack usage (bytes) of the SD worker and codec/encode threads since boot,
  /// appended at offsets 76–80 (84-byte firmware); 0 on older builds or when the
  /// firmware's stack-info configs are off. These are gauges (high-water since boot),
  /// not counters — displayed raw against the configured stack sizes, never
  /// baseline-subtracted. Large unused headroom (`used` well below the configured
  /// size) means the stack is over-provisioned and reclaimable.
  final int sdWorkerStackUsed;
  final int codecStackUsed;
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
    this.idleGcRuns = 0,
    this.idleGcMaxMs = 0,
    this.sdWorkerStackUsed = 0,
    this.codecStackUsed = 0,
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
        'idleGcRuns': idleGcRuns,
        'idleGcMaxMs': idleGcMaxMs,
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
        idleGcRuns: g('idleGcRuns'),
        idleGcMaxMs: g('idleGcMaxMs'),
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
      markerPauseGateSaves < baseline.markerPauseGateSaves ||
      idleGcRuns < baseline.idleGcRuns ||
      idleGcMaxMs < baseline.idleGcMaxMs;
}
