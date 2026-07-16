import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/devices/device_drop_stats.dart';

void main() {
  DeviceDropStats stats({
    int blockDrops = 0,
    int streamFrameDrops = 0,
    int bootFrameDrops = 0,
    int codecFrameDrops = 0,
    int lastBlockDropUptimeMs = 0,
    int currentUptimeMs = 0,
  }) =>
      DeviceDropStats(
        blockDrops: blockDrops,
        lastBlockDropUptimeMs: lastBlockDropUptimeMs,
        streamFrameDrops: streamFrameDrops,
        bootFrameDrops: bootFrameDrops,
        currentUptimeMs: currentUptimeMs,
        codecFrameDrops: codecFrameDrops,
        readAt: DateTime.fromMillisecondsSinceEpoch(0),
      );

  group('hasAnyDrops', () {
    test('false when every drop counter is zero', () {
      expect(stats().hasAnyDrops, isFalse);
    });

    test('true if any single counter is non-zero', () {
      expect(stats(blockDrops: 1).hasAnyDrops, isTrue);
      expect(stats(streamFrameDrops: 1).hasAnyDrops, isTrue);
      expect(stats(bootFrameDrops: 1).hasAnyDrops, isTrue);
      expect(stats(codecFrameDrops: 1).hasAnyDrops, isTrue);
    });

    test('does NOT count lastBlockDropUptimeMs/currentUptimeMs as drops', () {
      // These are timestamps, not counters — a fresh device with uptime but no
      // drops must read as healthy.
      expect(stats(lastBlockDropUptimeMs: 5000, currentUptimeMs: 9000).hasAnyDrops, isFalse);
    });
  });

  group('msSinceLastBlockDrop', () {
    test('null when there has been no block drop since boot', () {
      expect(stats(lastBlockDropUptimeMs: 0, currentUptimeMs: 10000).msSinceLastBlockDrop, isNull);
    });

    test('elapsed firmware-uptime delta when a drop occurred', () {
      expect(
        stats(lastBlockDropUptimeMs: 4000, currentUptimeMs: 10000).msSinceLastBlockDrop,
        6000,
      );
    });

    test('uses firmware uptime, independent of phone clock / readAt', () {
      final s = DeviceDropStats(
        blockDrops: 1,
        lastBlockDropUptimeMs: 1000,
        streamFrameDrops: 0,
        bootFrameDrops: 0,
        currentUptimeMs: 1500,
        readAt: DateTime.now(),
      );
      expect(s.msSinceLastBlockDrop, 500);
    });
  });

  group('appended-field defaults (older firmware that omits them)', () {
    test('failedConn / codec / msgq / write-fairness default to 0/false', () {
      final s = stats();
      expect(s.failedConnCount, 0);
      expect(s.lastFailedConnDuringSlowAdv, isFalse);
      expect(s.codecFrameDrops, 0);
      expect(s.msgqPeakDepth, 0);
      expect(s.writeFairActivations, 0);
    });
  });

  group('baseline JSON round-trip', () {
    test('preserves every boot-relative counter and the capture uptime', () {
      final original = DeviceDropStats(
        blockDrops: 11,
        lastBlockDropUptimeMs: 999, // NOT persisted — derived, not a baseline field
        streamFrameDrops: 22,
        bootFrameDrops: 33,
        currentUptimeMs: 123456,
        codecFrameDrops: 44,
        msgqPeakDepth: 55,
        writeFairActivations: 66,
        priorityRecordStarts: 7,
        priorityRecordStops: 6,
        markerWriteDrops: 5,
        emptyBinRotations: 4,
        sessionEndMarkerEmits: 3,
        markerPauseGateSaves: 2,
        readAt: DateTime.now(),
      );

      final restored = DeviceDropStats.fromBaselineJson(original.toBaselineJson())!;

      expect(restored.blockDrops, 11);
      expect(restored.streamFrameDrops, 22);
      expect(restored.bootFrameDrops, 33);
      expect(restored.codecFrameDrops, 44);
      expect(restored.msgqPeakDepth, 55);
      expect(restored.writeFairActivations, 66);
      expect(restored.priorityRecordStarts, 7);
      expect(restored.priorityRecordStops, 6);
      expect(restored.markerWriteDrops, 5);
      expect(restored.emptyBinRotations, 4);
      expect(restored.sessionEndMarkerEmits, 3);
      expect(restored.markerPauseGateSaves, 2);
      // currentUptimeMs must survive: the restore path uses it to detect a reboot
      // (uptime going backwards) and discard the stale baseline.
      expect(restored.currentUptimeMs, 123456);
      // Derived field is intentionally reset, not carried through.
      expect(restored.lastBlockDropUptimeMs, 0);
    });

    test('returns null on malformed JSON instead of throwing', () {
      expect(DeviceDropStats.fromBaselineJson('not json'), isNull);
      expect(DeviceDropStats.fromBaselineJson(''), isNull);
    });

    test('missing keys decode to 0 (forward/backward-compatible snapshot)', () {
      final restored = DeviceDropStats.fromBaselineJson('{"blockDrops": 9}')!;
      expect(restored.blockDrops, 9);
      expect(restored.priorityRecordStarts, 0);
      expect(restored.currentUptimeMs, 0);
    });
  });
}
