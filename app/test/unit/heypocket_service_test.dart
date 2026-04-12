import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/services/heypocket_service.dart';

void main() {
  group('HeyPocketService testConnection', () {
    test('returns true on 200 success', () async {
      final mockClient = MockClient((request) async {
        return http.Response('', 200);
      });

      await http.runWithClient(() async {
        final result = await HeyPocketService.testConnection('test_key');
        expect(result, isTrue);
      }, () => mockClient);
    });

    test('returns false on 401 error', () async {
      final mockClient = MockClient((request) async {
        return http.Response('', 401);
      });

      await http.runWithClient(() async {
        final result = await HeyPocketService.testConnection('test_key');
        expect(result, isFalse);
      }, () => mockClient);
    });

    test('throws HeyPocketException on TimeoutException', () async {
      final mockClient = MockClient((request) async {
        throw TimeoutException('Timeout');
      });

      await http.runWithClient(() async {
        expect(
          () => HeyPocketService.testConnection('test_key'),
          throwsA(
            isA<HeyPocketException>().having((e) => e.message, 'message', 'Connection timed out — check your network'),
          ),
        );
      }, () => mockClient);
    });

    test('throws HeyPocketException on SocketException', () async {
      final mockClient = MockClient((request) async {
        throw const SocketException('No network connection');
      });

      await http.runWithClient(() async {
        expect(
          () => HeyPocketService.testConnection('test_key'),
          throwsA(
            isA<HeyPocketException>().having((e) => e.message, 'message', 'No network connection'),
          ),
        );
      }, () => mockClient);
    });

    test('throws HeyPocketException on generic exception', () async {
      final mockClient = MockClient((request) async {
        throw Exception('Generic error');
      });

      await http.runWithClient(() async {
        expect(
          () => HeyPocketService.testConnection('test_key'),
          throwsA(
            isA<HeyPocketException>().having((e) => e.message, 'message', 'Connection failed'),
          ),
        );
      }, () => mockClient);
    });
  });
}
