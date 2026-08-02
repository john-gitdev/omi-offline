import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/utils/platform/platform_manager.dart';
import 'package:omi/backend/preferences.dart';

void main() {
  group('PlatformManager tests', () {
    late bool simulateDeviceInfoError;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      simulateDeviceInfoError = false;

      SharedPreferences.setMockInitialValues({});

      // Initialize SharedPreferencesUtil to avoid dependency issues
      const secureStorageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(secureStorageChannel,
          (call) async {
        if (call.method == 'readAll') return <String, String>{};
        return null;
      });
      await SharedPreferencesUtil.init();

      // Mock package_info
      const packageInfoChannel = MethodChannel('dev.fluttercommunity.plus/package_info');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(packageInfoChannel,
          (MethodCall methodCall) async {
        if (methodCall.method == 'getAll') {
          return <String, dynamic>{
            'appName': 'Test App',
            'packageName': 'com.test.app',
            'version': '1.0.0',
            'buildNumber': '1',
            'buildSignature': '',
          };
        }
        return null;
      });

      // Mock device_info
      const deviceInfoChannel = MethodChannel('dev.fluttercommunity.plus/device_info');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(deviceInfoChannel,
          (MethodCall methodCall) async {
        if (methodCall.method == 'getDeviceInfo') {
          if (simulateDeviceInfoError) {
            throw PlatformException(code: 'ERROR', message: 'Simulated device info error');
          }
          // Defaulting to simulating Android
          return <String, dynamic>{
            'id': 'test-android-device-id',
            'version': {'release': '12'},
          };
        }
        return null;
      });
    });

    test('initializeServices handles success path (Android/iOS info works)', () async {
      // SharedPreferences doesn't have it initially
      expect(SharedPreferencesUtil().deviceIdHash, isEmpty);

      await PlatformManager.initializeServices();
      final deviceIdHash = PlatformManager.instance.deviceIdHash;
      expect(deviceIdHash, isNotEmpty);
      expect(deviceIdHash.length, 8); // SHA256 substring(0, 8)

      // Verify it's cached in SharedPreferencesUtil
      expect(SharedPreferencesUtil().deviceIdHash, deviceIdHash);
    });

    test('initializeServices handles exception and uses fallback timestamp', () async {
      simulateDeviceInfoError = true;

      // Clear preferences to ensure it generates a new hash
      SharedPreferencesUtil().deviceIdHash = '';

      await PlatformManager.initializeServices();
      final deviceIdHash = PlatformManager.instance.deviceIdHash;
      expect(deviceIdHash, isNotEmpty);
      expect(deviceIdHash.length, 8); // SHA256 substring(0, 8)

      // Make sure it cached the generated one
      expect(SharedPreferencesUtil().deviceIdHash, deviceIdHash);
    });

    test('initializeServices uses previously stored deviceIdHash if available', () async {
      SharedPreferencesUtil().deviceIdHash = 'cached12';

      await PlatformManager.initializeServices();
      final deviceIdHash = PlatformManager.instance.deviceIdHash;
      expect(deviceIdHash, 'cached12');
    });
  });
}
