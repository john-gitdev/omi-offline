import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';

/// Guards the filter that decides which raw bins the VAD pass is allowed to
/// decode. The pass PRUNES every bin it consumes, so anything wrongly admitted
/// here is deleted from disk — these cases are all data-loss shaped.
void main() {
  File bin(String rel) => File('/docs/raw_segments/$rel');

  const String partial = '1784260394/1784260394_4230330572.bin';
  const String whole = '1784263022/1784263022_4230330572.bin';

  group('isProcessableBin', () {
    test('an ordinary bin is processable', () {
      expect(RecordingsController.isProcessableBin(bin(whole), {}, {}, {}), isTrue);
    });

    test('a bin still awaiting a resumed read is NOT processable', () {
      // The regression this guards: the sync completeness guard leaves a
      // short-read bin on disk as a PREFIX with the WAL parked at a resume
      // offset. Decoding it drafts a truncated recording and prunes the file the
      // next sync has to resume into — the resumed tail then lands at position 0
      // of a recreated file and the bin is scrambled.
      expect(RecordingsController.isProcessableBin(bin(partial), {}, {}, {partial}), isFalse);
    });

    test('incompleteness is judged per bin, not per sync', () {
      // A partial head must not park its already-whole siblings.
      expect(RecordingsController.isProcessableBin(bin(whole), {}, {}, {partial}), isTrue);
    });

    test('a discarded bin is NOT processable', () {
      expect(RecordingsController.isProcessableBin(bin(whole), {whole}, {}, {}), isFalse);
    });

    test('a covered bin is NOT processable', () {
      // `covered` is keyed on the absolute path, unlike the rel-path sets.
      expect(RecordingsController.isProcessableBin(bin(whole), {}, {bin(whole).path}, {}), isFalse);
    });

    test('omitted filter sets fall back to processable', () {
      // The optional params keep older call sites (and the estimate path) working.
      expect(RecordingsController.isProcessableBin(bin(whole), {}), isTrue);
    });

    test('a path outside raw_segments/ is left alone', () {
      expect(RecordingsController.isProcessableBin(File('/docs/elsewhere/x.bin'), {}, {}, {partial}), isTrue);
    });
  });
}
