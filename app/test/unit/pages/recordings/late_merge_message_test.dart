import 'package:flutter_test/flutter_test.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';

void main() {
  group('lateMergeMessage', () {
    final absorbed = DateTime(2026, 9, 15, 9, 50);
    final merged = DateTime(2026, 9, 15, 9, 40);
    String entry(DateTime a, DateTime m) => '${a.millisecondsSinceEpoch}:${m.millisecondsSinceEpoch}';

    test('names both times for a single merge', () {
      expect(
        RecordingsController.lateMergeMessage([entry(absorbed, merged)], use24Hour: false),
        'Audio that arrived late was added to your 9:50 AM recording from Tue 15 Sep — it now starts at 9:40 AM.',
      );
    });

    test('follows the 24-hour setting', () {
      expect(
        RecordingsController.lateMergeMessage([entry(absorbed, merged)], use24Hour: true),
        'Audio that arrived late was added to your 09:50 recording from Tue 15 Sep — it now starts at 09:40.',
      );
    });

    test('names the day when the recording now starts on an earlier one', () {
      expect(
        RecordingsController.lateMergeMessage(
          [entry(DateTime(2026, 9, 15, 0, 5), DateTime(2026, 9, 14, 23, 58))],
          use24Hour: true,
        ),
        'Audio that arrived late was added to your 00:05 recording from Tue 15 Sep — '
        'it now starts at 23:58 on Mon 14 Sep.',
      );
    });

    test('several become one message, and junk entries are skipped', () {
      expect(
        RecordingsController.lateMergeMessage(
          [entry(absorbed, merged), 'junk', entry(absorbed.add(const Duration(hours: 2)), merged)],
          use24Hour: false,
        ),
        'Audio that arrived late was added to 2 of your recordings. Each is now listed from its earlier start time.',
      );
    });

    test('nothing usable, nothing shown', () {
      expect(RecordingsController.lateMergeMessage(['junk', '1:2:3'], use24Hour: false), isNull);
    });
  });
}
