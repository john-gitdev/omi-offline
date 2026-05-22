import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:omi/utils/environment_detector.dart';
import 'dart:io';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('com.omi/environment');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    EnvironmentDetector.platformIsIOSForTesting = true;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    EnvironmentDetector.platformIsIOSForTesting = null;
  });

  group('EnvironmentDetector.isTestFlight', () {
    test('returns false when not iOS', () async {
      EnvironmentDetector.platformIsIOSForTesting = false;
      final result = await EnvironmentDetector.isTestFlight();
      expect(result, false);
    });

    test('falls back to Platform.isIOS when platformIsIOSForTesting is null', () async {
      EnvironmentDetector.platformIsIOSForTesting = null;
      final result = await EnvironmentDetector.isTestFlight();
      // On desktop/CI where this runs, Platform.isIOS is likely false.
      // We just need to hit the line that checks Platform.isIOS.
      if (!Platform.isIOS) {
        expect(result, false);
      }
    });

    test('handles PlatformException and returns false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (MethodCall methodCall) async {
        if (methodCall.method == 'isTestFlight') {
          throw PlatformException(
            code: 'ERROR',
            message: 'Failed to check testflight',
          );
        }
        return null;
      });

      final result = await EnvironmentDetector.isTestFlight();
      expect(result, false);
    });

    test('returns true when channel returns true', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (MethodCall methodCall) async {
        if (methodCall.method == 'isTestFlight') {
          return true;
        }
        return null;
      });

      final result = await EnvironmentDetector.isTestFlight();
      expect(result, true);
    });
  });
}
