import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/other/string_utils.dart';

void main() {
  group('String Utils - capitalize', () {
    test('capitalizes normal string correctly', () {
      expect(capitalize('hello'), 'Hello');
    });

    test('returns empty string if input is empty', () {
      expect(capitalize(''), '');
    });

    test('returns same string if already capitalized', () {
      expect(capitalize('Hello'), 'Hello');
    });

    test('capitalizes single character correctly', () {
      expect(capitalize('a'), 'A');
    });

    test('handles numbers and special characters gracefully', () {
      expect(capitalize('1hello'), '1hello');
      expect(capitalize('!hello'), '!hello');
    });
  });

  group('String Utils - convertToHHMMSS', () {
    test('converts 0 seconds correctly', () {
      expect(convertToHHMMSS(0), '00:00:00');
    });

    test('converts seconds less than a minute correctly', () {
      expect(convertToHHMMSS(59), '00:00:59');
    });

    test('converts exactly 60 seconds correctly', () {
      expect(convertToHHMMSS(60), '00:01:00');
    });

    test('converts seconds less than an hour correctly', () {
      expect(convertToHHMMSS(3599), '00:59:59');
    });

    test('converts exactly an hour correctly', () {
      expect(convertToHHMMSS(3600), '01:00:00');
    });

    test('converts mixed hours, minutes, and seconds correctly', () {
      expect(convertToHHMMSS(3661), '01:01:01');
    });

    test('converts large number of seconds correctly (just under a day)', () {
      expect(convertToHHMMSS(86399), '23:59:59');
    });

    test('converts exactly a day correctly', () {
      expect(convertToHHMMSS(86400), '24:00:00');
    });

    test('converts multi-day duration correctly', () {
      expect(convertToHHMMSS(359999), '99:59:59');
    });

    test('converts more than 100 hours correctly', () {
      expect(convertToHHMMSS(360000), '100:00:00');
    });

    test('handles negative values idiosyncratically due to Dart modulo operator', () {
      expect(convertToHHMMSS(-1), '00:59:59');
    });
  });

  group('String Utils - extractJson', () {
    test('extracts standard JSON correctly', () {
      final input = 'Here is some text {"key": "value"} and more text';
      expect(extractJson(input), '{"key": "value"}');
    });

    test('extracts nested JSON correctly', () {
      final input = 'Data: {"outer": {"inner": 1}} end';
      expect(extractJson(input), '{"outer": {"inner": 1}}');
    });

    test('returns empty string if no JSON is present', () {
      expect(extractJson('Just some normal text'), '');
    });

    test('returns empty string for empty input', () {
      expect(extractJson(''), '');
    });

    test('returns empty string for missing closing brace', () {
      expect(extractJson('Text {"key": "value"'), '');
    });

    test('returns empty string for missing opening brace', () {
      expect(extractJson('Text "key": "value"}'), '');
    });
  });

  group('String Utils - padBase64', () {
    test('pads base64 strings with remainder 1 correctly', () {
      expect(padBase64('a'), 'a___');
    });

    test('pads base64 strings with remainder 2 correctly', () {
      expect(padBase64('ab'), 'ab__');
    });

    test('pads base64 strings with remainder 3 correctly', () {
      expect(padBase64('abc'), 'abc_');
    });

    test('does not pad base64 strings with remainder 0', () {
      expect(padBase64('abcd'), 'abcd');
    });
  });

  group('String Utils - decodeBase64', () {
    test('decodes valid non-padded base64 correctly', () {
      expect(decodeBase64('YWJj'), 'abc');
    });

    test('decodes valid padded base64 correctly', () {
      expect(decodeBase64('YQ=='), 'a');
    });

    test('throws FormatException for invalid padding with underscores', () {
      expect(() => decodeBase64('YQ__'), throwsA(isA<FormatException>()));
    });
  });

  group('String Utils - tryDecodingText', () {
    test('decodes valid utf-8 string correctly', () {
      final text = 'Hello world';
      expect(tryDecodingText(text), text);
    });

    test('returns original string if utf-8 decoding fails', () {
      // Create a string that when converted to codeUnits creates an invalid UTF-8 byte sequence
      // This throws a FormatException during utf8.decode(codeUnits)
      final text = String.fromCharCodes([0xFF]);
      expect(tryDecodingText(text), text);
    });

    test('returns original string if input contains invalid utf-8 sequences', () {
      // In Dart, String.codeUnits creates a list. utf8.decode throws FormatException
      // if it encounters invalid utf-8 sequences. This tests the catch block error path.
      final invalidUtf8Bytes = [0xC3, 0x28]; // Invalid sequence
      final invalidText = String.fromCharCodes(invalidUtf8Bytes);
      expect(tryDecodingText(invalidText), invalidText);
    });
  });
}
