import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';

class SharedPreferencesUtil {
  static final SharedPreferencesUtil _instance = SharedPreferencesUtil._internal();
  static SharedPreferences? _preferences;

  factory SharedPreferencesUtil() {
    return _instance;
  }

  SharedPreferencesUtil._internal();

  String get deviceIdHash => _preferences?.getString('deviceIdHash') ?? '';
  set deviceIdHash(String value) => _preferences?.setString('deviceIdHash', value);

  //--------------------------- Offline Audio Processing ---------------------//

  double get offlineSilenceThreshold => getDouble('offlineSilenceThreshold', defaultValue: -45.0);

  set offlineSilenceThreshold(double value) => saveDouble('offlineSilenceThreshold', value);

  int get offlineSplitSeconds => getInt('offlineSplitSeconds', defaultValue: 120);

  set offlineSplitSeconds(int value) => saveInt('offlineSplitSeconds', value);

  int get offlineMinSpeechSeconds => getInt('offlineMinSpeechSeconds', defaultValue: 0);

  set offlineMinSpeechSeconds(int value) => saveInt('offlineMinSpeechSeconds', value);

  int get offlinePreSpeechSeconds => getInt('offlinePreSpeechSeconds', defaultValue: 1);

  set offlinePreSpeechSeconds(int value) => saveInt('offlinePreSpeechSeconds', value);

  int get offlineGapSeconds => getInt('offlineGapSeconds', defaultValue: 10);

  set offlineGapSeconds(int value) => saveInt('offlineGapSeconds', value);

  bool get offlineAdjustmentMode => getBool('offlineAdjustmentMode', defaultValue: false);

  set offlineAdjustmentMode(bool value) => saveBool('offlineAdjustmentMode', value);

  static Future<void> init() async {
    _preferences = await SharedPreferences.getInstance();

    // Set default values if not present
    if (!_preferences!.containsKey('offlineSilenceThreshold')) {
      _preferences!.setDouble('offlineSilenceThreshold', -45.0);
    }
    if (!_preferences!.containsKey('offlineSplitSeconds')) {
      _preferences!.setInt('offlineSplitSeconds', 120); // 2 minutes default
    }
    if (!_preferences!.containsKey('offlineMinSpeechSeconds')) {
      _preferences!.setInt('offlineMinSpeechSeconds', 0); // 0 seconds default
    }
    if (!_preferences!.containsKey('offlinePreSpeechSeconds')) {
      _preferences!.setInt('offlinePreSpeechSeconds', 1);
    }
    if (!_preferences!.containsKey('offlineGapSeconds')) {
      _preferences!.setInt('offlineGapSeconds', 10);
    }
    if (!_preferences!.containsKey('offlineAdjustmentMode')) {
      _preferences!.setBool('offlineAdjustmentMode', false);
    }
  }

  //-------------------------------- Device ----------------------------------//

  bool? get hasOmiDevice => _preferences?.getBool('hasOmiDevice');

  set hasOmiDevice(bool? value) {
    if (value != null) {
      _preferences?.setBool('hasOmiDevice', value);
    } else {
      _preferences?.remove('hasOmiDevice');
    }
  }

  set btDevice(BtDevice value) {
    saveString('btDevice', jsonEncode(value.toJson()));
  }

  Future<void> btDeviceSet(BtDevice value) async {
    await saveString('btDevice', jsonEncode(value.toJson()));
  }

  BtDevice get btDevice {
    final String device = getString('btDevice') ?? '';
    if (device.isEmpty) return BtDevice(id: '', name: '', type: DeviceType.omi, rssi: 0);
    return BtDevice.fromJson(jsonDecode(device));
  }

  set deviceName(String value) => saveString('deviceName', value);

  String get deviceName => getString('deviceName');

  bool get deviceIsV2 => getBool('deviceIsV2');

  set deviceIsV2(bool value) => saveBool('deviceIsV2', value);

  // Double tap behavior: 0 = end conversation (default), 1 = pause/mute, 2 = star ongoing conversation
  int get doubleTapAction => getInt('doubleTapAction');

  set doubleTapAction(int value) => saveInt('doubleTapAction', value);

  // Keep backward compatibility
  bool get doubleTapPausesMuting => doubleTapAction == 1;

  set doubleTapPausesMuting(bool value) => doubleTapAction = value ? 1 : 0;

  // Developer Diagnostics
  bool get devLogsToFileEnabled => getBool('devLogsToFileEnabled');

  set devLogsToFileEnabled(bool value) => saveBool('devLogsToFileEnabled', value);

  //--------------------------- Setters & Getters -----------------------------//

  String getString(String key, {String defaultValue = ''}) => _preferences?.getString(key) ?? defaultValue;

  int getInt(String key, {int defaultValue = 0}) => _preferences?.getInt(key) ?? defaultValue;

  bool getBool(String key, {bool defaultValue = false}) => _preferences?.getBool(key) ?? defaultValue;

  double getDouble(String key, {double defaultValue = 0.0}) => _preferences?.getDouble(key) ?? defaultValue;

  List<String> getStringList(String key, {List<String> defaultValue = const []}) =>
      _preferences?.getStringList(key) ?? defaultValue;

  Future<bool> saveString(String key, String value) async => await _preferences?.setString(key, value) ?? false;

  Future<bool> saveInt(String key, int value) async => await _preferences?.setInt(key, value) ?? false;

  Future<bool> saveBool(String key, bool value) async => await _preferences?.setBool(key, value) ?? false;

  Future<bool> saveDouble(String key, double value) async => await _preferences?.setDouble(key, value) ?? false;

  Future<bool> saveStringList(String key, List<String> value) async =>
      await _preferences?.setStringList(key, value) ?? false;

  Future<bool> remove(String key) async => await _preferences?.remove(key) ?? false;

  Future<bool> clear() async => await _preferences?.clear() ?? false;
}
