import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';

void main() {
  group('SharedPreferencesUtil Core Functionality', () {
    late SharedPreferencesUtil prefsUtil;
    late SharedPreferences rawPrefs;
    final Map<String, String> secureStorageMock = {};

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      secureStorageMock.clear();

      // Mock FlutterSecureStorage platform channel to allow SharedPreferencesUtil.init() to pass
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
      await SharedPreferencesUtil.init();
      prefsUtil = SharedPreferencesUtil();
      rawPrefs = await SharedPreferences.getInstance();
    });

    test('String primitives: getString and saveString work correctly', () async {
      expect(prefsUtil.getString('test_string'), '');
      expect(prefsUtil.getString('test_string', defaultValue: 'default'), 'default');

      await prefsUtil.saveString('test_string', 'hello');
      expect(prefsUtil.getString('test_string'), 'hello');
    });

    test('Int primitives: getInt and saveInt work correctly', () async {
      expect(prefsUtil.getInt('test_int'), 0);
      expect(prefsUtil.getInt('test_int', defaultValue: 42), 42);

      await prefsUtil.saveInt('test_int', 100);
      expect(prefsUtil.getInt('test_int'), 100);
    });

    test('Bool primitives: getBool and saveBool work correctly', () async {
      expect(prefsUtil.getBool('test_bool'), false);
      expect(prefsUtil.getBool('test_bool', defaultValue: true), true);

      await prefsUtil.saveBool('test_bool', true);
      expect(prefsUtil.getBool('test_bool'), true);
    });

    test('Double primitives: getDouble and saveDouble work correctly', () async {
      expect(prefsUtil.getDouble('test_double'), 0.0);
      expect(prefsUtil.getDouble('test_double', defaultValue: 3.14), 3.14);

      await prefsUtil.saveDouble('test_double', 9.99);
      expect(prefsUtil.getDouble('test_double'), 9.99);
    });

    test('StringList primitives: getStringList and saveStringList work correctly', () async {
      expect(prefsUtil.getStringList('test_string_list'), []);
      expect(prefsUtil.getStringList('test_string_list', defaultValue: ['a']), ['a']);

      await prefsUtil.saveStringList('test_string_list', ['x', 'y', 'z']);
      expect(prefsUtil.getStringList('test_string_list'), ['x', 'y', 'z']);
    });

    test('remove and clear methods work correctly', () async {
      await prefsUtil.saveString('key1', 'val1');
      await prefsUtil.saveInt('key2', 2);

      expect(prefsUtil.getString('key1'), 'val1');

      await prefsUtil.remove('key1');
      expect(prefsUtil.getString('key1'), '');
      expect(prefsUtil.getInt('key2'), 2);

      await prefsUtil.clear();
      expect(prefsUtil.getInt('key2'), 0);
    });

    test('Specific configuration wrappers read and write correctly', () async {
      // Test use24HourTime (default true)
      expect(prefsUtil.use24HourTime, true);
      prefsUtil.use24HourTime = false;
      expect(prefsUtil.use24HourTime, false);

      // Test deviceIdHash
      expect(prefsUtil.deviceIdHash, '');
      prefsUtil.deviceIdHash = 'hash123';
      expect(prefsUtil.deviceIdHash, 'hash123');

      // Test vadSpeechThreshold
      expect(prefsUtil.vadSpeechThreshold, 0.5);
      prefsUtil.vadSpeechThreshold = 0.8;
      expect(prefsUtil.vadSpeechThreshold, 0.8);
    });

    test('BtDevice serialization and deserialization work correctly', () async {
      // Default should return an empty BtDevice
      final defaultDevice = prefsUtil.btDevice;
      expect(defaultDevice.id, '');
      expect(defaultDevice.name, '');

      final device = BtDevice(id: '00:11:22:33:44:55', name: 'Omi Test', type: DeviceType.omi, rssi: -50);
      prefsUtil.btDevice = device;

      final retrievedDevice = prefsUtil.btDevice;
      expect(retrievedDevice.id, '00:11:22:33:44:55');
      expect(retrievedDevice.name, 'Omi Test');
      expect(retrievedDevice.rssi, -50);
    });

    test('Nullable property hasOmiDevice handles null to remove key', () async {
      prefsUtil.hasOmiDevice = true;
      expect(prefsUtil.hasOmiDevice, true);
      expect(rawPrefs.containsKey('hasOmiDevice'), true);

      // Setting to null should remove the key entirely
      prefsUtil.hasOmiDevice = null;
      expect(prefsUtil.hasOmiDevice, null);
      expect(rawPrefs.containsKey('hasOmiDevice'), false);
    });

    test('getDouble handles values incorrectly saved as int due to Dart numerics', () async {
      // Simulate saving an int into shared preferences instead of a double
      await rawPrefs.setInt('test_num', 5);

      // getDouble should safely cast it to a double
      final val = prefsUtil.getDouble('test_num');
      expect(val, 5.0);
    });
  });
}
