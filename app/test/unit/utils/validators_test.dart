import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/other/validators.dart';

void main() {
  group('isValidUrl', () {
    test('should return true for valid URLs', () {
      expect(isValidUrl('https://www.google.com'), isTrue);
      expect(isValidUrl('http://google.com'), isTrue);
      expect(isValidUrl('google.com'), isTrue);
      expect(isValidUrl('https://sub.domain.example.com/path?query=1'), isTrue);
      expect(isValidUrl('http://192.168.1.1'), isTrue);
      expect(isValidUrl('192.168.1.1'), isTrue);
      expect(isValidUrl('127.0.0.1:8080'), isTrue);
      expect(isValidUrl('abc.com/xyz'), isTrue);
    });

    test('should return false for invalid URLs', () {
      expect(isValidUrl('not-a-url'), isFalse);
      expect(isValidUrl('http://'), isFalse);
      expect(isValidUrl('https://.com'), isFalse);
      expect(isValidUrl(''), isFalse);
      expect(isValidUrl('just-words'), isFalse);
    });
  });

  group('isValidPayPalMeUrl', () {
    test('should return true for valid PayPal.Me URLs', () {
      expect(isValidPayPalMeUrl('paypal.me/username'), isTrue);
      expect(isValidPayPalMeUrl('paypal.me/user-name'), isTrue);
      expect(isValidPayPalMeUrl('paypal.me/user123'), isTrue);
    });

    test('should return false for invalid PayPal.Me URLs', () {
      expect(isValidPayPalMeUrl('paypal.me/'), isFalse);
      expect(isValidPayPalMeUrl('https://paypal.me/username'), isFalse);
      expect(isValidPayPalMeUrl('google.com'), isFalse);
      expect(isValidPayPalMeUrl('paypal.me/user.name'), isFalse); // regex says [a-zA-Z0-9-]
      expect(isValidPayPalMeUrl(''), isFalse);
    });
  });

  group('isValidWebSocketUrl', () {
    test('should return true for valid WebSocket URLs', () {
      expect(isValidWebSocketUrl('ws://echo.websocket.org'), isTrue);
      expect(isValidWebSocketUrl('wss://echo.websocket.org'), isTrue);
      expect(isValidWebSocketUrl('ws://127.0.0.1:8080'), isTrue);
    });

    test('should return false for invalid WebSocket URLs', () {
      expect(isValidWebSocketUrl('echo.websocket.org'), isFalse);
      expect(isValidWebSocketUrl('http://google.com'), isFalse);
      expect(isValidWebSocketUrl('not-a-url'), isFalse);
      expect(isValidWebSocketUrl(''), isFalse);
    });
  });

  group('isValidEmail', () {
    test('should return true for valid emails', () {
      expect(isValidEmail('test@example.com'), isTrue);
      expect(isValidEmail('user.name@domain.co.uk'), isTrue);
      expect(isValidEmail('user_name123@sub.domain.com'), isTrue);
    });

    test('should return false for invalid emails', () {
      expect(isValidEmail('test@example'), isFalse);
      expect(isValidEmail('@example.com'), isFalse);
      expect(isValidEmail('test@.com'), isFalse);
      expect(isValidEmail('plainaddress'), isFalse);
      expect(isValidEmail(''), isFalse);
    });
  });
}
