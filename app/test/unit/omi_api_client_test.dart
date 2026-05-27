import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/services/omi_api_client.dart';

void main() {
  group('OmiApiClient testConnection', () {
    test('returns false when refreshToken is empty', () async {
      final result = await OmiApiClient.testConnection(refreshToken: '', apiKey: 'test_key');
      expect(result, isFalse);
    });

    test('returns false when apiKey is empty', () async {
      final result = await OmiApiClient.testConnection(refreshToken: 'test_token', apiKey: '');
      expect(result, isFalse);
    });

    test('returns true on 200 success', () async {
      final mockClient = MockClient((request) async {
        return http.Response('', 200);
      });

      await http.runWithClient(() async {
        final result = await OmiApiClient.testConnection(refreshToken: 'test_token', apiKey: 'test_key');
        expect(result, isTrue);
      }, () => mockClient);
    });

    test('returns false on non-200 response', () async {
      final mockClient = MockClient((request) async {
        return http.Response('', 401);
      });

      await http.runWithClient(() async {
        final result = await OmiApiClient.testConnection(refreshToken: 'test_token', apiKey: 'test_key');
        expect(result, isFalse);
      }, () => mockClient);
    });

    test('returns false on TimeoutException', () async {
      final mockClient = MockClient((request) async {
        throw TimeoutException('Timeout');
      });

      await http.runWithClient(() async {
        final result = await OmiApiClient.testConnection(refreshToken: 'test_token', apiKey: 'test_key');
        expect(result, isFalse);
      }, () => mockClient);
    });

    test('returns false on SocketException', () async {
      final mockClient = MockClient((request) async {
        throw const SocketException('No network connection');
      });

      await http.runWithClient(() async {
        final result = await OmiApiClient.testConnection(refreshToken: 'test_token', apiKey: 'test_key');
        expect(result, isFalse);
      }, () => mockClient);
    });

    test('returns false on generic exception', () async {
      final mockClient = MockClient((request) async {
        throw Exception('Generic error');
      });

      await http.runWithClient(() async {
        final result = await OmiApiClient.testConnection(refreshToken: 'test_token', apiKey: 'test_key');
        expect(result, isFalse);
      }, () => mockClient);
    });
  });
}
