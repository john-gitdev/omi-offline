import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';

class SharedPreferencesUtil {
  static final SharedPreferencesUtil _instance = SharedPreferencesUtil._internal();
  static SharedPreferences? _preferences;
  static const _secureStorage = FlutterSecureStorage();

  factory SharedPreferencesUtil() {
    return _instance;
  }

  SharedPreferencesUtil._internal();

  Future<void>? _heypocketUploadGuard;
  String _heypocketApiKey = '';

  String get deviceIdHash => _preferences?.getString('deviceIdHash') ?? '';
  set deviceIdHash(String value) => _preferences?.setString('deviceIdHash', value);

  //--------------------------- Offline Audio Processing ---------------------//

  bool get forceSyncSkipConfirm => getBool('force_sync_skip_confirm', defaultValue: false);
  set forceSyncSkipConfirm(bool value) => saveBool('force_sync_skip_confirm', value);

  // When enabled, raw .bin segments are preserved after processing so days can
  // be reprocessed with different VAD settings via the Reprocess Day button.
  bool get adjustmentMode => getBool('adjustmentMode', defaultValue: false);
  set adjustmentMode(bool value) => saveBool('adjustmentMode', value);

  // Set to true the first time adjustment mode is turned ON; cleared only after
  // the cleanup banner's "Process & Delete" completes. Used to suppress the
  // cleanup banner when adjustment mode has never been enabled.
  bool get adjustmentModeWasEnabled => getBool('adjustmentModeWasEnabled', defaultValue: false);
  set adjustmentModeWasEnabled(bool value) => saveBool('adjustmentModeWasEnabled', value);

  // Silero VAD speech probability cutoff (0.0–1.0). Frames with probability
  // above this value are classified as speech.
  double get vadSpeechThreshold => getDouble('vadSpeechThreshold', defaultValue: 0.5);
  set vadSpeechThreshold(double v) => saveDouble('vadSpeechThreshold', v);

  // Frames of speech to continue counting after Silero reports silence,
  // to smooth out brief dropouts within a sentence.
  double get vadHangoverSeconds => getDouble('vadHangoverSeconds', defaultValue: 0.5);
  set vadHangoverSeconds(double v) => saveDouble('vadHangoverSeconds', v);

  // Continuous silence duration (seconds) that triggers a conversation cut.
  int get vadSplitSeconds => getInt('vadSplitSeconds', defaultValue: 120);
  set vadSplitSeconds(int v) => saveInt('vadSplitSeconds', v);

  // Minimum speech duration (seconds) for a conversation to be saved. Shorter conversations
  // are discarded (e.g. a cough, a door slam).
  int get vadMinSpeechSeconds => getInt('vadMinSpeechSeconds', defaultValue: 3);
  set vadMinSpeechSeconds(int v) => saveInt('vadMinSpeechSeconds', v);

  // Seconds of silence frames to prepend before a new conversation starts,
  // so speech doesn't begin abruptly.
  double get vadPreSpeechSeconds => getDouble('vadPreSpeechSeconds', defaultValue: 1.0);
  set vadPreSpeechSeconds(double v) => saveDouble('vadPreSpeechSeconds', v);

  // Gap between consecutive segment files (seconds) that forces a conversation
  // cut, regardless of VAD state.
  int get vadGapSeconds => getInt('vadGapSeconds', defaultValue: 30);
  set vadGapSeconds(int v) => saveInt('vadGapSeconds', v);

  // Maximum continuous conversation length (minutes) before forcing a cut.
  int get vadMaxConversationMinutes => getInt('vadMaxConversationMinutes', defaultValue: 60);
  set vadMaxConversationMinutes(int v) => saveInt('vadMaxConversationMinutes', v);

  bool get autoSyncEnabled => getBool('autoSyncEnabled', defaultValue: true);

  set autoSyncEnabled(bool value) => saveBool('autoSyncEnabled', value);

  // Whether to display times in 24-hour format (true) or 12-hour AM/PM (false).
  bool get use24HourTime => getBool('use24HourTime', defaultValue: true);
  set use24HourTime(bool value) => saveBool('use24HourTime', value);

  // True while extraction/processing is in progress. Persisted so that on
  // restart after a crash we can detect incomplete processing and clean up
  // the temp directory to avoid duplicate recordings.
  bool get extractionInProgress => getBool('extractionInProgress', defaultValue: false);

  set extractionInProgress(bool value) => saveBool('extractionInProgress', value);

  //--------------------------- HeyPocket Integration ---------------------//

