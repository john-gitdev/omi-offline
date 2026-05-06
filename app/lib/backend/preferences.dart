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

  String _omiRefreshToken = '';
  String _omiFirebaseApiKey = '';

  String get deviceIdHash => _preferences?.getString('deviceIdHash') ?? '';
  set deviceIdHash(String value) => _preferences?.setString('deviceIdHash', value);

  //--------------------------- Offline Audio Processing ---------------------//

  bool get forceSyncSkipConfirm => getBool('force_sync_skip_confirm', defaultValue: false);
  set forceSyncSkipConfirm(bool value) => saveBool('force_sync_skip_confirm', value);

  // When enabled, raw .bin segments are preserved after processing so days can
  // be reprocessed with different VAD settings via the Reprocess Day button.
  bool get adjustmentMode => getBool('adjustmentMode', defaultValue: false);
  set adjustmentMode(bool value) => saveBool('adjustmentMode', value);

  // When true, uploads to integrations are permitted even when adjustmentMode is ON.
  // This is a debug setting; normally uploads are paused during adjustment.
  bool get allowUploadDuringAdjustment => getBool('allowUploadDuringAdjustment', defaultValue: false);
  set allowUploadDuringAdjustment(bool value) => saveBool('allowUploadDuringAdjustment', value);

  // Set to true the first time adjustment mode is turned ON; cleared only after
  // the cleanup banner's "Process & Delete" completes. Used to suppress the
  // cleanup banner when adjustment mode has never been enabled.
  bool get adjustmentModeWasEnabled => getBool('adjustmentModeWasEnabled', defaultValue: false);
  set adjustmentModeWasEnabled(bool value) => saveBool('adjustmentModeWasEnabled', value);

  // When true, Silero VAD classifies each audio frame as speech or silence.
  // When false, all audio is treated as speech (AAD mode — splits by firmware timestamps only).
  bool get vadEnabled => getBool('vadEnabled', defaultValue: true);
  set vadEnabled(bool v) => saveBool('vadEnabled', v);

  // Silero VAD speech probability cutoff (0.0–1.0). Frames with probability
  // above this value are classified as speech.
  double get vadSpeechThreshold => getDouble('vadSpeechThreshold', defaultValue: 0.5);
  set vadSpeechThreshold(double v) => saveDouble('vadSpeechThreshold', v);

  // Continuous silence duration (seconds) that triggers a conversation cut.
  int get vadSplitSeconds => getInt('vadSplitSeconds', defaultValue: 120);
  set vadSplitSeconds(int v) => saveInt('vadSplitSeconds', v);

  // Minimum wall-clock duration (seconds) threshold for short-recording handling.
  // What happens to recordings below this is controlled by discardShortRecordings.
  // 0 = no filtering.
  int get filterMinDurationSeconds => getInt('filterMinDurationSeconds', defaultValue: 0);
  set filterMinDurationSeconds(int v) => saveInt('filterMinDurationSeconds', v);

  // Minimum detected speech duration (seconds) required to save a recording.
  // Options: 0 (off), 3, 10, 30.
  int get vadMinSpeechSeconds => getInt('vadMinSpeechSeconds', defaultValue: 3);
  set vadMinSpeechSeconds(int v) => saveInt('vadMinSpeechSeconds', v);

  // When true, recordings shorter than filterMinDurationSeconds are permanently
  // discarded during processing. When false, they are saved but hidden from the
  // list and skipped by integrations.
  bool get discardShortRecordings => getBool('discardShortRecordings', defaultValue: false);
  set discardShortRecordings(bool v) => saveBool('discardShortRecordings', v);

  // Maximum continuous conversation length (minutes) before forcing a cut.
  int get vadMaxConversationMinutes => getInt('vadMaxConversationMinutes', defaultValue: 60);
  set vadMaxConversationMinutes(int v) => saveInt('vadMaxConversationMinutes', v);

  // The format to save processed audio files. Options: 'm4a', 'ogg', 'wav'.
  String get audioSaveFormat {
    if (_preferences?.containsKey('convertOpusToM4a') == true) {
      final isM4a = getBool('convertOpusToM4a', defaultValue: false);
      remove('convertOpusToM4a');
      final format = isM4a ? 'm4a' : 'ogg';
      saveString('audioSaveFormat', format);
      return format;
    }
    return getString('audioSaveFormat', defaultValue: 'm4a');
  }

  set audioSaveFormat(String value) => saveString('audioSaveFormat', value);

  int get backgroundSyncIntervalMinutes => getInt('backgroundSyncIntervalMinutes', defaultValue: 30);
  set backgroundSyncIntervalMinutes(int v) => saveInt('backgroundSyncIntervalMinutes', v);

  // Whether to disconnect bluetooth after a sync to maximize battery.
  bool get maximizeBattery => getBool('maximizeBattery', defaultValue: false);
  set maximizeBattery(bool v) => saveBool('maximizeBattery', v);

  // Whether to display times in 24-hour format (true) or 12-hour AM/PM (false).
  bool get use24HourTime => getBool('use24HourTime', defaultValue: false);
  set use24HourTime(bool value) => saveBool('use24HourTime', value);

  // True while extraction/processing is in progress. Persisted so that on
  // restart after a crash we can detect incomplete processing and clean up
  // the temp directory to avoid duplicate recordings.
  bool get extractionInProgress => getBool('extractionInProgress', defaultValue: false);

  set extractionInProgress(bool value) => saveBool('extractionInProgress', value);

  // How long to keep recordings locally before they are auto-deleted.
  // -1: Never (Always keep)
  //  0: Immediately (Passthrough Mode)
  //  3: 3 days
  //  7: 7 days
  int get keepRecordingsDays => getInt('keepRecordingsDays', defaultValue: -1);
  set keepRecordingsDays(int v) => saveInt('keepRecordingsDays', v);

  // When enabled, recordings are uploaded to integrations immediately and the
  // local audio file is deleted after a successful upload. Only the metadata
  // sidecar (.meta) is kept so the conversation still appears in the list.
  bool get passthroughMode => keepRecordingsDays == 0;
  set passthroughMode(bool v) => keepRecordingsDays = v ? 0 : -1;

  //--------------------------- Omi Server Sync --------------------------//

  // Whether the Omi integration is active (controls bin generation, upload button, passthrough gating).
  bool get omiEnabled => getBool('omiSyncEnabled', defaultValue: false);
  set omiEnabled(bool v) => saveBool('omiSyncEnabled', v);

  // Whether recordings are automatically uploaded after processing. Requires omiEnabled.
  bool get omiAutoUpload => getBool('omiAutoUpload', defaultValue: true);
  set omiAutoUpload(bool v) => saveBool('omiAutoUpload', v);

  // Short-lived JWT — refreshed automatically; stored in regular prefs.
  String get omiIdToken => getString('omiIdToken', defaultValue: '');
  set omiIdToken(String v) => saveString('omiIdToken', v);

  // Unix ms when the current ID token expires.
  int get omiTokenExpiry => getInt('omiTokenExpiry', defaultValue: 0);
  set omiTokenExpiry(int v) => saveInt('omiTokenExpiry', v);

  // Long-lived refresh token — stored in secure storage.
  String get omiRefreshToken => _omiRefreshToken;
  Future<void> setOmiRefreshToken(String v) async {
    _omiRefreshToken = v;
    await _secureStorage.write(key: 'omiRefreshToken', value: v);
  }

  // Firebase API key — stored in secure storage.
  String get omiFirebaseApiKey => _omiFirebaseApiKey;
  Future<void> setOmiFirebaseApiKey(String v) async {
    _omiFirebaseApiKey = v;
    await _secureStorage.write(key: 'omiFirebaseApiKey', value: v);
  }

  List<String> get omiSyncedFiles => getStringList('omiSyncedFiles');

  bool isOmiSynced(String binPath) => omiSyncedFiles.contains(binPath);

  Future<void> markOmiSynced(String binPath) async {
    if (isOmiSynced(binPath)) return;
    final updated = {...omiSyncedFiles}..add(binPath);
    await saveStringList('omiSyncedFiles', updated.toList());
  }

  Future<void> clearOmiSyncedFiles() async => saveStringList('omiSyncedFiles', []);

  Future<void> removeOmiSynced(Iterable<String> binPaths) async {
    final paths = binPaths.toSet();
    if (paths.isEmpty) return;
    final current = omiSyncedFiles;
    final pruned = current.where((p) => !paths.contains(p)).toList();
    if (pruned.length != current.length) {
      await saveStringList('omiSyncedFiles', pruned);
    }
  }

  //--------------------------- HeyPocket Integration ---------------------//

  String get heypocketApiKey => _heypocketApiKey;
  Future<void> setHeypocketApiKey(String v) async {
    _heypocketApiKey = v;
    await _secureStorage.write(key: 'heypocketApiKey', value: v);
  }

  bool get heypocketEnabled => getBool('heypocketEnabled', defaultValue: false);
  set heypocketEnabled(bool v) => saveBool('heypocketEnabled', v);

  // Whether recordings are automatically uploaded after processing. Requires heypocketEnabled.
  bool get heypocketAutoUpload => getBool('heypocketAutoUpload', defaultValue: true);
  set heypocketAutoUpload(bool v) => saveBool('heypocketAutoUpload', v);

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

  /// Removes [keys] from the uploaded-files list. Serialized through the same
  /// guard as [markUploadedToHeypocket] to avoid lost-update races.
  Future<void> removeUploadedFromHeypocket(Set<String> keys) async {
    if (keys.isEmpty) return;
    while (_heypocketUploadGuard != null) {
      await _heypocketUploadGuard;
    }
    final completer = Completer<void>();
    _heypocketUploadGuard = completer.future;
    try {
      final current = heypocketUploadedFiles;
      final pruned = current.where((k) => !keys.contains(k)).toList();
      if (pruned.length != current.length) {
        await saveStringList('heypocketUploadedFiles', pruned);
      }
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
    _instance._omiRefreshToken = await _secureStorage.read(key: 'omiRefreshToken') ?? '';
    _instance._omiFirebaseApiKey = await _secureStorage.read(key: 'omiFirebaseApiKey') ?? '';
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
