import 'dart:typed_data';

/// Wraps a list of raw Opus frames into a valid Ogg/Opus byte stream that
/// Deepgram (and any compliant Ogg/Opus decoder) can read.
///
/// Reference: RFC 7845 — Ogg Encapsulation for the Opus Audio Codec.
///
/// Frame assumptions (matching firmware config):
///   - Sample rate : 16 000 Hz
///   - Channels    : 1 (mono)
///   - Frame size  : 20 ms → 320 samples at 16 kHz
///   - Granule pos : counted at 48 kHz (Ogg/Opus spec §4) → 960 per 20-ms frame
///   - Pre-skip    : 312 samples at 48 kHz (standard libopus default)
///
/// Each Ogg page carries at most [_maxSegmentsPerPage] lacing segments
/// (255 bytes each → 65 025 bytes max per page).  For typical Opus VBR frames
/// of 40–80 bytes a page will hold many frames; for safety we flush one page
/// per [_framesPerPage] frames so granule_position advances smoothly.
class OggOpusBuilder {
  static const int _sampleRate = 16000;
  static const int _channels = 1;
  static const int _preSkip = 312; // samples at 48 kHz
  static const int _pcmSamplesPerFrame = 320; // 20 ms × 16 000 Hz
  // Ogg/Opus spec counts granule at 48 kHz regardless of input sample rate
  static const int _granulePerFrame = 960; // 20 ms × 48 000 Hz
  static const int _framesPerPage = 50; // one page per ~1 s of audio

  /// Encodes [opusFrames] (raw Opus packets, no length prefix) into an
  /// Ogg/Opus byte stream and returns the result as a [Uint8List].
  static Uint8List build(List<Uint8List> opusFrames) {
    final out = BytesBuilder(copy: false);
    final serial = DateTime.now().millisecondsSinceEpoch & 0xFFFFFFFF;

    // Page 0 — BOS + Opus ID header
    out.add(_buildIdHeaderPage(serial));

    // Page 1 — Opus comment header
    out.add(_buildCommentHeaderPage(serial));

    // Audio pages
    int pageSeq = 2;
    int granulePos = _preSkip;
    int frameIdx = 0;

    while (frameIdx < opusFrames.length) {
      final end = (frameIdx + _framesPerPage).clamp(0, opusFrames.length);
      final pageFrames = opusFrames.sublist(frameIdx, end);
      final isLast = end == opusFrames.length;
      granulePos += pageFrames.length * _granulePerFrame;
      out.add(_buildAudioPage(serial, pageSeq, granulePos, pageFrames, isLast));
      pageSeq++;
      frameIdx = end;
    }

    return out.toBytes();
  }

  // ---------------------------------------------------------------------------
  // Ogg ID header (RFC 7845 §5.1)
  // ---------------------------------------------------------------------------
  static Uint8List _buildIdHeaderPage(int serial) {
    // Build the OpusHead payload (19 bytes)
    final payload = ByteData(19);
    // Magic signature "OpusHead"
    final magic = 'OpusHead'.codeUnits;
    for (int i = 0; i < 8; i++) {
      payload.setUint8(i, magic[i]);
    }
    payload.setUint8(8, 1); // version
    payload.setUint8(9, _channels);
    payload.setUint16(10, _preSkip, Endian.little);
    payload.setUint32(12, _sampleRate, Endian.little);
    payload.setUint16(16, 0, Endian.little); // output gain = 0
    payload.setUint8(18, 0); // channel mapping family 0

    return _buildOggPage(
      serial: serial,
      pageSeq: 0,
      granulePos: 0,
      headerType: 0x02, // BOS
      segments: [payload.buffer.asUint8List()],
    );
  }

  // ---------------------------------------------------------------------------
  // Ogg comment header (RFC 7845 §5.2) — minimal vendor string, no tags
  // ---------------------------------------------------------------------------
  static Uint8List _buildCommentHeaderPage(int serial) {
    final vendor = 'omi-offline'.codeUnits;
    final buf = BytesBuilder();
    buf.add('OpusTags'.codeUnits);
    // Vendor string length (LE u32) + vendor string
    buf.add(_u32le(vendor.length));
    buf.add(vendor);
    // User comment list length = 0
    buf.add(_u32le(0));

    return _buildOggPage(
      serial: serial,
      pageSeq: 1,
      granulePos: 0,
      headerType: 0x00,
      segments: [buf.toBytes()],
    );
  }

