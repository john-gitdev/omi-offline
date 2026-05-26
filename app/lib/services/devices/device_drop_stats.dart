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
class DeviceDropStats {
  final int blockDrops;
  final int lastBlockDropUptimeMs;
  final int streamFrameDrops;
  final int bootFrameDrops;
  final int currentUptimeMs;
  final DateTime readAt;

  const DeviceDropStats({
    required this.blockDrops,
    required this.lastBlockDropUptimeMs,
    required this.streamFrameDrops,
    required this.bootFrameDrops,
    required this.currentUptimeMs,
    required this.readAt,
  });

  bool get hasAnyDrops => blockDrops > 0 || streamFrameDrops > 0 || bootFrameDrops > 0;

  /// Milliseconds since the most recent block drop, or `null` if none.
  int? get msSinceLastBlockDrop {
    if (lastBlockDropUptimeMs == 0) return null;
    return currentUptimeMs - lastBlockDropUptimeMs;
  }
}
