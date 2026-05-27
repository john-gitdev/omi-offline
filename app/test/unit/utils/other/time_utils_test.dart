import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/utils/other/time_utils.dart';

void main() {
  group('Time Utils Test', () {
    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => null,
      );
      SharedPreferences.setMockInitialValues({});
      await SharedPreferencesUtil.init();
    });

    group('fmtHourMin', () {
      test('formats correctly when use24HourTime is true', () async {
        SharedPreferencesUtil().use24HourTime = true;

        expect(fmtHourMin(DateTime(2023, 1, 1, 0, 5)), '00:05');
        expect(fmtHourMin(DateTime(2023, 1, 1, 12, 30)), '12:30');
        expect(fmtHourMin(DateTime(2023, 1, 1, 14, 45)), '14:45');
        expect(fmtHourMin(DateTime(2023, 1, 1, 23, 59)), '23:59');
      });

      test('formats correctly when use24HourTime is false', () async {
        SharedPreferencesUtil().use24HourTime = false;

        expect(fmtHourMin(DateTime(2023, 1, 1, 0, 5)), '12:05 AM');
        expect(fmtHourMin(DateTime(2023, 1, 1, 1, 15)), '1:15 AM');
        expect(fmtHourMin(DateTime(2023, 1, 1, 11, 59)), '11:59 AM');
        expect(fmtHourMin(DateTime(2023, 1, 1, 12, 30)), '12:30 PM');
        expect(fmtHourMin(DateTime(2023, 1, 1, 14, 45)), '2:45 PM');
        expect(fmtHourMin(DateTime(2023, 1, 1, 23, 59)), '11:59 PM');
      });
    });

    group('roundToMinute', () {
      test('truncates to the minute boundary', () {
        expect(roundToMinute(DateTime(2023, 1, 1, 10, 30, 29)), DateTime(2023, 1, 1, 10, 30));
        expect(roundToMinute(DateTime(2023, 1, 1, 10, 30, 0)), DateTime(2023, 1, 1, 10, 30));
        expect(roundToMinute(DateTime(2023, 1, 1, 10, 30, 30)), DateTime(2023, 1, 1, 10, 30));
        expect(roundToMinute(DateTime(2023, 1, 1, 10, 30, 59)), DateTime(2023, 1, 1, 10, 30));
      });

      test('does not round up across hour and day boundaries', () {
        expect(roundToMinute(DateTime(2023, 1, 1, 10, 59, 30)), DateTime(2023, 1, 1, 10, 59));
        expect(roundToMinute(DateTime(2023, 1, 1, 23, 59, 30)), DateTime(2023, 1, 1, 23, 59));
        expect(roundToMinute(DateTime(2023, 12, 31, 23, 59, 45)), DateTime(2023, 12, 31, 23, 59));
      });
    });

    group('secondsToHumanReadable', () {
      test('formats seconds correctly', () {
        expect(secondsToHumanReadable(0), '0 secs');
        expect(secondsToHumanReadable(1), '1 sec');
        expect(secondsToHumanReadable(59), '59 secs');
      });

      test('formats minutes correctly', () {
        expect(secondsToHumanReadable(60), '1 min');
        expect(secondsToHumanReadable(61), '1 mins 1 secs');
        expect(secondsToHumanReadable(120), '2 mins');
        expect(secondsToHumanReadable(3599), '59 mins 59 secs');
      });

      test('formats hours correctly', () {
        expect(secondsToHumanReadable(3600), '1 hour');
        expect(secondsToHumanReadable(3660), '1 hours 1 mins');
        expect(secondsToHumanReadable(7200), '2 hours');
        expect(secondsToHumanReadable(86399), '23 hours 59 mins');
      });

      test('formats days correctly', () {
        expect(secondsToHumanReadable(86400), '1 day');
        expect(secondsToHumanReadable(90000), '1 days 1 hours');
        expect(secondsToHumanReadable(172800), '2 days');
        expect(secondsToHumanReadable(259200), '3 days');
      });
    });

    group('secondsToCompactDuration', () {
      test('formats seconds correctly', () {
        expect(secondsToCompactDuration(0), '0s');
        expect(secondsToCompactDuration(59), '59s');
      });

      test('formats minutes correctly', () {
        expect(secondsToCompactDuration(60), '1m');
        expect(secondsToCompactDuration(61), '1m 1s');
        expect(secondsToCompactDuration(599), '9m 59s');
      });

      test('formats minutes >= 10 concisely', () {
        expect(secondsToCompactDuration(600), '10m');
        expect(secondsToCompactDuration(601), '10m');
        expect(secondsToCompactDuration(3599), '59m');
      });

      test('formats hours correctly', () {
        expect(secondsToCompactDuration(3600), '1h');
        expect(secondsToCompactDuration(3660), '1h 1m');
        expect(secondsToCompactDuration(35999), '9h 59m');
      });

      test('formats hours >= 10 concisely', () {
        expect(secondsToCompactDuration(36000), '10h');
        expect(secondsToCompactDuration(36060), '10h');
        expect(secondsToCompactDuration(86399), '23h');
      });
    });

    group('secondsToHMS', () {
      test('formats seconds correctly', () {
        expect(secondsToHMS(0), '0:0:0');
        expect(secondsToHMS(59), '0:0:59');
      });

      test('formats minutes correctly', () {
        expect(secondsToHMS(60), '0:1:0');
        expect(secondsToHMS(61), '0:1:1');
        expect(secondsToHMS(3599), '0:59:59');
      });

      test('formats hours correctly', () {
        expect(secondsToHMS(3600), '1:0:0');
        expect(secondsToHMS(3661), '1:1:1');
        expect(secondsToHMS(86399), '23:59:59');
        expect(secondsToHMS(86400), '24:0:0');
      });
    });
  });
}
