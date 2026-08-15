import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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

  bool get sileroVadSkipConfirm => getBool('silero_vad_skip_confirm', defaultValue: false);
  set sileroVadSkipConfirm(bool value) => saveBool('silero_vad_skip_confirm', value);

  // Manual recording mode: recording is started/stopped by device double-tap.
  // When true, Silero VAD is off and the device AAD threshold is toggled between 0 and 32768.
  // Can only be toggled while the device is connected so the BLE write always lands.
  bool get manualMode => getBool('manualMode', defaultValue: true);
  set manualMode(bool v) => saveBool('manualMode', v);

  // UI-visibility only: whether red "Priority Recording" markers
  // show in the timeline. Read in the main isolate; the VAD processor always
  // emits the marker with isHighPriority=true regardless.
  bool get showHighPriorityMarker => getBool('showHighPriorityMarker', defaultValue: true);
  set showHighPriorityMarker(bool v) => saveBool('showHighPriorityMarker', v);

  // UI-visibility only: whether "ghost" rows (VAD-dropped / muted stretches, the
  // discards.jsonl entries) show in the conversations list. Hiding them only
  // suppresses the rows — the underlying discard records stay on disk and remain
  // recoverable once shown again.
  bool get hideGhosts => getBool('hideGhosts', defaultValue: false);
  set hideGhosts(bool v) => saveBool('hideGhosts', v);

  // Per-mode button-action configs (6 slots: single / single-hold / double /
  // double-hold / triple / triple-hold; values are button_action_t indices
  // 0=None,1=Mute,2=Marker,3=Toggle LED,4=Record Start,5=Record Stop). The app
  // owns both and pushes the active mode's config to the firmware on connect and
  // on mode switch (the firmware keeps a single active slot). Mute is a no-op in
  // manual mode, so the manual default omits it.
  // Marker stays mapped in manual (single-tap-hold): it is live during a manual
  // recording, where bookmarking a moment inside a long capture is exactly the
  // point. It is inert only in manual STANDBY, where there is nothing to bookmark.
  static const List<int> defaultButtonConfigManual = [0, 2, 4, 3, 5, 0];
  static const List<int> defaultButtonConfigAuto = [0, 4, 2, 1, 3, 5];

  List<int> get buttonConfigManual => _getButtonConfig('buttonConfigManual', defaultButtonConfigManual);
  set buttonConfigManual(List<int> v) => saveStringList('buttonConfigManual', v.map((e) => e.toString()).toList());

  List<int> get buttonConfigAuto => _getButtonConfig('buttonConfigAuto', defaultButtonConfigAuto);
  set buttonConfigAuto(List<int> v) => saveStringList('buttonConfigAuto', v.map((e) => e.toString()).toList());

  // The config for the device's current mode (the one that should be live on the
  // firmware right now).
  List<int> get activeButtonConfig => manualMode ? buttonConfigManual : buttonConfigAuto;

  // Whether the two split recording actions (Record Start = 4 / Record Stop = 5)
  // are collapsed into a single Record Toggle action (6) in the button mapping.
  // App-only preference, one global switch for both mode configs. Default false =
  // separate Start/Stop, matching existing behaviour with zero migration.
  bool get combineRecordButton => getBool('combineRecordButton', defaultValue: false);
  set combineRecordButton(bool v) => saveBool('combineRecordButton', v);

  // On-device diagnostic event log (dev tool). Default off; the app pushes this to
  // the firmware's runtime gate (0x0064) on connect and drains the ring (0x0063)
  // when on. Not persisted on-device, so a rebooted device stays silent until the
  // app re-enables. See diag_log_record.dart.
  bool get diagLogEnabled => getBool('diagLogEnabled', defaultValue: false);
  set diagLogEnabled(bool v) => saveBool('diagLogEnabled', v);

  /// Make a 6-slot button config valid for the given recording-button style,
  /// so the firmware and the picker only ever see in-range actions. Idempotent,
  /// and the same rule serves both the switch-flip and the migration/defensive
  /// paths (normalize-to-a-mode == remap-on-flip-into-that-mode):
  /// - combine ON (single Toggle): Start(4) → Toggle(6) — preserve the gesture;
  ///   Stop(5) → None(0) — redundant once a Toggle exists.
  /// - combine OFF (split Start/Stop): Toggle(6) → None(0) — one gesture can't
  ///   auto-split into two placed gestures, so blank it and let the user assign
  ///   Start + Stop deliberately (never auto-creates a Start-without-Stop).
  static List<int> normalizeButtonConfigForCombine(List<int> cfg, bool combine) {
    return cfg.map((v) {
      if (combine) {
        if (v == 4) return 6;
        if (v == 5) return 0;
      } else {
        if (v == 6) return 0;
      }
      return v;
    }).toList();
  }

  // One-time migration guard: when first upgrading to per-mode configs, the
  // device's existing single config is preserved into the auto slot.
  bool get buttonConfigMigrated => getBool('buttonConfigMigrated', defaultValue: false);
  set buttonConfigMigrated(bool v) => saveBool('buttonConfigMigrated', v);

  List<int> _getButtonConfig(String key, List<int> fallback) {
    final raw = getStringList(key);
    if (raw.length != 6) return List<int>.from(fallback);
    return raw.map((e) => int.tryParse(e) ?? 0).toList();
  }

  /// One-time per-mode-config migration decision: should the device's existing
  /// single button config be preserved into the auto slot? Yes for a valid
  /// customized / old-firmware config; no for a factory-fresh new-firmware device
  /// (its config already equals the new manual default), which should keep the
  /// proper auto default instead.
  static bool shouldPreserveExistingButtonConfig(List<int>? existing) =>
      existing != null && existing.length == 6 && !listEquals(existing, defaultButtonConfigManual);

  bool get adjustmentMode => getBool('adjustmentMode', defaultValue: false);
  set adjustmentMode(bool v) => saveBool('adjustmentMode', v);

  // Epoch ms when Adjustment Mode was last toggled on (0 = never / off).
  int get adjustmentModeEnabledAt => getInt('adjustmentModeEnabledAt', defaultValue: 0);
  set adjustmentModeEnabledAt(int v) => saveInt('adjustmentModeEnabledAt', v);

  int get autoVadThreshold => getInt('autoVadThreshold', defaultValue: 250);
  set autoVadThreshold(int v) => saveInt('autoVadThreshold', v);

  // Auto-mode Priority Recording safety cap, in minutes (0 = no cap). Default 2 h.
  int get priorityRecordMaxMinutes => getInt('priorityRecordMaxMinutes', defaultValue: 120);
  set priorityRecordMaxMinutes(int v) => saveInt('priorityRecordMaxMinutes', v);

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
  // 0 = no filtering.
  int get filterMinDurationSeconds => getInt('filterMinDurationSeconds', defaultValue: 0);
  set filterMinDurationSeconds(int v) => saveInt('filterMinDurationSeconds', v);

  // Minimum detected speech duration (seconds) required to save a recording.
  // Options: 0 (off), 3, 10, 30.
  int get vadMinSpeechSeconds => getInt('vadMinSpeechSeconds', defaultValue: 3);
  set vadMinSpeechSeconds(int v) => saveInt('vadMinSpeechSeconds', v);

  // Maximum continuous conversation length (minutes) before forcing a cut.
  int get vadMaxConversationMinutes => getInt('vadMaxConversationMinutes', defaultValue: 60);
  set vadMaxConversationMinutes(int v) => saveInt('vadMaxConversationMinutes', v);

  // Per-mode recording settings snapshots. Default to the active pref so existing
  // users see their current settings the first time they open each mode.
  bool get autoModeVadEnabled => getBool('auto_vadEnabled', defaultValue: false);
  set autoModeVadEnabled(bool v) => saveBool('auto_vadEnabled', v);
  double get autoModeVadSpeechThreshold => getDouble('auto_vadSpeechThreshold', defaultValue: 0.5);
  set autoModeVadSpeechThreshold(double v) => saveDouble('auto_vadSpeechThreshold', v);
  int get autoModeVadMinSpeechSeconds => getInt('auto_vadMinSpeechSeconds', defaultValue: 3);
  set autoModeVadMinSpeechSeconds(int v) => saveInt('auto_vadMinSpeechSeconds', v);
  int get autoModeVadSplitSeconds => getInt('auto_vadSplitSeconds', defaultValue: 120);
  set autoModeVadSplitSeconds(int v) => saveInt('auto_vadSplitSeconds', v);
  int get autoModeVadMaxConversationMinutes => getInt('auto_vadMaxConversationMinutes', defaultValue: 0);
  set autoModeVadMaxConversationMinutes(int v) => saveInt('auto_vadMaxConversationMinutes', v);

  // Manual mode pins VAD off, no speech/duration filtering, no short-recording
  // discard, and uses the session-end marker as the conversation boundary, so
  // those knobs aren't user-tunable and don't need per-mode snapshots. The cap
  // below is the one user-editable manual-mode setting.
  int get manualModeVadMaxConversationMinutes => getInt('manual_vadMaxConversationMinutes', defaultValue: 0);
  set manualModeVadMaxConversationMinutes(int v) => saveInt('manual_vadMaxConversationMinutes', v);

  // ---------------------------------------------------------------------------
  // Recording-mode switch history
  //
  // A recording mode is a property of the audio, not of the toggle: flipping the
  // mode rewrites the live VAD prefs, and the processor reads those at run time,
  // so a backlog recorded under one mode was being re-cut under the other's
  // rules. Both directions are wrong in their own way — manual's pinned
  // vadSplitSeconds=0 chops auto audio at every bin boundary and AAD wake, and
  // auto's Silero + minSpeech filter can discard a deliberate manual capture as
  // noise.
  //
  // So every switch appends {at, outgoing settings} here, and the processing run
  // cuts each bin with the settings that were live when it was recorded. A LIST,
  // not a single previous-mode snapshot: flip twice before the backlog drains and
  // the audio has two boundaries in it, each needing its own settings. Entries
  // retire from the front once no bin on disk predates them. JSON array; '' =
  // no switch pending, which is the steady state. See [ModeSwitchRecord] and
  // RecordingsController._drainModeSwitchBacklog.
  String get processingModeSwitchHistory => getString('processingModeSwitchHistory');
  set processingModeSwitchHistory(String v) => saveString('processingModeSwitchHistory', v);

  // Whether the user has ever chosen a recording mode themselves, as opposed to
  // running on the default. A fresh install has `manualMode` true because that is
  // the default, not because anyone asked for it — so an Omi in auto is not a
  // disagreement worth reporting until this is set. Written only by
  // DeviceProvider.setManualMode.
  //
  // Deliberately NOT migrated for installs that predate it. Someone who chose
  // manual before this existed reads as `false`, and cannot be told apart from
  // someone who never chose: `manualMode` is true either way, being the default.
  // Both possible seeds guess wrong half the time, and the only cost of guessing
  // low is a missing mismatch banner on a replacement Omi — which self-corrects
  // the first time the mode is changed. Don't add a migration.
  bool get manualModeUserSet => getBool('manualModeUserSet', defaultValue: false);
  set manualModeUserSet(bool v) => saveBool('manualModeUserSet', v);

  /// Writes the flat processing prefs that a recording mode implies.
  ///
  /// `manualMode` is only the label; the processor reads the flat vad* prefs. The
  /// two must never disagree — an auto label over manual's `vadSplitSeconds = 0`
  /// is the 2026-08-14 configuration. The settings page keeps them in step when
  /// the user switches; this keeps them in step when the app adopts a mode from
  /// the device instead.
  ///
  /// Manual's values are fixed by design (VAD off, no filtering — the firmware's
  /// session-end marker is the boundary). Auto's come from its own snapshot, so a
  /// round trip through manual and back restores what the user had.
  void applyRecordingModeDefaults(bool manual) {
    if (manual) {
      vadEnabled = false;
      vadSpeechThreshold = 0.5;
      vadMinSpeechSeconds = 0;
      vadSplitSeconds = 0;
      vadMaxConversationMinutes = manualModeVadMaxConversationMinutes;
    } else {
      vadEnabled = autoModeVadEnabled;
      vadSpeechThreshold = autoModeVadSpeechThreshold;
      vadMinSpeechSeconds = autoModeVadMinSpeechSeconds;
      vadSplitSeconds = autoModeVadSplitSeconds;
      vadMaxConversationMinutes = autoModeVadMaxConversationMinutes;
    }
  }

  // The format to save processed audio files. Options: 'm4a', 'wav'.
  // OGG support was removed entirely; any stored 'ogg' value (from the legacy
  // convertOpusToM4a migration or a previously-chosen setting) is coerced to
  // 'wav' so the settings dropdown and save path never see an unknown format.
  String get audioSaveFormat {
    if (_preferences?.containsKey('convertOpusToM4a') == true) {
      final isM4a = getBool('convertOpusToM4a', defaultValue: false);
      remove('convertOpusToM4a');
      final format = isM4a ? 'm4a' : 'wav';
      saveString('audioSaveFormat', format);
      return format;
    }
    final format = getString('audioSaveFormat', defaultValue: 'wav');
    if (format == 'ogg') {
      saveString('audioSaveFormat', 'wav');
      return 'wav';
    }
    return format;
  }

  set audioSaveFormat(String value) => saveString('audioSaveFormat', value);

  int get backgroundSyncIntervalMinutes => getInt('backgroundSyncIntervalMinutes', defaultValue: 30);
  set backgroundSyncIntervalMinutes(int v) => saveInt('backgroundSyncIntervalMinutes', v);

  // Whether to display times in 24-hour format (true) or 12-hour AM/PM (false).
  bool get use24HourTime => getBool('use24HourTime', defaultValue: false);
  set use24HourTime(bool value) => saveBool('use24HourTime', value);

  // Whether the "Debug Tools" entry is shown in the settings drawer. Default off,
  // so debug tooling is hidden until explicitly enabled in App Settings.
  bool get showDebugMenu => getBool('showDebugMenu', defaultValue: false);
  set showDebugMenu(bool value) => saveBool('showDebugMenu', value);

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

  // True iff the most recent processing run that WANTED Silero VAD (vadEnabled)
  // had to fall back to firmware AAD because the model failed to load. AAD marks
  // every frame as speech (no on-phone silence split), so a silent fallback can
  // spray hundreds of 1-frame junk recordings. The processing isolate sets this
  // each VAD run (true on fallback, false once Silero loads again); the UI shows
  // a banner while it's true. Runs that don't want VAD (manual mode) leave it
  // untouched.
  bool get lastVadFallbackActive => getBool('lastVadFallbackActive', defaultValue: false);
  set lastVadFallbackActive(bool v) => saveBool('lastVadFallbackActive', v);

  // When enabled, recordings are uploaded to integrations immediately and the
  // local audio file is deleted after a successful upload. Only the metadata
  // sidecar (.meta) is kept so the conversation still appears in the list.
  bool get passthroughMode => keepRecordingsDays == 0;
  set passthroughMode(bool v) => keepRecordingsDays = v ? 0 : -1;

  // When enabled, uploads to integrations are restricted to WiFi connections only.
  bool get uploadOnWifiOnly => getBool('uploadOnWifiOnly', defaultValue: false);
  set uploadOnWifiOnly(bool v) => saveBool('uploadOnWifiOnly', v);

  //--------------------------- Omi Server Sync --------------------------//

  // Whether the Omi integration is active (controls bin generation, upload button, passthrough gating).
  bool get omiEnabled => getBool('omiSyncEnabled', defaultValue: false);
  set omiEnabled(bool v) => saveBool('omiSyncEnabled', v);

  // Whether recordings are automatically uploaded after processing. Requires omiEnabled.
  bool get omiAutoUpload => getBool('omiAutoUpload', defaultValue: false);
  set omiAutoUpload(bool v) {
    saveBool('omiAutoUpload', v);
    if (v) omiAutoUploadAt = DateTime.now().millisecondsSinceEpoch;
  }

  // Epoch ms when auto-upload was last enabled — used to limit auto-upload to new recordings only.
  int get omiAutoUploadAt => getInt('omiAutoUploadAt', defaultValue: 0);
  set omiAutoUploadAt(int v) => saveInt('omiAutoUploadAt', v);

  // Short-lived JWT — refreshed automatically; stored in regular prefs.
  // omiIdToken is stored in secure storage as it is a sensitive credential.
  Future<String> get omiIdToken async => await _secureStorage.read(key: 'omiIdToken') ?? '';
  Future<void> setOmiIdToken(String v) async => await _secureStorage.write(key: 'omiIdToken', value: v);

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

  Future<void> clearOmiSyncedFiles() async {
    await saveStringList('omiSyncedFiles', []);
    await saveStringList('omiSyncedSegments', []);
    await saveStringList('omiSegmentTotals', []);
    await saveStringList('omiSegmentJobs', []);
  }

  Future<void> removeOmiSynced(Iterable<String> binPaths) async {
    final paths = binPaths.toSet();
    if (paths.isEmpty) return;
    final current = omiSyncedFiles;
    final pruned = current.where((p) => !paths.contains(p)).toList();
    if (pruned.length != current.length) {
      await saveStringList('omiSyncedFiles', pruned);
    }
    for (final p in paths) {
      await clearOmiSegments(p);
    }
  }

  // Per-segment delivery markers for an Omi Cloud upload, keyed '<binPath>#<index>'.
  // A recording's bin is uploaded one 5-min segment at a time; recording each
  // delivered segment lets a retry after a partial failure resume from the first
  // undelivered segment instead of re-sending the whole recording. Pruned by
  // [clearOmiSegments] once the whole bin is marked synced.
  List<String> get omiSyncedSegments => getStringList('omiSyncedSegments');

  bool isOmiSegmentSynced(String segmentKey) => omiSyncedSegments.contains(segmentKey);

  Future<void> markOmiSegmentSynced(String segmentKey) async {
    if (isOmiSegmentSynced(segmentKey)) return;
    final updated = {...omiSyncedSegments}..add(segmentKey);
    await saveStringList('omiSyncedSegments', updated.toList());
  }

  /// How many of [binPath]'s segments have been delivered (keys '<binPath>#<i>').
  int omiSyncedSegmentCount(String binPath) {
    final prefix = '$binPath#';
    return omiSyncedSegments.where((k) => k.startsWith(prefix)).length;
  }

  // Total segment count for an Omi upload, recorded when the upload is first
  // built, so the UI can show "delivered/total chunks" — including after a
  // partial failure where only some chunks made it. Entry form '<binPath>\t<n>'.
  // Pruned by [clearOmiSegments] once the whole bin is synced so progress for a
  // completed recording doesn't linger.
  List<String> get _omiSegmentTotals => getStringList('omiSegmentTotals');

  int getOmiSegmentTotal(String binPath) {
    final prefix = '$binPath\t';
    for (final e in _omiSegmentTotals) {
      if (e.startsWith(prefix)) return int.tryParse(e.substring(prefix.length)) ?? 0;
    }
    return 0;
  }

  Future<void> setOmiSegmentTotal(String binPath, int count) async {
    final prefix = '$binPath\t';
    final updated = _omiSegmentTotals.where((e) => !e.startsWith(prefix)).toList()..add('$prefix$count');
    await saveStringList('omiSegmentTotals', updated);
  }

  // Outstanding server job id per chunk, keyed '<binPath>#<index>\t<jobId>'. A
  // chunk whose job is still queued/processing (or whose poll budget elapsed) is
  // recorded here so the next upload attempt reattaches (polls) the same job
  // instead of re-uploading and enqueuing a duplicate. Cleared once the chunk
  // completes or fails, and pruned with the rest of a bin's segments by
  // [clearOmiSegments].
  List<String> get _omiSegmentJobs => getStringList('omiSegmentJobs');

  String? getOmiSegmentJobId(String segmentKey) {
    final prefix = '$segmentKey\t';
    for (final e in _omiSegmentJobs) {
      if (e.startsWith(prefix)) return e.substring(prefix.length);
    }
    return null;
  }

  Future<void> setOmiSegmentJobId(String segmentKey, String jobId) async {
    final prefix = '$segmentKey\t';
    final updated = _omiSegmentJobs.where((e) => !e.startsWith(prefix)).toList()..add('$prefix$jobId');
    await saveStringList('omiSegmentJobs', updated);
  }

  Future<void> clearOmiSegmentJobId(String segmentKey) async {
    final prefix = '$segmentKey\t';
    final current = _omiSegmentJobs;
    final pruned = current.where((e) => !e.startsWith(prefix)).toList();
    if (pruned.length != current.length) {
      await saveStringList('omiSegmentJobs', pruned);
    }
  }

  // Epoch millis before which auto-upload should not re-attempt [binPath], set
  // when the server reports it's busy (a 503/502/504), so a struggling backend
  // isn't hammered. 0 = no backoff. Cleared on full sync by [clearOmiSegments].
  int getOmiBackoffUntil(String binPath) => getInt('omiBackoffUntil_$binPath', defaultValue: 0);

  Future<void> setOmiBackoffUntil(String binPath, int epochMs) async {
    await saveInt('omiBackoffUntil_$binPath', epochMs);
  }

  // Consecutive server-busy count for [binPath], driving the exponential backoff
  // window (see OmiPassthroughIntegration). Reset to 0 once a chunk is accepted
  // (backend healthy again) and cleared on full sync by [clearOmiSegments].
  int getOmiBusyStreak(String binPath) => getInt('omiBusyStreak_$binPath', defaultValue: 0);

  Future<void> incrementOmiBusyStreak(String binPath) async {
    await saveInt('omiBusyStreak_$binPath', getOmiBusyStreak(binPath) + 1);
  }

  Future<void> clearOmiBusyStreak(String binPath) async {
    await remove('omiBusyStreak_$binPath');
  }

  Future<void> clearOmiSegments(String binPath) async {
    final prefix = '$binPath#';
    final current = omiSyncedSegments;
    final pruned = current.where((k) => !k.startsWith(prefix)).toList();
    if (pruned.length != current.length) {
      await saveStringList('omiSyncedSegments', pruned);
    }
    final tPrefix = '$binPath\t';
    final totals = _omiSegmentTotals;
    final tPruned = totals.where((e) => !e.startsWith(tPrefix)).toList();
    if (tPruned.length != totals.length) {
      await saveStringList('omiSegmentTotals', tPruned);
    }
    // Job-id entries are keyed '<binPath>#<index>\t…', so the '<binPath>#' prefix
    // prunes them too.
    final jobs = _omiSegmentJobs;
    final jPruned = jobs.where((e) => !e.startsWith(prefix)).toList();
    if (jPruned.length != jobs.length) {
      await saveStringList('omiSegmentJobs', jPruned);
    }
    await remove('omiBackoffUntil_$binPath');
    await remove('omiBusyStreak_$binPath');
  }

  /// Last-seen "firmware identity" for a device — its DIS firmware revision plus
  /// capability bitfield. Changing it is the signal that the device's GATT layout
  /// may have moved, so Android's cached attribute database has to be dropped
  /// (see DeviceProvider._shouldRefreshGattCache). Per-device, since a phone can
  /// be bonded to more than one Omi. Empty = never seen.
  String gattFingerprint(String deviceId) => getString('gattFingerprint_$deviceId');

  /// Awaitable so the caller can be sure the record landed before the link it
  /// describes is torn down.
  Future<void> setGattFingerprint(String deviceId, String value) async =>
      await saveString('gattFingerprint_$deviceId', value);

  // Firebase user UID and email — stored in plain SharedPreferences (non-sensitive identifiers).
  String get omiAuthUid => getString('omiAuthUid');
  set omiAuthUid(String v) => saveString('omiAuthUid', v);

  String get omiAuthEmail => getString('omiAuthEmail');
  set omiAuthEmail(String v) => saveString('omiAuthEmail', v);

  // Whether the last login used the fallback WebView flow (shows raw token fields).
  bool get omiConnectedViaFallback => getBool('omiConnectedViaFallback', defaultValue: false);
  set omiConnectedViaFallback(bool v) => saveBool('omiConnectedViaFallback', v);

  bool get omiHasSpeechProfile => getBool('omiHasSpeechProfile', defaultValue: false);
  set omiHasSpeechProfile(bool v) => saveBool('omiHasSpeechProfile', v);

  int get omiSpeechProfileCheckedAtMs => getInt('omiSpeechProfileCheckedAtMs', defaultValue: 0);
  set omiSpeechProfileCheckedAtMs(int v) => saveInt('omiSpeechProfileCheckedAtMs', v);

  //--------------------------- HeyPocket Integration ---------------------//

  String get heypocketApiKey => _heypocketApiKey;
  Future<void> setHeypocketApiKey(String v) async {
    _heypocketApiKey = v;
    await _secureStorage.write(key: 'heypocketApiKey', value: v);
  }

  bool get heypocketEnabled => getBool('heypocketEnabled', defaultValue: false);
  set heypocketEnabled(bool v) => saveBool('heypocketEnabled', v);

  // Whether recordings are automatically uploaded after processing. Requires heypocketEnabled.
  bool get heypocketAutoUpload => getBool('heypocketAutoUpload', defaultValue: false);
  set heypocketAutoUpload(bool v) {
    saveBool('heypocketAutoUpload', v);
    if (v) heypocketKeySetAt = DateTime.now().millisecondsSinceEpoch;
  }

  List<String> get heypocketUploadedFiles => getStringList('heypocketUploadedFiles');
  set heypocketUploadedFiles(List<String> v) => saveStringList('heypocketUploadedFiles', v);

  // Epoch ms when Auto-Upload was last enabled (set only by the heypocketAutoUpload
  // setter, not on key save) — limits auto-upload to recordings made after it. 0 =
  // never enabled; auto-upload fails closed in that case (see HeyPocket.isEnabled).
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

  int getAutoUploadRetries(String key) => getInt('autoUploadRetry_$key', defaultValue: 0);

  Future<void> incrementAutoUploadRetry(String key) async {
    final current = getAutoUploadRetries(key);
    await saveInt('autoUploadRetry_$key', current + 1);
  }

  /// Epoch millis of the most recent failed upload attempt for [key], or 0 if
  /// none recorded. Surfaced as the "Last Upload Failed at" label.
  int getAutoUploadLastFailureAt(String key) => getInt('autoUploadFailAt_$key', defaultValue: 0);

  Future<void> setAutoUploadLastFailureAt(String key) async {
    await saveInt('autoUploadFailAt_$key', DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> clearAutoUploadRetry(String key) async {
    await remove('autoUploadRetry_$key');
    await remove('autoUploadFailAt_$key');
  }

  /// Removes the Debug Tools diagnostics baselines left behind from when each key was
  /// suffixed with a device id. Only one Omi is ever paired, so the keys are plain now
  /// and any suffixed ones are unreachable. The plain keys have no trailing underscore,
  /// so they can't match these prefixes.
  Future<void> clearLegacyPerDeviceBaselines() async {
    final keys = (_preferences?.getKeys() ?? {})
        .where(
          (k) =>
              k.startsWith('drop_baseline_json_') ||
              k.startsWith('conn_fail_baseline_') ||
              k.startsWith('estab_fail_baseline_'),
        )
        .toList();
    for (final key in keys) {
      await _preferences?.remove(key);
    }
  }

  Future<void> clearAllAutoUploadRetries() async {
    final keys = (_preferences?.getKeys() ?? {})
        .where((k) => k.startsWith('autoUploadRetry_') || k.startsWith('autoUploadFailAt_'))
        .toList();
    for (final key in keys) {
      await _preferences?.remove(key);
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

  // Timestamp of the last sync that actually moved data (success/partial). Used by the
  // auto-sync interval gate to decide when the next cycle is due — NOT stamped on a skip.
  int get lastSyncCompletedMs => getInt('lastSyncCompletedMs', defaultValue: 0);

  set lastSyncCompletedMs(int v) => saveInt('lastSyncCompletedMs', v);

  // Timestamp of the last sync *outcome* of any kind (success, partial, or skip). This is
  // what the notification displays next to its status, so a skip shows its own time rather
  // than borrowing a stale completion timestamp. Falls back to the completion timestamp so
  // users upgrading mid-cycle don't briefly lose their "Last Sync" line.
  int get lastSyncStatusMs => getInt('lastSyncStatusMs', defaultValue: lastSyncCompletedMs);

  set lastSyncStatusMs(int v) => saveInt('lastSyncStatusMs', v);

  bool get lastSyncPartial => getBool('lastSyncPartial', defaultValue: false);

  set lastSyncPartial(bool v) => saveBool('lastSyncPartial', v);

  bool get lastSyncSkipped => getBool('lastSyncSkipped', defaultValue: false);

  set lastSyncSkipped(bool v) => saveBool('lastSyncSkipped', v);

  // Developer Diagnostics
  bool get devLogsToFileEnabled => getBool('devLogsToFileEnabled');
  set devLogsToFileEnabled(bool value) => saveBool('devLogsToFileEnabled', value);

  // Last app version / firmware revision / device uptime the debug log was
  // stamped with. Their only job is to mark a *change* — see
  // DebugLogManager.logAppStart / logDeviceVersion. Updated whether or not file
  // logging is on, so they always describe reality rather than the last time
  // somebody happened to be watching.
  String get lastLoggedAppVersion => getString('lastLoggedAppVersion');
  set lastLoggedAppVersion(String value) => saveString('lastLoggedAppVersion', value);

  String get lastLoggedFirmwareRevision => getString('lastLoggedFirmwareRevision');
  set lastLoggedFirmwareRevision(String value) => saveString('lastLoggedFirmwareRevision', value);

  // The device's live uptime (0x0062) at the last connect. A reading LOWER than
  // this one means the Omi rebooted in between — the only reboot signal that
  // survives the app being closed, and the one that catches a DFU whose version
  // string did not change.
  int get lastSeenDeviceUptimeMs => getInt('lastSeenDeviceUptimeMs', defaultValue: 0);
  set lastSeenDeviceUptimeMs(int value) => saveInt('lastSeenDeviceUptimeMs', value);

  // When true, the app holds a wakelock while open so the screen never sleeps
  // (useful for babysitting a foreground sync/processing run).
  bool get keepScreenOn => getBool('keepScreenOn');
  set keepScreenOn(bool value) => saveBool('keepScreenOn', value);

  // When true, the Diagnostics panel (SD-write drops + BLE connect failures) is
  // shown on Debug Tools and polls the device's diagnostics counters every 2s.
  // Off by default so the BLE read never runs unless the user is investigating.
  // (Key kept as 'showSdWriteDrops' to preserve existing users' setting.)
  bool get showSdWriteDrops => getBool('showSdWriteDrops', defaultValue: false);
  set showSdWriteDrops(bool value) => saveBool('showSdWriteDrops', value);

  // Android only. Defaults ON. The app registers as a system companion of the Omi. This
  // does NOT arm CompanionDevice *presence observation* (that path was removed entirely —
  // it was the OEM-contention "toggle Bluetooth to reconnect" wedge on OnePlus/Oppo/Realme);
  // only a bare association is held. Companion status exempts the app from aggressive OEM
  // battery-manager freezing/killing and grants background-FGS-start, so when a ghost-GATT
  // wedge occurs the foreground service's recovery machinery (purge + advertising probe +
  // backoff reconnect) keeps running and clears it, instead of the app being frozen until
  // the next sync alarm or a manual BT toggle. When true, the app creates the association on
  // first connect (a one-time system pairing dialog via find_devices / the settings toggle;
  // manageDevice never disassociates). When false, no association is created and any existing
  // one is cleared on the next connect, so the app connects purely by address + bond — the
  // fallback for the rare OEM where a bare association still hurts. The native
  // OmiBleForegroundService default MUST match this. Read natively as
  // flutter.companionDeviceEnabled.
  bool get companionDeviceEnabled => getBool('companionDeviceEnabled', defaultValue: true);
  set companionDeviceEnabled(bool value) => saveBool('companionDeviceEnabled', value);

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
