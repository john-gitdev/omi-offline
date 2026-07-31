import 'dart:typed_data';

/// One 16-byte diagnostic event drained from the firmware's on-device event ring
/// (BLE 0x19B10063). The firmware records these for the health events that the
/// aggregate drop counters (0x19B10062) only total — giving per-event timing and
/// cause context (see firmware `diag_log.h` for the event-code table).
///
/// Wire layout (little-endian, matching `diag_event_t`):
///   [u32 seq][u32 uptime_ms][u8 code][u8 backend][u16 arg0][u32 arg1]
class DiagLogRecord {
  /// Monotonic sequence assigned by the firmware at enqueue. The ack key: acking
  /// `seq` drops every record with seq <= that value.
  final int seq;

  /// Device uptime (ms) at the event — `k_uptime_get_32()`.
  final int uptimeMs;

  /// Event code — see [label]. APPEND-ONLY on the firmware side; an unknown code
  /// (newer firmware than this app) renders generically rather than being dropped.
  final int code;

  /// Storage backend active at the event: 0 = LittleFS, 1 = ring. Not meaningful
  /// for pre-storage events (codec drops report 0).
  final int backend;

  /// Event-specific — see the per-code notes in [description].
  final int arg0;

  /// Event-specific — see the per-code notes in [description].
  final int arg1;

  const DiagLogRecord({
    required this.seq,
    required this.uptimeMs,
    required this.code,
    required this.backend,
    required this.arg0,
    required this.arg1,
  });

  static const int sizeBytes = 16;

  /// Parse one record from [data] starting at [offset]. Returns null if fewer than
  /// [sizeBytes] bytes remain.
  static DiagLogRecord? fromBytes(List<int> data, int offset) {
    if (offset + sizeBytes > data.length) return null;
    final bd = ByteData.sublistView(Uint8List.fromList(data), offset, offset + sizeBytes);
    return DiagLogRecord(
      seq: bd.getUint32(0, Endian.little),
      uptimeMs: bd.getUint32(4, Endian.little),
      code: bd.getUint8(8),
      backend: bd.getUint8(9),
      arg0: bd.getUint16(10, Endian.little),
      arg1: bd.getUint32(12, Endian.little),
    );
  }

  /// Short, stable label for the event code. Mirror of the firmware
  /// `diag_event_code_t` table — keep in sync (append-only).
  String get label {
    switch (code) {
      case 1:
        return 'empty_bin_rotation';
      case 2:
        return 'marker_write_drop';
      case 3:
        return 'marker_pause_gate_save';
      case 4:
        return 'priority_record_start';
      case 5:
        return 'priority_record_stop';
      case 6:
        return 'session_end_marker_emit';
      case 7:
        return 'sd_block_drop';
      case 8:
        return 'codec_drop';
      case 9:
        return 'write_blocked';
      case 10:
        return 'ring_io_error';
      case 11:
        return 'backend_mount';
      case 12:
        return 'bond_state';
      default:
        return 'code_$code';
    }
  }

  String get backendLabel {
    switch (backend) {
      case 0:
        return 'littlefs';
      case 1:
        return 'ring';
      default:
        return 'b$backend';
    }
  }

  /// Human-readable one-liner with the code's specific arg meaning. Unknown codes
  /// fall back to the raw args so a newer device still shows something useful.
  String get description {
    switch (code) {
      case 1:
        return 'Empty bin rotation ($backendLabel) — bin closed with $arg1 B (header only)';
      case 2:
        return 'Marker write drop ($backendLabel) — lost inline marker (blockDrops=$arg1)';
      case 3:
        return 'Marker kept at SD pause gate ($backendLabel) — block ${arg1}B';
      case 4:
        return 'Priority recording start ($backendLabel) — session $arg1';
      case 5:
        return 'Priority recording stop ($backendLabel) — session $arg1';
      case 6:
        return 'Session-end marker emit ($backendLabel) — session $arg1';
      case 7:
        return 'SD block drop ($backendLabel) — audio block lost (blockDrops=$arg1)';
      case 8:
        return 'Codec drop — PCM block lost before encode (codecDrops=$arg1)';
      case 9:
        return 'Write blocked ($backendLabel) — arg0=$arg0 arg1=$arg1';
      case 10:
        return 'Ring IO error — arg0=$arg0 arg1=$arg1';
      case 11:
        return 'Backend mount ($backendLabel) — arg1=$arg1';
      case 12:
        // arg0 = cause (0 boot load / 1 post-DFU wipe / 2 button wipe), arg1 = bonds held after.
        // "0 key(s)" on a boot load with no preceding wipe is the device having silently lost
        // its pairing — the origin of the reconnect-forever outage.
        switch (arg0) {
          case 0:
            return 'Bonds at boot — $arg1 key(s) loaded'
                '${arg1 == 0 ? ' (device is UNPAIRED)' : ''}';
          case 1:
            return 'Bonds wiped by post-update unpair — $arg1 key(s) remain';
          case 2:
            return 'Bonds wiped by 5-tap gesture — $arg1 key(s) remain';
          default:
            return 'Bond state — cause=$arg0, $arg1 key(s)';
        }
      default:
        return 'Event code=$code backend=$backend arg0=$arg0 arg1=$arg1';
    }
  }

