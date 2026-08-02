import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/devices/diag_log_record.dart';

/// Encode one 16-byte record exactly as the firmware `diag_event_t` (LE):
///   [u32 seq][u32 uptime_ms][u8 code][u8 backend][u16 arg0][u32 arg1]
List<int> encodeRecord({
  required int seq,
  required int uptimeMs,
  required int code,
  required int backend,
  int arg0 = 0,
  int arg1 = 0,
}) {
  final b = ByteData(16);
  b.setUint32(0, seq, Endian.little);
  b.setUint32(4, uptimeMs, Endian.little);
  b.setUint8(8, code);
  b.setUint8(9, backend);
  b.setUint16(10, arg0, Endian.little);
  b.setUint32(12, arg1, Endian.little);
  return b.buffer.asUint8List();
}

/// Encode the 12-byte 0x0063 snapshot header (LE) followed by [records].
List<int> encodeSnapshot({
  required int recordCount,
  required int dropped,
  required int maxSeq,
  List<List<int>> records = const [],
  int recordSize = 16,
}) {
  final h = ByteData(12);
  h.setUint8(0, recordSize);
  h.setUint8(1, 0);
  h.setUint16(2, recordCount, Endian.little);
  h.setUint32(4, dropped, Endian.little);
  h.setUint32(8, maxSeq, Endian.little);
  return [...h.buffer.asUint8List(), for (final r in records) ...r];
}

