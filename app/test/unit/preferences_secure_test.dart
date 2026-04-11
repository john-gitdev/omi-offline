import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';

void main() {
  group('SharedPreferencesUtil Secure Storage Migration', () {
    late SharedPreferences prefs;
    final Map<String, String> secureStorageMock = {};

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      secureStorageMock.clear();

      // Mock FlutterSecureStorage platform channel
      const MethodChannel channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'read') {
          return secureStorageMock[call.arguments['key']];
        } else if (call.method == 'write') {
          secureStorageMock[call.arguments['key']] = call.arguments['value'];
          return null;
        } else if (call.method == 'delete') {
          secureStorageMock.remove(call.arguments['key']);
          return null;
        } else if (call.method == 'containsKey') {
          return secureStorageMock.containsKey(call.arguments['key']);
        } else if (call.method == 'readAll') {
          return secureStorageMock;
        }
        return null;
      });

      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('migration from SharedPreferences to FlutterSecureStorage works', () async {
      // 1. Set up legacy data
      const legacyKey = 'pk_test_12345';
      await prefs.setString('heypocketApiKey', legacyKey);

      // 2. Initialize SharedPreferencesUtil (triggers migration)
      await SharedPreferencesUtil.init();
      final util = SharedPreferencesUtil();

      // 3. Verify migration
      expect(util.heypocketApiKey, legacyKey);
      expect(prefs.containsKey('heypocketApiKey'), isFalse);
    });

    test('secure storage takes precedence over legacy data', () async {
      // 1. Set up both legacy and secure data
      const legacyKey = 'pk_legacy';
      const secureKey = 'pk_secure';
      await prefs.setString('heypocketApiKey', legacyKey);
      secureStorageMock['heypocketApiKey'] = secureKey;

      // 2. Initialize
      await SharedPreferencesUtil.init();
      final util = SharedPreferencesUtil();

      // 3. Verify secureKey won
      expect(util.heypocketApiKey, secureKey);
      expect(prefs.containsKey('heypocketApiKey'), isFalse);
    });

    test('setting API key updates secure storage and cache', () async {
      await SharedPreferencesUtil.init();
      final util = SharedPreferencesUtil();

      const newKey = 'pk_new_123';
      util.heypocketApiKey = newKey;

      expect(util.heypocketApiKey, newKey);
      expect(secureStorageMock['heypocketApiKey'], newKey);
    });
  });
}
