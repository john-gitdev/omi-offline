import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/models/recordings/recordings_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    tempDir = Directory.systemTemp.createTempSync('models_test');
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    // Deterministic, locale-free labels (24h => no AM/PM branch).
    SharedPreferencesUtil().use24HourTime = true;
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  File fileOfBytes(String name, int bytes) {
    final f = File('${tempDir.path}/$name');
    f.writeAsBytesSync(List.filled(bytes, 0));
    return f;
  }

  Conversation conv({
    required File file,
    DateTime? start,
    Duration duration = const Duration(minutes: 5),
    bool passthrough = false,
    bool? isSilero,
  }) =>
      Conversation(
        file: file,
        startTime: start ?? DateTime(2026, 6, 22, 13, 5, 0),
        duration: duration,
        passthrough: passthrough,
        isSilero: isSilero,
      );

  group('Conversation.endTime', () {
    test('is startTime + duration', () {
      final c = conv(file: fileOfBytes('a.m4a', 10), duration: const Duration(minutes: 7));
      expect(c.endTime, DateTime(2026, 6, 22, 13, 12, 0));
    });
  });

  group('Conversation.isUnknown', () {
    test('false for a normal recording_<ms> filename', () {
      expect(conv(file: fileOfBytes('recording_1782120000000.m4a', 10)).isUnknown, isFalse);
    });

    test('true for unknown_ prefix (no RTC sync)', () {
      expect(conv(file: fileOfBytes('unknown_1782120000000.wav', 10)).isUnknown, isTrue);
    });

    test('true for session_ prefix (pre-time-sync)', () {
      expect(conv(file: fileOfBytes('session_abc.wav', 10)).isUnknown, isTrue);
    });
  });

  group('Conversation.fileSizeBytes', () {
    test('reads on-disk length', () {
      expect(conv(file: fileOfBytes('sz.m4a', 2048)).fileSizeBytes, 2048);
    });

    test('returns 0 for a missing file instead of throwing', () {
      final missing = File('${tempDir.path}/does_not_exist.m4a');
      expect(conv(file: missing).fileSizeBytes, 0);
    });
  });

  group('Conversation.sizeLabel', () {
    test('bytes under 1 KiB render as "N B"', () {
      expect(conv(file: fileOfBytes('s.m4a', 512)).sizeLabel, '512 B');
    });

    test('KiB range rounds to a whole number of KB', () {
      expect(conv(file: fileOfBytes('s.m4a', 2048)).sizeLabel, '2 KB');
    });

    test('MiB range renders one decimal place', () {
      expect(conv(file: fileOfBytes('s.m4a', 1024 * 1024 + 512 * 1024)).sizeLabel, '1.5 MB');
    });

    test('passthrough recordings have no size label (file is gone)', () {
      expect(conv(file: fileOfBytes('s.m4a', 4096), passthrough: true).sizeLabel, '');
    });

    test('appends VAD when isSilero is true', () {
      expect(conv(file: fileOfBytes('s.m4a', 512), isSilero: true).sizeLabel, '512 B  ·  VAD');
    });

    test('appends AAD when isSilero is false', () {
      expect(conv(file: fileOfBytes('s.m4a', 512), isSilero: false).sizeLabel, '512 B  ·  AAD');
    });

    test('no codec suffix when isSilero is null (legacy meta)', () {
      expect(conv(file: fileOfBytes('s.m4a', 512), isSilero: null).sizeLabel, '512 B');
    });
  });

  group('Conversation.durationLabel', () {
    test('sub-minute shows just seconds', () {
      expect(conv(file: fileOfBytes('s.m4a', 10), duration: const Duration(seconds: 45)).durationLabel, '45s');
    });

    test('over a minute shows minutes and seconds', () {
      expect(conv(file: fileOfBytes('s.m4a', 10), duration: const Duration(seconds: 90)).durationLabel, '1m 30s');
    });

    test('rounds milliseconds to the nearest second', () {
      expect(
        conv(file: fileOfBytes('s.m4a', 10), duration: const Duration(milliseconds: 1600)).durationLabel,
        '2s',
      );
    });
  });

  group('Conversation.timeRangeLabel (inclusive end)', () {
    test('30-min recording shows end one second early (HH:MM–HH:34, not HH:35)', () {
      final c = conv(
        file: fileOfBytes('s.m4a', 10),
        start: DateTime(2026, 6, 22, 13, 5, 0),
        duration: const Duration(minutes: 30),
      );
      expect(c.timeRangeLabel, '13:05 – 13:34');
    });

    test('zero-duration recording uses the start time for both ends', () {
      final c = conv(
        file: fileOfBytes('s.m4a', 10),
        start: DateTime(2026, 6, 22, 13, 5, 0),
        duration: Duration.zero,
      );
      expect(c.timeRangeLabel, '13:05 – 13:05');
    });
  });

  group('DiscardRecord', () {
    DiscardRecord rec({
      required String reason,
      DateTime? start,
      DateTime? end,
      List<String> bins = const ['s/a.bin'],
    }) =>
        DiscardRecord(
          startTime: start ?? DateTime(2026, 6, 22, 10, 0, 0),
          endTime: end ?? DateTime(2026, 6, 22, 10, 0, 30),
          reason: reason,
          maxVoiceProb: 0.1,
          relativeBins: bins,
          sourceJsonl: File('${tempDir.path}/discards.jsonl'),
        );

    test('duration is end - start', () {
      expect(rec(reason: 'noise').duration, const Duration(seconds: 30));
    });

    test('expiresAt is endTime + the 48h retention window', () {
      final r = rec(reason: 'noise');
      expect(r.expiresAt, r.endTime.add(const Duration(hours: 48)));
      expect(DiscardRecord.discardRetentionWindow, const Duration(hours: 48));
    });

    test('isNoise matches any reason containing "noise"', () {
      expect(rec(reason: 'noise').isNoise, isTrue);
      expect(rec(reason: 'low-snr noise drop').isNoise, isTrue);
      expect(rec(reason: 'muted').isNoise, isFalse);
    });

    test('isMuted is an exact match for "muted" only', () {
      expect(rec(reason: 'muted').isMuted, isTrue);
      expect(rec(reason: 'noise').isMuted, isFalse);
      expect(rec(reason: 'muted stretch').isMuted, isFalse);
    });

    test('id combines source path, start ms, and bin list for stable identity', () {
      final r = rec(
        reason: 'noise',
        start: DateTime.fromMillisecondsSinceEpoch(1782120000000),
        bins: ['s/a.bin', 's/b.bin'],
      );
      expect(r.id, '${r.sourceJsonl.path}:1782120000000:s/a.bin,s/b.bin');
    });

    test('records differing only by bins have distinct ids', () {
      final a = rec(reason: 'noise', bins: ['s/a.bin']);
      final b = rec(reason: 'noise', bins: ['s/b.bin']);
      expect(a.id, isNot(b.id));
    });
  });

  group('MarkerConversation', () {
    test('isPending is true when no segment is attached yet', () {
      final mc = MarkerConversation(
        markerTime: DateTime(2026, 6, 22, 9, 15),
        edlFile: File('${tempDir.path}/marker.edl'),
      );
      expect(mc.isPending, isTrue);
      expect(mc.timeRangeLabel, '');
    });

    test('isPending is false once a segment is set', () {
      final mc = MarkerConversation(
        markerTime: DateTime(2026, 6, 22, 9, 15),
        edlFile: File('${tempDir.path}/marker.edl'),
        segment: fileOfBytes('recording_1.m4a', 10),
      );
      expect(mc.isPending, isFalse);
    });

    test('markerTimeLabel formats the tap time as HH:MM', () {
      final mc = MarkerConversation(
        markerTime: DateTime(2026, 6, 22, 9, 5),
        edlFile: File('${tempDir.path}/marker.edl'),
      );
      expect(mc.markerTimeLabel, '09:05');
    });
  });
}
