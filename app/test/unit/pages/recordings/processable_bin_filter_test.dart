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

  /// Decides which side of a pending mode switch a bin falls on, and therefore
  /// whether it is cut by the settings it was recorded under or the ones the
  /// user just switched to. Getting a bin onto the wrong side re-cuts it under
  /// the other mode's rules — which is how a manual-mode switch chopped an auto
  /// backlog on 2026-08-14.
  group('binStartUtcSeconds', () {
    test('reads the firmware timerStart out of the bin name', () {
      expect(RecordingsController.binStartUtcSeconds(bin(whole)), 1784263022);
    });

    test('partitions either side of a switch instant', () {
      const int switchAt = 1784262000; // between the two bins above
      expect(RecordingsController.binStartUtcSeconds(bin(partial)) < switchAt, isTrue);
      expect(RecordingsController.binStartUtcSeconds(bin(whole)) < switchAt, isFalse);
    });

    test('a pre-time-sync bin sorts before any switch', () {
      // No usable clock, so it lands in session_<id>/ with no epoch in the name.
      // 0 puts it in the frozen-settings group, which is the safe side: audio
      // that predates a working clock certainly predates a switch made today.
      expect(RecordingsController.binStartUtcSeconds(bin('session_4230330572/1234_4230330572.bin')), 0);
    });

    test('an unparseable name sorts before any switch rather than throwing', () {
      expect(RecordingsController.binStartUtcSeconds(File('/docs/raw_segments/x/notanumber.bin')), 0);
    });
  });

  /// When the mode-switch pin may be retired. Retiring it early drops any
  /// pre-switch audio that arrives afterwards back onto the current mode's
  /// settings — the failure the pin exists to stop — so "no processable
  /// pre-switch bins in this run" is deliberately NOT one of the conditions.
  group('preSwitchPinIsSpent', () {
    const int switchAt = 1784262000;
    bool spent({
      bool onDisk = false,
      bool partial = false,
      int ageSeconds = 60,
    }) =>
        RecordingsController.preSwitchPinIsSpent(
          switchAt: switchAt,
          nowUtcSeconds: switchAt + ageSeconds,
          anyPreSwitchBinOnDisk: onDisk,
          lastSyncPartial: partial,
        );

    test('retires once the backlog is drained and the sync completed', () {
      expect(spent(), isTrue);
    });

    test('survives while a pre-switch bin is still on disk', () {
      // Includes the mid-transfer case: isProcessableBin hides those from the
      // partition, so a run can see zero pre-switch bins to process while one is
      // actively downloading. That is the ordinary state when an interrupted
      // sync hands over to processing, not a corner case.
      expect(spent(onDisk: true), isFalse);
    });

    test('survives a partial sync even with nothing left on disk', () {
      // The Omi keeps recording while disconnected, so a cut-short sync means it
      // still holds pre-switch files that have not reached the phone at all.
      expect(spent(partial: true), isFalse);
    });

    test('retires on age even with a partial sync and bins on disk', () {
      // The escape hatch: a live pin blocks the NEXT switch from recording its
      // own, so a device that is never fully drained must not disarm the
      // mechanism for every switch after it.
      expect(spent(onDisk: true, partial: true, ageSeconds: 8 * 24 * 3600), isTrue);
      expect(spent(onDisk: true, partial: true, ageSeconds: 6 * 24 * 3600), isFalse);
    });
  });
}