void main() {
  group('DiagLogRecord.fromBytes', () {
    test('round-trips every field little-endian', () {
      final bytes = encodeRecord(
        seq: 0x01020304,
        uptimeMs: 123456,
        code: 1,
        backend: 1,
        arg0: 0xBEEF,
        arg1: 0xDEADBEEF,
      );
      final r = DiagLogRecord.fromBytes(bytes, 0)!;
      expect(r.seq, 0x01020304);
      expect(r.uptimeMs, 123456);
      expect(r.code, 1);
      expect(r.backend, 1);
      expect(r.arg0, 0xBEEF);
      expect(r.arg1, 0xDEADBEEF);
    });

    test('parses at a non-zero offset (record within a stream)', () {
      final a = encodeRecord(seq: 1, uptimeMs: 10, code: 4, backend: 0, arg1: 7);
      final b = encodeRecord(seq: 2, uptimeMs: 20, code: 5, backend: 1, arg1: 7);
      final stream = [...a, ...b];
      final r = DiagLogRecord.fromBytes(stream, 16)!;
      expect(r.seq, 2);
      expect(r.code, 5);
      expect(r.backend, 1);
    });

    test('returns null when fewer than 16 bytes remain', () {
      expect(DiagLogRecord.fromBytes(List.filled(15, 0), 0), isNull);
      final bytes = encodeRecord(seq: 1, uptimeMs: 1, code: 1, backend: 0);
      expect(DiagLogRecord.fromBytes(bytes, 8), isNull); // only 8 bytes left
    });
  });

  group('DiagLogRecord labels', () {
    test('known codes map to stable labels', () {
      DiagLogRecord rec(int code) => DiagLogRecord(seq: 1, uptimeMs: 0, code: code, backend: 0, arg0: 0, arg1: 0);
      expect(rec(1).label, 'empty_bin_rotation');
      expect(rec(2).label, 'marker_write_drop');
      expect(rec(3).label, 'marker_pause_gate_save');
      expect(rec(4).label, 'priority_record_start');
      expect(rec(5).label, 'priority_record_stop');
      expect(rec(6).label, 'session_end_marker_emit');
      expect(rec(7).label, 'sd_block_drop');
      expect(rec(8).label, 'codec_drop');
      expect(rec(13).label, 'adv_start_fail');
      expect(rec(14).label, 'adv_watchdog_rescue');
      expect(rec(15).label, 'adv_stop_fail');
    });

    test('advertising events decode mode and errno, and stay distinguishable', () {
      // 13 and 15 are deliberately separate codes: a failed start means the radio is
      // off the air, a failed stop only means the interval could not be changed.
      // Conflating them would mislead field diagnosis, so assert they read differently.
      DiagLogRecord rec(int code, int mode, int errnoMag) =>
          DiagLogRecord(seq: 1, uptimeMs: 0, code: code, backend: 0, arg0: mode, arg1: errnoMag);

      // arg1 carries the errno MAGNITUDE; the rendered form negates it (12 -> ENOMEM).
      expect(rec(13, 0, 12).description, contains('start failed'));
      expect(rec(13, 0, 12).description, contains('(fast)'));
      expect(rec(13, 0, 12).description, contains('-12'));
      expect(rec(13, 1, 12).description, contains('(slow)'));

      expect(rec(15, 1, 5).description, contains('stop failed'));
      expect(rec(15, 1, 5).description, contains('(slow)'));
      expect(rec(15, 1, 5).description, contains('interval unchanged'));
      // Must not read as an off-air event.
      expect(rec(15, 1, 5).description, isNot(contains('off the air')));

      expect(rec(14, 0, 0).description, contains('watchdog rescue'));
      expect(rec(14, 0, 0).description, contains('believed off the air'));
      expect(rec(14, 1, 0).description, contains('(slow)'));
    });

    test('unknown code falls back to a generic label + description', () {
      final r = DiagLogRecord(seq: 9, uptimeMs: 0, code: 99, backend: 2, arg0: 5, arg1: 6);
      expect(r.label, 'code_99');
      // Fallback description still surfaces the raw args so a newer device shows something.
      expect(r.description, contains('code=99'));
      expect(r.description, contains('arg0=5'));
      expect(r.description, contains('arg1=6'));
    });

    test('backend label maps 0/1 and is generic otherwise', () {
      DiagLogRecord rec(int backend) => DiagLogRecord(seq: 1, uptimeMs: 0, code: 1, backend: backend, arg0: 0, arg1: 0);
      expect(rec(0).backendLabel, 'littlefs');
      expect(rec(1).backendLabel, 'ring');
      expect(rec(7).backendLabel, 'b7');
    });
  });

  group('DiagLogSnapshot.parse', () {
    test('parses header and all full records', () {
      final records = [
        encodeRecord(seq: 1, uptimeMs: 100, code: 1, backend: 1, arg1: 36),
        encodeRecord(seq: 2, uptimeMs: 200, code: 4, backend: 1, arg1: 555),
      ];
      final blob = encodeSnapshot(recordCount: 2, dropped: 3, maxSeq: 2, records: records);
      final snap = DiagLogSnapshot.parse(blob)!;
      expect(snap.recordSize, 16);
      expect(snap.recordCount, 2);
      expect(snap.droppedCount, 3);
      expect(snap.maxSeq, 2);
      expect(snap.records.length, 2);
      expect(snap.records[0].seq, 1);
      expect(snap.records[1].seq, 2);
      expect(snap.lastReceivedSeq, 2);
    });

    test('floors to whole records when the read ends mid-record (MTU-bounded)', () {
      // Header says 3 records but only 1.5 records worth of bytes arrived — the
      // Android single-read path. Parse the whole one; drop the trailing 8 bytes.
      final full = encodeRecord(seq: 10, uptimeMs: 1, code: 7, backend: 0, arg1: 42);
      final partial = full.sublist(0, 8);
      final blob = [
        ...encodeSnapshot(recordCount: 3, dropped: 0, maxSeq: 30),
        ...full,
        ...partial,
      ];
      final snap = DiagLogSnapshot.parse(blob)!;
      expect(snap.recordCount, 3); // header total (device still holds 3)
      expect(snap.records.length, 1); // only 1 full record received
      expect(snap.records.single.seq, 10);
      expect(snap.lastReceivedSeq, 10); // ack target for this batch
    });

    test('header-only read yields zero records (fully drained)', () {
      final blob = encodeSnapshot(recordCount: 0, dropped: 0, maxSeq: 0);
      final snap = DiagLogSnapshot.parse(blob)!;
      expect(snap.records, isEmpty);
      expect(snap.lastReceivedSeq, 0);
    });

    test('returns null on a too-short (sub-header) read', () {
      expect(DiagLogSnapshot.parse(const []), isNull);
      expect(DiagLogSnapshot.parse(List.filled(11, 0)), isNull);
    });
  });
}
