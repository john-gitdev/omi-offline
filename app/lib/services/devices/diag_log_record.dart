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
      case 13:
        return 'adv_start_fail';
      case 14:
        return 'adv_watchdog_rescue';
      case 15:
        return 'adv_stop_fail';
      case 16:
        return 'vad_level';
      case 17:
        return 'mic_power_cycle';
      case 18:
        return 'mic_state';
      default:
        return 'code_$code';
    }
  }

  /// Legacy storage-backend tag. LittleFS was removed in `oo-2.9.0`, so current
  /// firmware has exactly one backend and reports `0` for every record — which used
  /// to render as "(littlefs)", naming a backend that no longer exists on every line
  /// of the log you read during an incident. Anything other than the two known values
  /// still shows, in case the byte is ever repurposed; `0`/`1` render as nothing.
  String get backendLabel {
    switch (backend) {
      case 0:
      case 1:
        return '';
      default:
        return 'b$backend';
    }
  }

  /// `" (tag)"` when [backendLabel] carries information, otherwise empty — so a
  /// description reads cleanly rather than trailing an empty pair of brackets.
  String get _backendSuffix => backendLabel.isEmpty ? '' : ' ($backendLabel)';

  /// Human-readable one-liner with the code's specific arg meaning. Unknown codes
  /// fall back to the raw args so a newer device still shows something useful.
  String get description {
    switch (code) {
      case 1:
        return 'Empty bin rotation$_backendSuffix — bin closed with $arg1 B (header only)';
      case 2:
        return 'Marker write drop$_backendSuffix — lost inline marker (blockDrops=$arg1)';
      case 3:
        return 'Marker kept at SD pause gate$_backendSuffix — block ${arg1}B';
      case 4:
        return 'Priority recording start$_backendSuffix — session $arg1';
      case 5:
        return 'Priority recording stop$_backendSuffix — session $arg1';
      case 6:
        return 'Session-end marker emit$_backendSuffix — session $arg1';
      case 7:
        return 'SD block drop$_backendSuffix — audio block lost (blockDrops=$arg1)';
      case 8:
        return 'Codec drop — PCM block lost before encode (codecDrops=$arg1)';
      case 9:
        return 'Write blocked$_backendSuffix — arg0=$arg0 arg1=$arg1';
      case 10:
        return 'Ring IO error — arg0=$arg0 arg1=$arg1';
      case 11:
        return 'Backend mount$_backendSuffix — arg1=$arg1';
      case 12:
        // arg0 = cause (0 boot load / 1 post-DFU wipe / 2 button wipe), arg1 = bonds held after.
        // "0 key(s)" on a boot load with no preceding wipe is the device having silently lost
        // its pairing — the origin of the reconnect-forever outage.
        switch (arg0) {
          case 0:
            return 'Bonds at boot — $arg1 key(s) loaded'
                '${arg1 == 0 ? ' (device is UNPAIRED)' : ''}';
          // The firmware emits these whether or not bt_unpair() actually succeeded —
          // an attempted-but-failed wipe is itself worth recording, since the device
          // then keeps a bond the phone believes is gone. arg1 is the count AFTER, so
          // a non-zero remainder means the wipe did not take; say that rather than
          // asserting "wiped" over the top of it.
          case 1:
            return arg1 == 0
                ? 'Bonds wiped by post-update unpair'
                : 'Post-update unpair FAILED — $arg1 key(s) still on device';
          case 2:
            return arg1 == 0 ? 'Bonds wiped by 5-tap gesture' : '5-tap unpair FAILED — $arg1 key(s) still on device';
          default:
            return 'Bond state — cause=$arg0, $arg1 key(s)';
        }
      case 13:
        // arg0 = advertising mode being started (0 fast / 1 slow); arg1 = errno magnitude
        // (positive, e.g. 12 = ENOMEM), so the negated form is rendered below.
        // The watchdog retries regardless, so a lone entry is a transient the guard
        // absorbed; a run of them means the radio would have gone dark before
        // oo-2.8.3. See BLE_Research.md "Wedge 5".
        return 'Advertising start failed (${arg0 == 1 ? "slow" : "fast"}) — errno -$arg1, watchdog will retry';
      case 14:
        // The watchdog restarted advertising after concluding it was down. arg0 = mode.
        //
        // That conclusion is an inference — a previous start failed, or a plain
        // re-assert returned success where it should have said "already advertising".
        // Neither is proof, so the wording says "believed" rather than asserting the
        // radio was off. This replaced a 0x0062 counter precisely because it could not
        // be kept exact; overstating it here would reintroduce the same problem in the
        // UI. Read it as evidence, not a verdict. See BLE_Research.md "Wedge 5".
        return 'Advertising watchdog rescue (${arg0 == 1 ? "slow" : "fast"}) — '
            'believed off the air, restarted';
      case 15:
        // The stop half of a mode change failed, so the interval could not be
        // reconfigured. The previous advertiser is still running — this is NOT an
        // off-air event, which is why it is a separate code from 13.
        return 'Advertising stop failed (${arg0 == 1 ? "slow" : "fast"}) — errno -$arg1, interval unchanged';
      case 16:
        // Peak-hold of the AAD input level over a 5-minute window. arg0 = max avg
        // amplitude seen, arg1 packs min in the high 16 bits and the threshold in
        // force in the low 16.
        //
        // This is the one reading that separates "the mic is dead" from "the room is
        // quiet" — the ambiguity that made the 2026-08-02 mic outage un-diagnosable
        // from logs, since a silent room and a wedged part both produce zero
        // recordings and zero bins. A max pinned at 0 across consecutive windows is a
        // wedged T5838 (digital-zero PDM output); any real room clears zero within
        // five minutes even when nothing ever crosses the threshold.
        final levelMin = (arg1 >> 16) & 0xFFFF;
        final levelThreshold = arg1 & 0xFFFF;
        final verdict = arg0 == 0 ? ' — NO SIGNAL (mic may be wedged)' : '';
        return 'Mic level: peak $arg0, floor $levelMin (threshold $levelThreshold)$verdict';
      case 17:
        // First boot of a new firmware version power-cycles PDM_EN, because a warm
        // reset leaves the T5838 powered through the flash and can strand it emitting
        // digital zero. arg0 = 1 only if the rail was actually taken low and restored,
        // which is the only outcome that clears a wedge. Capture starts either way —
        // a rail that stays down surfaces as a vad_level record with a zero peak.
        return arg0 == 1
            ? 'Mic rail power-cycled after firmware update'
            : 'Mic rail NOT cycled after update — a wedged mic would persist';
      case 18:
        // The mic gate opened or closed capture. arg1 = the VAD threshold at the
        // transition, which is what decided it: 32769 = manual standby (parked),
        // 65535 = force-capture, anything else = auto.
        //
        // These exist because a parked mic emits nothing at all — no frames means no
        // vad_level window ever closes — so a gap in the log is otherwise ambiguous
        // between "off on purpose" and "died". A `parked` record explains a gap; a
        // gap with no `parked` before it does not.
        switch (arg0) {
          case 0:
            return 'Mic parked — capture stopped (threshold $arg1)';
          case 1:
            return 'Mic resumed — capture started (threshold $arg1)';
          case 2:
            return 'Mic resume FAILED — dmic START rejected twice, NOT capturing (threshold $arg1)';
          case 3:
            // Distinct from a failed START: the driver said yes and the part still
            // returned digital zero, which a real room never does. This is the wedge
            // signature, caught at the one moment it matters.
            return 'Mic resumed but SILENT — first frames were all zero, mic likely wedged (threshold $arg1)';
          default:
            return 'Mic state — arg0=$arg0 threshold=$arg1';
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
  String toString() => '#$seq @${uptimeMs}ms $label$_backendSuffix arg0=$arg0 arg1=$arg1';
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