  String get heypocketApiKey => _heypocketApiKey;
  Future<void> setHeypocketApiKey(String v) async {
    _heypocketApiKey = v;
    await _secureStorage.write(key: 'heypocketApiKey', value: v);
  }

  bool get heypocketEnabled => getBool('heypocketEnabled', defaultValue: false);
  set heypocketEnabled(bool v) => saveBool('heypocketEnabled', v);

  List<String> get heypocketUploadedFiles => getStringList('heypocketUploadedFiles');
  set heypocketUploadedFiles(List<String> v) => saveStringList('heypocketUploadedFiles', v);

  // Epoch ms when the API key was first saved — used to limit auto-upload to new recordings only.
  int get heypocketKeySetAt => getInt('heypocketKeySetAt', defaultValue: 0);
  set heypocketKeySetAt(int v) => saveInt('heypocketKeySetAt', v);

  bool isUploadedToHeypocket(String uploadKey) => heypocketUploadedFiles.contains(uploadKey);

  /// Serialized read-modify-write to prevent concurrent calls from losing updates.
  Future<void> markUploadedToHeypocket(String uploadKey) async {
    // Wait for any in-flight update to complete before reading.
    while (_heypocketUploadGuard != null) {
      await _heypocketUploadGuard;
    }
    final completer = Completer<void>();
    _heypocketUploadGuard = completer.future;
    try {
      if (isUploadedToHeypocket(uploadKey)) return;
      final updated = {...heypocketUploadedFiles};
      updated.add(uploadKey);
      await saveStringList('heypocketUploadedFiles', updated.toList());
    } finally {
      _heypocketUploadGuard = null;
      completer.complete();
    }
  }

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _preferences = prefs;

    // Initialize secure storage and handle migration
    _instance._heypocketApiKey = await _secureStorage.read(key: 'heypocketApiKey') ?? '';
    if (prefs.containsKey('heypocketApiKey')) {
      final legacyKey = prefs.getString('heypocketApiKey') ?? '';
      if (legacyKey.isNotEmpty && _instance._heypocketApiKey.isEmpty) {
        _instance._heypocketApiKey = legacyKey;
        await _secureStorage.write(key: 'heypocketApiKey', value: legacyKey);
      }
      await prefs.remove('heypocketApiKey');
    }

    // Set default values if not present
    if (!prefs.containsKey('vadSpeechThreshold')) {
      prefs.setDouble('vadSpeechThreshold', 0.5);
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
    if (device.isEmpty) {
      return BtDevice(id: '', name: '', type: DeviceType.omi, rssi: 0);
    }
    return BtDevice.fromJson(jsonDecode(device));
  }

  set lastConnectedDeviceAddress(String value) => saveString('lastConnectedDeviceAddress', value);

  String get lastConnectedDeviceAddress => getString('lastConnectedDeviceAddress');

  set deviceName(String value) => saveString('deviceName', value);

  String get deviceName => getString('deviceName');

  bool get deviceIsV2 => getBool('deviceIsV2');

  set deviceIsV2(bool value) => saveBool('deviceIsV2', value);

  // Double tap behavior: 0 = end conversation (default), 1 = pause/mute, 2 = bookmark ongoing conversation
  int get doubleTapAction => getInt('doubleTapAction');

  set doubleTapAction(int value) => saveInt('doubleTapAction', value);

  // Keep backward compatibility
  bool get doubleTapPausesMuting => doubleTapAction == 1;

  set doubleTapPausesMuting(bool value) => doubleTapAction = value ? 1 : 0;

  // Last known battery level — restored on connect so the indicator isn't grey
  // until the first BLE notification fires.
  int get lastBatteryLevel => getInt('lastBatteryLevel', defaultValue: -1);

  set lastBatteryLevel(int value) => saveInt('lastBatteryLevel', value);

  // Developer Diagnostics
  bool get devLogsToFileEnabled => getBool('devLogsToFileEnabled');

  set devLogsToFileEnabled(bool value) => saveBool('devLogsToFileEnabled', value);

  //--------------------------- Setters & Getters -----------------------------//

  String getString(String key, {String defaultValue = ''}) => _preferences?.getString(key) ?? defaultValue;

  int getInt(String key, {int defaultValue = 0}) => _preferences?.getInt(key) ?? defaultValue;

  bool getBool(String key, {bool defaultValue = false}) => _preferences?.getBool(key) ?? defaultValue;

  double getDouble(String key, {double defaultValue = 0.0}) {
    final value = _preferences?.get(key);
    return (value is num) ? value.toDouble() : defaultValue;
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