  Map<String, dynamic> toJson() => {
        'seq': seq,
        'uptimeMs': uptimeMs,
        'code': code,
        'label': label,
        'backend': backend,
        'arg0': arg0,
        'arg1': arg1,
      };

  @override
  String toString() => '#$seq @${uptimeMs}ms $label($backendLabel) arg0=$arg0 arg1=$arg1';
}

/// A single 0x19B10063 read: the 12-byte snapshot header plus whatever full records
/// fit in this ATT read. On a single-read transport (Android, MTU-bounded) [records]
/// is a batch and the caller acks + reads again; on a long-read transport (iOS) the
/// whole snapshot arrives at once. Either way the drain loop terminates when a read
/// yields zero records.
///
/// Header layout (little-endian, from firmware `diag_log.h`):
///   [u8 record_size=16][u8 reserved][u16 record_count][u32 dropped_count][u32 max_seq]
class DiagLogSnapshot {
  /// Firmware record size (16). A mismatch means a wire-format change — the caller
  /// should stop rather than misparse.
  final int recordSize;

  /// Total records in the firmware's snapshot (may exceed [records].length when the
  /// read was MTU-bounded).
  final int recordCount;

  /// Keep-newest overwrites since the last ack — records lost because the phone was
  /// away while the ring filled. Nonzero = some events were never captured.
  final int droppedCount;

  /// Highest seq in the firmware's snapshot (the overall ack ceiling).
  final int maxSeq;

  /// The full records actually contained in this read (trailing partial bytes are
  /// discarded).
  final List<DiagLogRecord> records;

  const DiagLogSnapshot({
    required this.recordSize,
    required this.recordCount,
    required this.droppedCount,
    required this.maxSeq,
    required this.records,
  });

  static const int headerSize = 12;

  /// Parse a 0x0063 read. Returns null if the payload is shorter than the header
  /// (too-short read tells us nothing — treat as "not available", not empty).
  static DiagLogSnapshot? parse(List<int> data) {
    if (data.length < headerSize) return null;
    final bd = ByteData.sublistView(Uint8List.fromList(data), 0, headerSize);
    final recordSize = bd.getUint8(0);
    final recordCount = bd.getUint16(2, Endian.little);
    final droppedCount = bd.getUint32(4, Endian.little);
    final maxSeq = bd.getUint32(8, Endian.little);

    final records = <DiagLogRecord>[];
    // Floor to whole records — a MTU-bounded read can end mid-record; the next read
    // re-fetches that record whole.
    final effectiveSize = recordSize == DiagLogRecord.sizeBytes ? recordSize : DiagLogRecord.sizeBytes;
    final available = data.length - headerSize;
    final n = available >= 0 ? available ~/ effectiveSize : 0;
    for (int i = 0; i < n; i++) {
      final r = DiagLogRecord.fromBytes(data, headerSize + i * effectiveSize);
      if (r == null) break;
      records.add(r);
    }
    return DiagLogSnapshot(
      recordSize: recordSize,
      recordCount: recordCount,
      droppedCount: droppedCount,
      maxSeq: maxSeq,
      records: records,
    );
  }

  /// Highest seq among the records actually received in this read — the ack target
  /// after processing this batch (0 when the batch is empty).
  int get lastReceivedSeq => records.isEmpty ? 0 : records.last.seq;
}

/// Aggregate result of a full drain (all batches concatenated). Returned by the
/// connection-layer drain helper.
class DiagLogDrainResult {
  final List<DiagLogRecord> records;
  final int droppedCount;

  const DiagLogDrainResult({required this.records, required this.droppedCount});

  bool get isEmpty => records.isEmpty && droppedCount == 0;
}
