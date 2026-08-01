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
        advRestartFailures: 9,
        advWatchdogRecoveries: 8,
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
      // Advertising-restart guard (oo-2.8.3+). These are monotonic event counters,
      // so they baseline like the rest — unlike the high-water marks, which are
      // deliberately excluded because peak − peak is not a since-reset peak.
      expect(restored.advRestartFailures, 9);
      expect(restored.advWatchdogRecoveries, 8);
      // currentUptimeMs is retained as provenance (when the reset was taken);
      // reboot detection is counter-based, so nothing reads it, but it round-trips.
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

  group('looksRebootedFrom', () {
    test('false when every counter is at or above the baseline', () {
      final base = stats(blockDrops: 3, streamFrameDrops: 2, codecFrameDrops: 1);
      final now = stats(blockDrops: 5, streamFrameDrops: 2, codecFrameDrops: 4);
      expect(now.looksRebootedFrom(base), isFalse);
    });

    test('true when any counter dropped below the baseline (reboot zeroed it)', () {
      final base = stats(blockDrops: 3, streamFrameDrops: 2);
      expect(stats(blockDrops: 0, streamFrameDrops: 0).looksRebootedFrom(base), isTrue);
      // A single counter going backwards is enough.
      expect(stats(blockDrops: 3, streamFrameDrops: 1).looksRebootedFrom(base), isTrue);
    });

    test('detects a reboot even when uptime has already climbed back past the baseline', () {
      // The old uptime-comparison heuristic missed this: device rebooted, then ran
      // long enough that its new uptime exceeds the captured one. The counters are
      // what give it away.
      final base = stats(blockDrops: 10, currentUptimeMs: 5000);
      final now = stats(blockDrops: 1, currentUptimeMs: 9000);
      expect(now.looksRebootedFrom(base), isTrue);
    });

    test('a uint32 uptime wrap with counters still climbing is NOT a reboot', () {
      // Uptime wrapped (~49.7 days), so currentUptimeMs went backwards, but the
      // counters kept increasing — this must not be treated as a reboot.
      final base = stats(blockDrops: 4, currentUptimeMs: 4294967000);
      final now = stats(blockDrops: 6, currentUptimeMs: 100);
      expect(now.looksRebootedFrom(base), isFalse);
    });

    test('a zero baseline reads as not-rebooted (display is current − 0 either way)', () {
      expect(stats(blockDrops: 7).looksRebootedFrom(stats()), isFalse);
    });

    test('a reboot visible ONLY in the advertising counters is still detected', () {
      // The wedge-guard counters can be the sole movers on a device that is
      // otherwise healthy: no drops, no rotations, nothing else to go backwards.
      // Before they were added to looksRebootedFrom, this reboot was invisible.
      final base = DeviceDropStats(
        blockDrops: 0,
        lastBlockDropUptimeMs: 0,
        streamFrameDrops: 0,
        bootFrameDrops: 0,
        currentUptimeMs: 5000,
        advRestartFailures: 4,
        advWatchdogRecoveries: 2,
        readAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      final afterReboot = DeviceDropStats(
        blockDrops: 0,
        lastBlockDropUptimeMs: 0,
        streamFrameDrops: 0,
        bootFrameDrops: 0,
        currentUptimeMs: 100,
        advRestartFailures: 0,
        advWatchdogRecoveries: 0,
        readAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(afterReboot.looksRebootedFrom(base), isTrue);

      // And each counter independently suffices, in BOTH directions — a watchdog
      // rescue can happen with no start ever having failed, and a start can fail
      // without the watchdog ever rescuing anything.
      expect(
        DeviceDropStats(
          blockDrops: 0,
          lastBlockDropUptimeMs: 0,
          streamFrameDrops: 0,
          bootFrameDrops: 0,
          currentUptimeMs: 100,
          advRestartFailures: 4, // flat
          advWatchdogRecoveries: 1, // only this one dropped
          readAt: DateTime.fromMillisecondsSinceEpoch(0),
        ).looksRebootedFrom(base),
        isTrue,
      );
      expect(
        DeviceDropStats(
          blockDrops: 0,
          lastBlockDropUptimeMs: 0,
          streamFrameDrops: 0,
          bootFrameDrops: 0,
          currentUptimeMs: 100,
          advRestartFailures: 3, // only this one dropped
          advWatchdogRecoveries: 2, // flat
          readAt: DateTime.fromMillisecondsSinceEpoch(0),
        ).looksRebootedFrom(base),
        isTrue,
      );
    });

    test('advertising counters climbing within a boot is NOT a reboot', () {
      // The watchdog firing repeatedly is exactly what a degraded-but-recovering
      // device looks like; it must not be misread as a reboot.
      final base = DeviceDropStats(
        blockDrops: 0,
        lastBlockDropUptimeMs: 0,
        streamFrameDrops: 0,
        bootFrameDrops: 0,
        currentUptimeMs: 5000,
        advRestartFailures: 1,
        advWatchdogRecoveries: 1,
        readAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      final later = DeviceDropStats(
        blockDrops: 0,
        lastBlockDropUptimeMs: 0,
        streamFrameDrops: 0,
        bootFrameDrops: 0,
        currentUptimeMs: 90000,
        advRestartFailures: 3,
        advWatchdogRecoveries: 5,
        readAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(later.looksRebootedFrom(base), isFalse);
    });
  });
}
