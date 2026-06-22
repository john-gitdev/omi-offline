import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/devices/device_crash_log.dart';

void main() {
  DeviceCrashLog log({int cause = 0, int uptime = 0}) => DeviceCrashLog(
        deviceId: 'dev',
        connectedAt: DateTime.fromMillisecondsSinceEpoch(0),
        resetCause: cause,
        uptimeSeconds: uptime,
      );

  group('isCrash', () {
    test('watchdog timeout (0x10) is a crash', () {
      expect(log(cause: 0x10).isCrash, isTrue);
    });

    test('CPU lockup (0x100) is a crash', () {
      expect(log(cause: 0x100).isCrash, isTrue);
    });

    test('watchdog + lockup together is a crash', () {
      expect(log(cause: 0x110).isCrash, isTrue);
    });

    test('a crash bit set alongside benign bits still counts as a crash', () {
      // power-on (0x08) + watchdog (0x10)
      expect(log(cause: 0x18).isCrash, isTrue);
    });

    test('benign causes (pin/software/brownout/power-on) are NOT crashes', () {
      expect(log(cause: 0x001).isCrash, isFalse); // pin reset
      expect(log(cause: 0x002).isCrash, isFalse); // software reset
      expect(log(cause: 0x004).isCrash, isFalse); // brownout
      expect(log(cause: 0x008).isCrash, isFalse); // power-on
    });

    test('zero cause is not a crash', () {
      expect(log(cause: 0).isCrash, isFalse);
    });
  });

  group('causeLabel', () {
    test('zero maps to "unknown"', () {
      expect(log(cause: 0).causeLabel, 'unknown');
    });

    test('each single bit maps to its human label', () {
      expect(log(cause: 0x001).causeLabel, 'pin reset');
      expect(log(cause: 0x002).causeLabel, 'software reset');
      expect(log(cause: 0x004).causeLabel, 'brownout');
      expect(log(cause: 0x008).causeLabel, 'power-on reset');
      expect(log(cause: 0x010).causeLabel, 'watchdog timeout');
      expect(log(cause: 0x020).causeLabel, 'debug reset');
      expect(log(cause: 0x040).causeLabel, 'security violation');
      expect(log(cause: 0x080).causeLabel, 'low power wake');
      expect(log(cause: 0x100).causeLabel, 'CPU lockup');
    });

    test('multiple bits join in ascending-bit order with ", "', () {
      // power-on (0x08) + watchdog (0x10) + CPU lockup (0x100)
      expect(log(cause: 0x118).causeLabel, 'power-on reset, watchdog timeout, CPU lockup');
    });

    test('an unmapped bit-only value falls back to zero-padded hex', () {
      // 0x200 has no label and no recognised bits → raw hex fallback.
      expect(log(cause: 0x200).causeLabel, '0x00000200');
    });

    test('recognised bits win even when unmapped bits are also set', () {
      // 0x201 = unmapped 0x200 + pin reset 0x001 → only the known label shows.
      expect(log(cause: 0x201).causeLabel, 'pin reset');
    });
  });

  group('uptimeStr', () {
    test('zero renders as the <10m floor (firmware reports 0 below resolution)', () {
      expect(log(uptime: 0).uptimeStr, '<10m');
    });

    test('sub-minute shows seconds', () {
      expect(log(uptime: 1).uptimeStr, '1s');
      expect(log(uptime: 59).uptimeStr, '59s');
    });

    test('sub-hour shows minutes and seconds', () {
      expect(log(uptime: 60).uptimeStr, '1m 0s');
      expect(log(uptime: 90).uptimeStr, '1m 30s');
      expect(log(uptime: 3599).uptimeStr, '59m 59s');
    });

    test('an hour or more shows hours and minutes', () {
      expect(log(uptime: 3600).uptimeStr, '1h 0m');
      expect(log(uptime: 3661).uptimeStr, '1h 1m');
      expect(log(uptime: 7320).uptimeStr, '2h 2m');
    });
  });

  group('toJson / fromJson', () {
    test('round-trips all fields', () {
      final original = DeviceCrashLog(
        deviceId: 'abc-123',
        connectedAt: DateTime.fromMillisecondsSinceEpoch(1782120000000),
        resetCause: 0x110,
        uptimeSeconds: 4242,
      );
      final restored = DeviceCrashLog.fromJson(original.toJson());
      expect(restored.deviceId, 'abc-123');
      expect(restored.connectedAt, original.connectedAt);
      expect(restored.resetCause, 0x110);
      expect(restored.uptimeSeconds, 4242);
    });

    test('fromJson tolerates a missing device_id (legacy persisted entry)', () {
      final restored = DeviceCrashLog.fromJson({
        'at': 0,
        'cause': 0x10,
        'uptime': 12,
      });
      expect(restored.deviceId, '');
      expect(restored.resetCause, 0x10);
      expect(restored.isCrash, isTrue);
    });
  });
}
