import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/byte_utils.dart';

void main() {
  // getUint32LittleEndian is the single decode primitive for every BLE protocol
  // field in this fork (storage stats, drop counters, crash cause, time sync,
  // file-list entries). Its correctness — especially unsigned handling of the
  // high bit — defines the wire format, so pin it explicitly.
  group('getUint32LittleEndian', () {
    test('all zero bytes decode to 0', () {
      expect([0, 0, 0, 0].getUint32LittleEndian(0), 0);
    });

    test('least-significant byte is byte 0 (little-endian)', () {
      expect([0x01, 0x00, 0x00, 0x00].getUint32LittleEndian(0), 1);
      expect([0x00, 0x01, 0x00, 0x00].getUint32LittleEndian(0), 256);
      expect([0x00, 0x00, 0x01, 0x00].getUint32LittleEndian(0), 65536);
      expect([0x00, 0x00, 0x00, 0x01].getUint32LittleEndian(0), 16777216);
    });

    test('mixed value assembles in little-endian order', () {
      expect([0x78, 0x56, 0x34, 0x12].getUint32LittleEndian(0), 0x12345678);
    });

    test('all-ones decodes as UNSIGNED 0xFFFFFFFF, never -1', () {
      // The `>>> 0` in the implementation is what guarantees this. A signed
      // shift would yield -1 and corrupt every counter/timestamp at full range.
      expect([0xFF, 0xFF, 0xFF, 0xFF].getUint32LittleEndian(0), 0xFFFFFFFF);
      expect([0xFF, 0xFF, 0xFF, 0xFF].getUint32LittleEndian(0), 4294967295);
    });

    test('high bit set stays positive (>= 2^31)', () {
      expect([0x00, 0x00, 0x00, 0x80].getUint32LittleEndian(0), 0x80000000);
      expect([0x00, 0x00, 0x00, 0x80].getUint32LittleEndian(0), 2147483648);
      expect([0x00, 0x00, 0x00, 0x80].getUint32LittleEndian(0).isNegative, isFalse);
    });

    test('decodes at a non-zero offset and ignores surrounding bytes', () {
      final buf = [0xAA, 0xBB, 0x78, 0x56, 0x34, 0x12, 0xCC];
      expect(buf.getUint32LittleEndian(2), 0x12345678);
    });

    test('two adjacent u32 fields decode independently (file-list style layout)', () {
      // index=7 at offset 0, timestamp=1782120037 at offset 4 — mirrors the
      // 16-byte storage-file record packing used by _parseAndSuccess.
      final buf = <int>[
        0x07, 0x00, 0x00, 0x00, // 7
        0x65, 0xFE, 0x38, 0x6A, // 1782120037 (0x6A38FE65)
      ];
      expect(buf.getUint32LittleEndian(0), 7);
      expect(buf.getUint32LittleEndian(4), 1782120037);
    });

    test('round-trips a realistic epoch-seconds timestamp', () {
      const epoch = 1782120038; // matches a timerStart used elsewhere in tests
      final bytes = [
        epoch & 0xFF,
        (epoch >> 8) & 0xFF,
        (epoch >> 16) & 0xFF,
        (epoch >> 24) & 0xFF,
      ];
      expect(bytes.getUint32LittleEndian(0), epoch);
    });
  });
}