  // ---------------------------------------------------------------------------
  // Audio data page
  // ---------------------------------------------------------------------------
  static Uint8List _buildAudioPage(
    int serial,
    int pageSeq,
    int granulePos,
    List<Uint8List> frames,
    bool isLast,
  ) {
    return _buildOggPage(
      serial: serial,
      pageSeq: pageSeq,
      granulePos: granulePos,
      headerType: isLast ? 0x04 : 0x00, // EOS on last page
      segments: frames,
    );
  }

  // ---------------------------------------------------------------------------
  // Low-level Ogg page assembler
  // ---------------------------------------------------------------------------
  static Uint8List _buildOggPage({
    required int serial,
    required int pageSeq,
    required int granulePos,
    required int headerType,
    required List<Uint8List> segments,
  }) {
    // Build lacing table.  Each segment packet is split into 255-byte laces;
    // the packet ends when a lace < 255 is encountered (RFC 3533 §6.1.1).
    final laces = <int>[];
    final body = BytesBuilder(copy: false);

    for (final seg in segments) {
      int remaining = seg.length;
      int offset = 0;
      while (remaining >= 255) {
        laces.add(255);
        body.add(seg.sublist(offset, offset + 255));
        offset += 255;
        remaining -= 255;
      }
      laces.add(remaining); // terminating lace (< 255)
      body.add(seg.sublist(offset));
    }

    final bodyBytes = body.toBytes();
    final headerLen = 27 + laces.length;
    final page = Uint8List(headerLen + bodyBytes.length);
    final bd = ByteData.sublistView(page);

    // Capture segments
    page[0] = 0x4F; // 'O'
    page[1] = 0x67; // 'g'
    page[2] = 0x67; // 'g'
    page[3] = 0x53; // 'S'
    page[4] = 0x00; // stream_structure_version
    page[5] = headerType;

    // granule_position (i64 LE) — we store as u64 with the same bits
    bd.setInt64(6, granulePos, Endian.little);

    bd.setUint32(14, serial, Endian.little); // bitstream_serial_number
    bd.setUint32(18, pageSeq, Endian.little); // page_sequence_number
    bd.setUint32(22, 0, Endian.little); // checksum placeholder
    page[26] = laces.length; // number_page_segments

    for (int i = 0; i < laces.length; i++) {
      page[27 + i] = laces[i];
    }
    page.setAll(headerLen, bodyBytes);

    // CRC-32 checksum (Ogg uses a specific 0x04C11DB7 polynomial, init 0, no flip)
    final crc = _oggCrc32(page);
    bd.setUint32(22, crc, Endian.little);

    return page;
  }

  // ---------------------------------------------------------------------------
  // Ogg CRC-32 (polynomial 0x04C11DB7, no pre/post-conditioning)
  // ---------------------------------------------------------------------------
  static final Uint32List _crcTable = _buildCrcTable();

  static Uint32List _buildCrcTable() {
    final t = Uint32List(256);
    for (int i = 0; i < 256; i++) {
      int r = i << 24;
      for (int j = 0; j < 8; j++) {
        r = (r & 0x80000000) != 0 ? (r << 1) ^ 0x04C11DB7 : r << 1;
        r &= 0xFFFFFFFF;
      }
      t[i] = r;
    }
    return t;
  }

  static int _oggCrc32(Uint8List data) {
    int crc = 0;
    for (final byte in data) {
      crc = ((crc << 8) ^ _crcTable[((crc >> 24) ^ byte) & 0xFF]) & 0xFFFFFFFF;
    }
    return crc;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  static Uint8List _u32le(int value) {
    final b = ByteData(4)..setUint32(0, value, Endian.little);
    return b.buffer.asUint8List();
  }

  // Exposed for tests
  static int get granulePerFrame => _granulePerFrame;
  static int get pcmSamplesPerFrame => _pcmSamplesPerFrame;
}
