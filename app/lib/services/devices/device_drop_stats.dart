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
  /// boot, out of SD_REQ_QUEUE_MSGS (100). Shows how close the write path runs
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
  /// [markerPauseGateDrops]); if it did NOT move, the emit path never fired.
  final int sessionEndMarkerEmits;

  /// Marker-bearing storage blocks the firmware discarded at its `sd_write_paused`
  /// gate, appended at offset 64; 0 on older builds. The one marker-loss path that
  /// bumps no other counter — a nonzero delta across a priority stop (with
  /// [sessionEndMarkerEmits] also moving) locates the loss at the SD pause gate.
  final int markerPauseGateDrops;
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
    this.markerPauseGateDrops = 0,
    required this.readAt,
  });

  bool get hasAnyDrops => blockDrops > 0 || streamFrameDrops > 0 || bootFrameDrops > 0 || codecFrameDrops > 0;

  /// Milliseconds since the most recent block drop, or `null` if none.
  int? get msSinceLastBlockDrop {
    if (lastBlockDropUptimeMs == 0) return null;
    return currentUptimeMs - lastBlockDropUptimeMs;
  }
}
