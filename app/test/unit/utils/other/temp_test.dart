import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/other/temp.dart';

void main() {
  group('formatChatTimestamp', () {
    // We use a fixed "now" date to ensure deterministic tests
    // 2024-05-15 is a Wednesday
    final fixedNow = DateTime(2024, 5, 15, 14, 0);

    test('should return only time if the message date is today', () {
      final dateTime = DateTime(2024, 5, 15, 10, 30);
      final result = formatChatTimestamp(dateTime, now: fixedNow);
      expect(result, '10:30 AM');
    });

    test('should return "Yesterday at [time]" if the message date is yesterday', () {
      final dateTime = DateTime(2024, 5, 14, 9, 15);
      final result = formatChatTimestamp(dateTime, now: fixedNow);
      expect(result, 'Yesterday at 9:15 AM');
    });

    test('should return formatted date and time if the message date is older than yesterday', () {
      final dateTime = DateTime(2024, 5, 13, 16, 45);
      final result = formatChatTimestamp(dateTime, now: fixedNow);
      expect(result, 'May 13, 4:45 PM');
    });

    test('should return formatted date and time for much older dates', () {
      final dateTime = DateTime(2023, 1, 1, 12, 0);
      final result = formatChatTimestamp(dateTime, now: fixedNow);
      expect(result, 'Jan 1, 12:00 PM');
    });

    test('should use actual DateTime.now() if now is not provided', () {
      final actualNow = DateTime.now();
      final result = formatChatTimestamp(actualNow);

      // formatChatTimestamp formats to 'h:mm a' for today
      // we check if it produces a string matching the time structure
      expect(RegExp(r'^\d{1,2}:\d{2}\s(AM|PM)$').hasMatch(result), isTrue);
    });
  });
}
