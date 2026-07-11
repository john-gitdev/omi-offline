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
      // Test use24HourTime (default false)
      expect(prefsUtil.use24HourTime, false);
      prefsUtil.use24HourTime = true;
      expect(prefsUtil.use24HourTime, true);

      // Test deviceIdHash
      expect(prefsUtil.deviceIdHash, '');
      prefsUtil.deviceIdHash = 'hash123';
      expect(prefsUtil.deviceIdHash, 'hash123');

      // Test vadSpeechThreshold
      expect(prefsUtil.vadSpeechThreshold, 0.5);
      prefsUtil.vadSpeechThreshold = 0.8;
      expect(prefsUtil.vadSpeechThreshold, 0.8);
    });

    test('All other properties read and write correctly with expected defaults', () async {
      // Offline Audio Processing
      expect(prefsUtil.forceSyncSkipConfirm, false);
      prefsUtil.forceSyncSkipConfirm = true;
      expect(prefsUtil.forceSyncSkipConfirm, true);

      expect(prefsUtil.vadSplitSeconds, 120);
      prefsUtil.vadSplitSeconds = 60;
      expect(prefsUtil.vadSplitSeconds, 60);

      expect(prefsUtil.filterMinDurationSeconds, 0);
      prefsUtil.filterMinDurationSeconds = 60;
      expect(prefsUtil.filterMinDurationSeconds, 60);

      expect(prefsUtil.vadMaxConversationMinutes, 60);
      prefsUtil.vadMaxConversationMinutes = 90;
      expect(prefsUtil.vadMaxConversationMinutes, 90);

      expect(prefsUtil.backgroundSyncIntervalMinutes, 30);
      prefsUtil.backgroundSyncIntervalMinutes = 15;
      expect(prefsUtil.backgroundSyncIntervalMinutes, 15);

      expect(prefsUtil.extractionInProgress, false);
      prefsUtil.extractionInProgress = true;
      expect(prefsUtil.extractionInProgress, true);

      // Device
      expect(prefsUtil.lastConnectedDeviceAddress, '');
      prefsUtil.lastConnectedDeviceAddress = 'AA:BB:CC';
      expect(prefsUtil.lastConnectedDeviceAddress, 'AA:BB:CC');

      expect(prefsUtil.deviceName, '');
      prefsUtil.deviceName = 'TestDevice';
      expect(prefsUtil.deviceName, 'TestDevice');

      expect(prefsUtil.deviceIsV2, false);
      prefsUtil.deviceIsV2 = true;
      expect(prefsUtil.deviceIsV2, true);

      expect(prefsUtil.doubleTapAction, 0);
      prefsUtil.doubleTapAction = 1;
      expect(prefsUtil.doubleTapAction, 1);

      expect(prefsUtil.doubleTapPausesMuting, true); // Since doubleTapAction is 1
      prefsUtil.doubleTapPausesMuting = false;
      expect(prefsUtil.doubleTapAction, 0);
      expect(prefsUtil.doubleTapPausesMuting, false);

      expect(prefsUtil.lastBatteryLevel, -1);
      prefsUtil.lastBatteryLevel = 50;
      expect(prefsUtil.lastBatteryLevel, 50);

      expect(prefsUtil.devLogsToFileEnabled, false);
      prefsUtil.devLogsToFileEnabled = true;
      expect(prefsUtil.devLogsToFileEnabled, true);

      expect(prefsUtil.uploadOnWifiOnly, false);
      prefsUtil.uploadOnWifiOnly = true;
      expect(prefsUtil.uploadOnWifiOnly, true);
    });

    test('HeyPocket uploaded files management and concurrency works correctly', () async {
      // Basic properties
      expect(prefsUtil.heypocketEnabled, false);
      prefsUtil.heypocketEnabled = true;
      expect(prefsUtil.heypocketEnabled, true);

      expect(prefsUtil.heypocketKeySetAt, 0);
      prefsUtil.heypocketKeySetAt = 123456789;
      expect(prefsUtil.heypocketKeySetAt, 123456789);

      expect(prefsUtil.heypocketUploadedFiles, []);
      prefsUtil.heypocketUploadedFiles = ['file1'];
      expect(prefsUtil.heypocketUploadedFiles, ['file1']);
      expect(prefsUtil.isUploadedToHeypocket('file1'), true);
      expect(prefsUtil.isUploadedToHeypocket('file2'), false);

      // Concurrency guarded methods
      await prefsUtil.markUploadedToHeypocket('file2');
      expect(prefsUtil.heypocketUploadedFiles, ['file1', 'file2']);
      expect(prefsUtil.isUploadedToHeypocket('file2'), true);

      // Duplicate addition does not affect list
      await prefsUtil.markUploadedToHeypocket('file2');
      expect(prefsUtil.heypocketUploadedFiles, ['file1', 'file2']);

      // Remove keys
      await prefsUtil.removeUploadedFromHeypocket({'file1'});
      expect(prefsUtil.heypocketUploadedFiles, ['file2']);

      // Remove non-existent key
      await prefsUtil.removeUploadedFromHeypocket({'file3'});
      expect(prefsUtil.heypocketUploadedFiles, ['file2']);

      // Remove empty set
      await prefsUtil.removeUploadedFromHeypocket({});
      expect(prefsUtil.heypocketUploadedFiles, ['file2']);
    });

    test('Per-mode button configs: defaults, round-trip, and activeButtonConfig', () async {
      // Defaults when unset.
      expect(prefsUtil.buttonConfigManual, SharedPreferencesUtil.defaultButtonConfigManual);
      expect(prefsUtil.buttonConfigAuto, SharedPreferencesUtil.defaultButtonConfigAuto);

      // Round-trip both configs (stored as a string list under the hood).
      prefsUtil.buttonConfigManual = [0, 2, 4, 3, 5, 1];
      prefsUtil.buttonConfigAuto = [1, 4, 2, 0, 3, 5];
      expect(prefsUtil.buttonConfigManual, [0, 2, 4, 3, 5, 1]);
      expect(prefsUtil.buttonConfigAuto, [1, 4, 2, 0, 3, 5]);

      // A corrupt (wrong-length) stored value falls back to the default.
      await prefsUtil.saveStringList('buttonConfigManual', ['9', '9']);
      expect(prefsUtil.buttonConfigManual, SharedPreferencesUtil.defaultButtonConfigManual);

      // activeButtonConfig follows manualMode.
      prefsUtil.manualMode = true;
      expect(prefsUtil.activeButtonConfig, prefsUtil.buttonConfigManual);
      prefsUtil.manualMode = false;
      expect(prefsUtil.activeButtonConfig, prefsUtil.buttonConfigAuto);

      // Migration guard defaults false.
      expect(prefsUtil.buttonConfigMigrated, false);
      prefsUtil.buttonConfigMigrated = true;
      expect(prefsUtil.buttonConfigMigrated, true);
    });

    test('combineRecordButton defaults off and round-trips', () {
      expect(prefsUtil.combineRecordButton, false);
      prefsUtil.combineRecordButton = true;
      expect(prefsUtil.combineRecordButton, true);
    });

    test('normalizeButtonConfigForCombine: asymmetric remap, idempotent, non-recording untouched', () {
      // Turning ON (split → combined): Start(4) preserved as Toggle(6),
      // Stop(5) blanked; Mute/Marker/LED/None untouched.
      expect(
        SharedPreferencesUtil.normalizeButtonConfigForCombine([0, 2, 4, 3, 5, 1], true),
        [0, 2, 6, 3, 0, 1],
      );
      // Turning OFF (combined → split): Toggle(6) blanked (never auto-created a
      // lone Start); everything else untouched.
      expect(
        SharedPreferencesUtil.normalizeButtonConfigForCombine([0, 2, 6, 3, 0, 1], false),
        [0, 2, 0, 3, 0, 1],
      );
      // Idempotent: normalizing to a mode a config already satisfies is a no-op.
      expect(
        SharedPreferencesUtil.normalizeButtonConfigForCombine([0, 2, 6, 3, 0, 1], true),
        [0, 2, 6, 3, 0, 1],
      );
      expect(
        SharedPreferencesUtil.normalizeButtonConfigForCombine([0, 2, 4, 3, 5, 1], false),
        [0, 2, 4, 3, 5, 1],
      );
    });

    test('shouldPreserveExistingButtonConfig: migrate old/customized, skip fresh device', () {
      // Old factory default (double-tap=Marker) → preserve into auto.
      expect(SharedPreferencesUtil.shouldPreserveExistingButtonConfig([0, 0, 2, 1, 3, 0]), true);
      // Any customized config → preserve.
      expect(SharedPreferencesUtil.shouldPreserveExistingButtonConfig([1, 2, 3, 0, 0, 0]), true);
      // Factory-fresh new-firmware device (== new manual default) → skip.
      expect(
        SharedPreferencesUtil.shouldPreserveExistingButtonConfig(SharedPreferencesUtil.defaultButtonConfigManual),
        false,
      );
      // Null / wrong-length reads → skip (nothing valid to preserve).
      expect(SharedPreferencesUtil.shouldPreserveExistingButtonConfig(null), false);
      expect(SharedPreferencesUtil.shouldPreserveExistingButtonConfig([0, 0, 2]), false);
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
