import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/other/temp.dart';

void main() {
  group('countryFlagFromCode', () {
    test('returns correct flag for 2-letter uppercase country code', () {
      expect(countryFlagFromCode('US'), '🇺🇸');
      expect(countryFlagFromCode('JP'), '🇯🇵');
      expect(countryFlagFromCode('GB'), '🇬🇧');
    });

    test('handles lowercase country codes', () {
      expect(countryFlagFromCode('us'), '🇺🇸');
      expect(countryFlagFromCode('jp'), '🇯🇵');
    });

    test('handles empty string by returning it', () {
      expect(countryFlagFromCode(''), '');
    });

    test('handles 1-character string by returning it', () {
      expect(countryFlagFromCode('A'), 'A');
      expect(countryFlagFromCode('a'), 'a');
    });

    test('handles >2 character string by returning it', () {
      expect(countryFlagFromCode('USA'), 'USA');
    });

    test('handles non-alphabet characters by returning them', () {
      expect(countryFlagFromCode('12'), '12');
      expect(countryFlagFromCode('!!'), '!!');
    });
  });
}
