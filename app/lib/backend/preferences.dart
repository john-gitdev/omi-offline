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

  double get offlineSnrMarginDb => getDouble('offlineSnrMarginDb', defaultValue: 10.0);

  set offlineSnrMarginDb(double value) => saveDouble('offlineSnrMarginDb', value);

  double get offlineHangoverSeconds => getDouble('offlineHangoverSeconds', defaultValue: 0.5);

  set offlineHangoverSeconds(double value) => saveDouble('offlineHangoverSeconds', value);

  int get offlineSplitSeconds => getInt('offlineSplitSeconds', defaultValue: 120);

  set offlineSplitSeconds(int value) => saveInt('offlineSplitSeconds', value);

  int get offlineMinSpeechSeconds => getInt('offlineMinSpeechSeconds', defaultValue: 0);

  set offlineMinSpeechSeconds(int value) => saveInt('offlineMinSpeechSeconds', value);

  double get offlinePreSpeechSeconds => getDouble('offlinePreSpeechSeconds', defaultValue: 1.0);

  set offlinePreSpeechSeconds(double value) => saveDouble('offlinePreSpeechSeconds', value);

  int get offlineGapSeconds => getInt('offlineGapSeconds', defaultValue: 10);

  set offlineGapSeconds(int value) => saveInt('offlineGapSeconds', value);

  bool get offlineAdjustmentMode => getBool('offlineAdjustmentMode', defaultValue: false);

  set offlineAdjustmentMode(bool value) => saveBool('offlineAdjustmentMode', value);

  bool get recordingsFilterEnabled => getBool('recordingsFilterEnabled', defaultValue: false);

  set recordingsFilterEnabled(bool value) => saveBool('recordingsFilterEnabled', value);

  int get recordingsFilterMinutes => getInt('recordingsFilterMinutes', defaultValue: 0);

  set recordingsFilterMinutes(int value) => saveInt('recordingsFilterMinutes', value);

  //--------------------------- Deepgram Integration -------------------------//

  String get deepgramApiKey => getString('deepgramApiKey');
  set deepgramApiKey(String value) => saveString('deepgramApiKey', value);

  bool get deepgramEnabled => getBool('deepgramEnabled', defaultValue: false);
  set deepgramEnabled(bool value) => saveBool('deepgramEnabled', value);

  /// Gap between words (in seconds) that triggers a conversation split.
  /// Range: 0–600 s. Default: 30 s.
  int get deepgramSplitGapSeconds => getInt('deepgramSplitGapSeconds', defaultValue: 30);
  set deepgramSplitGapSeconds(int value) => saveInt('deepgramSplitGapSeconds', value);

  /// When true: fall back to VAD immediately if Deepgram is unreachable.
  /// When false: queue the batch and retry when connectivity is restored.
  bool get deepgramFallbackToVad => getBool('deepgramFallbackToVad', defaultValue: true);
  set deepgramFallbackToVad(bool value) => saveBool('deepgramFallbackToVad', value);

  /// Epoch-ms timestamp of the last conversation end written for [dateString].
  /// Used by the overlap strategy to avoid re-writing already-processed conversations.
  int deepgramLastWrittenEndMs(String dateString) => getInt('deepgramLastWrittenEndMs_$dateString');
  Future<void> setDeepgramLastWrittenEndMs(String dateString, int ms) =>
      saveInt('deepgramLastWrittenEndMs_$dateString', ms);

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _preferences = prefs;

    // Set default values if not present
    if (!prefs.containsKey('offlineSnrMarginDb')) {
      prefs.setDouble('offlineSnrMarginDb', 10.0);
    }
    if (!prefs.containsKey('offlineHangoverSeconds')) {
      prefs.setDouble('offlineHangoverSeconds', 0.5);
    }
    if (!prefs.containsKey('offlineSplitSeconds')) {
      prefs.setInt('offlineSplitSeconds', 120); // 2 minutes default
    }
    if (!prefs.containsKey('offlineMinSpeechSeconds')) {
      prefs.setInt('offlineMinSpeechSeconds', 0); // 0 seconds default
    }
    if (!prefs.containsKey('offlinePreSpeechSeconds')) {
      prefs.setDouble('offlinePreSpeechSeconds', 1.0);
    }
    if (!prefs.containsKey('offlineGapSeconds')) {
      prefs.setInt('offlineGapSeconds', 10);
    }
    if (!prefs.containsKey('offlineAdjustmentMode')) {
      prefs.setBool('offlineAdjustmentMode', false);
    }
    if (!prefs.containsKey('deepgramEnabled')) {
      prefs.setBool('deepgramEnabled', false);
    }
    if (!prefs.containsKey('deepgramSplitGapSeconds')) {
      prefs.setInt('deepgramSplitGapSeconds', 30);
    }
    if (!prefs.containsKey('deepgramFallbackToVad')) {
      prefs.setBool('deepgramFallbackToVad', true);
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

  int get latestSyncedSessionId => getInt('latestSyncedSessionId', defaultValue: 0);

  set latestSyncedSessionId(int value) => saveInt('latestSyncedSessionId', value);

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

  double getDouble(String key, {double defaultValue = 0.0}) {
    final value = _preferences?.get(key);
    if (value is double) return value;
    if (value is int) return value.toDouble();
    return defaultValue;
  }

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
