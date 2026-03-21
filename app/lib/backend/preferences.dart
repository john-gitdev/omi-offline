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

  int get offlineMinSpeechSeconds => getInt('offlineMinSpeechSeconds', defaultValue: 5);

  set offlineMinSpeechSeconds(int value) => saveInt('offlineMinSpeechSeconds', value);

  double get offlinePreSpeechSeconds => getDouble('offlinePreSpeechSeconds', defaultValue: 1.0);

  set offlinePreSpeechSeconds(double value) => saveDouble('offlinePreSpeechSeconds', value);

  int get offlineGapSeconds => getInt('offlineGapSeconds', defaultValue: 30);

  set offlineGapSeconds(int value) => saveInt('offlineGapSeconds', value);

  bool get offlineAdjustmentMode => getBool('offlineAdjustmentMode', defaultValue: false);

  set offlineAdjustmentMode(bool value) => saveBool('offlineAdjustmentMode', value);

  // 'automatic' = continuous VAD, 'marker' = marker-based extraction, 'fixed' = fixed wall-clock intervals
  String get offlineRecordingMode => getString('offlineRecordingMode', defaultValue: 'automatic');

  set offlineRecordingMode(String v) => saveString('offlineRecordingMode', v);

  // Interval in minutes for fixed recording mode: 30, 60, or 120
  int get offlineFixedIntervalMinutes => getInt('offlineFixedIntervalMinutes', defaultValue: 60);

  set offlineFixedIntervalMinutes(int value) => saveInt('offlineFixedIntervalMinutes', value);

  // Lookback window in minutes for marker mode: how far before a marker to scan for conversation start.
  // Options: 15, 30, 60, 120. Default: 120 (2 hours).
  int get markerLookbackMinutes => getInt('markerLookbackMinutes', defaultValue: 120);

  set markerLookbackMinutes(int value) => saveInt('markerLookbackMinutes', value);

  // Epoch ms of the next pending boundary for fixed mode.
  // Persisted so a fresh processor on the next sync knows which frames in the
  // boundary-crossing segment were already included in the previous clip.
  // 0 = no active boundary (no in-progress interval).
  int get fixedModeNextBoundaryMs => getInt('fixedModeNextBoundaryMs', defaultValue: 0);

  set fixedModeNextBoundaryMs(int value) => saveInt('fixedModeNextBoundaryMs', value);

  bool get autoSyncEnabled => getBool('autoSyncEnabled', defaultValue: true);

  set autoSyncEnabled(bool value) => saveBool('autoSyncEnabled', value);

  bool get recordingsFilterEnabled => getBool('recordingsFilterEnabled', defaultValue: false);

  set recordingsFilterEnabled(bool value) => saveBool('recordingsFilterEnabled', value);

  int get recordingsFilterMinutes => getInt('recordingsFilterMinutes', defaultValue: 0);

  set recordingsFilterMinutes(int value) => saveInt('recordingsFilterMinutes', value);

  //--------------------------- HeyPocket Integration ---------------------//

  String get heypocketApiKey => getString('heypocketApiKey');
  set heypocketApiKey(String v) => saveString('heypocketApiKey', v);

  bool get heypocketEnabled => getBool('heypocketEnabled', defaultValue: false);
  set heypocketEnabled(bool v) => saveBool('heypocketEnabled', v);

  List<String> get heypocketUploadedFiles => getStringList('heypocketUploadedFiles');
  set heypocketUploadedFiles(List<String> v) => saveStringList('heypocketUploadedFiles', v);

  // Epoch ms when the API key was first saved — used to limit auto-upload to new recordings only.
  int get heypocketKeySetAt => getInt('heypocketKeySetAt', defaultValue: 0);
  set heypocketKeySetAt(int v) => saveInt('heypocketKeySetAt', v);

  bool isUploadedToHeypocket(String uploadKey) => heypocketUploadedFiles.contains(uploadKey);

  void markUploadedToHeypocket(String uploadKey) {
    if (isUploadedToHeypocket(uploadKey)) return;
    final set = {...heypocketUploadedFiles};
    set.add(uploadKey);
    heypocketUploadedFiles = set.toList();
  }

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
      prefs.setInt('offlineMinSpeechSeconds', 5); // 5 seconds default
    }
    if (!prefs.containsKey('offlinePreSpeechSeconds')) {
      prefs.setDouble('offlinePreSpeechSeconds', 1.0);
    }
    if (!prefs.containsKey('offlineGapSeconds')) {
      prefs.setInt('offlineGapSeconds', 30);
    }
    if (!prefs.containsKey('offlineAdjustmentMode')) {
      prefs.setBool('offlineAdjustmentMode', false);
    }
    if (!prefs.containsKey('offlineRecordingMode')) {
      prefs.setString('offlineRecordingMode', 'automatic');
    }
    if (!prefs.containsKey('offlineFixedIntervalMinutes')) {
      prefs.setInt('offlineFixedIntervalMinutes', 60);
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
    final String device = getString('btDevice');
    if (device.isEmpty) return BtDevice(id: '', name: '', type: DeviceType.omi, rssi: 0);
    return BtDevice.fromJson(jsonDecode(device));
  }

  set deviceName(String value) => saveString('deviceName', value);

  String get deviceName => getString('deviceName');

  bool get deviceIsV2 => getBool('deviceIsV2');

  set deviceIsV2(bool value) => saveBool('deviceIsV2', value);

  int get latestSyncedDeviceSessionId => getInt('latestSyncedDeviceSessionId', defaultValue: 0);

  set latestSyncedDeviceSessionId(int value) => saveInt('latestSyncedDeviceSessionId', value);

  // Double tap behavior: 0 = end conversation (default), 1 = pause/mute, 2 = bookmark ongoing conversation
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
